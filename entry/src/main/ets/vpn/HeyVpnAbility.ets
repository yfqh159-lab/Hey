import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import { NetworkProbe } from '../services/NetworkProbe';
import {
  NetAutomationConfig,
  NET_ACTION_DISCONNECT,
  decideNetAutomationAction,
  networkContextSignature,
  networkTransportSignature,
  shouldReloadActiveCoreAfterNetworkChange
} from '../core/NetworkAutomation';
import { NetSceneStopFlag } from '../services/NetSceneStopFlag';
import { APP_MODE_VPN, AppLanguage, ConnectionStatus, resolveVpnInterfaceAddressConfig, RuntimeStats } from '../core/Profile';
import {
  createDefaultVpnConfig,
  normalizeVpnMtu,
  VPN_COMMAND_KEY,
  VPN_COMMAND_STOP,
  VPN_HANDOVER_CONFIG_KEY,
  VPN_HEALTH_PORT_KEY,
  VPN_PROFILE_UPDATED_AT_KEY,
  VPN_SESSION_ID_KEY,
  isValidVpnSessionId
} from './VpnConstants';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
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
  VpnRuntimeStateStore,
  shouldCleanupAfterVpnRuntimeStateWriteFailures
} from '../services/VpnRuntimeStateStore';
import { isRuntimeHealthPort, probeRuntimeSocksHealth, waitForRuntimeSocksHealth } from '../services/RuntimeHealthProbe';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { SPEED_NOTIFICATION_MANAGER } from '../services/SpeedNotificationManager';
import { CONTROL_CARD_MANAGER } from '../services/ControlCardManager';
import { DEFAULT_LANGUAGE } from '../core/I18n';
import { isVpnCleanupComplete } from '../core/RuntimeHealth';

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
const NOTIFICATION_CANCEL_TIMEOUT_MS: number = 2000;
const CONTROL_CARD_RESET_TIMEOUT_MS: number = 2000;
const NET_SCENE_BASELINE_TIMEOUT_MS: number = 2000;
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

  onCreate(want: Want): void {
    this.destroying = false;
    this.beginSession(want);
  }

  private beginSession(want: Want): void {
    const sessionGeneration = ++this.sessionGeneration;
    this.startedAt = Date.now();
    this.sessionId = this.resolveSessionId(want);
    this.activeCoreType = isSingboxCore(this.getStringParameter(want, 'coreType', 'xray')) ? 'singbox' : 'xray';
    this.activeProfileUpdatedAt = this.getNonNegativeIntegerParameter(want, VPN_PROFILE_UPDATED_AT_KEY);
    this.stopRequested = false;
    this.cleanupAgainRequested = false;
    this.lastCleanupComplete = false;
    this.unhealthySampleCount = 0;
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
      // 明确的新启动在创建任何数据面前废弃上一会话的自动断开标志，并等待文件操作
      // 完成。运行后不再异步清除，避免覆盖本会话刚写入的可信网络断开证据。
      try {
        await NetSceneStopFlag.clear(this.context);
      } catch (error) {
        // startedAt 比较仍会隔离旧标志；清理失败不应把新连接直接判成启动失败。
        this.emitInfo('Network scene stop flag reset failed.', this.errorMessage(error));
      }
      this.ensureStartAllowed('network scene stop flag reset', sessionGeneration);
      // 不再做 testNativeXrayConfig 预检：重编后的 libXray 的 CGoTestXray 冷 cgo 入口
      // 会在 VPN 扩展进程里 SIGSEGV（真机 ALN-AL80 / HarmonyOS 6.1 复现，崩在本行附近，
      // Go-on-musl 的 TLS/栈问题），导致扩展进程当场死亡、无法回写启动状态。预检本就是
      // 非阻塞诊断，startNativeXray 才是真相来源，直接走它（与 1.1 行为一致）。

      const creatingConnection = vpnExtension.createVpnConnection(this.context);
      this.vpnConnection = creatingConnection;
      this.emitInfo('Creating VPN connection.');
      const settings = await SETTINGS_CONTROLLER.load(this.context);
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
      this.vpnCreateInFlight = true;
      try {
        this.tunFd = await creatingConnection.create(vpnConfig);
      } finally {
        this.vpnCreateInFlight = false;
      }
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
      const coreResult = useSingbox
        ? startNativeSingbox(configJson, this.context.filesDir)
        : startNativeXray(configJson, this.context.filesDir);
      if (!coreResult.ok) {
        throw new Error(coreResult.message);
      }
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
        startedAt: this.startedAt,
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
        NetworkProbe.readCurrentNetContext(),
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
      const settings = await SETTINGS_CONTROLLER.load(this.context);
      if (sessionGeneration !== this.sessionGeneration || this.cleaningUp || this.stopRequested) {
        return;
      }
      const ctx = await NetworkProbe.readCurrentNetContext();
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
      this.emitInfo('Net scene decision.', `kind=${ctx.kind}; action=${action}`);
      if (action === NET_ACTION_DISCONNECT) {
        this.emitInfo('Net scene: trusted network, auto-disconnecting.', `kind=${ctx.kind}`);
        // 写跨进程标志，供主进程回前台校正「运行中」滞留状态。
        try {
          await NetSceneStopFlag.markStopped(this.context, Date.now());
        } catch (error) {
          // 标志只辅助 UI 跨进程校正；落盘失败不能阻止实际 VPN 清理。
          this.emitInfo('Net scene stop flag write failed.', this.errorMessage(error));
        }
        this.requestCleanup('Network scene auto-disconnect.', `session=${this.sessionId}`);
        return;
      }
      if (transportChanged && shouldReloadActiveCoreAfterNetworkChange(ctx, action)) {
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
      this.netScenePollInFlight = false;
    }
  }

  private async reloadCoreAfterNetworkChange(sessionGeneration: number): Promise<void> {
    if (sessionGeneration !== this.sessionGeneration || this.coreReloading || this.cleaningUp ||
      this.stopRequested || this.activeConfigJson.length === 0) {
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
      const startResult = this.activeCoreType === 'singbox'
        ? startNativeSingbox(this.activeHandoverConfigJson, this.context.filesDir)
        : startNativeXray(this.activeHandoverConfigJson, this.context.filesDir);
      if (!startResult.ok) {
        throw new Error(startResult.message);
      }
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
        this.requestCleanup('Network handover recovery failed; cleaning up without reconnecting.',
          `session=${this.sessionId}`);
      }
    } finally {
      this.coreReloading = false;
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
            await connection.destroy();
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
          tun2socksResult.ok, xrayResult.ok, singboxResult.ok, vpnDestroyed) && !this.vpnCreateInFlight;
        this.lastCleanupComplete = cleanupCompleted;
        cleanupDetails = `tun=${tun2socksResult.ok}; xray=${xrayResult.ok}; singbox=${singboxResult.ok}; vpn=${vpnDestroyed}; createPending=${this.vpnCreateInFlight}`;
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
          !cleanupComplete
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
      this.healthProbeInFlight = false;
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
        startedAt: this.startedAt,
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
          this.requestCleanup('Unpersisted VPN runtime cleanup requested.', `session=${this.sessionId}`);
          return;
        }
      }
    }
    DiagnosticLog.append(this.context, {
      at: Date.now(),
      level: 'info',
      source: 'vpn-stats',
      message: 'Native bridge stats.',
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
    this.requestCleanup('Unhealthy VPN runtime cleanup requested.', `session=${this.sessionId}`);
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
