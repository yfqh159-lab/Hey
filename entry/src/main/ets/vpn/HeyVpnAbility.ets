import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import { NetworkProbe } from '../services/NetworkProbe';
import {
  NetAutomationConfig,
  NetContext,
  NET_ACTION_DISCONNECT,
  NET_ACTION_NOOP,
  decideNetAutomationAction,
  networkContextSignature,
  networkTransportSignature,
  shouldReloadActiveCoreAfterNetworkChange
} from '../core/NetworkAutomation';
import { NetSceneStopFlag } from '../services/NetSceneStopFlag';
import { APP_MODE_VPN, AppLanguage, AppSettings, ConnectionStatus, resolveVpnInterfaceAddressConfig, RuntimeStats } from '../core/Profile';
import {
  createDefaultVpnConfig,
  normalizeVpnMtu,
  VPN_COMMAND_KEY,
  VPN_COMMAND_STOP,
  VPN_HANDOVER_CONFIG_KEY,
  VPN_HEALTH_PORT_KEY,
  VPN_PROFILE_UPDATED_AT_KEY,
  VPN_SETTINGS_SNAPSHOT_KEY,
  VPN_SESSION_ID_KEY,
  isValidVpnSessionId
} from './VpnConstants';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SettingsStore } from '../storage/SettingsStore';
import {
  getNativeStats,
  startNativeHevTun,
  startNativeSingbox,
  startNativeTun2Socks,
  startNativeXray,
  stopNativeSingbox,
  stopNativeTun2Socks,
  stopNativeXray
} from '../native/HeyNative';
import { VPN_DATA_SOCKS_HOST, VPN_DATA_SOCKS_PORT } from '../core/XrayConfig';
import { buildHevTunConfigYaml } from '../core/HevTunConfig';
import { isSingboxCore } from '../core/CoreSelection';
import { DiagnosticLog } from '../services/DiagnosticLog';
import {
  normalizeActiveVpnStartedAt,
  VpnRuntimeStateStore,
  shouldCleanupAfterVpnRuntimeStateWriteFailures
} from '../services/VpnRuntimeStateStore';
import { isRuntimeHealthPort, probeRuntimeSocksHealth, waitForRuntimeSocksHealth } from '../services/RuntimeHealthProbe';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { SPEED_NOTIFICATION_MANAGER } from '../services/SpeedNotificationManager';
import { CONTROL_CARD_MANAGER } from '../services/ControlCardManager';
import { DEFAULT_LANGUAGE } from '../core/I18n';
import { isVpnCleanupComplete } from '../core/RuntimeHealth';
import { areGeoAssetsStableForCore, assertGeoAssetsStableForCore } from '../services/GeoCoreReadiness';
import { VpnStartCancellationStore } from '../services/VpnStartCancellationStore';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'HeyVpnAbility';
const STATS_INTERVAL_MS: number = 2000;
// 即使用户关闭速度显示，也要持续回写低频健康心跳。主进程与 VPN Extension
// 分属不同进程，不能用主进程 native 全局变量判断隧道是否仍在运行。
const HEALTH_INTERVAL_MS: number = 5000;
const RUNTIME_STATE_INTERVAL_MS: number = 4000;
// 连续两次采样都看不到核心或 TUN 才判定失效，避免单次桥查询抖动误拆连接。
const UNHEALTHY_SAMPLE_LIMIT: number = 2;
const PROTECT_PROCESS_TIMEOUT_MS: number = 10000;
// Extension 的完整启动确认窗口为 25 秒；create() 留出后续 10 秒进程保护与 5 秒
// SOCKS 就绪检查。超时只停止等待，底层 Promise 仍由 observeVpnCreateCompletion 跟踪。
const VPN_CREATE_TIMEOUT_MS: number = 8000;
// 主进程只等待 15 秒确认完整清理。系统 destroy() 若永久 pending，Extension 不能把
// cleaningUp 永久锁死；8 秒后如实回写 cleanup incomplete，保留连接引用供用户重试停止。
const VPN_DESTROY_TIMEOUT_MS: number = 8000;
const VPN_START_SETTINGS_TIMEOUT_MS: number = 5000;
const NOTIFICATION_CANCEL_TIMEOUT_MS: number = 2000;
const CONTROL_CARD_RESET_TIMEOUT_MS: number = 2000;
const NET_SCENE_BASELINE_TIMEOUT_MS: number = 2000;
const NET_SCENE_POLL_STEP_TIMEOUT_MS: number = 3000;
// 网络场景轮询间隔：VPN 扩展进程后台存活，自驱动定时器可跑（区别于后台收不到的 connection.on 事件）。
const NET_SCENE_POLL_MS: number = 5000;

// protectProcessNet 自 HarmonyOS API 22 提供，而工程仍以 API 21 SDK 为兼容构建基线。
// 用局部能力接口隔离新增 API，避免仅因静态 SDK 类型缺少该成员而无法构建；低于 API 22
// 时由 VpnConfig 排除自身 bundle 的既有路径防回环，本地代理模式不经过这里。
interface ProcessNetworkProtector {
  protectProcessNet(): Promise<void>;
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timerId = setTimeout(() => {
      reject(new Error(message));
    }, timeoutMs);
    promise.then((value: T) => {
      clearTimeout(timerId);
      resolve(value);
    }, (error: Object) => {
      clearTimeout(timerId);
      reject(error);
    });
  });
}

export default class HeyVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  // destroy() 的系统 Promise 无法由外层超时取消。同一个 VpnConnection 在真正结算前
  // 始终复用同一销毁任务，避免用户重试停止时堆积系统调用。
  private vpnDestroyInFlight: Promise<void> | null = null;
  private vpnDestroyConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private statsTimerId: number = -1;
  private sessionId: string = '';
  private startedAt: number = 0;
  private activeCoreType: string = 'xray';
  private activeProfileUpdatedAt: number = 0;
  private activeLanguage: AppLanguage = DEFAULT_LANGUAGE;
  private lastRuntimeStateAt: number = 0;
  private runtimeStateWriteFailureCount: number = 0;
  private cleaningUp: boolean = false;
  private cleanupAgainRequested: boolean = false;
  // 一旦系统销毁、用户停止、网络场景断开或健康检查失败，当前启动协程不得再继续
  // 创建 TUN / 启动核心 / 回写 active。该闩锁在单次会话内只会 false→true；系统复用同一
  // Ability 实例承接下一次用户明确启动时，由 beginSession 重置并用 generation 隔离旧协程。
  private stopRequested: boolean = false;
  private unhealthySampleCount: number = 0;
  private healthProbeInFlight: boolean = false;
  private runtimeHealthProbePort: number = 0;
  private activeConfigJson: string = '';
  private activeHandoverConfigJson: string = '';
  private coreReloading: boolean = false;
  // 网络场景自动化（后台断开）：VPN 扩展进程内轮询网络，切到可信网络即拆隧道。
  private netScenePollTimerId: number = -1;
  private netSceneSignature: string = '';
  private netSceneTransportSignature: string = '';
  private netSceneSeeded: boolean = false;
  private netScenePollInFlight: boolean = false;
  // startVpnExtensionAbility 在已有 Extension 实例上会再次进入 onRequest。后台自清理
  // 只销毁 VPN/TUN，不应假设系统必然同时重建 Ability；保留一次明确的新启动请求，
  // 等旧资源已确认清理后在同一实例启动。该字段绝不由健康检查自行填充。
  private pendingStartWant: Want | null = null;
  private lastCleanupComplete: boolean = false;
  private destroying: boolean = false;
  private sessionGeneration: number = 0;
  private vpnCreateInFlight: boolean = false;
  // 自身判定必须终止且等待用户手动重连时，原启动 Want 必须先进入跨进程取消集。
  // 标志落盘失败则本轮清理不能宣称完整，避免系统重投递旧 Want 后静默复活 TUN。
  private restartFenceReliable: boolean = true;
  // 外层轮询超时不能取消 ArkData Promise。永久 pending 时后续 5 秒轮询复用同一
  // 底层读取，避免后台会话不断向 SettingsStore 串行队列追加任务。
  private settingsLoadInFlight: Promise<AppSettings> | null = null;
  // NetworkKit Promise 同样无法由 withTimeout 取消。启动基线与后续轮询共用一个
  // 底层探针，避免物理网络查询永久 pending 时每 5 秒继续堆积系统调用。
  private networkProbeInFlight: Promise<NetContext> | null = null;

  onCreate(want: Want): void {
    this.destroying = false;
    this.beginSession(want);
  }

  private beginSession(want: Want): void {
    const sessionGeneration = ++this.sessionGeneration;
    this.startedAt = Date.now();
    const requestedSessionId = this.getStringParameter(want, VPN_SESSION_ID_KEY, '');
    const requestedSessionValid = isValidVpnSessionId(requestedSessionId);
    this.sessionId = this.resolveSessionId(want);
    this.activeCoreType = isSingboxCore(this.getStringParameter(want, 'coreType', 'xray')) ? 'singbox' : 'xray';
    this.activeProfileUpdatedAt = this.getNonNegativeIntegerParameter(want, VPN_PROFILE_UPDATED_AT_KEY);
    this.stopRequested = false;
    this.cleanupAgainRequested = false;
    this.lastCleanupComplete = false;
    this.unhealthySampleCount = 0;
    this.healthProbeInFlight = false;
    this.runtimeStateWriteFailureCount = 0;
    this.lastRuntimeStateAt = 0;
    this.runtimeHealthProbePort = 0;
    this.activeConfigJson = '';
    this.activeHandoverConfigJson = '';
    this.coreReloading = false;
    this.netSceneSignature = '';
    this.netSceneTransportSignature = '';
    this.netSceneSeeded = false;
    this.netScenePollInFlight = false;
    this.restartFenceReliable = true;
    // 当前版本的所有显式启动都必须携带一次性会话 ID。缺失/损坏 ID 的升级遗留或异常
    // 重投递请求无法和停止意图绑定，必须在创建任何系统/原生资源前拒绝。停止命令仍可
    // 使用内部回退 ID 执行幂等清理。
    if (!this.isStopCommand(want) && !requestedSessionValid) {
      this.emitError('VPN start failed.',
        `session=${this.sessionId}; error=VPN start session ID is missing or invalid.`);
      this.requestCleanup('VPN startup rejected because session identity is unavailable.',
        `session=${this.sessionId}`);
      return;
    }
    const cancellation = VpnStartCancellationStore.check(this.context, this.sessionId);
    if (!cancellation.reliable || cancellation.cancelled) {
      const reason = cancellation.cancelled ? 'the start session was cancelled' :
        'the start cancellation state is unreadable';
      this.emitError('VPN start failed.', `session=${this.sessionId}; error=${reason}.`);
      this.requestCleanup('VPN startup rejected before creating system resources.',
        `session=${this.sessionId}; reason=${reason}`);
      return;
    }
    // 新会话尚未完成核心 + TUN 启动，先覆盖上次可能残留的 active 心跳。只有完整数据面
    // 就绪后 startVpn 才会写 active=true，主进程重建时不会把“启动中”误接管为已连接。
    const initialized = VpnRuntimeStateStore.write(this.context,
      VpnRuntimeStateStore.stopped(
        this.sessionId, this.startedAt, this.activeCoreType, this.activeProfileUpdatedAt));
    if (!initialized) {
      // ConnectionController waits for this exact terminal event before deciding
      // whether the system start request succeeded.
      this.emitError('VPN start failed.',
        `session=${this.sessionId}; error=VPN runtime state initialization failed.`);
      this.requestCleanup('VPN startup cancelled because runtime state is unavailable.',
        `session=${this.sessionId}`);
      return;
    }
    this.emitInfo('VPN ability created.', `session=${this.sessionId}`);
    if (this.isStopCommand(want)) {
      this.restartFenceReliable = this.persistRestartFence();
      this.requestCleanup('VPN stop command received on create.', 'startId=0');
      return;
    }
    this.startVpn(want, sessionGeneration).catch((error: Object) => {
      if (sessionGeneration !== this.sessionGeneration) {
        return;
      }
      this.emitError('VPN start task failed.', this.errorMessage(error));
    });
  }

  onRequest(want: Want, startId: number): void {
    if (this.isStopCommand(want)) {
      const targetSessionId = this.getStringParameter(want, VPN_SESSION_ID_KEY, '');
      if (targetSessionId.length > 0 && targetSessionId !== this.sessionId) {
        this.emitInfo('Stale VPN stop command ignored.',
          `session=${this.sessionId}; targetSession=${targetSessionId}; startId=${startId}`);
        return;
      }
      this.restartFenceReliable = this.persistRestartFence();
      this.pendingStartWant = null;
      this.requestCleanup('VPN stop command received.', `startId=${startId}`);
      return;
    }
    if (this.destroying || !this.stopRequested) {
      // 活跃/启动中的同会话仍拒绝重复 start，避免两套核心或 TUN 重叠。
      this.emitInfo('VPN request ignored.', `startId=${startId}, session=${this.sessionId}`);
      return;
    }
    // 只有外部明确再次调用 startVpnExtensionAbility 才会来到这里。若旧会话的清理仍在
    // 进行，先暂存于内存；清理成功后消费一次，失败则丢弃并回写新会话启动失败。
    this.pendingStartWant = want;
    if (this.cleaningUp || this.vpnCreateInFlight || !this.lastCleanupComplete) {
      this.cleanupAgainRequested = true;
      this.cleanup().catch((error: Object) => {
        this.emitError('VPN cleanup before a new request failed.', this.errorMessage(error));
      });
      return;
    }
    this.startPendingSessionIfReady();
  }

  onDestroy(): void {
    this.destroying = true;
    this.pendingStartWant = null;
    this.emitInfo('VPN ability destroying.', `session=${this.sessionId}`);
    // 即使 createVpnConnection 尚未完成也要置停止闩锁；否则异步启动协程可能在
    // onDestroy 返回后继续启动核心。cleanup 的同步前半段会先写 inactive 并停原生组件。
    this.requestCleanup('VPN destroy cleanup requested.', `session=${this.sessionId}`);
  }

  private async startVpn(want: Want, sessionGeneration: number): Promise<void> {
    const configJson = this.getStringParameter(want, 'xrayConfigJson', '');
    this.activeConfigJson = configJson;
    const handoverConfigJson = this.getStringParameter(want, VPN_HANDOVER_CONFIG_KEY, '');
    this.activeHandoverConfigJson = handoverConfigJson.length > 0 ? handoverConfigJson : configJson;
    const useSingbox = isSingboxCore(this.getStringParameter(want, 'coreType', 'xray'));
    this.activeCoreType = useSingbox ? 'singbox' : 'xray';
    // TUN 数据面固定把流量交给主进程传入的回环 SOCKS 入口；完整配置若没有
    // 对应监听器也必须启动失败，不能在不可转发时虚报 VPN 已连接。
    const requestedHealthPort = Number(this.getStringParameter(want, VPN_HEALTH_PORT_KEY, '0'));
    this.runtimeHealthProbePort = isRuntimeHealthPort(requestedHealthPort) ? requestedHealthPort : 0;

    try {
      this.emitInfo('VPN start requested.', `core=${useSingbox ? 'singbox' : 'xray'}, configBytes=${configJson.length}`);
      // 系统可能在 UIAbility 不存在时单独重建 VPN Extension。若共享沙箱里仍有 Geo
      // rename 事务工件，不能让扩展进程与 UI 并发恢复，也不能把半套文件交给核心。
      assertGeoAssetsStableForCore(this.context.filesDir);
      this.ensureStartAllowed('Geo data transaction check', sessionGeneration);
      // 明确的新启动在创建任何数据面前废弃上一会话的自动断开标志，并等待文件操作
      // 完成。运行后不再异步清除，避免覆盖本会话刚写入的可信网络断开证据。
      try {
        await NetSceneStopFlag.clear(this.context, this.sessionId);
      } catch (error) {
        // 会话 ID 会隔离旧标志；清理失败不应把新连接直接判成启动失败。
        this.emitInfo('Network scene stop flag reset failed.', this.errorMessage(error));
      }
      this.ensureStartAllowed('network scene stop flag reset', sessionGeneration);
      // 不再做 testNativeXrayConfig 预检：重编后的 libXray 的 CGoTestXray 冷 cgo 入口
      // 会在 VPN 扩展进程里 SIGSEGV（真机 ALN-AL80 / HarmonyOS 6.1 复现，崩在本行附近，
      // Go-on-musl 的 TLS/栈问题），导致扩展进程当场死亡、无法回写启动状态。预检本就是
      // 非阻塞诊断，startNativeXray 才是真相来源，直接走它（与 1.1 行为一致）。

      const settings = await this.resolveStartSettings(want);
      this.activeLanguage = settings.language;
      this.ensureStartAllowed('settings load', sessionGeneration);
      await this.seedNetSceneBaseline(settings.netAutomationEnabled, sessionGeneration);
      this.ensureStartAllowed('underlying network baseline', sessionGeneration);
      const perAppEnabled = settings.perAppProxyEnabled;
      const bypassMode = settings.perAppProxyBypass ?? false;
      const appList = settings.perAppProxyList ?? [];
      const vpnMtu = normalizeVpnMtu(settings.vpnMtu);
      const addressConfig = resolveVpnInterfaceAddressConfig(settings.vpnInterfaceAddressIndex);
      const vpnConfig = createDefaultVpnConfig(
        perAppEnabled,
        bypassMode,
        appList,
        settings.vpnDns,
        settings.ipv6Enabled,
        vpnMtu,
        settings.vpnInterfaceAddressIndex,
        settings.vpnBypassLan,
        settings.routingRules,
        settings.trafficMode === 'rules' && settings.routeOnlyEnabled
      );
      const dnsAddresses = vpnConfig.dnsAddresses ?? [];
      // 设置快照、兼容读取和网络基线都完成后才取得连接对象；前置任务失败或超时时，
      // 不必对一个从未 create() 的 VpnConnection 执行额外销毁。
      const creatingConnection = vpnExtension.createVpnConnection(this.context);
      this.vpnConnection = creatingConnection;
      this.emitInfo('Creating VPN connection.');
      this.vpnCreateInFlight = true;
      const createPromise = creatingConnection.create(vpnConfig);
      this.observeVpnCreateCompletion(creatingConnection, createPromise, sessionGeneration);
      this.tunFd = await withTimeout(
        createPromise,
        VPN_CREATE_TIMEOUT_MS,
        'VPN interface creation timed out.'
      );
      if (this.stopRequested && this.vpnConnection === null) {
        // cleanup 可能已在 create() 返回前成功 destroy 并清空成员引用。若系统随后仍返回
        // 一个迟到的 TUN fd，重新登记原连接，让启动 catch 的下一轮幂等清理能够再次
        // destroy；否则只剩 tunFd 数字而没有可释放它的 VpnConnection。
        this.vpnConnection = creatingConnection;
        this.cleanupAgainRequested = true;
      }
      this.ensureStartAllowed('VPN interface creation', sessionGeneration);
      this.emitInfo('VPN created.', `tunFd=${this.tunFd}, dns=${dnsAddresses.join(',')}, ipv6=${settings.ipv6Enabled}, preferIpv6=${settings.preferIpv6}, mtu=${vpnMtu}, address=${addressConfig.displayName}, bypassLan=${settings.vpnBypassLan}`);

      // API 22+ 再做进程级保护，且必须发生在核心创建任何 outbound / DNS socket 之前。
      // API 21 及保护调用异常时仍有 VpnConfig 的 blocked/trustedApplications 约束保证
      // Hey 自身 bundle 不进入 TUN；记录降级原因，便于真机区分系统能力与数据面故障。
      try {
        const protector = this.vpnConnection as Object as ProcessNetworkProtector;
        const protection = protector.protectProcessNet();
        await withTimeout(protection, PROTECT_PROCESS_TIMEOUT_MS, 'VPN process network protection timed out.');
        this.emitInfo('VPN process network protection enabled.');
      } catch (error) {
        this.emitInfo('VPN process network protection unavailable; self-bundle exclusion remains active.',
          this.errorMessage(error));
      }
      this.ensureStartAllowed('VPN process network protection', sessionGeneration);

      // 两个内核统一走 tun2socks 数据面：内核在 127.0.0.1:VPN_DATA_SOCKS_PORT 起本地
      // SOCKS 入站，再把 Harmony TUN fd 的流量转发进去。sing-box 因此不需要把 tun fd
      // 交给核心（无 OpenTun / gvisor tun 栈），与 Xray 路径一致。
      // 首次检查之后已经经过设置读取、网络探测和系统 VPN 创建；UI 进程可能在这些
      // await 期间开始 Geo rename，因此在真正进入原生核心前必须再次 fail-closed。
      assertGeoAssetsStableForCore(this.context.filesDir);
      const coreResult = useSingbox
        ? startNativeSingbox(configJson, this.context.filesDir)
        : startNativeXray(configJson, this.context.filesDir);
      if (!coreResult.ok) {
        throw new Error(coreResult.message);
      }
      // UI 更新与 Extension 位于不同进程，事务也可能恰好在上一次检查后开始。若核心
      // 启动返回时仍可见替换工件，立即走启动失败清理，绝不报告 VPN 已连接。
      assertGeoAssetsStableForCore(this.context.filesDir);
      this.ensureStartAllowed('core startup', sessionGeneration);
      this.emitInfo(`${useSingbox ? 'sing-box' : 'Xray'} started.`, coreResult.message);

      if (this.runtimeHealthProbePort <= 0) {
        throw new Error('VPN data-plane SOCKS health port is missing.');
      }
      const coreReady = await waitForRuntimeSocksHealth(this.runtimeHealthProbePort);
      this.ensureStartAllowed('core SOCKS readiness', sessionGeneration);
      if (!coreReady.ok) {
        throw new Error(`Core SOCKS data entry did not become ready: ${coreReady.status}`);
      }
      this.emitInfo('Core SOCKS data entry is ready.', `port=${this.runtimeHealthProbePort}`);

      // 数据面引擎二选一：useHevTun=true 走 hev-socks5-tunnel（高性能，libhevsocks5tun.so），
      // 否则走默认 gvisor/xjasonlyu（libheytun2socks.so）。两者都把 TUN fd 转发到同一个
      // 本地 SOCKS 入站，只是实现不同。停止时统一调 stopNativeTun2Socks（原生侧按引擎分发）。
      const useHevTun = settings.useHevTun;
      const tun2socksResult = useHevTun
        ? startNativeHevTun(
            this.tunFd,
            buildHevTunConfigYaml(vpnMtu, VPN_DATA_SOCKS_HOST, VPN_DATA_SOCKS_PORT, settings.hevTunLogLevel, settings.hevTunRwTimeout)
          )
        : startNativeTun2Socks(this.tunFd, VPN_DATA_SOCKS_HOST, VPN_DATA_SOCKS_PORT, vpnMtu);
      if (!tun2socksResult.ok) {
        throw new Error(tun2socksResult.message);
      }
      this.ensureStartAllowed('TUN data-plane startup', sessionGeneration);
      this.emitInfo('tun data plane started.', `engine=${useHevTun ? 'hev' : 'gvisor'}, ${VPN_DATA_SOCKS_HOST}:${VPN_DATA_SOCKS_PORT}, mtu=${vpnMtu}, core=${useSingbox ? 'singbox' : 'xray'}, ${tun2socksResult.message}`);

      const activeAt = Date.now();
      const activeStateStored = VpnRuntimeStateStore.write(this.context, {
        sessionId: this.sessionId,
        active: true,
        startedAt: normalizeActiveVpnStartedAt(this.startedAt, activeAt),
        heartbeatAt: activeAt,
        coreType: this.activeCoreType,
        profileUpdatedAt: this.activeProfileUpdatedAt,
        xrayRunning: true,
        tunRunning: true
      });
      if (!activeStateStored) {
        throw new Error('VPN runtime state could not be persisted.');
      }
      this.lastRuntimeStateAt = activeAt;
      this.runtimeStateWriteFailureCount = 0;

      this.startStatsTimer(settings.speedEnabled ? STATS_INTERVAL_MS : HEALTH_INTERVAL_MS, sessionGeneration);
      if (!settings.speedEnabled) {
        this.emitInfo('Speed display disabled; low-frequency VPN health heartbeat remains enabled.');
      }
      this.emitInfo('Native VPN bridge started.', `session=${this.sessionId}`);
      this.startNetScenePoll(sessionGeneration);
    } catch (error) {
      if (sessionGeneration !== this.sessionGeneration) {
        return;
      }
      this.emitError('VPN start failed.', `session=${this.sessionId}; error=${this.errorMessage(error)}`);
      await this.cleanup();
    }
  }

  private observeVpnCreateCompletion(
    connection: vpnExtension.VpnConnection,
    createPromise: Promise<number>,
    sessionGeneration: number
  ): void {
    createPromise.then((lateTunFd: number) => {
      this.vpnCreateInFlight = false;
      if (sessionGeneration !== this.sessionGeneration || this.stopRequested || this.destroying) {
        // withTimeout 只结束 ArkTS 的启动等待，不能取消系统 create()。若它在停止或
        // 销毁之后才返回，重新登记原 connection/fd 并立刻补一轮幂等清理，禁止迟到
        // 的系统 TUN 脱离生命周期追踪。
        if (this.vpnConnection === null) {
          this.vpnConnection = connection;
        }
        this.tunFd = lateTunFd;
        this.cleanupAgainRequested = true;
        this.cleanup().catch((error: Object) => {
          this.emitError('Late VPN create cleanup failed.', this.errorMessage(error));
        });
      }
    }, (error: Object) => {
      this.vpnCreateInFlight = false;
      if (sessionGeneration !== this.sessionGeneration || this.stopRequested || this.destroying) {
        this.cleanupAgainRequested = true;
        this.cleanup().catch((cleanupError: Object) => {
          this.emitError('Rejected VPN create cleanup failed.',
            `${this.errorMessage(error)}; cleanup=${this.errorMessage(cleanupError)}`);
        });
      }
    });
  }

  private async resolveStartSettings(want: Want): Promise<AppSettings> {
    const snapshotJson = this.getStringParameter(want, VPN_SETTINGS_SNAPSHOT_KEY, '');
    if (snapshotJson.length === 0) {
      // 兼容升级前或系统重投递的旧启动请求；新请求始终携带原子设置快照。
      return withTimeout(
        this.loadSettingsForNetScene(),
        VPN_START_SETTINGS_TIMEOUT_MS,
        'Legacy VPN start settings load timed out.'
      );
    }
    const selection = SettingsStore.selectStoredSettings(snapshotJson, '');
    if (selection.settings === null) {
      throw new Error('VPN start settings snapshot is invalid.');
    }
    return selection.settings;
  }

  // 在 VPN 扩展生命周期内用自驱动定时器尽力轮询网络场景，补充 UI 进程退后台后可能
  // 收不到的 connection.on 事件；实际触发频率仍服从 HarmonyOS 的后台与省电调度。
  private startNetScenePoll(sessionGeneration: number): void {
    this.stopNetScenePoll();
    this.netScenePollTimerId = setInterval(() => {
      this.pollNetScene(sessionGeneration);
    }, NET_SCENE_POLL_MS);
    // 启动阶段可能跨越 VPN 授权、核心与 TUN 就绪等待；完成后立即对照启动前基线，
    // 避免恰好发生在首个 5 秒定时器前的 Wi-Fi/蜂窝切换被当作初始网络漏掉。
    this.pollNetScene(sessionGeneration);
  }

  private async seedNetSceneBaseline(automationEnabled: boolean, sessionGeneration: number): Promise<void> {
    try {
      const ctx = await withTimeout(
        this.loadNetworkContextForNetScene(),
        NET_SCENE_BASELINE_TIMEOUT_MS,
        'Underlying network baseline timed out.'
      );
      if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.stopRequested) {
        return;
      }
      this.netSceneSeeded = true;
      this.netSceneSignature = networkContextSignature(ctx);
      this.netSceneTransportSignature = networkTransportSignature(ctx);
      this.emitInfo('Underlying network baseline recorded.',
        `kind=${ctx.kind}; ssid=${ctx.ssid === undefined ? '<none>' : '<redacted>'}; automation=${automationEnabled}`);
    } catch (error) {
      if (sessionGeneration !== this.sessionGeneration) {
        return;
      }
      // 连续性观测是辅助能力；拿不到基线时连接仍可继续，完成后的立即轮询会只 seed
      // 当前承载而不贸然重载或自动断开。
      this.netSceneSeeded = false;
      this.netSceneSignature = '';
      this.netSceneTransportSignature = '';
      this.emitInfo('Underlying network baseline unavailable; first poll will seed it.',
        this.errorMessage(error));
    }
  }

  private stopNetScenePoll(): void {
    if (this.netScenePollTimerId >= 0) {
      clearInterval(this.netScenePollTimerId);
      this.netScenePollTimerId = -1;
    }
  }

  private async pollNetScene(sessionGeneration: number): Promise<void> {
    if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.stopRequested || this.netScenePollInFlight) {
      return;
    }
    this.netScenePollInFlight = true;
    try {
      const settings = await withTimeout(
        this.loadSettingsForNetScene(),
        NET_SCENE_POLL_STEP_TIMEOUT_MS,
        'Network scene settings load timed out.'
      );
      if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.stopRequested) {
        return;
      }
      const ctx = await withTimeout(
        this.loadNetworkContextForNetScene(),
        NET_SCENE_POLL_STEP_TIMEOUT_MS,
        'Underlying network poll timed out.'
      );
      if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.stopRequested) {
        return;
      }
      const signature = networkContextSignature(ctx);
      const transportSignature = networkTransportSignature(ctx);
      // 首次只 seed 不动作——避免拆掉用户「在可信网络手动开的 VPN」；仅对之后的网络切换生效。
      if (!this.netSceneSeeded) {
        this.netSceneSeeded = true;
        this.netSceneSignature = signature;
        this.netSceneTransportSignature = transportSignature;
        this.emitInfo('Underlying network observed.',
          `kind=${ctx.kind}; ssid=${ctx.ssid === undefined ? '<none>' : '<redacted>'}; automation=${settings.netAutomationEnabled}`);
        return;
      }
      if (signature === this.netSceneSignature) {
        return;
      }
      const transportChanged = transportSignature !== this.netSceneTransportSignature;
      this.netSceneSignature = signature;
      this.netSceneTransportSignature = transportSignature;
      this.emitInfo('Underlying network changed.',
        `kind=${ctx.kind}; ssid=${ctx.ssid === undefined ? '<none>' : '<redacted>'}; automation=${settings.netAutomationEnabled}`);
      const cfg: NetAutomationConfig = {
        enabled: settings.netAutomationEnabled,
        // 固定为「仅可信网络自动断开」——不做自动连接（已移除方向选项）。
        trustedSsids: settings.netAutomationTrustedSsids,
        cellularTrusted: settings.netAutomationCellularTrusted
      };
      const action = decideNetAutomationAction(ctx, cfg, true);
      let effectiveAction = action;
      this.emitInfo('Net scene decision.', `kind=${ctx.kind}; action=${action}`);
      if (action === NET_ACTION_DISCONNECT) {
        // 初次设置读取与网络探测之间可能恰逢用户关闭自动化或修改可信网络。拆除数据面
        // 属于破坏性动作，必须用同一会话内第二次持久设置读取确认；读取失败时保留 VPN，
        // 仍允许下面按普通承载切换重载核心。
        const disconnectConfirmed = await this.confirmNetSceneDisconnect(ctx, sessionGeneration);
        if (disconnectConfirmed) {
          this.emitInfo('Net scene: trusted network, auto-disconnecting.', `kind=${ctx.kind}`);
          const stoppedAt = Date.now();
          // 实际数据面清理优先于辅助 UI 标志。cleanup() 在首个系统 destroy await 前已
          // 同步置停止闩锁、写 inactive 并停止核心/tun2socks；即使文件系统写标志卡顿，
          // 也不能继续让代理承载流量。时间戳取触发时刻，迟到落盘不会命中新会话。
          this.requestCleanupWithoutRestart(
            'Network scene auto-disconnect.', `session=${this.sessionId}`);
          // 写跨进程标志，供主进程回前台校正「运行中」滞留状态。
          try {
            await NetSceneStopFlag.markStopped(this.context, stoppedAt, this.sessionId);
          } catch (error) {
            // 标志只辅助 UI 跨进程校正；落盘失败不能阻止实际 VPN 清理。
            this.emitInfo('Net scene stop flag write failed.', this.errorMessage(error));
          }
          return;
        }
        this.emitInfo('Net scene auto-disconnect skipped after settings confirmation.',
          `kind=${ctx.kind}; session=${this.sessionId}`);
        effectiveAction = NET_ACTION_NOOP;
      }
      if (transportChanged && shouldReloadActiveCoreAfterNetworkChange(ctx, effectiveAction)) {
        // 蜂窝→Wi-Fi 常是 make-before-break：旧核心连接可能仍挂在即将消失的承载上。
        // 只重载当前核心并保留 VPN/TUN，迫使域名解析和新出站使用当前默认网络；一次网络
        // 签名变化最多执行一次。失败时清理整个会话，等待用户手动重连。
        await this.reloadCoreAfterNetworkChange(sessionGeneration);
      }
    } catch (error) {
      if (sessionGeneration === this.sessionGeneration && !this.cleaningUp && !this.stopRequested) {
        this.emitInfo('Net scene poll failed.', this.errorMessage(error));
      }
    } finally {
      if (sessionGeneration === this.sessionGeneration) {
        this.netScenePollInFlight = false;
      }
    }
  }

  private async reloadCoreAfterNetworkChange(sessionGeneration: number): Promise<void> {
    if (sessionGeneration !== this.sessionGeneration || this.coreReloading || this.cleaningUp ||
      this.stopRequested || this.activeConfigJson.length === 0) {
      return;
    }
    // Geo 更新由 UI 进程执行；若它正处于 rename 窗口，保留当前已加载的健康核心，
    // 不并发读半套文件，也不把安全延迟误判成切网恢复失败而拆掉 VPN。清空已提交的
    // 承载签名，让下一轮 5 秒轮询在事务结束后再次识别同一变化并重试。
    if (!areGeoAssetsStableForCore(this.context.filesDir)) {
      this.netSceneSignature = '';
      this.netSceneTransportSignature = '';
      this.emitInfo('Core reload deferred while Geo data replacement is in progress.',
        `session=${this.sessionId}`);
      return;
    }
    this.coreReloading = true;
    try {
      this.ensureStartAllowed('network handover core reload', sessionGeneration);
      const stopResult = this.activeCoreType === 'singbox' ? stopNativeSingbox() : stopNativeXray();
      if (!stopResult.ok) {
        throw new Error(stopResult.message);
      }
      this.ensureStartAllowed('network handover core stop', sessionGeneration);
      // 另一个进程可能在前一次目录检查后才开始 rename。旧核心已经停止时只能继续
      // fail-closed，不能让新核心读取一半旧、一半新的规则文件。
      assertGeoAssetsStableForCore(this.context.filesDir);
      const startResult = this.activeCoreType === 'singbox'
        ? startNativeSingbox(this.activeHandoverConfigJson, this.context.filesDir)
        : startNativeXray(this.activeHandoverConfigJson, this.context.filesDir);
      if (!startResult.ok) {
        throw new Error(startResult.message);
      }
      assertGeoAssetsStableForCore(this.context.filesDir);
      this.ensureStartAllowed('network handover core start', sessionGeneration);
      if (this.runtimeHealthProbePort <= 0) {
        throw new Error('VPN data-plane SOCKS health port is missing after network handover.');
      }
      const ready = await waitForRuntimeSocksHealth(this.runtimeHealthProbePort);
      this.ensureStartAllowed('network handover SOCKS readiness', sessionGeneration);
      if (!ready.ok) {
        throw new Error(`Core SOCKS data entry did not recover after network handover: ${ready.status}`);
      }
      this.unhealthySampleCount = 0;
      this.lastRuntimeStateAt = 0;
      this.emitInfo('Core reloaded after underlying network change.',
        `core=${this.activeCoreType}; session=${this.sessionId}`);
    } catch (error) {
      if (sessionGeneration === this.sessionGeneration && !this.stopRequested && !this.cleaningUp) {
        this.emitError('Core reload after underlying network change failed.',
          `session=${this.sessionId}; error=${this.errorMessage(error)}`);
        this.requestCleanupWithoutRestart(
          'Network handover recovery failed; cleaning up without reconnecting.',
          `session=${this.sessionId}`);
      }
    } finally {
      if (sessionGeneration === this.sessionGeneration) {
        this.coreReloading = false;
      }
    }
  }

  private loadSettingsForNetScene(): Promise<AppSettings> {
    if (this.settingsLoadInFlight !== null) {
      return this.settingsLoadInFlight;
    }
    const promise = SETTINGS_CONTROLLER.load(this.context);
    this.settingsLoadInFlight = promise;
    promise.then(
      (_settings: AppSettings): void => this.releaseSettingsLoad(promise),
      (_error: Object): void => this.releaseSettingsLoad(promise)
    );
    return promise;
  }

  private loadNetworkContextForNetScene(): Promise<NetContext> {
    if (this.networkProbeInFlight !== null) {
      return this.networkProbeInFlight;
    }
    const promise = NetworkProbe.readCurrentNetContext();
    this.networkProbeInFlight = promise;
    promise.then(
      (_ctx: NetContext): void => this.releaseNetworkProbe(promise),
      (_error: Object): void => this.releaseNetworkProbe(promise)
    );
    return promise;
  }

  private async confirmNetSceneDisconnect(ctx: NetContext, sessionGeneration: number): Promise<boolean> {
    try {
      const settings = await withTimeout(
        this.loadSettingsForNetScene(),
        NET_SCENE_POLL_STEP_TIMEOUT_MS,
        'Network auto-disconnect confirmation timed out.'
      );
      if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.stopRequested) {
        return false;
      }
      const cfg: NetAutomationConfig = {
        enabled: settings.netAutomationEnabled,
        trustedSsids: settings.netAutomationTrustedSsids,
        cellularTrusted: settings.netAutomationCellularTrusted
      };
      return decideNetAutomationAction(ctx, cfg, true) === NET_ACTION_DISCONNECT;
    } catch (error) {
      if (sessionGeneration === this.sessionGeneration && !this.cleaningUp && !this.stopRequested) {
        this.emitInfo('Net scene auto-disconnect confirmation failed; keeping VPN active.',
          this.errorMessage(error));
      }
      return false;
    }
  }

  private releaseSettingsLoad(promise: Promise<AppSettings>): void {
    if (this.settingsLoadInFlight === promise) {
      this.settingsLoadInFlight = null;
    }
  }

  private releaseNetworkProbe(promise: Promise<NetContext>): void {
    if (this.networkProbeInFlight === promise) {
      this.networkProbeInFlight = null;
    }
  }

  private getStringParameter(want: Want, key: string, fallback: string): string {
    const value = want.parameters?.[key];
    if (value === undefined || value === null) {
      return fallback;
    }
    return value.toString();
  }

  private resolveSessionId(want: Want): string {
    const requested = this.getStringParameter(want, VPN_SESSION_ID_KEY, '');
    if (isValidVpnSessionId(requested)) {
      return requested;
    }
    return this.startedAt.toString();
  }

  private getNonNegativeIntegerParameter(want: Want, key: string): number {
    const parsed = Number(this.getStringParameter(want, key, '0'));
    if (Number.isNaN(parsed) || parsed < 0) {
      return 0;
    }
    return Math.floor(parsed);
  }

  private isStopCommand(want: Want): boolean {
    return this.getStringParameter(want, VPN_COMMAND_KEY, '') === VPN_COMMAND_STOP;
  }

  private requestCleanup(message: string, details: string): void {
    this.stopRequested = true;
    this.emitInfo(message, details);
    this.cleanup().catch((error: Object) => {
      this.emitError('VPN cleanup task failed.', this.errorMessage(error));
    });
  }

  private requestCleanupWithoutRestart(message: string, details: string): void {
    this.restartFenceReliable = this.persistRestartFence();
    this.requestCleanup(message, details);
  }

  private persistRestartFence(): boolean {
    const existing = VpnStartCancellationStore.check(this.context, this.sessionId);
    if (existing.reliable && existing.cancelled) {
      return true;
    }
    const stored = VpnStartCancellationStore.markCancelled(this.context, this.sessionId);
    if (!stored) {
      this.emitError('VPN restart cancellation marker could not be persisted.',
        `session=${this.sessionId}`);
    }
    return stored;
  }

  private async cleanup(): Promise<void> {
    this.stopRequested = true;
    if (this.cleaningUp) {
      // cleanup 可能正 await destroy()，而启动协程在此期间刚拿到迟到的 tun fd。
      // 记录重入请求，让在途清理完成后再扫一遍全部原生资源。
      this.cleanupAgainRequested = true;
      return;
    }
    this.cleaningUp = true;
    // 通知由 UI 进程发布，但 VPN 可能在 UI 被挂起/回收后由扩展自行清理。立即并行撤销，
    // 不能让“正在运行”的常驻通知晚于真实隧道状态；失败或超时不得阻塞 TUN/核心释放。
    const notificationCancel = this.cancelSpeedNotificationSafely();
    let cleanupCompleted = false;
    let cleanupDetails = '';
    try {
      do {
        this.cleanupAgainRequested = false;
        this.persistStoppedRuntimeState('before data-plane cleanup', false);
        this.stopNetScenePoll();
        this.stopStatsTimer();
        this.emitInfo('VPN cleanup started.', `tunFd=${this.tunFd}`);

        // 先停 tun2socks 适配器（停止往 SOCKS 转发），再停内核。各操作幂等（未运行即 no-op），
        // 无论本会话用哪条数据面都安全。
        const tun2socksResult = stopNativeTun2Socks();
        this.emitInfo('tun2socks stop requested.', tun2socksResult.message);
        const xrayResult = stopNativeXray();
        this.emitInfo('Xray stop requested.', xrayResult.message);
        const singboxResult = stopNativeSingbox();
        this.emitInfo('sing-box stop requested.', singboxResult.message);

        const connection = this.vpnConnection;
        let vpnDestroyed = connection === null;
        if (connection !== null) {
          try {
            await withTimeout(
              this.destroyVpnConnectionSingleFlight(connection),
              VPN_DESTROY_TIMEOUT_MS,
              'VPN connection destroy timed out.'
            );
            vpnDestroyed = true;
            this.emitInfo('VPN destroyed.');
          } catch (error) {
            const businessError = error as BusinessError;
            this.emitError('VPN destroy failed.', businessError.message ?? JSON.stringify(error));
          }
        }

        if (vpnDestroyed && this.vpnConnection === connection) {
          this.vpnConnection = null;
        }
        this.tunFd = -1;
        this.runtimeHealthProbePort = 0;
        cleanupCompleted = isVpnCleanupComplete(
          tun2socksResult.ok, xrayResult.ok, singboxResult.ok, vpnDestroyed) &&
          !this.vpnCreateInFlight && this.restartFenceReliable;
        this.lastCleanupComplete = cleanupCompleted;
        cleanupDetails = `tun=${tun2socksResult.ok}; xray=${xrayResult.ok}; singbox=${singboxResult.ok}; vpn=${vpnDestroyed}; createPending=${this.vpnCreateInFlight}; restartFence=${this.restartFenceReliable}`;
        const controlCardUpdate = this.updateControlCardAfterCleanupSafely(cleanupCompleted);
        // 保持 cleaningUp 闩锁直到附属界面状态也完成（或超时）；期间的重入停止请求只会
        // 设置 cleanupAgainRequested，并由下一轮重新扫描全部原生资源。
        await notificationCancel;
        await controlCardUpdate;
        this.persistStoppedRuntimeState('after cleanup completion', cleanupCompleted);
      } while (this.cleanupAgainRequested);
    } finally {
      this.cleaningUp = false;
    }
    // cleanupAgainRequested 可能在 do/while 已判定 false 之后、finally 解除 cleaningUp
    // 之前由迟到的 create()/停止请求置位。这里没有异步间隙地补接一轮，避免该请求
    // 落入循环边界而遗留 TUN 或核心；下一轮仍是停止/清理，不会触发重新连接。
    if (this.cleanupAgainRequested) {
      await this.cleanup();
      return;
    }
    // 配置只用于当前内存会话与切网重载；清理结束后立即释放其中可能包含的节点凭据。
    this.activeConfigJson = '';
    this.activeHandoverConfigJson = '';
    if (cleanupCompleted) {
      this.emitInfo('VPN cleanup finished.', `session=${this.sessionId}`);
      this.startPendingSessionIfReady();
    } else {
      const pending = this.pendingStartWant;
      this.pendingStartWant = null;
      this.emitError('VPN cleanup incomplete.', `session=${this.sessionId}; ${cleanupDetails}`);
      if (pending !== null && !this.destroying) {
        // 使用新请求自己的 sessionId 回写终态，使主进程无需等到启动超时；不覆盖旧会话
        // 的清理失败记录，也绝不在资源未确认释放时叠加启动。
        const failedSessionId = this.getStringParameter(pending, VPN_SESSION_ID_KEY, '');
        this.emitError('VPN start failed.',
          `session=${failedSessionId}; error=Previous VPN cleanup is incomplete.`);
      }
    }
  }

  private startPendingSessionIfReady(): void {
    if (this.destroying || this.cleaningUp || this.vpnCreateInFlight || !this.stopRequested || !this.lastCleanupComplete ||
      this.pendingStartWant === null) {
      return;
    }
    const want = this.pendingStartWant;
    this.pendingStartWant = null;
    this.beginSession(want);
  }

  private destroyVpnConnectionSingleFlight(connection: vpnExtension.VpnConnection): Promise<void> {
    if (this.vpnDestroyConnection === connection && this.vpnDestroyInFlight !== null) {
      return this.vpnDestroyInFlight;
    }
    const promise = connection.destroy();
    this.vpnDestroyConnection = connection;
    this.vpnDestroyInFlight = promise;
    promise.then(
      (): void => this.handleVpnDestroySettled(connection, promise, true),
      (_error: Object): void => this.handleVpnDestroySettled(connection, promise, false)
    );
    return promise;
  }

  private handleVpnDestroySettled(
    connection: vpnExtension.VpnConnection,
    promise: Promise<void>,
    destroyed: boolean
  ): void {
    if (this.vpnDestroyConnection === connection && this.vpnDestroyInFlight === promise) {
      this.vpnDestroyConnection = null;
      this.vpnDestroyInFlight = null;
    }
    if (!destroyed || this.vpnConnection !== connection || !this.stopRequested) {
      return;
    }
    // 超时只结束 ArkTS 的等待；系统稍后确认销毁时立即移除旧连接归属，并补完停止态。
    // 若原 cleanup 仍在等待，重入标志会让它在同一串行循环再核对一次，不会并发清理。
    this.vpnConnection = null;
    this.tunFd = -1;
    this.cleanupAgainRequested = true;
    if (!this.cleaningUp) {
      this.cleanup().catch((error: Object) => {
        this.emitError('Late VPN destroy cleanup failed.', this.errorMessage(error));
      });
    }
  }

  private async cancelSpeedNotificationSafely(): Promise<void> {
    try {
      await withTimeout(
        SPEED_NOTIFICATION_MANAGER.cancel(this.context),
        NOTIFICATION_CANCEL_TIMEOUT_MS,
        'Speed notification cancellation timed out.'
      );
    } catch (error) {
      this.emitInfo('Speed notification cancellation did not complete.', this.errorMessage(error));
    }
  }

  private async updateControlCardAfterCleanupSafely(cleanupComplete: boolean): Promise<void> {
    try {
      await withTimeout(
        CONTROL_CARD_MANAGER.sync(
          this.context,
          cleanupComplete ? ConnectionStatus.IDLE : ConnectionStatus.ERROR,
          '00:00',
          this.activeLanguage,
          cleanupComplete ? '' : 'VPN cleanup incomplete.',
          false,
          APP_MODE_VPN,
          !cleanupComplete,
          0
        ),
        CONTROL_CARD_RESET_TIMEOUT_MS,
        'Control card cleanup update timed out.'
      );
    } catch (error) {
      this.emitInfo('Control card cleanup update did not complete.', this.errorMessage(error));
    }
  }

  private ensureStartAllowed(stage: string, sessionGeneration: number): void {
    if (sessionGeneration !== this.sessionGeneration) {
      throw new Error(`VPN start cancelled after ${stage}: the session was superseded.`);
    }
    if (this.stopRequested) {
      throw new Error(`VPN start cancelled after ${stage}: stop was requested.`);
    }
  }

  private startStatsTimer(intervalMs: number, sessionGeneration: number): void {
    this.stopStatsTimer();
    this.unhealthySampleCount = 0;
    this.statsTimerId = setInterval(() => {
      this.recordStatsSafely(sessionGeneration);
    }, intervalMs);
    this.recordStatsSafely(sessionGeneration);
  }

  private stopStatsTimer(): void {
    if (this.statsTimerId >= 0) {
      clearInterval(this.statsTimerId);
      this.statsTimerId = -1;
    }
  }

  private async recordStatsSafely(sessionGeneration: number): Promise<void> {
    if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.coreReloading ||
      this.healthProbeInFlight) {
      return;
    }
    this.healthProbeInFlight = true;
    try {
      await this.recordStats(sessionGeneration);
    } catch (error) {
      if (sessionGeneration === this.sessionGeneration) {
        this.noteUnhealthySample(`statsError=${this.errorMessage(error)}`);
      }
    } finally {
      if (sessionGeneration === this.sessionGeneration) {
        this.healthProbeInFlight = false;
      }
    }
  }

  private async recordStats(sessionGeneration: number): Promise<void> {
    const stats: RuntimeStats = getNativeStats();
    if (this.runtimeHealthProbePort > 0) {
      const probe = await probeRuntimeSocksHealth(this.runtimeHealthProbePort);
      if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.stopRequested) {
        return;
      }
      if (!probe.ok) {
        this.emitInfo('Xray runtime health probe failed; waiting for confirmation.', `status=${probe.status}`);
        this.noteUnhealthySample(`xrayProbe=${probe.status}`);
        return;
      }
    }
    // 当前 libxray 只导出 CGoInvoke/CGoFree，不再导出旧 CGoQueryStats；流量采用
    // tun2socks/hev 数据面的真实累计字节。核心存活由上面的 SOCKS 数据入口探测。
    const uploadBytes = stats.uploadBytes;
    const downloadBytes = stats.downloadBytes;
    const now = Date.now();
    if (now - this.lastRuntimeStateAt >= RUNTIME_STATE_INTERVAL_MS) {
      const stored = VpnRuntimeStateStore.write(this.context, {
        sessionId: this.sessionId,
        active: true,
        startedAt: normalizeActiveVpnStartedAt(this.startedAt, now),
        heartbeatAt: now,
        coreType: this.activeCoreType,
        profileUpdatedAt: this.activeProfileUpdatedAt,
        xrayRunning: stats.xrayRunning,
        tunRunning: stats.tunRunning
      });
      if (stored) {
        this.lastRuntimeStateAt = now;
        if (this.runtimeStateWriteFailureCount > 0) {
          this.emitInfo('VPN runtime state persistence recovered.');
        }
        this.runtimeStateWriteFailureCount = 0;
      } else {
        this.runtimeStateWriteFailureCount++;
        if (this.runtimeStateWriteFailureCount === 1) {
          // 单次状态文件写入失败仍由 Extension 自行重试，不能让前台把可恢复抖动当作
          // 致命 VPN error 而提前拆除健康数据面。达到阈值后才发出会话级 error。
          this.emitInfo('VPN runtime state heartbeat write failed; retrying.',
            `session=${this.sessionId}`);
        }
        if (shouldCleanupAfterVpnRuntimeStateWriteFailures(this.runtimeStateWriteFailureCount)) {
          this.emitError('VPN runtime state persistence remained unavailable; cleaning up without reconnecting.',
            `session=${this.sessionId}`);
          this.requestCleanupWithoutRestart(
            'Unpersisted VPN runtime cleanup requested.', `session=${this.sessionId}`);
          return;
        }
      }
    }
    DiagnosticLog.append(this.context, {
      at: Date.now(),
      level: 'info',
      source: 'vpn-stats',
      message: 'Native bridge stats.',
      sessionId: this.sessionId,
      details: stats.lastMessage,
      uploadBytes,
      downloadBytes,
      xrayRunning: stats.xrayRunning,
      tunRunning: stats.tunRunning
    });
    if (!stats.xrayRunning || !stats.tunRunning) {
      this.noteUnhealthySample(`core=${stats.xrayRunning}; tun=${stats.tunRunning}`);
      return;
    }
    this.unhealthySampleCount = 0;
  }

  private noteUnhealthySample(details: string): void {
    this.unhealthySampleCount++;
    if (this.unhealthySampleCount < UNHEALTHY_SAMPLE_LIMIT || this.cleaningUp) {
      return;
    }
    this.emitError('VPN runtime became unhealthy; cleaning up without reconnecting.',
      `session=${this.sessionId}; ${details}`);
    this.requestCleanupWithoutRestart(
      'Unhealthy VPN runtime cleanup requested.', `session=${this.sessionId}`);
  }

  private persistStoppedRuntimeState(stage: string, cleanupComplete: boolean): boolean {
    const stored = VpnRuntimeStateStore.write(this.context,
      VpnRuntimeStateStore.stopped(
        this.sessionId,
        this.startedAt > 0 ? this.startedAt : Date.now(),
        this.activeCoreType,
        this.activeProfileUpdatedAt,
        cleanupComplete,
        true));
    if (!stored) {
      this.emitError('VPN stopped state write failed.', `stage=${stage}; session=${this.sessionId}`);
    }
    return stored;
  }

  private emitInfo(message: string, details: string = ''): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s %{public}s',
      redactDiagnosticText(message), redactDiagnosticText(details));
    DiagnosticLog.append(this.context, {
      at: Date.now(),
      level: 'info',
      source: 'vpn',
      message,
      details
    });
  }

  private emitError(message: string, details: string = ''): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s %{public}s',
      redactDiagnosticText(message), redactDiagnosticText(details));
    DiagnosticLog.append(this.context, {
      at: Date.now(),
      level: 'error',
      source: 'vpn',
      message,
      details
    });
  }

  private errorMessage(error: Object): string {
    const businessError = error as BusinessError;
    return businessError.message ?? JSON.stringify(error);
  }
}
