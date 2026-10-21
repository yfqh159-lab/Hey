import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { APP_MODE_PROXY_ONLY, AppRuntimeMode, normalizeAppRuntimeMode } from './Profile';

/**
 * 内核选择（全局开关，预览功能）。
 *
 * 用独立的轻量 preferences 存储，而不是塞进庞大的 AppSettings 管线 —— 把 sing-box
 * 这个预览特性隔离开，便于以后正式化或回退。当前是 Xray / sing-box 二选一的全局开关。
 */
export type CoreType = 'xray' | 'singbox';

export const CORE_TYPE_XRAY: CoreType = 'xray';
export const CORE_TYPE_SINGBOX: CoreType = 'singbox';
export const DEFAULT_CORE_TYPE: CoreType = CORE_TYPE_XRAY;

const PREFERENCES_NAME: string = 'hey_core_selection';
const CORE_TYPE_KEY: string = 'core_type';

export function normalizeCoreType(value: string | undefined): CoreType {
  return value === CORE_TYPE_SINGBOX ? CORE_TYPE_SINGBOX : CORE_TYPE_XRAY;
}

export function isSingboxCore(value: CoreType | string | undefined): boolean {
  return normalizeCoreType(value as string | undefined) === CORE_TYPE_SINGBOX;
}

// 仅 sing-box 内核支持的协议：Xray-core 没有对应 outbound（如 anytls / tuic / hysteria2）。
// 命中这些协议的节点必须用 sing-box 跑，无论全局内核开关选的是什么——否则丢给
// Xray 会因找不到 outbound handler 而启动失败。
const SINGBOX_ONLY_PROTOCOLS: Array<string> = ['anytls', 'tuic', 'hysteria2'];

export function isSingboxOnlyProtocol(protocol: string | undefined): boolean {
  if (protocol === undefined) {
    return false;
  }
  return SINGBOX_ONLY_PROTOCOLS.indexOf(protocol.trim().toLowerCase()) >= 0;
}

/**
 * 解析一次连接真正使用的内核。
 *
 * 本地代理目前由主 Xray 内核提供用户配置的 SOCKS/HTTP 入站；sing-box 预览只实现了
 * VPN 内部固定端口。旧设置即使还保存着 sing-box，也不能让普通节点误入 VPN-only
 * 分支。sing-box 独有协议仍交给 sing-box，使调用方得到明确的模式不支持错误。
 */
export function resolveRuntimeCoreType(
  selectedCore: CoreType | string | undefined,
  protocol: string | undefined,
  runtimeMode: AppRuntimeMode | string | undefined
): CoreType {
  if (isSingboxOnlyProtocol(protocol)) {
    return CORE_TYPE_SINGBOX;
  }
  if (normalizeAppRuntimeMode(runtimeMode) === APP_MODE_PROXY_ONLY) {
    return CORE_TYPE_XRAY;
  }
  return normalizeCoreType(selectedCore as string | undefined);
}

// 为跑 protocol 需要临时切换到的内核；currentCore 已能支持则返回 null。
// 目前只有 anytls / tuic / hysteria2 是 sing-box 独有：Xray 内核下需切 sing-box；
// sing-box 内核覆盖全部协议，无需反向切换。
export function requiredCoreForProtocol(
  currentCore: CoreType | string | undefined,
  protocol: string | undefined,
  runtimeMode?: AppRuntimeMode | string
): CoreType | null {
  // 本地代理不展示“一次性切到 sing-box”的确认：该预览内核目前没有用户可见的
  // 本地代理入站。启动层会对 sing-box 独有协议返回明确的不支持提示。
  if (normalizeAppRuntimeMode(runtimeMode) === APP_MODE_PROXY_ONLY) {
    return null;
  }
  if (!isSingboxCore(currentCore) && isSingboxOnlyProtocol(protocol)) {
    return CORE_TYPE_SINGBOX;
  }
  return null;
}

export class CoreSelectionStore {
  static async load(context: common.Context): Promise<CoreType> {
    try {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const raw = (await store.get(CORE_TYPE_KEY, DEFAULT_CORE_TYPE)).toString();
      return normalizeCoreType(raw);
    } catch (error) {
      return DEFAULT_CORE_TYPE;
    }
  }

  static async save(context: common.Context, coreType: CoreType): Promise<CoreType> {
    const normalized = normalizeCoreType(coreType);
    try {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      await store.put(CORE_TYPE_KEY, normalized);
      await store.flush();
    } catch (error) {
      // ignore
    }
    return normalized;
  }
}
