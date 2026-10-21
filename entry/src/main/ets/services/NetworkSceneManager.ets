// 网络变化观测与场景自动化 —— 编排单例
//
// 始终监听网络变化并刷新实际出口；只有用户开启可信网络自动化时才允许执行断开。
// 幂等：每个「网络签名」只处理一次，避免网络抖动导致重复检测或连断风暴。

import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { APP_LANGUAGE_STORAGE_KEY, normalizeLanguage, translate } from '../core/I18n';
import { AppLanguage } from '../core/Profile';
import {
  NetAutomationConfig,
  NET_ACTION_DISCONNECT,
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
  private started: boolean = false;
  private debounceTimer: number = -1;
  private evaluating: boolean = false;
  private evaluationPending: boolean = false;
  private pendingForce: boolean = false;
  private lastHandledSignature: string = '';
  private lastHandledTransportSignature: string = '';
  // 隔离 UIAbility 销毁/重建前后的异步评估；旧任务即使稍后恢复也不得操作新会话。
  private lifecycleGeneration: number = 0;

  /** 启动网络变化监听（幂等），生命周期跟随 UIAbility，与自动断开开关无关。 */
  ensureStarted(context: common.Context): void {
    this.context = context;
    if (this.started) {
      return;
    }
    try {
      this.lifecycleGeneration++;
      const netConnection = connection.createNetConnection();
      netConnection.on('netAvailable', () => this.scheduleEvaluate(false));
      netConnection.on('netLost', () => this.scheduleEvaluate(false));
      netConnection.on('netCapabilitiesChange', () => this.scheduleEvaluate(false));
      netConnection.register((error: Object) => {
        if (error !== undefined && error !== null) {
          hilog.warn(DOMAIN, TAG, 'register net connection failed: %{public}s',
            redactDiagnosticText(JSON.stringify(error)));
        }
      });
      this.netConnection = netConnection;
      this.started = true;
      hilog.info(DOMAIN, TAG, 'listener started');
      // 启动后立刻补判一次当前网络
      this.refreshNow(true);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'ensureStarted failed: %{public}s', redactDiagnosticText(JSON.stringify(error)));
    }
  }

  /** UIAbility 销毁时停止监听。 */
  stop(): void {
    this.lifecycleGeneration++;
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
    this.evaluationPending = false;
    this.pendingForce = false;
    this.lastHandledSignature = '';
    this.lastHandledTransportSignature = '';
    hilog.info(DOMAIN, TAG, 'listener stopped');
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
      const settings = await SettingsStore.load(context);
      if (!this.isCurrentEvaluation(context, generation)) {
        return;
      }
      // 启停期间不介入，但保留一次补判；不能假设忙碌结束后系统还会再发网络事件。
      if (SHARED_RUNTIME_CONTROLLER.isBusy()) {
        this.evaluationPending = true;
        this.pendingForce = this.pendingForce || force;
        return;
      }
      const ctx = await NetworkProbe.readCurrentNetContext();
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
        await NetSceneStopFlag.wasStopped(context, SHARED_RUNTIME_CONTROLLER.runtimeStartedAt());
      if (!this.isCurrentEvaluation(context, generation)) {
        return;
      }
      if (sceneStopped) {
        SHARED_RUNTIME_CONTROLLER.reconcileStopped();
      }
      // 此自动化只管理系统 VPN/TUN。仅代理模式没有系统隧道，切换可信网络
      // 不应悄悄停止用户正在使用的本地 SOCKS/HTTP 监听器。
      const running = SHARED_RUNTIME_CONTROLLER.isVpnRunning();
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
      if (action === NET_ACTION_DISCONNECT) {
        await this.applyDisconnect(context);
      } else if (runtimeRunning) {
        const language = this.currentLanguage();
        // VPN 核心由 Extension 的后台轮询恢复；Proxy-only 与 UI 同进程，需要在确认是
        // 真实签名变化（而非首次/强制补判）后重建预解析配置并原地重载核心。
        if (transportChanged && shouldReloadActiveCoreAfterNetworkChange(ctx, action)) {
          await SHARED_RUNTIME_CONTROLLER.recoverProxyOnlyAfterNetworkChange(context, language);
        }
        // 恢复完成后再经当前代理复测出口，避免把旧承载的结果继续展示为当前出口。
        await SHARED_RUNTIME_CONTROLLER.recheckCurrentEgressIp(language);
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
