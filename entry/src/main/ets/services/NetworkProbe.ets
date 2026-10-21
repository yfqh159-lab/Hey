// 网络能力探针 —— 隔离 HarmonyOS 系统 API（connection / wifiManager / 权限）
//
// 只提供「读」和「权限」能力，不含任何决策逻辑（决策在 core/NetworkAutomation.ets）。
// 关键点：从 getAllNets 跳过 BEARER_VPN，并优先选择系统已验证可上网的物理承载；
// wifiManager 只补充 SSID，不能让“已关联但不可上网”的 Wi-Fi 覆盖实际蜂窝出口。

import { connection } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import {
  NetContext,
  NetKind,
  NET_KIND_CELLULAR,
  NET_KIND_NONE,
  NET_KIND_OTHER,
  NET_KIND_WIFI,
  UnderlyingNetworkCandidate,
  selectUnderlyingNetworkCandidate
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
    if (underlying.kind === NET_KIND_WIFI) {
      // 承载选择以 NetworkKit 的已验证物理网络为准；wifiManager 仅补充可能受定位
      // 权限限制的 SSID，不再单凭 isConnected() 把无互联网 Wi-Fi 当成真实出口。
      let ssid: string | undefined = undefined;
      try {
        if (wifiManager.isConnected()) {
          ssid = await NetworkProbe.readCurrentSsid();
        }
      } catch (error) {
        ssid = undefined;
      }
      return {
        kind: NET_KIND_WIFI,
        ssid: ssid,
        networkId: underlying.networkId
      };
    }
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
      // 非 VPN（Proxy-only/空闲）时，官方 getDefaultNet 就是系统实际选中的出网承载，
      // 优先使用它可避免 Wi-Fi 与蜂窝同时存在时凭固定顺序猜错。VPN 运行时默认网络
      // 可能是隧道本身，此时跳过并在全部网络中筛选已验证的物理承载。
      try {
        const defaultNet = await connection.getDefaultNet();
        const defaultCaps = connection.getNetCapabilitiesSync(defaultNet);
        const defaultBearers = defaultCaps.bearerTypes ?? [];
        if (defaultBearers.length > 0 && !defaultBearers.includes(connection.NetBearType.BEARER_VPN)) {
          const defaultId = NetworkProbe.readNetworkId(defaultNet);
          if (defaultBearers.includes(connection.NetBearType.BEARER_WIFI)) {
            return { kind: NET_KIND_WIFI, networkId: defaultId };
          }
          if (defaultBearers.includes(connection.NetBearType.BEARER_CELLULAR)) {
            return { kind: NET_KIND_CELLULAR, networkId: defaultId };
          }
          return { kind: NET_KIND_OTHER, networkId: defaultId };
        }
      } catch (error) {
        // 无默认网络或设备实现不允许查询时，继续走 getAllNets 的物理承载回退。
      }

      const nets = await connection.getAllNets();
      const candidates = new Array<UnderlyingNetworkCandidate>();
      for (let index = 0; index < nets.length; index++) {
        const caps = connection.getNetCapabilitiesSync(nets[index]);
        const bearers = caps.bearerTypes ?? [];
        if (bearers.includes(connection.NetBearType.BEARER_VPN)) {
          continue; // 跳过自身 VPN 隧道
        }
        const networkId = NetworkProbe.readNetworkId(nets[index]);
        const networkCaps = caps.networkCap ?? [];
        const validated = networkCaps.includes(connection.NetCap.NET_CAPABILITY_VALIDATED);
        if (bearers.includes(connection.NetBearType.BEARER_WIFI)) {
          candidates.push({ kind: NET_KIND_WIFI, networkId, validated });
          continue;
        }
        if (bearers.includes(connection.NetBearType.BEARER_CELLULAR)) {
          candidates.push({ kind: NET_KIND_CELLULAR, networkId, validated });
        } else {
          candidates.push({ kind: NET_KIND_OTHER, networkId, validated });
        }
      }
      return selectUnderlyingNetworkCandidate(candidates);
    } catch (error) {
      return { kind: NET_KIND_NONE };
    }
  }

  private static readNetworkId(handle: Object): number | undefined {
    const value = (handle as NetworkHandleLike).netId;
    return value !== undefined && Number.isFinite(value) && value >= 0 ? Math.floor(value) : undefined;
  }

}
