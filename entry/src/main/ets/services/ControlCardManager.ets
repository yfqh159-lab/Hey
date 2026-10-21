import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { APP_MODE_VPN, AppLanguage, AppRuntimeMode, ConnectionStatus } from '../core/Profile';
import {
  CONTROL_CARD_STOP_URI,
  ControlCardFormData,
  buildControlCardFormData,
  isControlCardLocalProxyRunning
} from '../core/ControlCard';
import { LOCAL_HTTP_PROXY_PORT, VPN_DATA_SOCKS_PORT } from '../core/XrayConfig';
import { ControlCardStore } from '../storage/ControlCardStore';
import { DiagnosticLog } from './DiagnosticLog';
import { isPersistedVpnCleanupIncomplete, isPersistedVpnRuntimeHealthy, VpnRuntimeStateStore } from './VpnRuntimeStateStore';
import { translate } from '../core/I18n';
import { probeRuntimeTcpHealth } from './RuntimeHealthProbe';

const CONTROL_CARD_REFRESH_INTERVAL_MS: number = 3000;

export class ControlCardManager {
  private lastSyncAt: number = 0;
  private lastImmediateKey: string = '';
  // 同一进程内首页周期同步、Form 系统刷新和 Extension 清理可能同时更新同一表单。
  // 按调用顺序串行，避免旧“运行中”系统调用比后来的停止更新更晚完成并覆盖卡片。
  private operationTail: Promise<void> = Promise.resolve();

  async registerForm(context: common.Context, formId: string): Promise<void> {
    return this.enqueueOperation((): Promise<void> => this.registerFormNow(context, formId));
  }

  private async registerFormNow(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    await ControlCardStore.addFormId(context, formId);
    await this.updateOne(context, formId, await this.loadReconciledState(context));
  }

  async unregisterForm(context: common.Context, formId: string): Promise<void> {
    return this.enqueueOperation((): Promise<void> => this.unregisterFormNow(context, formId));
  }

  private async unregisterFormNow(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    await ControlCardStore.removeFormId(context, formId);
  }

  async refreshForm(context: common.Context, formId: string): Promise<void> {
    return this.enqueueOperation((): Promise<void> => this.refreshFormNow(context, formId));
  }

  private async refreshFormNow(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    await this.updateOne(context, formId, await this.loadReconciledState(context));
  }

  async sync(
    context: common.Context,
    status: ConnectionStatus,
    elapsedText: string,
    language: AppLanguage,
    lastError: string,
    vpnBacked: boolean,
    runtimeMode: AppRuntimeMode,
    cleanupRequired: boolean = false
  ): Promise<void> {
    return this.enqueueOperation((): Promise<void> => this.syncNow(
      context, status, elapsedText, language, lastError, vpnBacked, runtimeMode, cleanupRequired));
  }

  private async syncNow(
    context: common.Context,
    status: ConnectionStatus,
    elapsedText: string,
    language: AppLanguage,
    lastError: string,
    vpnBacked: boolean,
    runtimeMode: AppRuntimeMode,
    cleanupRequired: boolean
  ): Promise<void> {
    const now = Date.now();
    const immediateKey = `${language}|${status}|${lastError}|${vpnBacked}|${runtimeMode}|${cleanupRequired}`;
    if (this.shouldSkipSync(now, immediateKey)) {
      return;
    }
    const state = await this.persistRuntimeState(
      context, status, elapsedText, language, lastError, vpnBacked, runtimeMode, cleanupRequired);
    const formIds = await ControlCardStore.loadFormIds(context);
    for (let index = 0; index < formIds.length; index++) {
      await this.updateOne(context, formIds[index], state);
    }
    this.lastSyncAt = now;
    this.lastImmediateKey = immediateKey;
  }

  private enqueueOperation(operation: () => Promise<void>): Promise<void> {
    const task = this.operationTail.then(
      (): Promise<void> => operation(),
      (): Promise<void> => operation()
    );
    this.operationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  // 启动数据面前先等待这一步，给 WorkScheduler 等独立进程一个持久的 fail-closed
  // 路由意图。这里只写状态，不依赖桌面卡片 ID 或系统表单更新是否可用。
  async persistRuntimeState(
    context: common.Context,
    status: ConnectionStatus,
    elapsedText: string,
    language: AppLanguage,
    lastError: string,
    vpnBacked: boolean,
    runtimeMode: AppRuntimeMode,
    cleanupRequired: boolean = false
  ): Promise<ControlCardFormData> {
    return ControlCardStore.saveState(
      context,
      buildControlCardFormData(
        language, status, elapsedText, lastError, vpnBacked, runtimeMode, cleanupRequired)
    );
  }

  private shouldSkipSync(now: number, immediateKey: string): boolean {
    if (immediateKey !== this.lastImmediateKey) {
      return false;
    }
    return now - this.lastSyncAt < CONTROL_CARD_REFRESH_INTERVAL_MS;
  }

  // FormExtensionAbility 可能在主界面进程已被回收后由系统单独唤起。VPN/TUN 需读取
  // 扩展进程心跳；本地代理需探测固定回环 HTTP 入口，不能原样复用过期的“运行中”。
  private async loadReconciledState(context: common.Context): Promise<ControlCardFormData> {
    const state = await ControlCardStore.loadState(context);
    const persistedRead = VpnRuntimeStateStore.readWithEvidence(context);
    let persisted = persistedRead.state;
    let authoritativeArtifactInvalid = persistedRead.authoritativeArtifactInvalid;
    // 不以卡片缓存中的 vpnBacked/动作作为检查前提：Form 进程可能持有 UI 启动 VPN
    // 之前的旧 Preferences 缓存。新鲜的跨进程心跳 + 会话绑定 SOCKS 探针才是权威。
    if (!authoritativeArtifactInvalid && persisted !== null &&
      isPersistedVpnRuntimeHealthy(persisted, Date.now())) {
      const expectedSessionId = persisted.sessionId;
      const expectedStartedAt = persisted.startedAt;
      const probe = await probeRuntimeTcpHealth(VPN_DATA_SOCKS_PORT);
      const confirmedRead = VpnRuntimeStateStore.readWithEvidence(context);
      const confirmed = confirmedRead.state;
      if (confirmed !== null && confirmed.sessionId === expectedSessionId &&
        confirmed.startedAt === expectedStartedAt && !confirmedRead.authoritativeArtifactInvalid &&
        isPersistedVpnRuntimeHealthy(confirmed, Date.now())) {
        if (probe.ok) {
          return buildControlCardFormData(
            state.language,
            ConnectionStatus.RUNNING,
            '',
            '',
            true,
            APP_MODE_VPN
          );
        }
        // 单次端口抖动只影响本次卡片渲染，不持久化 cleanupRequired。下次系统刷新会
        // 重新核对；但当前不能继续显示“运行中”或暴露启动动作叠加另一条数据面。
        return buildControlCardFormData(
          state.language,
          ConnectionStatus.ERROR,
          '',
          translate(state.language, 'runtime.vpnHealthLost'),
          false,
          APP_MODE_VPN,
          true
        );
      }
      // 探针期间状态可能已经停止或换成新会话；旧探针结果不得确认新会话。
      persisted = confirmed;
      authoritativeArtifactInvalid = confirmedRead.authoritativeArtifactInvalid;
      if (persisted !== null && isPersistedVpnRuntimeHealthy(persisted, Date.now())) {
        return buildControlCardFormData(
          state.language,
          ConnectionStatus.ERROR,
          '',
          translate(state.language, 'runtime.vpnHealthLost'),
          false,
          APP_MODE_VPN,
          true
        );
      }
    }
    // “仍需清理”是 fail-closed 状态。没有同一控制流程明确写回成功前，卡片继续只
    // 提供停止动作；不能因状态文件暂时缺失或仍是旧记录而重新暴露启动。
    if (state.cleanupRequired) {
      return state;
    }
    if (authoritativeArtifactInvalid) {
      // 可能已回退到旧 inactive/active 备份，不能据此宣称空闲或运行。该结果不落盘，
      // Extension 下一次成功心跳修复文件后，卡片仍可自行恢复。
      return buildControlCardFormData(
        state.language,
        ConnectionStatus.ERROR,
        '',
        translate(state.language, 'runtime.vpnHealthLost'),
        false,
        APP_MODE_VPN,
        true
      );
    }
    if (persisted !== null && isPersistedVpnCleanupIncomplete(persisted)) {
      return ControlCardStore.saveState(
        context,
        buildControlCardFormData(
          state.language,
          ConnectionStatus.ERROR,
          '',
          translate(state.language, 'runtime.vpnCleanupRequired'),
          false,
          APP_MODE_VPN,
          true
        )
      );
    }
    if (isControlCardLocalProxyRunning(state)) {
      const probe = await probeRuntimeTcpHealth(LOCAL_HTTP_PROXY_PORT);
      if (probe.ok) {
        return state;
      }
      return ControlCardStore.saveState(
        context,
        buildControlCardFormData(
          state.language,
          ConnectionStatus.ERROR,
          '',
          translate(state.language, 'runtime.proxyHealthLost'),
          false,
          state.runtimeMode
        )
      );
    }
    if (!state.vpnBacked || state.primaryActionUri !== CONTROL_CARD_STOP_URI) {
      return state;
    }
    const status = persisted !== null && !persisted.active ? ConnectionStatus.IDLE : ConnectionStatus.ERROR;
    const error = status === ConnectionStatus.ERROR ? translate(state.language, 'runtime.vpnHealthLost') : '';
    return ControlCardStore.saveState(
      context,
      buildControlCardFormData(state.language, status, '', error, false, APP_MODE_VPN)
    );
  }

  private async updateOne(context: common.Context, formId: string, state: ControlCardFormData): Promise<void> {
    try {
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(state));
    } catch (error) {
      DiagnosticLog.append(context, {
        at: Date.now(),
        level: 'warn',
        source: 'form',
        message: 'Control card update failed.',
        details: JSON.stringify(error)
      });
    }
  }
}

export const CONTROL_CARD_MANAGER: ControlCardManager = new ControlCardManager();
