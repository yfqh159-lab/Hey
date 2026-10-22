import { DEFAULT_LANGUAGE, normalizeLanguage, translate } from './I18n';
import {
  APP_MODE_PROXY_ONLY,
  APP_MODE_VPN,
  AppLanguage,
  AppRuntimeMode,
  ConnectionStatus,
  isProxyOnlyRuntimeMode,
  normalizeAppRuntimeMode
} from './Profile';

export const CONTROL_CARD_FORM_NAME: string = 'HeyControlCard';
export const CONTROL_CARD_TOGGLE_URI: string = 'hey://toggle';
export const CONTROL_CARD_START_URI: string = 'hey://start';
export const CONTROL_CARD_STOP_URI: string = 'hey://stop';
export const CONTROL_CARD_SCAN_URI: string = 'hey://scan';

export interface ControlCardFormData {
  language: AppLanguage;
  // 仅用于系统刷新卡片时核对跨进程 VPN 心跳，不在卡片上展示。
  vpnBacked: boolean;
  // 供系统单独拉起卡片或后台任务时恢复真实模式/过渡态，不在卡片上展示。
  runtimeStatus: ConnectionStatus;
  runtimeMode: AppRuntimeMode;
  // 仅用于跨进程探测前后识别同一运行会话，不在卡片上展示。
  runtimeStartedAt: number;
  // 停止/回滚未确认完成时只允许继续清理，不得把错误态呈现为可启动。
  cleanupRequired: boolean;
  appName: string;
  subtitle: string;
  toggleUri: string;
  startUri: string;
  stopUri: string;
  scanUri: string;
  statusLabel: string;
  statusDetail: string;
  primaryActionLabel: string;
  primaryActionUri: string;
  statusColor: string;
  statusBackground: string;
  primaryColor: string;
  primaryTextColor: string;
}

export function buildControlCardFormData(
  language: AppLanguage = DEFAULT_LANGUAGE,
  status: ConnectionStatus = ConnectionStatus.IDLE,
  elapsedText: string = '',
  lastError: string = '',
  vpnBacked: boolean = false,
  runtimeMode: AppRuntimeMode = APP_MODE_VPN,
  cleanupRequired: boolean = false,
  runtimeStartedAt: number = 0
): ControlCardFormData {
  const running = status === ConnectionStatus.RUNNING;
  const busy = status === ConnectionStatus.STARTING || status === ConnectionStatus.STOPPING;
  const error = status === ConnectionStatus.ERROR;
  const stopAction = running || busy || cleanupRequired;
  return {
    language,
    vpnBacked: running && vpnBacked,
    runtimeStatus: status,
    runtimeMode: normalizeAppRuntimeMode(runtimeMode, APP_MODE_VPN),
    runtimeStartedAt: normalizeRuntimeStartedAt(runtimeStartedAt),
    cleanupRequired,
    appName: 'Hey',
    subtitle: translate(language, 'control.card.subtitle'),
    toggleUri: CONTROL_CARD_TOGGLE_URI,
    startUri: CONTROL_CARD_START_URI,
    stopUri: CONTROL_CARD_STOP_URI,
    scanUri: CONTROL_CARD_SCAN_URI,
    statusLabel: statusLabel(language, status),
    statusDetail: statusDetail(language, status, elapsedText, lastError),
    primaryActionLabel: stopAction ? translate(language, 'action.stop') : translate(language, 'action.start'),
    primaryActionUri: stopAction ? CONTROL_CARD_STOP_URI : CONTROL_CARD_START_URI,
    statusColor: statusColor(running, busy, error),
    statusBackground: statusBackground(running, busy, error),
    primaryColor: stopAction ? '#EF4444' : '#F97316',
    primaryTextColor: '#FFFFFF'
  };
}

export function normalizeControlCardFormData(data: ControlCardFormData | null | undefined): ControlCardFormData {
  if (data === null || data === undefined) {
    return buildControlCardFormData();
  }
  const fallback = buildControlCardFormData();
  const storedPrimaryActionUri = normalizePrimaryActionUri(data.primaryActionUri);
  const runtimeStatus = normalizeRuntimeStatus(data.runtimeStatus, storedPrimaryActionUri);
  const cleanupRequired = typeof data.cleanupRequired === 'boolean' ? data.cleanupRequired : false;
  const runtimeStartedAt = normalizeRuntimeStartedAt(data.runtimeStartedAt);
  const mustStop = cleanupRequired || runtimeStatus === ConnectionStatus.STARTING ||
    runtimeStatus === ConnectionStatus.RUNNING || runtimeStatus === ConnectionStatus.STOPPING;
  const primaryActionUri = mustStop ? CONTROL_CARD_STOP_URI : storedPrimaryActionUri;
  const vpnBacked = typeof data.vpnBacked === 'boolean'
    ? data.vpnBacked
    : storedPrimaryActionUri === CONTROL_CARD_STOP_URI;
  const fallbackMode = storedPrimaryActionUri === CONTROL_CARD_STOP_URI && !vpnBacked
    ? APP_MODE_PROXY_ONLY : APP_MODE_VPN;
  return {
    language: normalizeLanguage(data.language),
    // 旧版本没有该字段；若旧卡片的主动作是“停止”，按 VPN 会话处理并要求心跳复核，
    // 宁可纠正为未连接，也不能长期保留一个无法证明的运行状态。
    vpnBacked,
    runtimeStatus,
    runtimeMode: normalizeAppRuntimeMode(data.runtimeMode, fallbackMode),
    runtimeStartedAt,
    cleanupRequired,
    appName: nonEmpty(data.appName, fallback.appName),
    subtitle: nonEmpty(data.subtitle, fallback.subtitle),
    // Card actions are executable Wants. Persisted presentation data must never
    // be able to replace these with an arbitrary external URI.
    toggleUri: CONTROL_CARD_TOGGLE_URI,
    startUri: CONTROL_CARD_START_URI,
    stopUri: CONTROL_CARD_STOP_URI,
    scanUri: CONTROL_CARD_SCAN_URI,
    statusLabel: nonEmpty(data.statusLabel, fallback.statusLabel),
    statusDetail: nonEmpty(data.statusDetail, fallback.statusDetail),
    primaryActionLabel: mustStop
      ? translate(normalizeLanguage(data.language), 'action.stop')
      : nonEmpty(data.primaryActionLabel, fallback.primaryActionLabel),
    primaryActionUri,
    statusColor: nonEmpty(data.statusColor, fallback.statusColor),
    statusBackground: nonEmpty(data.statusBackground, fallback.statusBackground),
    primaryColor: mustStop ? '#EF4444' : nonEmpty(data.primaryColor, fallback.primaryColor),
    primaryTextColor: nonEmpty(data.primaryTextColor, fallback.primaryTextColor)
  };
}

export function isControlCardLocalProxyRunning(data: ControlCardFormData): boolean {
  return data.runtimeStatus === ConnectionStatus.RUNNING &&
    isProxyOnlyRuntimeMode(data.runtimeMode) &&
    data.primaryActionUri === CONTROL_CARD_STOP_URI;
}

export function sameControlCardRuntimeIdentity(
  left: ControlCardFormData,
  right: ControlCardFormData
): boolean {
  return left.runtimeStatus === right.runtimeStatus && left.runtimeMode === right.runtimeMode &&
    left.runtimeStartedAt === right.runtimeStartedAt && left.vpnBacked === right.vpnBacked &&
    left.cleanupRequired === right.cleanupRequired && left.primaryActionUri === right.primaryActionUri;
}

function normalizeRuntimeStartedAt(value: number | undefined): number {
  return value !== undefined && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

function normalizeRuntimeStatus(value: ConnectionStatus | undefined, primaryActionUri: string): ConnectionStatus {
  switch (value) {
    case ConnectionStatus.IDLE:
    case ConnectionStatus.STARTING:
    case ConnectionStatus.RUNNING:
    case ConnectionStatus.STOPPING:
    case ConnectionStatus.ERROR:
      return value;
    default:
      return primaryActionUri === CONTROL_CARD_STOP_URI ? ConnectionStatus.RUNNING : ConnectionStatus.IDLE;
  }
}

function statusLabel(language: AppLanguage, status: ConnectionStatus): string {
  switch (status) {
    case ConnectionStatus.STARTING:
      return translate(language, 'status.starting');
    case ConnectionStatus.RUNNING:
      return translate(language, 'status.running');
    case ConnectionStatus.STOPPING:
      return translate(language, 'status.stopping');
    case ConnectionStatus.ERROR:
      return translate(language, 'status.error');
    default:
      return translate(language, 'status.idle');
  }
}

function statusDetail(language: AppLanguage, status: ConnectionStatus, elapsedText: string, lastError: string): string {
  if (status === ConnectionStatus.RUNNING) {
    const elapsed = elapsedText.length > 0 ? elapsedText : '00:00';
    return `${translate(language, 'home.duration')} ${elapsed}`;
  }
  if (status === ConnectionStatus.STARTING || status === ConnectionStatus.STOPPING) {
    return translate(language, 'home.busy');
  }
  if (status === ConnectionStatus.ERROR) {
    return lastError.length > 0 ? lastError : translate(language, 'status.error');
  }
  return translate(language, 'home.ready');
}

function statusColor(running: boolean, busy: boolean, error: boolean): string {
  if (running) {
    return '#15803D';
  }
  if (busy) {
    return '#B45309';
  }
  if (error) {
    return '#B91C1C';
  }
  return '#9A3412';
}

function statusBackground(running: boolean, busy: boolean, error: boolean): string {
  if (running) {
    return '#DCFCE7';
  }
  if (busy) {
    return '#FEF3C7';
  }
  if (error) {
    return '#FEE2E2';
  }
  return '#FED7AA';
}

function nonEmpty(value: Object | undefined | null, fallback: string): string {
  if (typeof value !== 'string' || (value as string).length === 0) {
    return fallback;
  }
  return value as string;
}

function normalizePrimaryActionUri(value: Object | undefined | null): string {
  return value === CONTROL_CARD_STOP_URI ? CONTROL_CARD_STOP_URI : CONTROL_CARD_START_URI;
}
