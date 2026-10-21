// 网络场景自动化 —— 纯决策器
//
// 根据当前网络（WiFi SSID / 蜂窝 / 其他）+ 用户指定的网络清单，
// 决定是否自动断开隧道。只做断开，不自动建立连接。
// 全程幂等：期望态==当前态时返回 noop，绝不与用户较劲。
//
// 本文件为纯函数、无任何系统 API 依赖，可被 LocalUnit 单测直接覆盖。

// 当前网络承载类型
export type NetKind = 'wifi' | 'cellular' | 'other' | 'none';
export const NET_KIND_WIFI: NetKind = 'wifi';
export const NET_KIND_CELLULAR: NetKind = 'cellular';
export const NET_KIND_OTHER: NetKind = 'other';
export const NET_KIND_NONE: NetKind = 'none';

// 决策动作。只做「断开」——自动建立连接不在本应用的能力范围内。
export type AutoAction = 'disconnect' | 'noop';
export const NET_ACTION_DISCONNECT: AutoAction = 'disconnect';
export const NET_ACTION_NOOP: AutoAction = 'noop';

// 当前网络上下文；ssid 仅 wifi 有意义，拿不到（无权限/隐藏 SSID）时为 undefined。
// networkId 是系统分配的非持久网络句柄，只用于区分同类型承载的切换，不参与可信网络判断。
export interface NetContext {
  kind: NetKind;
  ssid?: string;
  networkId?: number;
}

export interface UnderlyingNetworkCandidate {
  kind: NetKind;
  networkId?: number;
  validated: boolean;
}

/**
 * 网络场景评估签名：SSID 可见性改变时也重新判断可信网络；不同底层 NetHandle 同样
 * 会触发评估。该签名只在进程内比较，不落盘、不作为设备或网络身份。
 */
export function networkContextSignature(ctx: NetContext): string {
  const networkId = ctx.networkId === undefined ? '' : `${ctx.networkId}`;
  return `${ctx.kind}|${ctx.ssid ?? ''}|${networkId}`;
}

/**
 * 真实承载去重签名：有 NetHandle 时以 kind + handle 为准，忽略同一承载上 SSID 因
 * 权限/系统抖动产生的可见性变化；拿不到 handle 时才用 SSID 区分同类 Wi-Fi。
 */
export function networkTransportSignature(ctx: NetContext): string {
  if (ctx.networkId !== undefined) {
    return `${ctx.kind}|id:${ctx.networkId}`;
  }
  return `${ctx.kind}|ssid:${ctx.ssid ?? ''}`;
}

/**
 * VPN 成为系统默认网络时，从剩余物理网络候选中选择最可能的真实承载。
 * 已通过系统互联网验证的网络优先；同一层级沿用 Wi-Fi、蜂窝、其他的产品优先级，
 * 同类多个句柄固定选择最小 ID，避免 getAllNets 顺序变化制造假切网事件。
 */
export function selectUnderlyingNetworkCandidate(candidates: Array<UnderlyingNetworkCandidate>): NetContext {
  const kinds: Array<NetKind> = [NET_KIND_WIFI, NET_KIND_CELLULAR, NET_KIND_OTHER];
  for (let validatedIndex = 0; validatedIndex < 2; validatedIndex++) {
    const requireValidated = validatedIndex === 0;
    for (let kindIndex = 0; kindIndex < kinds.length; kindIndex++) {
      const kind = kinds[kindIndex];
      let selectedId: number | undefined = undefined;
      let found = false;
      for (let index = 0; index < candidates.length; index++) {
        const candidate = candidates[index];
        if (candidate.kind !== kind || (requireValidated && !candidate.validated)) {
          continue;
        }
        found = true;
        if (candidate.networkId !== undefined &&
          (selectedId === undefined || candidate.networkId < selectedId)) {
          selectedId = candidate.networkId;
        }
      }
      if (found) {
        return { kind, networkId: selectedId };
      }
    }
  }
  return { kind: NET_KIND_NONE };
}

// 自动化配置（来自 AppSettings 的相关子集）
export interface NetAutomationConfig {
  enabled: boolean;
  trustedSsids: string[];
  cellularTrusted: boolean;
}

/**
 * 判定当前网络是否「可信」。
 * - 蜂窝：由 cellularTrusted 决定。
 * - WiFi：SSID 命中可信列表则可信；拿不到 SSID 按「不可信」处理（fail-secure，宁可代理）。
 * - none/other：不参与，返回 false。
 */
export function isTrustedNetwork(ctx: NetContext, cfg: NetAutomationConfig): boolean {
  if (ctx.kind === NET_KIND_CELLULAR) {
    return cfg.cellularTrusted;
  }
  if (ctx.kind === NET_KIND_WIFI) {
    const ssid = ctx.ssid;
    if (ssid === undefined || ssid.length === 0) {
      return false;
    }
    return cfg.trustedSsids.includes(ssid);
  }
  return false;
}

/**
 * 返回应执行的动作。幂等——期望态已满足则返回 noop。
 * @param currentlyRunning VPN 隧道当前是否在运行
 */
export function decideNetAutomationAction(
  ctx: NetContext,
  cfg: NetAutomationConfig,
  currentlyRunning: boolean
): AutoAction {
  if (!cfg.enabled) {
    return NET_ACTION_NOOP;
  }
  // 无网络 / 未知承载：不动
  if (ctx.kind === NET_KIND_NONE || ctx.kind === NET_KIND_OTHER) {
    return NET_ACTION_NOOP;
  }

  // 指定网络下且正在运行时断开；其余一律不动作。
  if (isTrustedNetwork(ctx, cfg) && currentlyRunning) {
    return NET_ACTION_DISCONNECT;
  }
  return NET_ACTION_NOOP;
}

/**
 * 已运行 VPN 或本地代理的底层承载发生真实变化后，是否应重载核心连接。
 * - 可信网络自动断开优先，不能先重载后再拆隧道。
 * - `none` 是切网中的瞬时断网，等待下一个可用承载，避免在无网络时把核心重载失败。
 * - 这里只决定已有会话的内部恢复，绝不创建 VPN，也不改变用户手动停止意图。
 */
export function shouldReloadActiveCoreAfterNetworkChange(ctx: NetContext, action: AutoAction): boolean {
  return action !== NET_ACTION_DISCONNECT && ctx.kind !== NET_KIND_NONE;
}
