// 网络变化观测与场景自动化 —— 编排单例
//
// 始终监听网络变化并刷新实际出口；只有用户开启可信网络自动化时才允许执行断开。
// 幂等：每个「网络签名」只处理一次，避免网络抖动导致重复检测或连断风暴。

import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { APP_LANGUAGE_STORAGE_KEY, normalizeLanguage, translate } from '../core/I18n';
import { AppLanguage, AppSettings } from '../core/Profile';
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
import { SettingsStore } from '../storage/SettingsStore';
import { NetSceneStopFlag } from './NetSceneStopFlag';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { NetworkProbe } from './NetworkProbe';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';

const DOMAIN: number = 0x0000;
const TAG: string = 'NetScene';
const DEBOUNCE_MS: number = 2500;
const REGISTER_RETRY_DELAY_MS: number = 1500;
const MAX_REGISTER_RETRIES: number = 3;
const REGISTER_CONFIRM_TIMEOUT_MS: number = 5000;
const EVALUATION_STEP_TIMEOUT_MS: number = 5000;

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timerId = setTimeout(() => reject(new Error(message)), timeoutMs);
    promise.then((value: T) => {
      clearTimeout(timerId);
      resolve(value);
    }, (error: Object) => {
      clearTimeout(timerId);
      reject(error);
    });
  });
}

export class NetworkSceneManager {
  private static instance: NetworkSceneManager | null = null;

  static shared(): NetworkSceneManager {
    if (NetworkSceneManager.instance === null) {
      NetworkSceneManager.instance = new NetworkSceneManager();
    }
    return NetworkSceneManager.instance;
  }

  private netConnection: connection.NetConnection | undefined = undefined;
  private context: common.Context | null = null;
  private owner: Object | null = null;
  private started: boolean = false;
  private registerConfirmTimer: number = -1;
  private registerRetryTimer: number = -1;
  private registerRetryCount: number = 0;
  private debounceTimer: number = -1;
  private evaluating: boolean = false;
  private evaluationPending: boolean = false;
  private pendingForce: boolean = false;
  private lastHandledSignature: string = '';
  private lastHandledTransportSignature: string = '';
  // 隔离 UIAbility 销毁/重建前后的异步评估；旧任务即使稍后恢复也不得操作新会话。
  private lifecycleGeneration: number = 0;
  // NetworkKit 事件可能在上一次 Preferences 读取的外层超时后继续到达。复用仍未
  // 结算的底层读取，避免每次补判都向 SettingsStore 队列追加永久等待的任务。
  private settingsLoadInFlight: Promise<AppSettings> | null = null;
  // Network Kit 查询同样可能忽略外层截止时间。网络事件与前台补判在
  // 原查询真正结算前复用同一 Promise，防止锁屏/切网抖动持续叠加系统任务。
  private networkProbeInFlight: Promise<NetContext> | null = null;

  /** 启动网络变化监听（幂等），生命周期跟随 UIAbility，与自动断开开关无关。 */
  ensureStarted(context: common.Context, owner?: Object): void {
    // 只有 UIAbility 本身可以成为生命周期 owner。设置页传入的 HostContext 仅用于
    // 首次/失败后的显式重试，不能因包装对象引用不同而接管所有权。
    if (owner !== undefined && this.owner !== owner) {
      const previousOwner = this.owner;
      if (previousOwner !== null) {
        this.stop(previousOwner);
      }
      this.owner = owner;
    }
    if (this.started) {
      return;
    }
    this.context = context;
    if (this.registerRetryTimer !== -1) {
      clearTimeout(this.registerRetryTimer);
      this.registerRetryTimer = -1;
    }
    // 前台显式调用视为新一轮尝试；自动重试由 scheduleRegisterRetry 保留计数。
    this.registerRetryCount = 0;
    this.startListener();
  }

  private startListener(): void {
    const context = this.context;
    if (context === null || this.started) {
      return;
    }
    const generation = ++this.lifecycleGeneration;
    let netConnection: connection.NetConnection | undefined = undefined;
    try {
      const createdConnection = connection.createNetConnection();
      netConnection = createdConnection;
      this.netConnection = createdConnection;
      this.started = true;
      createdConnection.on('netAvailable', () =>
        this.scheduleEvaluateForListener(createdConnection, generation));
      createdConnection.on('netLost', () =>
        this.scheduleEvaluateForListener(createdConnection, generation));
      createdConnection.on('netCapabilitiesChange', () =>
        this.scheduleEvaluateForListener(createdConnection, generation));
      // 某些系统实现可能既不回调成功也不回调失败。没有确认或任何网络事件时不能
      // 永久把 started 当成健康；超时释放该实例并沿用有界注册重试。
      this.registerConfirmTimer = setTimeout(() => {
        this.registerConfirmTimer = -1;
        if (this.isCurrentListener(createdConnection, context, generation)) {
          hilog.warn(DOMAIN, TAG, 'register net connection confirmation timed out');
          this.handleRegisterFailure(createdConnection, context, generation);
        }
      }, REGISTER_CONFIRM_TIMEOUT_MS);
      createdConnection.register((error: Object) => {
        if (!this.isCurrentListener(createdConnection, context, generation)) {
          return;
        }
        this.clearRegisterConfirmTimer();
        if (error !== undefined && error !== null) {
          hilog.warn(DOMAIN, TAG, 'register net connection failed: %{public}s',
            redactDiagnosticText(JSON.stringify(error)));
          this.handleRegisterFailure(createdConnection, context, generation);
          return;
        }
        this.registerRetryCount = 0;
      });
      hilog.info(DOMAIN, TAG, 'listener started');
      // 启动后立刻补判一次当前网络
      this.refreshNow(true);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'ensureStarted failed: %{public}s', redactDiagnosticText(JSON.stringify(error)));
      if (netConnection !== undefined) {
        this.handleRegisterFailure(netConnection, context, generation);
      } else if (this.context === context && this.lifecycleGeneration === generation) {
        this.started = false;
        this.netConnection = undefined;
        this.scheduleRegisterRetry(context);
      }
    }
  }

  /** UIAbility 销毁时停止监听。 */
  stop(owner?: Object): void {
    if (owner !== undefined && this.owner !== owner) {
      return;
    }
    this.lifecycleGeneration++;
    this.clearRegisterConfirmTimer();
    if (this.registerRetryTimer !== -1) {
      clearTimeout(this.registerRetryTimer);
      this.registerRetryTimer = -1;
    }
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    const netConnection = this.netConnection;
    if (netConnection !== undefined) {
      try {
        netConnection.unregister((error: Object) => {
          if (error !== undefined && error !== null) {
            hilog.warn(DOMAIN, TAG, 'unregister failed: %{public}s', redactDiagnosticText(JSON.stringify(error)));
          }
        });
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'unregister threw: %{public}s', redactDiagnosticText(JSON.stringify(error)));
      }
    }
    this.netConnection = undefined;
    this.started = false;
    this.context = null;
    this.owner = null;
    this.registerRetryCount = 0;
    this.evaluationPending = false;
    this.pendingForce = false;
    this.lastHandledSignature = '';
    this.lastHandledTransportSignature = '';
    hilog.info(DOMAIN, TAG, 'listener stopped');
  }

  private scheduleEvaluateForListener(netConnection: connection.NetConnection, generation: number): void {
    if (this.netConnection !== netConnection || this.lifecycleGeneration !== generation || !this.started) {
      return;
    }
    // 实际事件证明注册已生效，即使设备遗漏 register 回调也不应误拆健康监听。
    this.clearRegisterConfirmTimer();
    this.registerRetryCount = 0;
    this.scheduleEvaluate(false);
  }

  private isCurrentListener(
    netConnection: connection.NetConnection,
    context: common.Context,
    generation: number
  ): boolean {
    return this.started && this.netConnection === netConnection && this.context === context &&
      this.lifecycleGeneration === generation;
  }

  private handleRegisterFailure(
    netConnection: connection.NetConnection,
    context: common.Context,
    generation: number
  ): void {
    if (!this.isCurrentListener(netConnection, context, generation)) {
      return;
    }
    this.clearRegisterConfirmTimer();
    this.lifecycleGeneration++;
    this.started = false;
    this.netConnection = undefined;
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    try {
      netConnection.unregister((error: Object) => {
        if (error !== undefined && error !== null) {
          hilog.warn(DOMAIN, TAG, 'unregister after register failure failed: %{public}s',
            redactDiagnosticText(JSON.stringify(error)));
        }
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'unregister after register failure threw: %{public}s',
        redactDiagnosticText(JSON.stringify(error)));
    }
    this.scheduleRegisterRetry(context);
  }

  private clearRegisterConfirmTimer(): void {
    if (this.registerConfirmTimer !== -1) {
      clearTimeout(this.registerConfirmTimer);
      this.registerConfirmTimer = -1;
    }
  }

  private scheduleRegisterRetry(context: common.Context): void {
    if (this.context !== context || this.started || this.registerRetryTimer !== -1 ||
      this.registerRetryCount >= MAX_REGISTER_RETRIES) {
      return;
    }
    this.registerRetryCount++;
    this.registerRetryTimer = setTimeout(() => {
      this.registerRetryTimer = -1;
      if (this.context === context && !this.started) {
        this.startListener();
      }
    }, REGISTER_RETRY_DELAY_MS);
  }

  /** 立即重新评估（前台补判 / 设置变化后）。force=true 时忽略签名去重强制评估一次。 */
  refreshNow(force: boolean): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    this.evaluate(force);
  }

  private scheduleEvaluate(force: boolean): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      this.evaluate(force);
    }, DEBOUNCE_MS);
  }

  private async evaluate(force: boolean): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    const generation = this.lifecycleGeneration;
    if (this.evaluating) {
      // 探测/出口请求在途时合并后续事件，结束后至少再评估一次；force 语义不得丢失。
      this.evaluationPending = true;
      this.pendingForce = this.pendingForce || force;
      return;
    }
    this.evaluating = true;
    try {
      const settings = await withTimeout(
        this.loadSettingsSingleFlight(context),
        EVALUATION_STEP_TIMEOUT_MS,
        'Network evaluation settings load timed out.'
      );
      if (!this.isCurrentEvaluation(context, generation)) {
        return;
      }
      // 启停期间不介入，但保留一次补判；不能假设忙碌结束后系统还会再发网络事件。
      if (SHARED_RUNTIME_CONTROLLER.isBusy()) {
        this.evaluationPending = true;
        this.pendingForce = this.pendingForce || force;
        return;
      }
      const ctx = await withTimeout(
        this.loadNetworkContextSingleFlight(),
        EVALUATION_STEP_TIMEOUT_MS,
        'Network evaluation probe timed out.'
      );
      if (!this.isCurrentEvaluation(context, generation)) {
        return;
      }
      const signature = networkContextSignature(ctx);
      const transportSignature = networkTransportSignature(ctx);
      const transportChanged = this.lastHandledTransportSignature.length > 0 &&
        transportSignature !== this.lastHandledTransportSignature;
      if (!force && signature === this.lastHandledSignature) {
        return; // 同一网络只处理一次，避免抖动/较劲
      }
      const cfg: NetAutomationConfig = {
        enabled: settings.netAutomationEnabled,
        // 固定为「仅可信网络自动断开」——不做自动连接（后台不可靠，已移除方向选项）。
        trustedSsids: settings.netAutomationTrustedSsids,
        cellularTrusted: settings.netAutomationCellularTrusted
      };
      // 后台可能已由 VPN 扩展自动断开，本进程状态滞留「运行中」；据跨进程标志校正。
      const sceneStopped = SHARED_RUNTIME_CONTROLLER.isRunning() &&
        await NetSceneStopFlag.wasStopped(
          context,
          SHARED_RUNTIME_CONTROLLER.runtimeStartedAt(),
          SHARED_RUNTIME_CONTROLLER.runtimeVpnSessionId()
        );
      if (!this.isCurrentEvaluation(context, generation)) {
        return;
      }
      if (sceneStopped) {
        SHARED_RUNTIME_CONTROLLER.reconcileStopped();
      }
      // 此自动化只管理系统 VPN/TUN。仅代理模式没有系统隧道，切换可信网络
      // 不应悄悄停止用户正在使用的本地 SOCKS/HTTP 监听器。
      const running = SHARED_RUNTIME_CONTROLLER.isVpnRunning();
      const evaluatedVpnStartedAt = running ? SHARED_RUNTIME_CONTROLLER.runtimeStartedAt() : 0;
      const action = decideNetAutomationAction(ctx, cfg, running);
      const runtimeRunning = SHARED_RUNTIME_CONTROLLER.isRunning();
      this.lastHandledSignature = signature;
      this.lastHandledTransportSignature = transportSignature;
      hilog.info(DOMAIN, TAG, 'evaluate kind=%{public}s running=%{public}s action=%{public}s',
        ctx.kind, running ? '1' : '0', action);
      // 诊断：写进运行日志，便于确认后台是否收到回调、SSID 是否可读。
      if (settings.netAutomationEnabled || runtimeRunning) {
        SHARED_RUNTIME_CONTROLLER.appendLog(
          `[netscene] kind=${ctx.kind}; ssid=${ctx.ssid === undefined ? '<none>' : '<redacted>'}; running=${running}; action=${action}`);
      }
      if (!this.isCurrentEvaluation(context, generation)) {
        return;
      }
      let effectiveAction = action;
      if (action === NET_ACTION_DISCONNECT) {
        // 设置页保存、网络探测和跨进程停止标志读取都是异步的。真正拆隧道前重新读取
        // 已落盘配置，并绑定最初参与决策的 VPN 会话；旧评估不得依据已关闭的自动化
        // 设置停止当前会话，也不得在用户停掉旧会话并手动启动新会话后误停新会话。
        const disconnectConfirmed = await this.confirmDisconnectStillConfigured(context, generation, ctx);
        if (!this.isCurrentEvaluation(context, generation)) {
          return;
        }
        if (!SHARED_RUNTIME_CONTROLLER.isVpnRunning() ||
          SHARED_RUNTIME_CONTROLLER.runtimeStartedAt() !== evaluatedVpnStartedAt) {
          return;
        }
        if (disconnectConfirmed) {
          await this.applyDisconnect(context);
          return;
        }
        effectiveAction = NET_ACTION_NOOP;
        SHARED_RUNTIME_CONTROLLER.appendLog('[netscene] stale auto-disconnect decision skipped.');
      }
      if (SHARED_RUNTIME_CONTROLLER.isRunning()) {
        const language = this.currentLanguage();
        const usableChangedTransport = transportChanged &&
          shouldReloadActiveCoreAfterNetworkChange(ctx, effectiveAction);
        if (transportChanged) {
          // 先撤销上一承载的在途出口请求；否则旧 Wi-Fi/蜂窝响应可能在新请求前后
          // 迟到写回，继续冒充当前出口。瞬时无网络只清空，等待下一可用承载事件。
          SHARED_RUNTIME_CONTROLLER.invalidateCurrentEgressIp();
        }
        // VPN 核心由 Extension 的后台轮询恢复；Proxy-only 与 UI 同进程，需要在确认是
        // 真实签名变化（而非首次/强制补判）后重建预解析配置并原地重载核心。
        if (usableChangedTransport) {
          await SHARED_RUNTIME_CONTROLLER.recoverProxyOnlyAfterNetworkChange(context, language);
        }
        // 恢复完成后再经当前代理复测出口，避免把旧承载的结果继续展示为当前出口。
        if (!transportChanged || usableChangedTransport) {
          await SHARED_RUNTIME_CONTROLLER.recheckCurrentEgressIp(language);
        }
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'evaluate failed: %{public}s', redactDiagnosticText(JSON.stringify(error)));
    } finally {
      this.evaluating = false;
      if (this.evaluationPending && this.context !== null) {
        const pendingForce = this.pendingForce;
        this.evaluationPending = false;
        this.pendingForce = false;
        this.scheduleEvaluate(pendingForce);
      }
    }
  }

  private isCurrentEvaluation(context: common.Context, generation: number): boolean {
    return this.started && this.context === context && this.lifecycleGeneration === generation;
  }

  private loadSettingsSingleFlight(context: common.Context): Promise<AppSettings> {
    if (this.settingsLoadInFlight !== null) {
      return this.settingsLoadInFlight;
    }
    const promise = SettingsStore.load(context);
    this.settingsLoadInFlight = promise;
    promise.then(
      (_settings: AppSettings): void => this.releaseSettingsLoad(promise),
      (_error: Object): void => this.releaseSettingsLoad(promise)
    );
    return promise;
  }

  private loadNetworkContextSingleFlight(): Promise<NetContext> {
    if (this.networkProbeInFlight !== null) {
      return this.networkProbeInFlight;
    }
    const promise = NetworkProbe.readCurrentNetContext();
    this.networkProbeInFlight = promise;
    promise.then(
      (_context: NetContext): void => this.releaseNetworkProbe(promise),
      (_error: Object): void => this.releaseNetworkProbe(promise)
    );
    return promise;
  }

  private releaseNetworkProbe(promise: Promise<NetContext>): void {
    if (this.networkProbeInFlight === promise) {
      this.networkProbeInFlight = null;
    }
  }

  private async confirmDisconnectStillConfigured(
    context: common.Context,
    generation: number,
    ctx: NetContext
  ): Promise<boolean> {
    try {
      const settings = await withTimeout(
        this.loadSettingsSingleFlight(context),
        EVALUATION_STEP_TIMEOUT_MS,
        'Network auto-disconnect confirmation timed out.'
      );
      if (!this.isCurrentEvaluation(context, generation)) {
        return false;
      }
      const cfg: NetAutomationConfig = {
        enabled: settings.netAutomationEnabled,
        trustedSsids: settings.netAutomationTrustedSsids,
        cellularTrusted: settings.netAutomationCellularTrusted
      };
      return decideNetAutomationAction(ctx, cfg, true) === NET_ACTION_DISCONNECT;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'auto-disconnect confirmation failed: %{public}s',
        redactDiagnosticText(JSON.stringify(error)));
      return false;
    }
  }

  private releaseSettingsLoad(promise: Promise<AppSettings>): void {
    if (this.settingsLoadInFlight === promise) {
      this.settingsLoadInFlight = null;
    }
  }


  private async applyDisconnect(context: common.Context): Promise<void> {
    const language = this.currentLanguage();
    SHARED_RUNTIME_CONTROLLER.appendLog(translate(language, 'log.netAutomationDisconnect'));
    await SHARED_RUNTIME_CONTROLLER.stop(context, language);
  }

  private currentLanguage(): AppLanguage {
    const stored = AppStorage.get<string>(APP_LANGUAGE_STORAGE_KEY);
    return normalizeLanguage(stored);
  }
}

export const NETWORK_SCENE_MANAGER: NetworkSceneManager = NetworkSceneManager.shared();
