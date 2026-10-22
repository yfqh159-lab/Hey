import { common } from '@kit.AbilityKit';
import { DEFAULT_LANGUAGE, translate } from '../../core/I18n';
import {
  isMissingVpnRuntimeStateUnhealthy,
  isProxyOnlyRuntimeUnhealthy,
  runtimeMayOwnNetwork,
  shouldApplyVpnDiagnosticError,
  shouldApplyVpnDiagnosticStats,
  shouldCleanupUnhealthyVpnRuntimeState,
  shouldRestartUnhealthyVpnObservation
} from '../../core/RuntimeHealth';
import { APP_MODE_PROXY_ONLY, APP_MODE_VPN, AppLanguage, AppRuntimeMode, AppSettings, ConnectionStatus, normalizeAppRuntimeMode, ProxyProfile, RuntimeStats } from '../../core/Profile';
import {
  PROXY_ONLY_INTERNAL_HTTP_PROXY_PORT,
  VPN_DATA_SOCKS_PORT,
  VPN_INTERNAL_HTTP_PROXY_PORT
} from '../../core/XrayConfig';
import { CoreSelectionStore, CoreType, isSingboxCore } from '../../core/CoreSelection';
import { ConnectionController, ConnectionSnapshot } from '../../services/ConnectionController';
import { NetSceneStopFlag } from '../../services/NetSceneStopFlag';
import { isPersistedVpnCleanupIncomplete, isPersistedVpnRuntimeHealthy, isPersistedVpnRuntimeSessionStopped, VpnRuntimeStateStore } from '../../services/VpnRuntimeStateStore';
import { DiagnosticEvent, DiagnosticLog } from '../../services/DiagnosticLog';
import { clearCoreLog, readCoreLogEntries } from '../../services/CoreLogReader';
import { LogEntry, normalizeLogLevel } from '../logs/LogModel';
import { fetchRemoteIpInfo, RemoteIpInfoResult } from '../../services/RemoteIpInfo';
import { probeRuntimeSocksHealth } from '../../services/RuntimeHealthProbe';
import { measureRuntimeProfileDelay, RuntimeDelayResult } from '../../services/RuntimeDelay';
import { connectionStatusBackground, connectionStatusColor, formatClockTime, formatDuration } from '../../utils/Formatters';
import { formatOne, localizedConnectionStatus, localizeCoreMessage, localizeDiagnosticHeartbeat } from '../../utils/LocalizationPresenter';
import { redactDiagnosticText } from '../../core/DiagnosticRedaction';
import { isCurrentEgressCheck } from '../../core/RuntimeEgress';

const EMPTY_STATS: RuntimeStats = {
  uploadBytes: 0,
  downloadBytes: 0,
  xrayRunning: false,
  tunRunning: false,
  lastMessage: translate(DEFAULT_LANGUAGE, 'runtime.nativeBridgeNotQueried')
};
const LOCAL_PROXY_HEALTH_INTERVAL_MS: number = 5000;
const LOCAL_PROXY_UNHEALTHY_SAMPLE_LIMIT: number = 2;
const MISSING_VPN_STATE_SAMPLE_LIMIT: number = 3;
const CORE_SELECTION_READ_TIMEOUT_MS: number = 2000;

function withRuntimeStoreTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timerId = setTimeout(() => reject(new Error('runtime store read timed out')), timeoutMs);
    promise.then((value: T) => {
      clearTimeout(timerId);
      resolve(value);
    }, (error: Object) => {
      clearTimeout(timerId);
      reject(error);
    });
  });
}

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
  // 由本次已生成的核心配置提供，因此动态 SOCKS 端口也能准确展示。
  localProxySocksPort: number;
  localProxyHttpPort: number;
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
  private egressCheckGeneration: number = 0;
  private lastProxyHealthProbeAt: number = 0;
  private proxyUnhealthySampleCount: number = 0;
  private recoveredProfileUpdatedAt: number = 0;
  private recoveredProfileMismatch: boolean = false;
  private missingVpnStateSampleCount: number = 0;
  private unhealthyVpnStateFirstSeenAt: number = 0;
  private unhealthyVpnStateLastSeenAt: number = 0;
  private unhealthyVpnStateSessionId: string = '';
  private networkRecoveryInFlight: boolean = false;
  // 页面允许在 STARTING 阶段主动取消。除了 ConnectionController 的底层代际，这里也要
  // 隔离 start() 的页面层续体；否则“取消完成后立即再次连接”时，第一次 start 的迟到
  // 返回可能拿到第二次会话的快照，却用第一次的节点/设置安排出口检测并写启动日志。
  private runtimeStartGeneration: number = 0;
  // Index 与 Logs 都可能按秒刷新同一个单例。共享层必须阻止跨页面并发读取把一次临时
  // 状态缺失累计为多次；权威恢复可排队，普通观察只取当前快照而不制造刷新积压。
  private runtimeRefreshBusy: boolean = false;
  private runtimeRefreshTail: Promise<void> = Promise.resolve();
  // 空闲态的内核偏好只影响日志标签，不能因 ArkData 永久 pending 卡住真实 VPN 状态
  // 刷新。超时后复用同一底层任务，直到它真正结算，避免每秒继续排队。
  private coreSelectionLoadInFlight: Promise<CoreType> | null = null;
  private coreSelectionReadWarningLogged: boolean = false;

  async start(context: common.Context, profile: ProxyProfile, settings: AppSettings, language: AppLanguage): Promise<RuntimeViewState> {
    if (this.status === ConnectionStatus.STARTING || this.status === ConnectionStatus.STOPPING ||
      this.status === ConnectionStatus.RUNNING) {
      return this.snapshot();
    }
    const runtimeStartGeneration = ++this.runtimeStartGeneration;
    this.runtimeMode = normalizeAppRuntimeMode(settings.mode, APP_MODE_VPN);
    // 必须在第一个 await 前公开忙碌态：网络场景管理器、首页和日志页共用此单例，
    // 否则底层正在异步启动时另一个入口仍会看到旧的 IDLE/RUNNING 并发起重叠操作。
    this.status = ConnectionStatus.STARTING;
    this.startedAt = Date.now();
    this.activeProfile = profile;
    this.activeSettings = settings;
    this.resetConnectionDelay();
    this.resetEgressIp();
    this.resetProxyHealth();
    this.missingVpnStateSampleCount = 0;
    this.resetUnhealthyVpnStateConfirmation();
    this.resetRecoveredProfileIdentity();
    this.appendLog(this.runtimeMode === APP_MODE_PROXY_ONLY ? translate(language, 'log.startingProxy') : translate(language, 'log.startingVpn'));
    const snapshot = await this.controller.start(context, profile, settings);
    if (runtimeStartGeneration !== this.runtimeStartGeneration) {
      // stop() 或更新的一次 start() 已经接管共享状态。旧续体不得覆盖其状态、清理标志，
      // 也不得拿旧 profile/settings 对新会话做测速或出口归属。
      return this.snapshot();
    }
    this.applySnapshot(snapshot, language);
    if (this.status === ConnectionStatus.RUNNING) {
      this.appendLog(this.runtimeMode === APP_MODE_PROXY_ONLY ?
        translate(language, 'log.proxyStarted') : translate(language, 'log.vpnStarted'));
      this.scheduleRuntimeConnectivityInfo(context, profile, settings, language, this.startedAt);
    } else if (this.status === ConnectionStatus.ERROR) {
      // ERROR 是真正的启动失败；STARTING/STOPPING/IDLE 可能是用户取消，不应记录成故障。
      this.appendLog(this.runtimeMode === APP_MODE_PROXY_ONLY ?
        translate(language, 'log.proxyStartIncomplete') : translate(language, 'log.vpnStartIncomplete'));
    }
    return this.refresh(context, language);
  }

  async stop(context: common.Context, language: AppLanguage): Promise<RuntimeViewState> {
    // 即使本地控制器仍是 IDLE，也要先使正在探测持久 VPN 的恢复续体失效，并让底层
    // ConnectionController 取消尚未完成的启动/重载。否则用户明确断开后，旧探针仍可
    // 把 Extension 中的会话迟到接管成 RUNNING。
    this.runtimeStartGeneration++;
    if (this.status === ConnectionStatus.STOPPING) {
      return this.snapshot();
    }
    if (this.status === ConnectionStatus.IDLE) {
      const persisted = VpnRuntimeStateStore.readWithEvidence(context).state;
      if (persisted !== null && persisted.active) {
        // UI 可能在后台会话核实完成前收到用户停止。先接管已知会话只为了向同一
        // Extension 下发停止与取消标志；这里绝不启动核心或创建 TUN。
        this.applySnapshot(this.controller.reconcileRunning(
          persisted.startedAt, persisted.coreType, persisted.sessionId), language);
        this.runtimeMode = APP_MODE_VPN;
      } else if (persisted !== null && isPersistedVpnCleanupIncomplete(persisted)) {
        this.applySnapshot(this.controller.reconcileCleanupRequired(
          persisted.sessionId, persisted.coreType, translate(language, 'runtime.vpnCleanupRequired')), language);
        this.runtimeMode = APP_MODE_VPN;
      } else {
        // ConnectionController.stop() 在 IDLE 也会同步递增底层启动/重载代际。
        await this.controller.stop(context);
        return this.snapshot();
      }
    }
    const stoppingMode = this.runtimeMode;
    // 与 start 相同，同步发布 STOPPING，阻止前台按钮和网络变化评估重复下发停止或
    // 在清理完成前启动另一套核心/TUN。
    this.status = ConnectionStatus.STOPPING;
    this.resetConnectionDelay();
    this.resetEgressIp();
    this.resetProxyHealth();
    this.missingVpnStateSampleCount = 0;
    this.resetUnhealthyVpnStateConfirmation();
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
    this.missingVpnStateSampleCount = 0;
    this.resetUnhealthyVpnStateConfirmation();
  }

  // 运行中按传入的新 Profile 热切换：先停后启。非运行态直接返回当前快照，调用方无需自行判断。
  // 供没有连接管线的页面（如订阅详情）复用，避免「界面显示已切换、隧道仍跑旧配置」。
  async reconnectWithProfile(context: common.Context, profile: ProxyProfile, settings: AppSettings, language: AppLanguage): Promise<RuntimeViewState> {
    if (this.status !== ConnectionStatus.RUNNING) {
      return this.snapshot();
    }
    const restartGeneration = this.runtimeStartGeneration + 1;
    const stopped = await this.stop(context, language);
    // stop() advances the generation once. Any concurrent explicit stop advances it again,
    // so an older reconnect continuation must not recreate a session after the user stopped it.
    if (stopped.status !== ConnectionStatus.IDLE || this.runtimeStartGeneration !== restartGeneration) {
      return stopped;
    }
    return this.start(context, profile, settings, language);
  }

  // Proxy-only 与 UI 同进程，不能依赖 VPN Extension 的后台轮询。网络监听确认承载发生
  // 真实变化后从原始运行配置重载核心；手动 stop 可在任意 await 处取消底层恢复代际。
  async recoverProxyOnlyAfterNetworkChange(
    context: common.Context,
    language: AppLanguage
  ): Promise<RuntimeViewState> {
    if (this.networkRecoveryInFlight || this.status !== ConnectionStatus.RUNNING ||
      this.runtimeMode !== APP_MODE_PROXY_ONLY) {
      return this.snapshot();
    }
    const sessionStartedAt = this.startedAt;
    this.networkRecoveryInFlight = true;
    this.resetEgressIp();
    this.appendLog(translate(language, 'log.restartingService'));
    try {
      const snapshot = await this.controller.reloadProxyOnlyAfterNetworkChange(context);
      // 用户可能在域名解析或 SOCKS 就绪等待期间手动停止；stop() 已经更新本地状态，
      // 此时绝不能用迟到的恢复结果覆盖它，更不能重新连接。
      if (this.status !== ConnectionStatus.RUNNING || this.runtimeMode !== APP_MODE_PROXY_ONLY ||
        this.startedAt !== sessionStartedAt) {
        return this.snapshot();
      }
      this.applySnapshot(snapshot, language);
      if (snapshot.status === ConnectionStatus.RUNNING) {
        this.resetProxyHealth();
      } else {
        this.activeProfile = null;
        this.activeSettings = null;
        this.resetConnectionDelay();
        this.resetEgressIp();
        if (this.lastError.length > 0) {
          this.appendLog(this.lastError);
        }
      }
      return this.snapshot();
    } finally {
      this.networkRecoveryInFlight = false;
    }
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

  async refresh(
    context: common.Context,
    language: AppLanguage,
    authoritative: boolean = false
  ): Promise<RuntimeViewState> {
    if (!authoritative && this.runtimeRefreshBusy) {
      return this.snapshot();
    }
    const previous = this.runtimeRefreshTail;
    this.runtimeRefreshBusy = true;
    const operation = previous.then(
      (): Promise<RuntimeViewState> => this.performRefresh(context, language),
      (): Promise<RuntimeViewState> => this.performRefresh(context, language)
    );
    const settled = operation.then(
      (): void => {},
      (): void => {}
    );
    this.runtimeRefreshTail = settled;
    try {
      return await operation;
    } finally {
      if (this.runtimeRefreshTail === settled) {
        this.runtimeRefreshBusy = false;
      }
    }
  }

  private async performRefresh(context: common.Context, language: AppLanguage): Promise<RuntimeViewState> {
    // Extension 可能在两次前台刷新之间已经写入致命 error 并完成自清理。若先读取
    // inactive 持久状态，下面会把 RUNNING 直接校正成 IDLE，随后错误因状态已改变而
    // 无法再应用。先消费精确匹配当前会话的错误，保留“异常断开”而不是伪装成正常停止。
    await this.applyPendingVpnDiagnosticError(context, language);
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
    if (running) {
      this.coreLabel = isSingboxCore(snap.coreType) ? 'sing-box' : 'Xray';
    } else {
      try {
        const effectiveCore = await withRuntimeStoreTimeout(
          this.loadCoreSelectionSingleFlight(context), CORE_SELECTION_READ_TIMEOUT_MS);
        this.coreLabel = isSingboxCore(effectiveCore) ? 'sing-box' : 'Xray';
        this.coreSelectionReadWarningLogged = false;
      } catch (error) {
        // 仅保留上一次标签；前面的权威 VPN 状态校正和后面的诊断刷新必须继续。
        if (!this.coreSelectionReadWarningLogged) {
          this.coreSelectionReadWarningLogged = true;
          console.error(`Runtime core label refresh failed: ${redactDiagnosticText(JSON.stringify(error))}`);
        }
      }
    }
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
    const persistedRead = VpnRuntimeStateStore.readWithEvidence(context);
    const persisted = persistedRead.state;
    const stateArtifactsInvalid = persistedRead.authoritativeArtifactInvalid;
    if (stateArtifactsInvalid) {
      // 回退备份可能比损坏主文件旧，也可能根本没有可解析备份：两种情况都不能退化为
      // 普通“文件缺失”的三次采样。健康 Extension 的下一次心跳会重写主文件；持续
      // 12 秒仍无法修复时才清理，避免 4 秒心跳周期内过早拆掉真实健康的数据面。
      if (this.status === ConnectionStatus.RUNNING) {
        const now = Date.now();
        const suspectedSessionId = persisted?.sessionId ?? this.controller.getSnapshot().vpnSessionId;
        this.noteUnhealthyVpnStateObservation(suspectedSessionId, now);
        if (shouldCleanupUnhealthyVpnRuntimeState(
          true,
          false,
          this.unhealthyVpnStateFirstSeenAt,
          now
        )) {
          await this.cleanupUnhealthyVpn(context, language);
        }
        return;
      }
      if (persisted === null || !persisted.active) {
        return;
      }
      // 空闲 UI 只有在下方会话绑定的 SOCKS 端口探针也成功后，才可接管旧 active 备份。
    }
    if (persisted === null) {
      if (this.status === ConnectionStatus.RUNNING) {
        this.missingVpnStateSampleCount++;
        if (isMissingVpnRuntimeStateUnhealthy(
          this.runtimeMode,
          this.status,
          this.missingVpnStateSampleCount,
          MISSING_VPN_STATE_SAMPLE_LIMIT
        )) {
          await this.cleanupUnhealthyVpn(context, language);
        }
      } else {
        this.missingVpnStateSampleCount = 0;
      }
      return;
    }
    this.missingVpnStateSampleCount = 0;

    if (!persisted.active) {
      this.resetUnhealthyVpnStateConfirmation();
      if (isPersistedVpnCleanupIncomplete(persisted)) {
        if (!this.controller.requiresCleanup()) {
          const message = translate(language, 'runtime.vpnCleanupRequired');
          const snapshot = this.controller.reconcileCleanupRequired(
            persisted.sessionId,
            persisted.coreType,
            message
          );
          this.applySnapshot(snapshot, language);
          this.appendLog(message);
        }
        this.runtimeMode = APP_MODE_VPN;
        this.activeProfile = null;
        this.activeSettings = null;
        this.resetConnectionDelay();
        this.resetEgressIp();
        return;
      }
      if (this.controller.requiresCleanup(persisted.sessionId) &&
        isPersistedVpnRuntimeSessionStopped(persisted, persisted.sessionId)) {
        this.applySnapshot(this.controller.reconcileStopped(), language);
        this.runtimeMode = APP_MODE_VPN;
        this.activeProfile = null;
        this.activeSettings = null;
        this.resetConnectionDelay();
        this.resetEgressIp();
        return;
      }
      if (this.status === ConnectionStatus.RUNNING) {
        this.reconcileStopped();
      }
      return;
    }

    const now = Date.now();
    const healthy = isPersistedVpnRuntimeHealthy(persisted, now);
    if (!healthy) {
      this.noteUnhealthyVpnStateObservation(persisted.sessionId, now);
      if (!shouldCleanupUnhealthyVpnRuntimeState(
        persisted.active,
        healthy,
        this.unhealthyVpnStateFirstSeenAt,
        now
      )) {
        return;
      }
      // UI 进程刚重建时控制器仍是 IDLE；确认状态持续不健康后先接管该会话，
      // 才能让 cleanupUnhealthyVpn() 向实际 VPN Extension 发送停止命令。
      if (this.status === ConnectionStatus.IDLE) {
        const snapshot = this.controller.reconcileRunning(
          persisted.startedAt, persisted.coreType, persisted.sessionId);
        this.applySnapshot(snapshot, language);
        this.runtimeMode = APP_MODE_VPN;
      }
      if (this.status === ConnectionStatus.RUNNING) {
        await this.cleanupUnhealthyVpn(context, language);
      }
      return;
    }

    if (this.status === ConnectionStatus.IDLE) {
      const recoveredSessionId = persisted.sessionId;
      const recoveredStartedAt = persisted.startedAt;
      const recoveredHealthPort = persisted.runtimeHealthPort ?? VPN_DATA_SOCKS_PORT;
      const recoveredGeneration = this.runtimeStartGeneration;
      const dataPlane = await probeRuntimeSocksHealth(recoveredHealthPort);
      if (!this.isCurrentRecoveredVpnCandidate(
        context, recoveredSessionId, recoveredStartedAt, recoveredHealthPort, recoveredGeneration)) {
        return;
      }
      if (!dataPlane.ok) {
        const probeNow = Date.now();
        this.noteUnhealthyVpnStateObservation(recoveredSessionId, probeNow);
        if (!shouldCleanupUnhealthyVpnRuntimeState(
          true,
          false,
          this.unhealthyVpnStateFirstSeenAt,
          probeNow
        )) {
          return;
        }
        // 状态文件仍声称 active，但固定数据入口持续不可达。先接管同一会话只为了
        // 向 Extension 下发幂等清理；绝不在该路径启动或恢复核心。
        const snapshot = this.controller.reconcileRunning(
          recoveredStartedAt, persisted.coreType, recoveredSessionId);
        this.applySnapshot(snapshot, language);
        this.runtimeMode = APP_MODE_VPN;
        await this.cleanupUnhealthyVpn(context, language);
        return;
      }
      this.resetUnhealthyVpnStateConfirmation();
      const sceneStopped = await NetSceneStopFlag.wasStopped(
        context, recoveredStartedAt, recoveredSessionId);
      // 探针或停止标志读取期间，用户可能已经启动另一模式或 Extension 已换会话。
      // 迟到结果不得把新的 STARTING/本地代理状态覆盖成旧 VPN 会话。
      if (!this.isCurrentRecoveredVpnCandidate(
        context, recoveredSessionId, recoveredStartedAt, recoveredHealthPort, recoveredGeneration)) {
        return;
      }
      if (sceneStopped) {
        return;
      }
      const snapshot = this.controller.reconcileRunning(
        recoveredStartedAt, persisted.coreType, recoveredSessionId);
      this.applySnapshot(snapshot, language);
      this.runtimeMode = APP_MODE_VPN;
      this.recoveredProfileUpdatedAt = persisted.profileUpdatedAt ?? 0;
      this.recoveredProfileMismatch = false;
      this.appendLog(translate(language, 'runtime.vpnSessionRecovered'));
      return;
    }
    this.resetUnhealthyVpnStateConfirmation();
  }

  private loadCoreSelectionSingleFlight(context: common.Context): Promise<CoreType> {
    if (this.coreSelectionLoadInFlight !== null) {
      return this.coreSelectionLoadInFlight;
    }
    const promise = CoreSelectionStore.load(context);
    this.coreSelectionLoadInFlight = promise;
    promise.then(
      (_coreType: CoreType): void => this.releaseCoreSelectionLoad(promise),
      (_error: Object): void => this.releaseCoreSelectionLoad(promise)
    );
    return promise;
  }

  private releaseCoreSelectionLoad(promise: Promise<CoreType>): void {
    if (this.coreSelectionLoadInFlight === promise) {
      this.coreSelectionLoadInFlight = null;
    }
  }

  private isCurrentRecoveredVpnCandidate(
    context: common.Context,
    expectedSessionId: string,
    expectedStartedAt: number,
    expectedHealthPort: number,
    expectedGeneration: number
  ): boolean {
    if (this.status !== ConnectionStatus.IDLE || this.runtimeStartGeneration !== expectedGeneration) {
      return false;
    }
    const current = VpnRuntimeStateStore.read(context);
    return current !== null && current.sessionId === expectedSessionId &&
      current.startedAt === expectedStartedAt &&
      (current.runtimeHealthPort ?? VPN_DATA_SOCKS_PORT) === expectedHealthPort &&
      isPersistedVpnRuntimeHealthy(current, Date.now());
  }

  private resetUnhealthyVpnStateConfirmation(): void {
    this.unhealthyVpnStateFirstSeenAt = 0;
    this.unhealthyVpnStateLastSeenAt = 0;
    this.unhealthyVpnStateSessionId = '';
  }

  private noteUnhealthyVpnStateObservation(sessionId: string, now: number): void {
    if (this.unhealthyVpnStateSessionId !== sessionId || shouldRestartUnhealthyVpnObservation(
      this.unhealthyVpnStateFirstSeenAt, this.unhealthyVpnStateLastSeenAt, now)) {
      this.unhealthyVpnStateSessionId = sessionId;
      this.unhealthyVpnStateFirstSeenAt = now;
    }
    this.unhealthyVpnStateLastSeenAt = now;
  }

  snapshot(): RuntimeViewState {
    const generated = this.controller.getSnapshot().generatedConfig;
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
      egressIpChecking: this.egressIpChecking,
      localProxySocksPort: generated?.socksPort ?? 0,
      localProxyHttpPort: generated?.httpProxyPort ?? 0
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

  requiresCleanup(): boolean {
    return this.controller.requiresCleanup();
  }

  runtimeStartedAt(): number {
    return this.startedAt;
  }

  runtimeVpnSessionId(): string {
    return this.controller.getSnapshot().vpnSessionId;
  }

  isBusy(): boolean {
    return this.networkRecoveryInFlight ||
      this.status === ConnectionStatus.STARTING || this.status === ConnectionStatus.STOPPING;
  }

  mayOwnNetwork(): boolean {
    return runtimeMayOwnNetwork(this.status, this.controller.requiresCleanup());
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
    const checkGeneration = ++this.egressCheckGeneration;
    this.egressIpChecking = this.status === ConnectionStatus.RUNNING &&
      this.resolveRemoteIpProxyPort(profile, settings) > 0;
    this.appendRuntimeConnectivityInfo(
      context, profile, settings, language, startedAt, checkGeneration).catch((error: Object) => {
      if (isCurrentEgressCheck(
        this.status, this.startedAt, startedAt, this.egressCheckGeneration, checkGeneration)) {
        this.egressIpChecking = false;
        this.egressIp = '';
        this.appendLog(formatOne(language, 'log.remoteIpInfoFailed', 'error', JSON.stringify(error)));
      }
    });
  }

  private async appendRuntimeConnectivityInfo(
    context: common.Context,
    profile: ProxyProfile,
    settings: AppSettings,
    language: AppLanguage,
    startedAt: number,
    checkGeneration: number
  ): Promise<void> {
    // 两项互不依赖：出口 IP 是经代理的 HTTPS 连通性验证，节点延迟是另一条诊断信号。
    // 并行执行可避免 TCP 探测超时后才开始出口验证，缩短首页“正在验证”时间。
    await Promise.all([
      this.measureConnectionDelayInternal(context, profile, settings, language, startedAt),
      this.appendRemoteIpInfo(profile, settings, language, startedAt, checkGeneration)
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
    const checkGeneration = ++this.egressCheckGeneration;
    this.egressIpChecking = true;
    try {
      await this.appendRemoteIpInfo(profile, settings, language, startedAt, checkGeneration);
    } catch (error) {
      if (isCurrentEgressCheck(
        this.status, this.startedAt, startedAt, this.egressCheckGeneration, checkGeneration)) {
        // 请求异常也不能继续展示上一次承载网络留下的出口，失败态应明确可见。
        this.egressIp = '';
        this.egressIpChecking = false;
        this.appendLog(formatOne(language, 'log.remoteIpInfoFailed', 'error', JSON.stringify(error)));
      }
    }
  }

  // 延迟测试与出口 IP 地址只是当前会话的观测偏好，不参与核心、监听器或 TUN 配置。
  // 设置页保存后热更新这两个字段，避免为了换诊断端点拆掉健康连接；不得把 mode 等
  // 新数据面设置一起覆盖到仍在运行的旧会话，否则内部代理端口会与真实会话错配。
  updateObservationSettings(settings: AppSettings): void {
    if (this.activeSettings === null) {
      return;
    }
    if (this.activeSettings.ipApiUrl !== settings.ipApiUrl) {
      // 旧端点的在途响应不能在设置更新后继续显示；下一次前台复测使用新端点。
      this.resetEgressIp();
    }
    this.activeSettings.delayTestUrl = settings.delayTestUrl;
    this.activeSettings.ipApiUrl = settings.ipApiUrl;
  }

  // 真实底层承载变化时先让所有在途请求失效。调用方随后可在确认存在可用承载后复测；
  // 这里不自行联网，也不重启核心/VPN。
  invalidateCurrentEgressIp(): void {
    this.resetEgressIp();
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
    let delayResult: RuntimeDelayResult;
    try {
      delayResult = await measureRuntimeProfileDelay(profile, context.filesDir, settings.delayTestUrl);
    } catch (_error) {
      // socket/taskpool/native 桥若在标准失败返回之外直接抛异常，也必须结束“测速中”。
      // 只对仍属本次会话的结果落状态；旧会话迟到异常不能清掉新会话正在进行的测试。
      if (this.status !== ConnectionStatus.RUNNING || this.startedAt !== startedAt) {
        return null;
      }
      this.connectionDelayTesting = false;
      this.connectionDelayMs = -1;
      this.connectionDelayFailed = true;
      const failure: RuntimeDelayResult = {
        ok: false,
        delayMs: -1,
        status: 'probe-failed',
        url: '',
        fallbackUsed: false,
        attemptedUrls: []
      };
      this.appendLog(formatOne(language, 'log.connectionDelayError', 'error', failure.status));
      return failure;
    }
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
    this.egressCheckGeneration++;
    this.egressIp = '';
    this.egressIpChecking = false;
  }

  private async appendRemoteIpInfo(
    profile: ProxyProfile,
    settings: AppSettings,
    language: AppLanguage,
    startedAt: number,
    checkGeneration: number
  ): Promise<void> {
    const proxyPort = this.resolveRemoteIpProxyPort(profile, settings);
    if (!isCurrentEgressCheck(
      this.status, this.startedAt, startedAt, this.egressCheckGeneration, checkGeneration) || proxyPort <= 0) {
      if (this.startedAt === startedAt && this.egressCheckGeneration === checkGeneration) {
        this.egressIpChecking = false;
      }
      return;
    }
    const result: RemoteIpInfoResult = await fetchRemoteIpInfo(settings.ipApiUrl, proxyPort);
    if (!isCurrentEgressCheck(
      this.status, this.startedAt, startedAt, this.egressCheckGeneration, checkGeneration)) {
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
    // 本地代理模式始终生成仅回环的应用内部 HTTP 入站。不要借用用户可见的 18081：
    // 后者可能要求认证或监听局域网，且保存后的新凭据未必属于当前仍运行的旧会话。
    return PROXY_ONLY_INTERNAL_HTTP_PROXY_PORT;
  }

  private async refreshDiagnostics(context: common.Context, language: AppLanguage): Promise<void> {
    if (this.diagnosticRefreshing) {
      return;
    }
    this.diagnosticRefreshing = true;

    try {
      const events = await DiagnosticLog.read(context, 80);
      this.diagnosticEntries = events.map((event: DiagnosticEvent) => RuntimeController.eventToEntry(event, language, this.coreLabel));
      this.applyDiagnosticStats(events);
      await this.applyDiagnosticError(context, events, language);
    } catch (error) {
      // 诊断解析失败绝不能让 refresh 整体抛出——否则页面收不到 snapshot，日志面板会全空。
      console.error(`Diagnostic refresh failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    } finally {
      this.diagnosticRefreshing = false;
    }
  }

  private async applyPendingVpnDiagnosticError(context: common.Context, language: AppLanguage): Promise<void> {
    if (this.runtimeMode !== APP_MODE_VPN || this.status !== ConnectionStatus.RUNNING) {
      return;
    }
    try {
      const events = await DiagnosticLog.read(context, 80);
      await this.applyDiagnosticError(context, events, language);
    } catch (error) {
      // 完整日志刷新稍后仍会重试；预检查失败不能阻断持久运行状态校正。
      console.error(`VPN diagnostic precheck failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    }
  }

  private applyDiagnosticStats(events: Array<DiagnosticEvent>): void {
    const connection = this.controller.getSnapshot();
    for (let index = 0; index < events.length; index++) {
      const event = events[index];
      if (event.uploadBytes !== undefined || event.downloadBytes !== undefined) {
        // 运行态只接受当前 VPN Extension 会话明确归属的心跳。仅比较时间戳无法抵御
        // 系统时钟回拨、旧日志迟到或切换到本地代理后的状态污染。
        if (!shouldApplyVpnDiagnosticStats(
          this.runtimeMode,
          this.status,
          this.startedAt,
          event.at,
          event.source,
          connection.vpnSessionId,
          event.sessionId
        )) {
          continue;
        }
        this.stats = {
          uploadBytes: event.uploadBytes ?? 0,
          downloadBytes: event.downloadBytes ?? 0,
          xrayRunning: event.xrayRunning ?? false,
          tunRunning: event.tunRunning ?? false,
          lastMessage: event.details ?? event.message
        };
        // Extension 自己会连续确认两次并发出本会话 vpn error 后清理。单条 stats=false
        // 可能只是原生查询抖动，不能在 UI 进程抢先拆隧道；跨进程状态另有短暂确认窗口。
        return;
      }
    }
  }

  // 心跳已经明确证明数据面不完整时，先清理残留 VPN，再保留错误态等待用户主动重连。
  // 不在此处调用 start，确保手动断开/异常断开之后都不会自行恢复。
  private async cleanupUnhealthyVpn(
    context: common.Context,
    language: AppLanguage,
    reason?: string
  ): Promise<void> {
    const message = reason ?? translate(language, 'runtime.vpnHealthLost');
    // refresh 可能由首页、日志页或网络监听同时触发；先同步封住第二次故障清理。
    this.status = ConnectionStatus.STOPPING;
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
    this.missingVpnStateSampleCount = 0;
    this.resetUnhealthyVpnStateConfirmation();
    this.appendLog(message);
  }

  // 本地代理与 UI 共进程：native 明确报告停止时立即处理，其余情况再探测实际 SOCKS
  // 监听器。异常退出时执行一次幂等停止以清理残余资源，但绝不自动启动。
  private async cleanupUnhealthyProxy(context: common.Context, language: AppLanguage): Promise<void> {
    const message = translate(language, 'runtime.proxyHealthLost');
    this.status = ConnectionStatus.STOPPING;
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

  private async applyDiagnosticError(
    context: common.Context,
    events: Array<DiagnosticEvent>,
    language: AppLanguage
  ): Promise<void> {
    if (events.length === 0) {
      return;
    }
    const connection = this.controller.getSnapshot();
    let event: DiagnosticEvent | null = null;
    // 日志按时间倒序返回。清理过程会在致命 error 后追加多条 info，不能只检查首条；
    // 同时必须精确匹配当前会话，避免上一会话的迟到错误拆除刚建立的新隧道。
    for (let index = 0; index < events.length; index++) {
      const candidate = events[index];
      if (shouldApplyVpnDiagnosticError(
        this.runtimeMode,
        this.status,
        this.startedAt,
        candidate.at,
        candidate.level,
        candidate.source,
        connection.vpnSessionId,
        candidate.details
      )) {
        event = candidate;
        break;
      }
    }
    if (event === null) {
      return;
    }
    const message = event.details !== undefined && event.details.length > 0 ? `${event.message} ${event.details}` : event.message;
    // Extension 的 error 均发生在启动失败或清理路径。不能只改 UI 状态而把底层
    // ConnectionController 留在 RUNNING，否则下一次手动连接会被误判为已经运行。
    await this.cleanupUnhealthyVpn(context, language, localizeCoreMessage(language, message));
  }
}

export const SHARED_RUNTIME_CONTROLLER: RuntimeController = new RuntimeController();
