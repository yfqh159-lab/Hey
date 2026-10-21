import {
  APP_MODE_VPN,
  APP_MODE_PROXY_ONLY,
  ConnectionStatus,
  RuntimeStats,
  normalizeAppRuntimeMode
} from './Profile';

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
