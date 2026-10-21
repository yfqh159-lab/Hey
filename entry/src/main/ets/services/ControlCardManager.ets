import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { AppLanguage, ConnectionStatus } from '../core/Profile';
import { CONTROL_CARD_STOP_URI, ControlCardFormData, buildControlCardFormData } from '../core/ControlCard';
import { ControlCardStore } from '../storage/ControlCardStore';
import { DiagnosticLog } from './DiagnosticLog';
import { isPersistedVpnRuntimeHealthy, VpnRuntimeStateStore } from './VpnRuntimeStateStore';
import { translate } from '../core/I18n';

const CONTROL_CARD_REFRESH_INTERVAL_MS: number = 3000;

export class ControlCardManager {
  private lastSyncAt: number = 0;
  private lastImmediateKey: string = '';

  async registerForm(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    await ControlCardStore.addFormId(context, formId);
    await this.updateOne(context, formId, await this.loadReconciledState(context));
  }

  async unregisterForm(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    await ControlCardStore.removeFormId(context, formId);
  }

  async refreshForm(context: common.Context, formId: string): Promise<void> {
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
    vpnBacked: boolean
  ): Promise<void> {
    const now = Date.now();
    const immediateKey = `${language}|${status}|${lastError}|${vpnBacked}`;
    if (this.shouldSkipSync(now, immediateKey)) {
      return;
    }
    const state = await ControlCardStore.saveState(
      context,
      buildControlCardFormData(language, status, elapsedText, lastError, vpnBacked)
    );
    const formIds = await ControlCardStore.loadFormIds(context);
    for (let index = 0; index < formIds.length; index++) {
      await this.updateOne(context, formIds[index], state);
    }
    this.lastSyncAt = now;
    this.lastImmediateKey = immediateKey;
  }

  private shouldSkipSync(now: number, immediateKey: string): boolean {
    if (immediateKey !== this.lastImmediateKey) {
      return false;
    }
    return now - this.lastSyncAt < CONTROL_CARD_REFRESH_INTERVAL_MS;
  }

  // FormExtensionAbility 可能在主界面进程已被回收后由系统单独唤起。若卡片上次记录的是
  // VPN/TUN 运行态，必须重新读取扩展进程心跳；不能原样复用过期的“运行中”。
  private async loadReconciledState(context: common.Context): Promise<ControlCardFormData> {
    const state = await ControlCardStore.loadState(context);
    if (!state.vpnBacked || state.primaryActionUri !== CONTROL_CARD_STOP_URI) {
      return state;
    }
    const persisted = VpnRuntimeStateStore.read(context);
    if (persisted !== null && isPersistedVpnRuntimeHealthy(persisted, Date.now())) {
      return state;
    }
    const status = persisted !== null && !persisted.active ? ConnectionStatus.IDLE : ConnectionStatus.ERROR;
    const error = status === ConnectionStatus.ERROR ? translate(state.language, 'runtime.vpnHealthLost') : '';
    return ControlCardStore.saveState(context, buildControlCardFormData(state.language, status, '', error, false));
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
