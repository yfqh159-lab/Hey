import { common } from '@kit.AbilityKit';
import { DEFAULT_LANGUAGE, translate } from '../../core/I18n';
import { shouldExposeLocalHttpProxy } from '../../core/LocalProxy';
import { isProxyOnlyRuntimeUnhealthy } from '../../core/RuntimeHealth';
import { APP_MODE_PROXY_ONLY, APP_MODE_VPN, AppLanguage, AppRuntimeMode, AppSettings, ConnectionStatus, normalizeAppRuntimeMode, ProxyProfile, RuntimeStats } from '../../core/Profile';
import { LOCAL_HTTP_PROXY_PORT, VPN_INTERNAL_HTTP_PROXY_PORT } from '../../core/XrayConfig';
import { CoreSelectionStore, isSingboxCore } from '../../core/CoreSelection';
import { ConnectionController, ConnectionSnapshot } from '../../services/ConnectionController';
import { NetSceneStopFlag } from '../../services/NetSceneStopFlag';
import { isPersistedVpnRuntimeHealthy, VpnRuntimeStateStore } from '../../services/VpnRuntimeStateStore';
import { DiagnosticEvent, DiagnosticLog } from '../../services/DiagnosticLog';
import { clearCoreLog, readCoreLogEntries } from '../../services/CoreLogReader';
import { LogEntry, normalizeLogLevel } from '../logs/LogModel';
import { fetchRemoteIpInfo, RemoteIpInfoResult } from '../../services/RemoteIpInfo';
import { probeRuntimeSocksHealth } from '../../services/RuntimeHealthProbe';
import { measureRuntimeProfileDelay, RuntimeDelayResult } from '../../services/RuntimeDelay';
import { connectionStatusBackground, connectionStatusColor, formatClockTime, formatDuration } from '../../utils/Formatters';
import { formatOne, localizedConnectionStatus, localizeCoreMessage, localizeDiagnosticHeartbeat } from '../../utils/LocalizationPresenter';
import { redactDiagnosticText } from '../../core/DiagnosticRedaction';

const EMPTY_STATS: RuntimeStats = {
  uploadBytes: 0,
  downloadBytes: 0,
  xrayRunning: false,
  tunRunning: false,
  lastMessage: translate(DEFAULT_LANGUAGE, 'runtime.nativeBridgeNotQueried')
};
const LOCAL_PROXY_HEALTH_INTERVAL_MS: number = 5000;
const LOCAL_PROXY_UNHEALTHY_SAMPLE_LIMIT: number = 2;

export interface RuntimeViewState {
  status: ConnectionStatus;
  runtimeMode: AppRuntimeMode;
  startedAt: number;
  elapsedText: string;
  lastError: string;
  entries: Array<LogEntry>;
  stats: RuntimeStats;
  // 「当前连接」延迟（连接页点按测速胶囊）：>=0 为最近一次实测毫秒数，-1 未测/失败。
  connectionDelayMs: number;
  connectionDelayTesting: boolean;
  connectionDelayFailed: boolean;
  egressIp: string;
  egressIpChecking: boolean;
}

export function settingsForRecoveredVpn(settings: AppSettings): AppSettings {
  const recovered = JSON.parse(JSON.stringify(settings)) as AppSettings;
  recovered.mode = APP_MODE_VPN;
  return recovered;
}

export function recoveredVpnProfileMatches(persistedUpdatedAt: number | undefined, currentUpdatedAt: number): boolean {
  return persistedUpdatedAt === undefined || persistedUpdatedAt <= 0 || persistedUpdatedAt === currentUpdatedAt;
}

export class RuntimeController {
  private controller: ConnectionController = new ConnectionController();
  private status: ConnectionStatus = ConnectionStatus.IDLE;
  private startedAt: number = 0;
  private elapsedText: string = '00:00';
  private lastError: string = '';
  private logs: Array<LogEntry> = RuntimeController.buildReadyLogs();
  private diagnosticEntries: Array<LogEntry> = [];
  private coreEntries: Array<LogEntry> = [];
  private stats: RuntimeStats = EMPTY_STATS;
  private diagnosticRefreshing: boolean = false;
  private runtimeMode: AppRuntimeMode = APP_MODE_VPN;
  // 当前运行内核名（Xray / sing-box），心跳日志据此渲染。
  private coreLabel: string = 'Xray';
  // 本次连接实际使用的 profile/settings，供「测试当前连接」按需复测（热切换重连时随 start 更新）。
  private activeProfile: ProxyProfile | null = null;
  private activeSettings: AppSettings | null = null;
  // 「当前连接」延迟状态：连接成功后自动测一次，连接页胶囊可点按复测。
  private connectionDelayMs: number = -1;
  private connectionDelayTesting: boolean = false;
  private connectionDelayFailed: boolean = false;
  // 只保存当前会话经代理实测得到的公网 IP；断开/切换会话立即清空，避免展示旧出口。
  private egressIp: string = '';
  private egressIpChecking: boolean = false;
  private lastProxyHealthProbeAt: number = 0;
  private proxyUnhealthySampleCount: number = 0;
  private recoveredProfileUpdatedAt: number = 0;
  private recoveredProfileMismatch: boolean = false;

  async start(context: common.Context, profile: ProxyProfile, settings: AppSettings, language: AppLanguage): Promise<RuntimeViewState> {
    this.runtimeMode = normalizeAppRuntimeMode(settings.mode, APP_MODE_VPN);
    this.activeProfile = profile;
    this.activeSettings = settings;
    this.resetConnectionDelay();
    this.resetEgressIp();
    this.resetProxyHealth();
    this.resetRecoveredProfileIdentity();
    this.appendLog(this.runtimeMode === APP_MODE_PROXY_ONLY ? translate(language, 'log.startingProxy') : translate(language, 'log.startingVpn'));
    const snapshot = await this.controller.start(context, profile, settings);
    this.applySnapshot(snapshot, language);
    // 新的一次启动：清除后台自动断开标志（此后再置位才代表本次启动后的自动断开）。
    NetSceneStopFlag.clear(context);
    if (this.runtimeMode === APP_MODE_PROXY_ONLY) {
      this.appendLog(this.status === ConnectionStatus.RUNNING ? translate(language, 'log.proxyStarted') : translate(language, 'log.proxyStartIncomplete'));
    } else {
      this.appendLog(this.status === ConnectionStatus.RUNNING ? translate(language, 'log.vpnStarted') : translate(language, 'log.vpnStartIncomplete'));
    }
    this.scheduleRuntimeConnectivityInfo(context, profile, settings, language, this.startedAt);
    return this.refresh(context, language);
  }

  async stop(context: common.Context, language: AppLanguage): Promise<RuntimeViewState> {
    const stoppingMode = this.runtimeMode;
    this.resetConnectionDelay();
    this.resetEgressIp();
    this.resetProxyHealth();
    this.appendLog(stoppingMode === APP_MODE_PROXY_ONLY ? translate(language, 'log.stoppingProxy') : translate(language, 'log.stoppingVpn'));
    const snapshot = await this.controller.stop(context);
    this.applySnapshot(snapshot, language);
    if (stoppingMode === APP_MODE_PROXY_ONLY) {
      this.appendLog(this.status === ConnectionStatus.IDLE ? translate(language, 'log.proxyStopped') : translate(language, 'log.proxyStopIncomplete'));
    } else {
      this.appendLog(this.status === ConnectionStatus.IDLE ? translate(language, 'log.vpnStopped') : translate(language, 'log.vpnStopIncomplete'));
    }
    if (this.status === ConnectionStatus.IDLE) {
      this.runtimeMode = APP_MODE_VPN;
      this.activeProfile = null;
      this.activeSettings = null;
      this.resetRecoveredProfileIdentity();
    }
    return this.refresh(context, language);
  }

  // 网络场景在后台由 VPN 扩展自动断开后，本进程状态会滞留「运行中」。据跨进程标志把
  // 控制器与本地镜像一起归零，使前台读到真实态。仅在自认为运行中时生效（幂等）。
  reconcileStopped(): void {
    if (this.status !== ConnectionStatus.RUNNING) {
      return;
    }
    this.controller.reconcileStopped();
    this.status = ConnectionStatus.IDLE;
    this.startedAt = 0;
    this.elapsedText = '00:00';
    this.runtimeMode = APP_MODE_VPN;
    this.activeProfile = null;
    this.activeSettings = null;
    this.resetRecoveredProfileIdentity();
    this.resetConnectionDelay();
    this.resetEgressIp();
  }

  // 运行中按传入的新 Profile 热切换：先停后启。非运行态直接返回当前快照，调用方无需自行判断。
  // 供没有连接管线的页面（如订阅详情）复用，避免「界面显示已切换、隧道仍跑旧配置」。
  async reconnectWithProfile(context: common.Context, profile: ProxyProfile, settings: AppSettings, language: AppLanguage): Promise<RuntimeViewState> {
    if (this.status !== ConnectionStatus.RUNNING) {
      return this.snapshot();
    }
    const stopped = await this.stop(context, language);
    if (stopped.status !== ConnectionStatus.IDLE) {
      return stopped;
    }
    return this.start(context, profile, settings, language);
  }

  // UI 进程重建后，reconcilePersistedVpnState() 只接管仍存活的 VPN 会话；这里再补回当前
  // 节点/设置上下文，恢复延迟与出口 IP 观测。不会调用 start/stop，也不会改变隧道。
  attachRecoveredSession(
    context: common.Context,
    profile: ProxyProfile,
    settings: AppSettings,
    language: AppLanguage
  ): RuntimeViewState {
    if (this.status !== ConnectionStatus.RUNNING || this.activeProfile !== null) {
      return this.snapshot();
    }
    if (!recoveredVpnProfileMatches(this.recoveredProfileUpdatedAt, profile.updatedAt)) {
      if (!this.recoveredProfileMismatch) {
        this.recoveredProfileMismatch = true;
        this.appendLog(translate(language, 'runtime.vpnProfileMismatch'));
      }
      this.resetConnectionDelay();
      this.resetEgressIp();
      return this.snapshot();
    }
    const recoveredSettings = settingsForRecoveredVpn(settings);
    this.activeProfile = profile;
    this.activeSettings = recoveredSettings;
    this.resetConnectionDelay();
    this.resetEgressIp();
    this.scheduleRuntimeConnectivityInfo(context, profile, recoveredSettings, language, this.startedAt);
    return this.snapshot();
  }

  async refresh(context: common.Context, language: AppLanguage): Promise<RuntimeViewState> {
    await this.reconcilePersistedVpnState(context, language);
    this.stats = this.controller.getStats();
    if (isProxyOnlyRuntimeUnhealthy(this.runtimeMode, this.status, this.stats)) {
      await this.cleanupUnhealthyProxy(context, language);
    } else {
      await this.checkProxyOnlyRuntimeHealth(context, language);
    }
    // 运行中显示实际使用的内核（anytls/tuic 会强制切到 sing-box）；空闲时显示全局设置。
    const snap = this.controller.getSnapshot();
    const running = snap.status === ConnectionStatus.RUNNING || snap.status === ConnectionStatus.STARTING;
    const effectiveCore = running ? snap.coreType : await CoreSelectionStore.load(context);
    this.coreLabel = isSingboxCore(effectiveCore) ? 'sing-box' : 'Xray';
    await this.refreshDiagnostics(context, language);
    this.coreEntries = readCoreLogEntries(context.filesDir);
    this.stats = this.localizeStats(this.stats, language);
    if (this.startedAt <= 0 || this.status !== ConnectionStatus.RUNNING) {
      this.elapsedText = '00:00';
      return this.snapshot();
    }
    const seconds = Math.max(0, Math.floor((Date.now() - this.startedAt) / 1000));
    this.elapsedText = formatDuration(seconds);
    return this.snapshot();
  }

  private async reconcilePersistedVpnState(context: common.Context, language: AppLanguage): Promise<void> {
    if (this.runtimeMode === APP_MODE_PROXY_ONLY || this.status === ConnectionStatus.STARTING ||
      this.status === ConnectionStatus.STOPPING) {
      return;
    }
    const persisted = VpnRuntimeStateStore.read(context);
    if (persisted === null) {
      return;
    }

    if (!persisted.active) {
      if (this.status === ConnectionStatus.RUNNING) {
        this.reconcileStopped();
      }
      return;
    }

    const healthy = isPersistedVpnRuntimeHealthy(persisted, Date.now());
    if (this.status === ConnectionStatus.IDLE) {
      if (await NetSceneStopFlag.wasStopped(context, persisted.startedAt)) {
        return;
      }
      const snapshot = this.controller.reconcileRunning(persisted.startedAt, persisted.coreType);
      this.applySnapshot(snapshot, language);
      this.runtimeMode = APP_MODE_VPN;
      this.recoveredProfileUpdatedAt = persisted.profileUpdatedAt ?? 0;
      this.recoveredProfileMismatch = false;
      if (healthy) {
        this.appendLog(translate(language, 'runtime.vpnSessionRecovered'));
        return;
      }
    }

    if (this.status === ConnectionStatus.RUNNING && !healthy) {
      await this.cleanupUnhealthyVpn(context, language);
    }
  }

  snapshot(): RuntimeViewState {
    return {
      status: this.status,
      runtimeMode: this.runtimeMode,
      startedAt: this.startedAt,
      elapsedText: this.elapsedText,
      lastError: this.lastError,
      entries: this.allEntries(),
      stats: this.stats,
      connectionDelayMs: this.connectionDelayMs,
      connectionDelayTesting: this.connectionDelayTesting,
      connectionDelayFailed: this.connectionDelayFailed,
      egressIp: this.egressIp,
      egressIpChecking: this.egressIpChecking
    };
  }

  // 当前内核标签（运行中反映实际内核），供日志页等复用，避免各自从全局设置重算。
  coreLabelText(): string {
    return this.coreLabel;
  }

  appendLog(message: string): void {
    const entry = RuntimeController.makeAppEntry(message);
    const next = [entry].concat(this.logs);
    this.logs = next.slice(0, 80);
  }

  clearLogs(context: common.Context, language: AppLanguage): RuntimeViewState {
    try {
      DiagnosticLog.clear(context);
    } catch (error) {
      this.appendLog(formatOne(language, 'error.clearDiagnostics', 'error', JSON.stringify(error)));
    }
    this.logs = [];
    this.diagnosticEntries = [];
    clearCoreLog(context.filesDir);
    this.coreEntries = [];
    return this.snapshot();
  }

  statusLabel(language: AppLanguage): string {
    return localizedConnectionStatus(language, this.status);
  }

  statusColor(): string {
    return connectionStatusColor(this.status);
  }

  statusBackground(): string {
    return connectionStatusBackground(this.status);
  }

  isRunning(): boolean {
    return this.status === ConnectionStatus.RUNNING;
  }

  isVpnRunning(): boolean {
    return this.status === ConnectionStatus.RUNNING && this.runtimeMode === APP_MODE_VPN;
  }

  isBusy(): boolean {
    return this.status === ConnectionStatus.STARTING || this.status === ConnectionStatus.STOPPING;
  }

  // 核心日志、诊断日志、应用日志各自最新在前，合并后按时间倒序统一排列（最新在顶），上限 120 条。
  private allEntries(): Array<LogEntry> {
    const merged = this.coreEntries.concat(this.diagnosticEntries).concat(this.logs);
    merged.sort((a: LogEntry, b: LogEntry) => b.at - a.at);
    return merged.slice(0, 120);
  }

  // 应用内日志没有等级信息，统一记为 info；raw 保留「时钟 + 正文」整行原文。
  private static makeAppEntry(message: string): LogEntry {
    const at = Date.now();
    const time = formatClockTime(at);
    const sanitized = redactDiagnosticText(message);
    return { at, time, level: 'info', source: '', message: sanitized, raw: `${time}  ${sanitized}` };
  }

  private static buildReadyLogs(): Array<LogEntry> {
    return [RuntimeController.makeAppEntry(translate(DEFAULT_LANGUAGE, 'log.ready'))];
  }

  // 诊断事件本身带 level/source，归一化等级。心跳（vpn-stats）渲染成带流量/状态的友好文案，
  // 其余沿用既有格式化输出（供复制/分享）。
  private static eventToEntry(event: DiagnosticEvent, language: AppLanguage, coreLabel: string): LogEntry {
    const time = formatClockTime(event.at);
    const level = normalizeLogLevel(event.level);
    if (event.source === 'vpn-stats') {
      const message = localizeDiagnosticHeartbeat(
        language,
        event.uploadBytes ?? 0,
        event.downloadBytes ?? 0,
        event.xrayRunning ?? false,
        event.tunRunning ?? false,
        coreLabel
      );
      return { at: event.at, time, level, source: event.source, message, raw: `${time}  ${message}` };
    }
    return {
      at: event.at,
      time,
      level,
      source: event.source,
      message: event.message,
      raw: DiagnosticLog.format(event, (value: number) => formatClockTime(value))
    };
  }

  private localizeStats(stats: RuntimeStats, language: AppLanguage): RuntimeStats {
    return {
      uploadBytes: stats.uploadBytes,
      downloadBytes: stats.downloadBytes,
      xrayRunning: stats.xrayRunning,
      tunRunning: stats.tunRunning,
      lastMessage: localizeCoreMessage(language, stats.lastMessage)
    };
  }

  private applySnapshot(snapshot: ConnectionSnapshot, language: AppLanguage): void {
    this.status = snapshot.status;
    this.startedAt = snapshot.startedAt;
    this.lastError = localizeCoreMessage(language, snapshot.lastError);
  }

  private scheduleRuntimeConnectivityInfo(
    context: common.Context,
    profile: ProxyProfile,
    settings: AppSettings,
    language: AppLanguage,
    startedAt: number
  ): void {
    this.egressIpChecking = this.status === ConnectionStatus.RUNNING &&
      this.resolveRemoteIpProxyPort(profile, settings) > 0;
    this.appendRuntimeConnectivityInfo(context, profile, settings, language, startedAt).catch((error: Object) => {
      if (this.startedAt === startedAt) {
        this.egressIpChecking = false;
      }
      this.appendLog(formatOne(language, 'log.connectionDelayError', 'error', JSON.stringify(error)));
    });
  }

  private async appendRuntimeConnectivityInfo(
    context: common.Context,
    profile: ProxyProfile,
    settings: AppSettings,
    language: AppLanguage,
    startedAt: number
  ): Promise<void> {
    // 两项互不依赖：出口 IP 是经代理的 HTTPS 连通性验证，节点延迟是另一条诊断信号。
    // 并行执行可避免 TCP 探测超时后才开始出口验证，缩短首页“正在验证”时间。
    await Promise.all([
      this.measureConnectionDelayInternal(context, profile, settings, language, startedAt),
      this.appendRemoteIpInfo(profile, settings, language, startedAt)
    ]);
  }

  // 点按复测「当前连接」延迟（连接页胶囊触发）。复用启动时自动测速的同一条链路与日志格式，
  // 结果通过快照回传给页面渲染。非运行态 / 已在测速中则直接返回。
  async measureCurrentConnectionDelay(context: common.Context, language: AppLanguage): Promise<void> {
    const profile = this.activeProfile;
    const settings = this.activeSettings;
    if (this.status !== ConnectionStatus.RUNNING || this.connectionDelayTesting || profile === null || settings === null) {
      return;
    }
    await this.measureConnectionDelayInternal(context, profile, settings, language, this.startedAt);
  }

  // 用户点按出口胶囊、页面重新回到前台或网络承载变化时复测。只使用本次运行会话保存的
  // profile/settings，不启动或重连代理；已有检测进行中时幂等返回，避免重复访问 IP API。
  async recheckCurrentEgressIp(language: AppLanguage): Promise<void> {
    const profile = this.activeProfile;
    const settings = this.activeSettings;
    if (this.status !== ConnectionStatus.RUNNING || this.egressIpChecking ||
      profile === null || settings === null || this.resolveRemoteIpProxyPort(profile, settings) <= 0) {
      return;
    }
    const startedAt = this.startedAt;
    this.egressIpChecking = true;
    try {
      await this.appendRemoteIpInfo(profile, settings, language, startedAt);
    } catch (error) {
      if (this.status === ConnectionStatus.RUNNING && this.startedAt === startedAt) {
        // 请求异常也不能继续展示上一次承载网络留下的出口，失败态应明确可见。
        this.egressIp = '';
        this.egressIpChecking = false;
        this.appendLog(formatOne(language, 'log.remoteIpInfoFailed', 'error', JSON.stringify(error)));
      }
    }
  }

  // 测「当前连接」延迟并把结果写入状态与日志。期间会话变化（断开/热切换重连）时返回 null，
  // 不落任何状态——新会话的状态由 start() 的复位和它自己的自动测速负责。
  private async measureConnectionDelayInternal(
    context: common.Context,
    profile: ProxyProfile,
    settings: AppSettings,
    language: AppLanguage,
    startedAt: number
  ): Promise<RuntimeDelayResult | null> {
    if (this.status !== ConnectionStatus.RUNNING || this.startedAt !== startedAt) {
      return null;
    }
    this.connectionDelayTesting = true;
    const delayResult: RuntimeDelayResult = await measureRuntimeProfileDelay(profile, context.filesDir, settings.delayTestUrl);
    if (this.status !== ConnectionStatus.RUNNING || this.startedAt !== startedAt) {
      return null;
    }
    this.connectionDelayTesting = false;
    this.connectionDelayMs = delayResult.ok ? delayResult.delayMs : -1;
    // unsupported-config 不算失败：该配置形态本就不支持测速，胶囊保持「未测」而非报错。
    this.connectionDelayFailed = !delayResult.ok && delayResult.status !== 'unsupported-config';
    if (delayResult.ok) {
      this.appendLog(formatOne(language, 'log.connectionDelay', 'delay', delayResult.delayMs.toString()));
    } else if (delayResult.status !== 'unsupported-config') {
      this.appendLog(formatOne(language, 'log.connectionDelayError', 'error', delayResult.status));
    }
    return delayResult;
  }

  private resetConnectionDelay(): void {
    this.connectionDelayTesting = false;
    this.connectionDelayMs = -1;
    this.connectionDelayFailed = false;
  }

  private resetEgressIp(): void {
    this.egressIp = '';
    this.egressIpChecking = false;
  }

  private async appendRemoteIpInfo(profile: ProxyProfile, settings: AppSettings, language: AppLanguage, startedAt: number): Promise<void> {
    const proxyPort = this.resolveRemoteIpProxyPort(profile, settings);
    if (this.status !== ConnectionStatus.RUNNING || this.startedAt !== startedAt || proxyPort <= 0) {
      if (this.startedAt === startedAt) {
        this.egressIpChecking = false;
      }
      return;
    }
    const result: RemoteIpInfoResult = await fetchRemoteIpInfo(settings.ipApiUrl, proxyPort);
    if (this.status !== ConnectionStatus.RUNNING || this.startedAt !== startedAt) {
      return;
    }
    this.egressIpChecking = false;
    if (result.ok && result.summary.length > 0) {
      this.egressIp = result.summary;
      this.appendLog(formatOne(language, 'log.remoteIpInfo', 'info', result.summary));
    } else {
      // 复测失败时清除旧值，不能把上一网络/上一出口继续伪装成当前结果。
      this.egressIp = '';
      this.appendLog(formatOne(language, 'log.remoteIpInfoFailed', 'error', result.status));
    }
  }

  private resolveRemoteIpProxyPort(profile: ProxyProfile, settings: AppSettings): number {
    if ((profile.configType ?? 'outbound') === 'full' || settings.ipApiUrl.trim().length === 0) {
      return 0;
    }
    // VPN 模式始终提供独立的仅回环内部 HTTP 入站；它不受用户可见本地代理开关影响，
    // 也不会暴露到局域网。Hey 自身被排除在 TUN 外，出口验证必须显式走这个入口。
    if (normalizeAppRuntimeMode(settings.mode, APP_MODE_VPN) === APP_MODE_VPN) {
      return VPN_INTERNAL_HTTP_PROXY_PORT;
    }
    return shouldExposeLocalHttpProxy(settings) ? LOCAL_HTTP_PROXY_PORT : 0;
  }

  private async refreshDiagnostics(context: common.Context, language: AppLanguage): Promise<void> {
    if (this.diagnosticRefreshing) {
      return;
    }
    this.diagnosticRefreshing = true;

    try {
      const events = await DiagnosticLog.read(context, 80);
      this.diagnosticEntries = events.map((event: DiagnosticEvent) => RuntimeController.eventToEntry(event, language, this.coreLabel));
      const healthLost = this.applyDiagnosticStats(events);
      if (healthLost) {
        await this.cleanupUnhealthyVpn(context, language);
      }
      this.applyDiagnosticError(events, language);
    } catch (error) {
      // 诊断解析失败绝不能让 refresh 整体抛出——否则页面收不到 snapshot，日志面板会全空。
      console.error(`Diagnostic refresh failed: ${JSON.stringify(error)}`);
    } finally {
      this.diagnosticRefreshing = false;
    }
  }

  private applyDiagnosticStats(events: Array<DiagnosticEvent>): boolean {
    for (let index = 0; index < events.length; index++) {
      const event = events[index];
      if (event.uploadBytes !== undefined || event.downloadBytes !== undefined) {
        // 运行态只接受本次启动请求之后的心跳，避免上一会话的最后一条记录
        // 暂时把新会话渲染成已停止。
        if (this.status === ConnectionStatus.RUNNING && event.at < this.startedAt) {
          continue;
        }
        this.stats = {
          uploadBytes: event.uploadBytes ?? 0,
          downloadBytes: event.downloadBytes ?? 0,
          xrayRunning: event.xrayRunning ?? false,
          tunRunning: event.tunRunning ?? false,
          lastMessage: event.details ?? event.message
        };
        return this.status === ConnectionStatus.RUNNING &&
          (event.xrayRunning === false || event.tunRunning === false);
      }
    }
    return false;
  }

  // 心跳已经明确证明数据面不完整时，先清理残留 VPN，再保留错误态等待用户主动重连。
  // 不在此处调用 start，确保手动断开/异常断开之后都不会自行恢复。
  private async cleanupUnhealthyVpn(context: common.Context, language: AppLanguage): Promise<void> {
    const message = translate(language, 'runtime.vpnHealthLost');
    await this.controller.stop(context);
    this.status = ConnectionStatus.ERROR;
    this.startedAt = 0;
    this.elapsedText = '00:00';
    this.lastError = message;
    this.activeProfile = null;
    this.activeSettings = null;
    this.resetRecoveredProfileIdentity();
    this.resetConnectionDelay();
    this.resetEgressIp();
    this.appendLog(message);
  }

  // 本地代理与 UI 共进程：native 明确报告停止时立即处理，其余情况再探测实际 SOCKS
  // 监听器。异常退出时执行一次幂等停止以清理残余资源，但绝不自动启动。
  private async cleanupUnhealthyProxy(context: common.Context, language: AppLanguage): Promise<void> {
    const message = translate(language, 'runtime.proxyHealthLost');
    await this.controller.stop(context);
    this.status = ConnectionStatus.ERROR;
    this.startedAt = 0;
    this.elapsedText = '00:00';
    this.lastError = message;
    this.activeProfile = null;
    this.activeSettings = null;
    this.resetRecoveredProfileIdentity();
    this.resetConnectionDelay();
    this.resetEgressIp();
    this.appendLog(message);
  }

  private async checkProxyOnlyRuntimeHealth(context: common.Context, language: AppLanguage): Promise<void> {
    if (this.runtimeMode !== APP_MODE_PROXY_ONLY || this.status !== ConnectionStatus.RUNNING) {
      return;
    }
    const generated = this.controller.getSnapshot().generatedConfig;
    if (generated === null || generated.runtimeHealthPort === undefined) {
      return;
    }
    const healthPort = generated.runtimeHealthPort;
    const now = Date.now();
    if (now - this.lastProxyHealthProbeAt < LOCAL_PROXY_HEALTH_INTERVAL_MS) {
      return;
    }
    this.lastProxyHealthProbeAt = now;
    const sessionStartedAt = this.startedAt;
    const result = await probeRuntimeSocksHealth(healthPort);
    if (this.runtimeMode !== APP_MODE_PROXY_ONLY || this.status !== ConnectionStatus.RUNNING ||
      this.startedAt !== sessionStartedAt) {
      return;
    }
    if (result.ok) {
      this.proxyUnhealthySampleCount = 0;
      return;
    }
    this.proxyUnhealthySampleCount++;
    if (this.proxyUnhealthySampleCount >= LOCAL_PROXY_UNHEALTHY_SAMPLE_LIMIT) {
      await this.cleanupUnhealthyProxy(context, language);
    }
  }

  private resetRecoveredProfileIdentity(): void {
    this.recoveredProfileUpdatedAt = 0;
    this.recoveredProfileMismatch = false;
  }

  private resetProxyHealth(): void {
    this.lastProxyHealthProbeAt = 0;
    this.proxyUnhealthySampleCount = 0;
  }

  private applyDiagnosticError(events: Array<DiagnosticEvent>, language: AppLanguage): void {
    if (events.length === 0) {
      return;
    }
    const event = events[0];
    if (event.level !== 'error') {
      return;
    }
    const message = event.details !== undefined && event.details.length > 0 ? `${event.message} ${event.details}` : event.message;
    this.lastError = localizeCoreMessage(language, message);
    if (this.status === ConnectionStatus.RUNNING || this.status === ConnectionStatus.STARTING) {
      this.status = ConnectionStatus.ERROR;
    }
  }
}

export const SHARED_RUNTIME_CONTROLLER: RuntimeController = new RuntimeController();
