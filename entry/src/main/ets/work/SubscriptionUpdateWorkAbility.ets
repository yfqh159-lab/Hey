import { common } from '@kit.AbilityKit';
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SUBSCRIPTIONS_CONTROLLER } from '../features/subscriptions/SubscriptionsController';
import { DiagnosticLog } from '../services/DiagnosticLog';
import { SubscriptionManager } from '../services/SubscriptionManager';
import { PersistedVpnRuntimeStateReadResult, VpnRuntimeStateStore } from '../services/VpnRuntimeStateStore';
import { ConnectionStatus } from '../core/Profile';
import { ControlCardStore } from '../storage/ControlCardStore';

export default class SubscriptionUpdateWorkAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    this.runSubscriptionUpdate(work);
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    DiagnosticLog.append(this.context as common.Context, {
      at: Date.now(),
      level: 'info',
      source: 'subscription-work',
      message: 'Subscription background work stopped.',
      details: `workId=${work.workId}`
    });
  }

  private async runSubscriptionUpdate(work: workScheduler.WorkInfo): Promise<void> {
    const context = this.context as common.Context;
    try {
      const settings = await SETTINGS_CONTROLLER.load(context);
      const groupId = this.workGroupId(work);
      // WorkScheduler 不能依赖 UI 单例。VPN 状态即使心跳稍旧也按“可能仍持有 VPN”
      // 处理；控制卡片状态补足本地代理模式。崩溃留下的运行态宁可令回环请求失败，
      // 也不把包含 Token/Basic Auth 的订阅 URL 降级到物理网络直连。
      const vpnStateBefore = VpnRuntimeStateStore.readWithEvidence(context);
      const controlCardState = await ControlCardStore.loadState(context);
      const vpnStateAfter = VpnRuntimeStateStore.readWithEvidence(context);
      const proxyPort = SubscriptionManager.resolvePersistedSubscriptionProxyPort(
        this.vpnMayOwnNetwork(vpnStateBefore) || this.vpnMayOwnNetwork(vpnStateAfter),
        controlCardState.runtimeMode,
        controlCardState.runtimeStatus !== ConnectionStatus.IDLE
      );
      const result = groupId.length > 0
        ? await SUBSCRIPTIONS_CONTROLLER.updateDueGroup(
          context, groupId, settings.language, Date.now(), proxyPort)
        : await SUBSCRIPTIONS_CONTROLLER.updateNextDue(
          context, settings.language, Date.now(), proxyPort);
      DiagnosticLog.append(context, {
        at: Date.now(),
        level: result.failedCount > 0 ? 'warn' : 'info',
        source: 'subscription-work',
        message: `Subscription background update completed: ${result.updatedCount} success, ${result.failedCount} failed.`,
        details: `workId=${work.workId}; groupId=${groupId}`
      });
      this.retireLegacyGroupWork(work, groupId);
    } catch (error) {
      DiagnosticLog.append(context, {
        at: Date.now(),
        level: 'error',
        source: 'subscription-work',
        message: 'Subscription background update failed.',
        details: this.stringifyError(error)
      });
      this.retireLegacyGroupWork(work, this.workGroupId(work));
    }
  }

  private workGroupId(work: workScheduler.WorkInfo): string {
    const parameters = work.parameters;
    if (parameters === undefined) {
      return '';
    }
    const groupId = parameters['groupId'];
    return typeof groupId === 'string' ? groupId.trim() : '';
  }

  private vpnMayOwnNetwork(read: PersistedVpnRuntimeStateReadResult): boolean {
    return read.authoritativeArtifactInvalid || (read.state !== null && read.state.active);
  }

  private retireLegacyGroupWork(work: workScheduler.WorkInfo, groupId: string): void {
    if (groupId.length === 0) {
      return;
    }
    try {
      // Releases per-group jobs created by older builds, including jobs whose persisted
      // index was damaged and therefore cannot be enumerated during foreground migration.
      workScheduler.stopWork(work, true);
    } catch (_error) {
      // The scheduler may already have removed the legacy job.
    }
  }

  private stringifyError(error: Error | Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return JSON.stringify(error);
  }
}
