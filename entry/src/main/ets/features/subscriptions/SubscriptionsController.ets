import { common } from '@kit.AbilityKit';
import { redactDiagnosticText } from '../../core/DiagnosticRedaction';
import { translate } from '../../core/I18n';
import { AppLanguage, ProxyNode, SubscriptionGroup, SubscriptionProfile } from '../../core/Profile';
import {
  DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES,
  isSubscriptionAutoUpdateDue,
  normalizeSubscriptionUpdateInterval,
  selectNextDueSubscriptionGroup
} from '../../core/SubscriptionGroups';
import { findSelectedNodeInGroup, shouldRefreshProfileForNode } from '../../core/SubscriptionSelection';
import { ProfileStore } from '../../storage/ProfileStore';
import { SubscriptionStore } from '../../storage/SubscriptionStore';
import { SubscriptionManager, SubscriptionUpdateResult } from '../../services/SubscriptionManager';
import { isSafeSubscriptionFilterPattern } from '../../core/SubscriptionSafety';
import { SubscriptionBackgroundScheduler } from '../../services/SubscriptionBackgroundScheduler';
import { formatOne, formatTwo, localizedSubscriptionStatusText, localizeCoreMessage } from '../../utils/LocalizationPresenter';

export interface SubscriptionsControllerState {
  subscriptionUrl: string;
  nodes: Array<ProxyNode>;
  selectedNodeId: string;
  subscriptionMessage: string;
  subscriptionUpdatedAt: number;
  subscriptionGroups: Array<SubscriptionGroup>;
  selectedGroupId: string;
}

export interface SubscriptionAutoUpdateResult {
  state: SubscriptionsControllerState;
  updatedCount: number;
  failedCount: number;
}

interface SubscriptionGroupUpdateResult {
  subscription: SubscriptionProfile;
  ok: boolean;
}

export class SubscriptionsController {
  private operationTail: Promise<void> = Promise.resolve();

  async load(context: common.Context, language: AppLanguage): Promise<SubscriptionsControllerState> {
    return this.buildState(await SubscriptionStore.load(context), language, '');
  }

  saveGroup(context: common.Context, urlValue: string, language: AppLanguage): Promise<SubscriptionsControllerState> {
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> => this.saveGroupNow(context, urlValue, language));
  }

  private async saveGroupNow(context: common.Context, urlValue: string, language: AppLanguage): Promise<SubscriptionsControllerState> {
    const url = urlValue.trim();
    if (url.length === 0) {
      return this.buildState(await SubscriptionStore.load(context), language, translate(language, 'error.emptySubscriptionUrl'));
    }
    const validationMessage = SubscriptionManager.validateSubscriptionUrl(url, false);
    if (validationMessage.length > 0) {
      return this.buildState(await SubscriptionStore.load(context), language, localizeCoreMessage(language, validationMessage));
    }
    try {
      const subscription = await SubscriptionStore.saveUrl(context, url);
      return this.buildState(subscription, language, translate(language, 'log.subscriptionGroupSaved'));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.saveSubscriptionGroup', 'error', this.stringifyError(error)));
    }
  }

  update(context: common.Context, groupId: string, urlValue: string, selectedNodeId: string, language: AppLanguage, proxyPort: number = 0): Promise<SubscriptionsControllerState> {
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> =>
        this.updateNow(context, groupId, urlValue, selectedNodeId, language, proxyPort));
  }

  private async updateNow(context: common.Context, groupId: string, urlValue: string, selectedNodeId: string, language: AppLanguage, proxyPort: number): Promise<SubscriptionsControllerState> {
    if (groupId === 'sub-local') {
      return this.buildState(await SubscriptionStore.load(context), language, translate(language, 'subscription.update.localGroupSkipped'));
    }
    const url = urlValue.trim();
    if (url.length === 0) {
      return this.buildState(await SubscriptionStore.load(context), language, translate(language, 'error.emptySubscriptionUrl'));
    }

    try {
      const profileBeforeUpdate = await SubscriptionStore.load(context);
      let targetGroupId = groupId.trim();
      if (targetGroupId.length === 0) {
        const active = SubscriptionStore.activeGroup(profileBeforeUpdate);
        if (active !== null && active.url === url) {
          targetGroupId = active.id;
        } else {
          const matched = SubscriptionStore.findGroupByUrl(profileBeforeUpdate.groups, url);
          if (matched !== null) {
            targetGroupId = matched.id;
          } else if (active !== null) {
            targetGroupId = active.id;
          }
        }
      }
      const allowInsecureUrl = this.findGroupAllowInsecureUrl(profileBeforeUpdate.groups, targetGroupId);
      const validationMessage = SubscriptionManager.validateSubscriptionUrl(url, allowInsecureUrl);
      if (validationMessage.length > 0) {
        // 输入不是 http(s) 链接：尝试当作粘贴的节点内容（base64 / 分享链接 / Clash YAML）离线解析导入，
        // 免去联网拉取（配置源地址不可达或网络受限时尤其有用）。解析不出节点才回退到原有的链接校验错误。
        const inlineNodes = SubscriptionManager.parseSubscriptionContent(url, '');
        if (inlineNodes.length > 0) {
          // Inline payloads commonly contain UUIDs/passwords and can be large. They are
          // import material, not a refreshable source URL; never duplicate them into the
          // visible group metadata or Preferences after parsing.
          const inlineProfile = await SubscriptionStore.saveUrl(context, '', targetGroupId, false);
          const inlineGroupId = targetGroupId.length > 0 ? targetGroupId : inlineProfile.selectedGroupId;
          const inlineFilter = this.findGroupFilter(inlineProfile.groups, inlineGroupId);
          const filteredInline = this.applyNodeFilter(inlineNodes, inlineFilter);
          const savedInline = await SubscriptionStore.saveNodes(context, inlineGroupId, '', filteredInline, selectedNodeId);
          const selectedInline = this.findNode(savedInline.nodes, savedInline.selectedNodeId);
          if (selectedInline !== null) {
            await ProfileStore.save(context, selectedInline.outboundJson, selectedInline.configType);
          }
          return this.buildState(savedInline, language, formatOne(language, 'subscription.updateComplete', 'count', `${filteredInline.length}`));
        }
        return this.buildState(profileBeforeUpdate, language, localizeCoreMessage(language, validationMessage));
      }

      const subscriptionBeforeUpdate = await SubscriptionStore.saveUrl(context, url, targetGroupId, false);
      if (targetGroupId.length === 0) {
        targetGroupId = subscriptionBeforeUpdate.selectedGroupId;
      }

      const userAgent = this.findGroupUserAgent(subscriptionBeforeUpdate.groups, targetGroupId);
      const result: SubscriptionUpdateResult = await SubscriptionManager.fetchAndParse(url, userAgent, allowInsecureUrl, proxyPort);
      if (!result.ok) {
        return this.buildState(await SubscriptionStore.load(context), language, localizeCoreMessage(language, result.message));
      }

      const filter = this.findGroupFilter(subscriptionBeforeUpdate.groups, targetGroupId);
      const nodes = this.applyNodeFilter(result.nodes, filter);

      const subscription = await SubscriptionStore.saveNodes(context, targetGroupId, url, nodes, selectedNodeId);
      const selected = this.findNode(subscription.nodes, subscription.selectedNodeId);
      if (selected !== null) {
        await ProfileStore.save(context, selected.outboundJson, selected.configType);
      }
      return this.buildState(subscription, language, localizeCoreMessage(language, result.message));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.updateSubscription', 'error', this.stringifyError(error)));
    }
  }

  addGroup(
    context: common.Context,
    name: string,
    url: string,
    userAgent: string,
    filter: string,
    prevProfile: string,
    nextProfile: string,
    allowInsecureUrl: boolean,
    language: AppLanguage,
    autoUpdate: boolean = false,
    updateIntervalMinutes: number = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
  ): Promise<SubscriptionsControllerState> {
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> => this.addGroupNow(
        context, name, url, userAgent, filter, prevProfile, nextProfile, allowInsecureUrl,
        language, autoUpdate, updateIntervalMinutes));
  }

  private async addGroupNow(
    context: common.Context,
    name: string,
    url: string,
    userAgent: string,
    filter: string,
    prevProfile: string,
    nextProfile: string,
    allowInsecureUrl: boolean,
    language: AppLanguage,
    autoUpdate: boolean,
    updateIntervalMinutes: number
  ): Promise<SubscriptionsControllerState> {
    const trimmedName = name.trim();
    const trimmedUrl = url.trim();
    if (trimmedName.length === 0) {
      return this.buildState(await SubscriptionStore.load(context), language, translate(language, 'subscription.edit.groupName.empty'));
    }
    const validationMessage = this.validateEditableSubscriptionUrl(trimmedUrl, allowInsecureUrl, language);
    if (validationMessage.length > 0) {
      return this.buildState(await SubscriptionStore.load(context), language, validationMessage);
    }
    try {
      const normalizedInterval = normalizeSubscriptionUpdateInterval(updateIntervalMinutes);
      const subscription = await SubscriptionStore.addGroup(context, trimmedName, trimmedUrl, userAgent.trim(), filter.trim(), prevProfile.trim(), nextProfile.trim(), allowInsecureUrl, autoUpdate, normalizedInterval);
      await this.syncBackgroundSchedule(context);
      return this.buildState(subscription, language, translate(language, 'log.subscriptionGroupSaved'));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.saveSubscriptionGroup', 'error', this.stringifyError(error)));
    }
  }

  updateGroup(
    context: common.Context,
    groupId: string,
    name: string,
    url: string,
    userAgent: string,
    filter: string,
    prevProfile: string,
    nextProfile: string,
    allowInsecureUrl: boolean,
    language: AppLanguage,
    autoUpdate: boolean = false,
    updateIntervalMinutes: number = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
  ): Promise<SubscriptionsControllerState> {
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> => this.updateGroupNow(
        context, groupId, name, url, userAgent, filter, prevProfile, nextProfile,
        allowInsecureUrl, language, autoUpdate, updateIntervalMinutes));
  }

  private async updateGroupNow(
    context: common.Context,
    groupId: string,
    name: string,
    url: string,
    userAgent: string,
    filter: string,
    prevProfile: string,
    nextProfile: string,
    allowInsecureUrl: boolean,
    language: AppLanguage,
    autoUpdate: boolean,
    updateIntervalMinutes: number
  ): Promise<SubscriptionsControllerState> {
    const trimmedName = name.trim();
    const trimmedUrl = url.trim();
    if (trimmedName.length === 0) {
      return this.buildState(await SubscriptionStore.load(context), language, translate(language, 'subscription.edit.groupName.empty'));
    }
    const validationMessage = this.validateEditableSubscriptionUrl(trimmedUrl, allowInsecureUrl, language);
    if (validationMessage.length > 0) {
      return this.buildState(await SubscriptionStore.load(context), language, validationMessage);
    }
    try {
      const normalizedInterval = normalizeSubscriptionUpdateInterval(updateIntervalMinutes);
      const subscription = await SubscriptionStore.updateGroup(context, groupId, trimmedName, trimmedUrl, userAgent.trim(), filter.trim(), prevProfile.trim(), nextProfile.trim(), allowInsecureUrl, autoUpdate, normalizedInterval);
      await this.syncBackgroundSchedule(context);
      return this.buildState(subscription, language, translate(language, 'log.subscriptionGroupSaved'));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.saveSubscriptionGroup', 'error', this.stringifyError(error)));
    }
  }

  updateAll(context: common.Context, language: AppLanguage, proxyPort: number = 0): Promise<SubscriptionsControllerState> {
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> => this.updateAllNow(context, language, proxyPort));
  }

  private async updateAllNow(context: common.Context, language: AppLanguage, proxyPort: number): Promise<SubscriptionsControllerState> {
    let subscription = await SubscriptionStore.load(context);
    let successCount = 0;
    let failedCount = 0;
    
    for (let index = 0; index < subscription.groups.length; index++) {
      const group = subscription.groups[index];
      const url = group.url.trim();
      if (url.length > 0 && group.enabled) {
        try {
          const result = await this.updateGroupNodes(context, group, false, proxyPort);
          subscription = result.subscription;
          if (result.ok) {
            successCount++;
          } else {
            failedCount++;
          }
        } catch (error) {
          failedCount++;
        }
      }
    }

    await this.syncBackgroundSchedule(context);
    
    const msg = failedCount === 0
      ? formatOne(language, 'subscription.updateAll.success', 'count', successCount.toString())
      : formatTwo(language, 'subscription.updateAll.partial',
        'success', successCount.toString(), 'failed', failedCount.toString());
    
    return this.buildState(subscription, language, msg);
  }

  updateDue(context: common.Context, language: AppLanguage, now: number = Date.now(), proxyPort: number = 0): Promise<SubscriptionAutoUpdateResult> {
    return this.enqueueOperation(
      (): Promise<SubscriptionAutoUpdateResult> => this.updateDueNow(context, language, now, proxyPort));
  }

  private async updateDueNow(context: common.Context, language: AppLanguage, now: number, proxyPort: number): Promise<SubscriptionAutoUpdateResult> {
    let subscription = await SubscriptionStore.load(context);
    let updatedCount = 0;
    let failedCount = 0;

    for (let index = 0; index < subscription.groups.length; index++) {
      const group = subscription.groups[index];
      if (!isSubscriptionAutoUpdateDue(group, now)) {
        continue;
      }
      try {
        const result = await this.updateGroupNodes(context, group, false, proxyPort);
        subscription = result.subscription;
        if (result.ok) {
          updatedCount++;
        } else {
          failedCount++;
        }
      } catch (error) {
        failedCount++;
      }
    }

    await this.syncBackgroundSchedule(context);

    let message = '';
    if (updatedCount > 0 || failedCount > 0) {
      message = failedCount === 0
        ? formatOne(language, 'subscription.autoUpdate.success', 'count', updatedCount.toString())
        : formatTwo(language, 'subscription.autoUpdate.partial',
          'success', updatedCount.toString(), 'failed', failedCount.toString());
    }

    return {
      state: this.buildState(subscription, language, message),
      updatedCount,
      failedCount
    };
  }

  updateDueGroup(context: common.Context, groupId: string, language: AppLanguage, now: number = Date.now(), proxyPort: number = 0): Promise<SubscriptionAutoUpdateResult> {
    return this.enqueueOperation(
      (): Promise<SubscriptionAutoUpdateResult> =>
        this.updateDueGroupNow(context, groupId, language, now, proxyPort));
  }

  private async updateDueGroupNow(context: common.Context, groupId: string, language: AppLanguage, now: number, proxyPort: number): Promise<SubscriptionAutoUpdateResult> {
    let subscription = await SubscriptionStore.load(context);
    const group = this.findGroup(subscription.groups, groupId);
    if (group === null || !isSubscriptionAutoUpdateDue(group, now)) {
      return {
        state: this.buildState(subscription, language, ''),
        updatedCount: 0,
        failedCount: 0
      };
    }

    let updatedCount = 0;
    let failedCount = 0;
    try {
      const result = await this.updateGroupNodes(context, group, false, proxyPort);
      subscription = result.subscription;
      if (result.ok) {
        updatedCount++;
      } else {
        failedCount++;
      }
    } catch (error) {
      failedCount++;
    }

    await this.syncBackgroundSchedule(context);

    const message = failedCount === 0
      ? formatOne(language, 'subscription.autoUpdateGroup.success', 'name', group.name)
      : formatOne(language, 'subscription.autoUpdateGroup.failed', 'name', group.name);

    return {
      state: this.buildState(subscription, language, message),
      updatedCount,
      failedCount
    };
  }

  updateNextDue(context: common.Context, language: AppLanguage, now: number = Date.now(), proxyPort: number = 0): Promise<SubscriptionAutoUpdateResult> {
    return this.enqueueOperation(
      (): Promise<SubscriptionAutoUpdateResult> =>
        this.updateNextDueNow(context, language, now, proxyPort));
  }

  private async updateNextDueNow(
    context: common.Context,
    language: AppLanguage,
    now: number,
    proxyPort: number
  ): Promise<SubscriptionAutoUpdateResult> {
    let subscription = await SubscriptionStore.load(context);
    const group = selectNextDueSubscriptionGroup(subscription.groups, now);
    if (group === null) {
      return {
        state: this.buildState(subscription, language, ''),
        updatedCount: 0,
        failedCount: 0
      };
    }

    let updatedCount = 0;
    let failedCount = 0;
    try {
      const result = await this.updateGroupNodes(context, group, false, proxyPort);
      subscription = result.subscription;
      if (result.ok) {
        updatedCount = 1;
      } else {
        failedCount = 1;
      }
    } catch (_error) {
      failedCount = 1;
    }
    return {
      state: this.buildState(subscription, language, failedCount === 0
        ? formatOne(language, 'subscription.autoUpdateGroup.success', 'name', group.name)
        : formatOne(language, 'subscription.autoUpdateGroup.failed', 'name', group.name)),
      updatedCount,
      failedCount
    };
  }

  selectGroup(context: common.Context, group: SubscriptionGroup, language: AppLanguage): Promise<SubscriptionsControllerState> {
    const groupId = group.id;
    const groupName = group.name;
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> => this.selectGroupNow(context, groupId, groupName, language));
  }

  private async selectGroupNow(context: common.Context, groupId: string, groupName: string, language: AppLanguage): Promise<SubscriptionsControllerState> {
    try {
      // 切组只是「浏览」该组节点列表：仅切换活动组，不改写当前节点 / 连接配置（解耦）。
      const subscription = await SubscriptionStore.selectGroup(context, groupId);
      return this.buildState(subscription, language, formatOne(language, 'log.openedSubscriptionGroup', 'name', groupName));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.selectSubscriptionGroup', 'error', this.stringifyError(error)));
    }
  }

  toggleGroup(context: common.Context, group: SubscriptionGroup, language: AppLanguage): Promise<SubscriptionsControllerState> {
    const groupId = group.id;
    const groupName = group.name;
    const wasEnabled = group.enabled;
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> =>
        this.toggleGroupNow(context, groupId, groupName, wasEnabled, language));
  }

  private async toggleGroupNow(context: common.Context, groupId: string, groupName: string, wasEnabled: boolean, language: AppLanguage): Promise<SubscriptionsControllerState> {
    try {
      const subscription = await SubscriptionStore.toggleGroup(context, groupId);
      await this.syncBackgroundSchedule(context);
      const status = wasEnabled ? translate(language, 'common.disabled') : translate(language, 'common.enabled');
      return this.buildState(subscription, language, formatTwo(language, 'log.subscriptionGroupToggled', 'name', groupName, 'status', status));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.toggleSubscriptionGroup', 'error', this.stringifyError(error)));
    }
  }

  removeGroup(context: common.Context, group: SubscriptionGroup, language: AppLanguage): Promise<SubscriptionsControllerState> {
    const groupId = group.id;
    const groupName = group.name;
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> => this.removeGroupNow(context, groupId, groupName, language));
  }

  private async removeGroupNow(context: common.Context, groupId: string, groupName: string, language: AppLanguage): Promise<SubscriptionsControllerState> {
    try {
      const subscription = await SubscriptionStore.removeGroup(context, groupId);
      await this.syncBackgroundSchedule(context);
      return this.buildState(subscription, language, formatOne(language, 'log.removedSubscriptionGroup', 'name', groupName));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.removeSubscriptionGroup', 'error', this.stringifyError(error)));
    }
  }

  moveGroup(context: common.Context, group: SubscriptionGroup, delta: number, language: AppLanguage): Promise<SubscriptionsControllerState> {
    const groupId = group.id;
    const groupName = group.name;
    return this.enqueueOperation(
      (): Promise<SubscriptionsControllerState> => this.moveGroupNow(context, groupId, groupName, delta, language));
  }

  private async moveGroupNow(context: common.Context, groupId: string, groupName: string, delta: number, language: AppLanguage): Promise<SubscriptionsControllerState> {
    try {
      const subscription = await SubscriptionStore.moveGroup(context, groupId, delta);
      return this.buildState(subscription, language, formatOne(language, 'log.subscriptionGroupReordered', 'name', groupName));
    } catch (error) {
      return this.buildState(await SubscriptionStore.load(context), language, formatOne(language, 'error.moveSubscriptionGroup', 'error', this.stringifyError(error)));
    }
  }

  private enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = this.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    this.operationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private buildState(subscription: SubscriptionProfile, language: AppLanguage, message: string): SubscriptionsControllerState {
    const state: SubscriptionsControllerState = {
      subscriptionUrl: subscription.url,
      nodes: subscription.nodes,
      selectedNodeId: subscription.selectedNodeId,
      subscriptionMessage: message.length > 0 ? message : localizedSubscriptionStatusText(language, subscription.updatedAt),
      subscriptionUpdatedAt: subscription.updatedAt,
      subscriptionGroups: subscription.groups,
      selectedGroupId: subscription.selectedGroupId
    };
    return state;
  }

  private findNode(nodes: Array<ProxyNode>, nodeId: string): ProxyNode | null {
    for (let index = 0; index < nodes.length; index++) {
      if (nodes[index].id === nodeId) {
        return nodes[index];
      }
    }
    return null;
  }

  private findGroup(groups: Array<SubscriptionGroup>, groupId: string): SubscriptionGroup | null {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].id === groupId) {
        return groups[index];
      }
    }
    return null;
  }

  private findGroupUserAgent(groups: Array<SubscriptionGroup>, groupId: string): string {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].id === groupId) {
        return groups[index].userAgent ?? '';
      }
    }
    return '';
  }

  private findGroupFilter(groups: Array<SubscriptionGroup>, groupId: string): string {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].id === groupId) {
        return groups[index].filter ?? '';
      }
    }
    return '';
  }

  private findGroupAllowInsecureUrl(groups: Array<SubscriptionGroup>, groupId: string): boolean {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].id === groupId) {
        return groups[index].allowInsecureUrl ?? false;
      }
    }
    return false;
  }

  private async updateGroupNodes(context: common.Context, group: SubscriptionGroup, makeActive: boolean, proxyPort: number): Promise<SubscriptionGroupUpdateResult> {
    const url = group.url.trim();
    const result = await SubscriptionManager.fetchAndParse(url, group.userAgent ?? '', group.allowInsecureUrl ?? false, proxyPort);
    if (!result.ok) {
      return {
        subscription: await SubscriptionStore.load(context),
        ok: false
      };
    }

    const nodes = this.applyNodeFilter(result.nodes, group.filter ?? '');
    const subscription = await SubscriptionStore.saveNodes(context, group.id, url, nodes, group.selectedNodeId, makeActive);
    const selected = findSelectedNodeInGroup(subscription.groups, group.id, subscription.selectedNodeId);
    if (selected !== null) {
      const profile = await ProfileStore.load(context);
      if (shouldRefreshProfileForNode(profile, selected)) {
        // 只同步下一次连接使用的 Profile 及其版本戳。运行中的旧会话不会在这里被
        // 停止或重启；前台恢复时会据版本不一致明确提示用户手动重连。
        await ProfileStore.save(context, selected.outboundJson, selected.configType ?? 'outbound');
      }
    }
    return {
      subscription,
      ok: true
    };
  }

  private validateEditableSubscriptionUrl(url: string, allowInsecureUrl: boolean, language: AppLanguage): string {
    if (url.length === 0) {
      return '';
    }
    const validationMessage = SubscriptionManager.validateSubscriptionUrl(url, allowInsecureUrl);
    if (validationMessage.length === 0) {
      return '';
    }
    // 不是 http(s) 链接但能解析成节点内容（base64 / 分享链接 / Clash YAML）时也放行，
    // 交给 update() 走离线解析导入。
    if (SubscriptionManager.parseSubscriptionContent(url, '').length > 0) {
      return '';
    }
    return localizeCoreMessage(language, validationMessage);
  }

  private async syncBackgroundSchedule(context: common.Context): Promise<void> {
    try {
      const result = await SubscriptionBackgroundScheduler.sync(context);
      if (!result.ok) {
        console.error(`Subscription background schedule sync failed: ${redactDiagnosticText(result.message)}`);
      }
    } catch (error) {
      console.error(`Subscription background schedule sync failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    }
  }

  // Keeps only nodes whose name matches the group's filter regex. An empty
  // filter, an invalid regex, or a pattern that matches nothing all fall back to
  // the full node list so a subscription is never silently emptied.
  private applyNodeFilter(nodes: Array<ProxyNode>, filter: string): Array<ProxyNode> {
    const pattern = filter.trim();
    if (pattern.length === 0 || !isSafeSubscriptionFilterPattern(pattern)) {
      return nodes;
    }
    try {
      const regex = new RegExp(pattern);
      const result = new Array<ProxyNode>();
      for (let index = 0; index < nodes.length; index++) {
        if (regex.test(nodes[index].name)) {
          result.push(nodes[index]);
        }
      }
      return result.length > 0 ? result : nodes;
    } catch (error) {
      return nodes;
    }
  }

  private stringifyError(error: Error): string {
    if (error.message.length > 0) {
      return redactDiagnosticText(error.message);
    }
    if (error.name.length > 0) {
      return redactDiagnosticText(error.name);
    }
    return redactDiagnosticText(`${error}`);
  }
}

export const SUBSCRIPTIONS_CONTROLLER: SubscriptionsController = new SubscriptionsController();
