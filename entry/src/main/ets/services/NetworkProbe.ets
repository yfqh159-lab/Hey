// 网络能力探针 —— 隔离 HarmonyOS 系统 API（connection / wifiManager / 权限）
//
// 只提供「读」和「权限」能力，不含任何决策逻辑（决策在 core/NetworkAutomation.ets）。
// 关键点：判 WiFi 用 wifiManager.isConnected()（物理层，不受自身 VPN 掩盖底层默认网影响），
// 判蜂窝用 getAllNets 跳过 BEARER_VPN 后的底层承载。

import { connection } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import {
  NetContext,
  NetKind,
  NET_KIND_CELLULAR,
  NET_KIND_NONE,
  NET_KIND_OTHER,
  NET_KIND_WIFI
} from '../core/NetworkAutomation';

// SSID/扫描只需模糊定位即可；请求模糊定位以尽量少打扰用户
const LOCATION_PERMISSION: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';

export interface WifiScanEntry {
  ssid: string;
  rssi: number;
}

interface UnderlyingNetworkSnapshot {
  kind: NetKind;
  networkId?: number;
}

interface NetworkHandleLike {
  netId?: number;
}

export class NetworkProbe {
  /** 读当前网络上下文（承载类型 + WiFi SSID）。任何异常都安全回退到 none。 */
  static async readCurrentNetContext(): Promise<NetContext> {
    const underlying = await NetworkProbe.readUnderlyingNetwork();
    // 1) WiFi 物理已连接（不受自身 VPN 影响）
    let wifiConnected = false;
    try {
      wifiConnected = wifiManager.isConnected();
    } catch (error) {
      wifiConnected = false;
    }
    if (wifiConnected) {
      const ssid = await NetworkProbe.readCurrentSsid();
      return {
        kind: NET_KIND_WIFI,
        ssid: ssid,
        networkId: underlying.kind === NET_KIND_WIFI ? underlying.networkId : undefined
      };
    }
    // 2) 否则看底层承载（跳过自身 VPN）
    return { kind: underlying.kind, networkId: underlying.networkId };
  }

  /** 读当前连接的 WiFi SSID；无权限/隐藏/异常时返回 undefined。 */
  static async readCurrentSsid(): Promise<string | undefined> {
    try {
      const info = await wifiManager.getLinkedInfo();
      const ssid = info.ssid;
      if (ssid === undefined || ssid.length === 0 || ssid === 'unknown ssid') {
        return undefined;
      }
      return ssid;
    } catch (error) {
      return undefined;
    }
  }

  /** 读系统最近一次扫描到的周边网络（去重、按信号强度降序）。无权限/异常时返回空数组。 */
  static readScanResults(): WifiScanEntry[] {
    try {
      const list = wifiManager.getScanInfoList();
      const seen = new Set<string>();
      const result: WifiScanEntry[] = [];
      for (let index = 0; index < list.length; index++) {
        const ssid = list[index].ssid;
        if (ssid === undefined || ssid.length === 0 || seen.has(ssid)) {
          continue;
        }
        seen.add(ssid);
        result.push({ ssid: ssid, rssi: list[index].rssi });
      }
      result.sort((a: WifiScanEntry, b: WifiScanEntry) => b.rssi - a.rssi);
      return result;
    } catch (error) {
      return [];
    }
  }

  /** 是否已授予（模糊）定位权限。 */
  static async hasLocationPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      const tokenId = bundleInfo.appInfo.accessTokenId;
      const status = await atManager.checkAccessToken(tokenId, LOCATION_PERMISSION);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      return false;
    }
  }

  /** 向用户申请定位权限（需 UIAbility 上下文）。返回是否已授予。 */
  static async requestLocationPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context, [LOCATION_PERMISSION]);
      const authResults = result.authResults;
      if (authResults.length === 0) {
        return false;
      }
      for (let index = 0; index < authResults.length; index++) {
        if (authResults[index] !== 0) {
          return false;
        }
      }
      return true;
    } catch (error) {
      return false;
    }
  }

  private static async readUnderlyingNetwork(): Promise<UnderlyingNetworkSnapshot> {
    try {
      const nets = await connection.getAllNets();
      let hasWifi = false;
      let hasCellular = false;
      let hasOther = false;
      let wifiId: number | undefined = undefined;
      let cellularId: number | undefined = undefined;
      let otherId: number | undefined = undefined;
      for (let index = 0; index < nets.length; index++) {
        const caps = connection.getNetCapabilitiesSync(nets[index]);
        const bearers = caps.bearerTypes ?? [];
        if (bearers.includes(connection.NetBearType.BEARER_VPN)) {
          continue; // 跳过自身 VPN 隧道
        }
        const networkId = NetworkProbe.readNetworkId(nets[index]);
        if (bearers.includes(connection.NetBearType.BEARER_WIFI)) {
          hasWifi = true;
          wifiId = NetworkProbe.preferStableNetworkId(wifiId, networkId);
          continue;
        }
        if (bearers.includes(connection.NetBearType.BEARER_CELLULAR)) {
          hasCellular = true;
          cellularId = NetworkProbe.preferStableNetworkId(cellularId, networkId);
        } else {
          hasOther = true;
          otherId = NetworkProbe.preferStableNetworkId(otherId, networkId);
        }
      }
      if (hasWifi) {
        return { kind: NET_KIND_WIFI, networkId: wifiId };
      }
      if (hasCellular) {
        return { kind: NET_KIND_CELLULAR, networkId: cellularId };
      }
      if (hasOther) {
        return { kind: NET_KIND_OTHER, networkId: otherId };
      }
      return { kind: NET_KIND_NONE };
    } catch (error) {
      return { kind: NET_KIND_NONE };
    }
  }

  private static readNetworkId(handle: Object): number | undefined {
    const value = (handle as NetworkHandleLike).netId;
    return value !== undefined && Number.isFinite(value) && value >= 0 ? Math.floor(value) : undefined;
  }

  // getAllNets() 的顺序不保证稳定；同一承载存在多个句柄时固定选择最小 id，避免假变化。
  private static preferStableNetworkId(current: number | undefined, candidate: number | undefined): number | undefined {
    if (candidate === undefined) {
      return current;
    }
    return current === undefined ? candidate : Math.min(current, candidate);
  }
}
