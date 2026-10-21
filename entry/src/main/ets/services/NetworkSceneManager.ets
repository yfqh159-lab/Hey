// 网络场景自动化 —— 编排单例
//
// 监听网络变化 → 防抖 → 读当前网络(NetworkProbe) → 决策(NetworkAutomation) → 驱动连断。
// 幂等：每个「网络签名」只处理一次，避免网络抖动导致连断风暴，也避免推翻用户手动操作。

import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { APP_LANGUAGE_STORAGE_KEY, normalizeLanguage, translate } from '../core/I18n';
import { AppLanguage, AppSettings } from '../core/Profile';
import {
  NetAutomationConfig,
  NET_ACTION_DISCONNECT,
  decideNetAutomationAction
} from '../core/NetworkAutomation';
import { SettingsStore } from '../storage/SettingsStore';
import { ProfileStore } from '../storage/ProfileStore';
import { NetSceneStopFlag } from './NetSceneStopFlag';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { NetworkProbe } from './NetworkProbe';

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
  private lastHandledSignature: string = '';

  /** 启动监听（幂等）。总开关开启 / App 启动 / VPN 启动时调用。 */
  ensureStarted(context: common.Context): void {
    this.context = context;
    if (this.started) {
      return;
    }
    try {
      const netConnection = connection.createNetConnection();
      netConnection.on('netAvailable', () => this.scheduleEvaluate(false));
      netConnection.on('netLost', () => this.scheduleEvaluate(false));
      netConnection.on('netCapabilitiesChange', () => this.scheduleEvaluate(false));
      netConnection.register((error: Object) => {
        if (error !== undefined && error !== null) {
          hilog.warn(DOMAIN, TAG, 'register net connection failed: %{public}s', JSON.stringify(error));
        }
      });
      this.netConnection = netConnection;
      this.started = true;
      hilog.info(DOMAIN, TAG, 'listener started');
      // 启动后立刻补判一次当前网络
      this.refreshNow(true);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'ensureStarted failed: %{public}s', JSON.stringify(error));
    }
  }

  /** 停止监听。总开关关闭时调用。 */
  stop(): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    const netConnection = this.netConnection;
    if (netConnection !== undefined) {
      try {
        netConnection.unregister((error: Object) => {
          if (error !== undefined && error !== null) {
            hilog.warn(DOMAIN, TAG, 'unregister failed: %{public}s', JSON.stringify(error));
          }
        });
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'unregister threw: %{public}s', JSON.stringify(error));
      }
    }
    this.netConnection = undefined;
    this.started = false;
    this.lastHandledSignature = '';
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
    if (context === null || this.evaluating) {
      return;
    }
    this.evaluating = true;
    try {
      const settings = await SettingsStore.load(context);
      if (!settings.netAutomationEnabled) {
        this.lastHandledSignature = '';
        return;
      }
      // 连接管线忙（启停中）时不动，等下次事件 / 补判
      if (SHARED_RUNTIME_CONTROLLER.isBusy()) {
        return;
      }
      const ctx = await NetworkProbe.readCurrentNetContext();
      const signature = `${ctx.kind}|${ctx.ssid ?? ''}`;
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
      if (SHARED_RUNTIME_CONTROLLER.isRunning() && await NetSceneStopFlag.wasStopped(context)) {
        SHARED_RUNTIME_CONTROLLER.reconcileStopped();
      }
      const running = SHARED_RUNTIME_CONTROLLER.isRunning();
      const action = decideNetAutomationAction(ctx, cfg, running);
      this.lastHandledSignature = signature;
      hilog.info(DOMAIN, TAG, 'evaluate kind=%{public}s running=%{public}s action=%{public}s',
        ctx.kind, running ? '1' : '0', action);
      // 诊断：写进运行日志，便于确认后台是否收到回调、SSID 是否可读。
      SHARED_RUNTIME_CONTROLLER.appendLog(
        `[netscene] kind=${ctx.kind}; ssid=${ctx.ssid === undefined ? '<none>' : '<redacted>'}; running=${running}; action=${action}`);
      if (action === NET_ACTION_DISCONNECT) {
        await this.applyDisconnect(context);
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'evaluate failed: %{public}s', JSON.stringify(error));
    } finally {
      this.evaluating = false;
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
