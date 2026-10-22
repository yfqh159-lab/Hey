import {
  APP_MODE_VPN,
  APP_MODE_PROXY_ONLY,
  ConnectionStatus,
  RuntimeStats,
  normalizeAppRuntimeMode
} from './Profile';

export const VPN_RUNTIME_UNHEALTHY_CONFIRM_MS: number = 12000;
export const VPN_RUNTIME_UNHEALTHY_OBSERVATION_GAP_MS: number = 5000;

export function shouldRestartUnhealthyVpnObservation(
  firstSeenAt: number,
  lastSeenAt: number,
  now: number,
  maxGapMs: number = VPN_RUNTIME_UNHEALTHY_OBSERVATION_GAP_MS
): boolean {
  return !Number.isFinite(firstSeenAt) || firstSeenAt <= 0 ||
    !Number.isFinite(lastSeenAt) || lastSeenAt <= 0 ||
    !Number.isFinite(now) || now <= 0 || !Number.isFinite(maxGapMs) || maxGapMs < 0 ||
    now < lastSeenAt || now - lastSeenAt > maxGapMs;
}

/**
 * 判断当前控制态是否仍可能持有核心、TUN 或本地监听器。普通配置/授权前错误没有
 * 创建数据面，允许应用网络请求直连；清理未确认的错误必须继续 fail-closed。
 */
export function runtimeMayOwnNetwork(status: ConnectionStatus, cleanupRequired: boolean): boolean {
  return status === ConnectionStatus.RUNNING || status === ConnectionStatus.STARTING ||
    status === ConnectionStatus.STOPPING || (status === ConnectionStatus.ERROR && cleanupRequired);
}

export function isVpnCleanupComplete(
  tunStopped: boolean,
  xrayStopped: boolean,
  singboxStopped: boolean,
  vpnDestroyed: boolean
): boolean {
  return tunStopped && xrayStopped && singboxStopped && vpnDestroyed;
}

/**
 * An older/parameterless Extension instance can record cleanup under a fallback session ID,
 * leaving the UI unable to match its terminal event. An explicit system stop may repair that
 * control-plane mismatch only when the persisted owner already reports every data-plane
 * component inactive and confirms that cleanup was attempted.
 */
export function canConfirmVpnReleasedAfterSystemStop(
  systemStopSucceeded: boolean,
  stateExists: boolean,
  authoritativeArtifactInvalid: boolean,
  active: boolean,
  xrayRunning: boolean,
  tunRunning: boolean,
  cleanupAttempted: boolean
): boolean {
  return systemStopSucceeded && stateExists && !authoritativeArtifactInvalid && !active &&
    !xrayRunning && !tunRunning && cleanupAttempted;
}

/**
 * 本地代理与 UI 位于同一进程，native bridge 明确报告停止时可立即判定异常；
 * bridge 的运行标志本身不代表监听器一定仍存活，后续还需 SOCKS 端口探测。
 * VPN 模式的核心在扩展进程中，必须使用跨进程心跳判断，不能走这里。
 */
export function isProxyOnlyRuntimeUnhealthy(
  mode: string | undefined,
  status: ConnectionStatus,
  stats: RuntimeStats
): boolean {
  return normalizeAppRuntimeMode(mode) === APP_MODE_PROXY_ONLY &&
    status === ConnectionStatus.RUNNING && !stats.xrayRunning;
}

/**
 * VPN 运行态连续读不到跨进程状态时才判定异常，容忍一次短暂文件替换/读取失败；
 * 本地代理不使用该状态文件，空闲和启停中也不能据此触发清理。
 */
export function isMissingVpnRuntimeStateUnhealthy(
  mode: string | undefined,
  status: ConnectionStatus,
  missingSamples: number,
  sampleLimit: number = 3
): boolean {
  return normalizeAppRuntimeMode(mode) === APP_MODE_VPN &&
    status === ConnectionStatus.RUNNING && sampleLimit > 0 && missingSamples >= sampleLimit;
}

/**
 * active 状态仅因心跳过期或一次采样报告数据面不完整时，先等待 Extension 恢复心跳或
 * 完成自己的双采样清理。锁屏恢复后 ArkTS 定时器可能晚于 UI 恢复，不能首帧就拆掉隧道。
 * inactive 是明确停止，不走此确认窗口；确认窗口也不代表自动重连。
 */
export function shouldCleanupUnhealthyVpnRuntimeState(
  active: boolean,
  healthy: boolean,
  firstSeenAt: number,
  now: number,
  confirmMs: number = VPN_RUNTIME_UNHEALTHY_CONFIRM_MS
): boolean {
  return active && !healthy && firstSeenAt > 0 && now >= firstSeenAt && confirmMs >= 0 &&
    now - firstSeenAt >= confirmMs;
}

/**
 * 只有当前 VPN 会话产生的 Extension 错误才能改变连接状态。订阅后台任务等组件共用
 * 诊断文件，它们的错误只应出现在日志里；本地代理健康由进程内探测单独判断。
 */
export function shouldApplyVpnDiagnosticError(
  mode: string | undefined,
  status: ConnectionStatus,
  startedAt: number,
  eventAt: number,
  eventLevel: string,
  eventSource: string,
  expectedSessionId: string,
  eventDetails: string | undefined
): boolean {
  // STARTING 的错误由 ConnectionController.start() 自己消费并回滚；刷新定时器不能
  // 同时进入停止流程，否则会与尚未返回的启动协程争用状态。
  if (normalizeAppRuntimeMode(mode) !== APP_MODE_VPN || status !== ConnectionStatus.RUNNING || startedAt <= 0 ||
    !Number.isFinite(eventAt) || eventAt <= 0 || eventLevel !== 'error' || eventSource !== 'vpn' ||
    expectedSessionId.length === 0 ||
    eventDetails === undefined) {
    return false;
  }
  const marker = `session=${expectedSessionId}`;
  return eventDetails === marker || eventDetails.startsWith(`${marker};`);
}

/**
 * Flow/core statistics are state, not merely log text. Accept them only from the exact active
 * VPN session; timestamps alone are insufficient when the wall clock changes or an old append
 * becomes visible after a mode/session switch.
 */
export function shouldApplyVpnDiagnosticStats(
  mode: string | undefined,
  status: ConnectionStatus,
  startedAt: number,
  eventAt: number,
  eventSource: string,
  expectedSessionId: string,
  eventSessionId: string | undefined
): boolean {
  return normalizeAppRuntimeMode(mode) === APP_MODE_VPN && status === ConnectionStatus.RUNNING &&
    startedAt > 0 && Number.isFinite(eventAt) && eventAt > 0 && eventSource === 'vpn-stats' &&
    expectedSessionId.length > 0 && eventSessionId === expectedSessionId;
}
