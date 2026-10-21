import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { IconButton } from '../components/IconButton';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { BOTTOM_SAFE_HEIGHT_KEY, TOP_SAFE_HEIGHT_KEY } from '../core/Immersive';
import { APP_MODE_VPN, AppLanguage, AppRuntimeMode, AppSettings, ConnectionStatus, isProxyOnlyRuntimeMode, normalizeAppRuntimeMode, normalizeHomeDelayTestInterval, normalizeRealPingConcurrency, ProxyNode, ProxyProfile, resolveDelayTestUrl, RuntimeStats, SubscriptionGroup, SubscriptionProfile, XrayConfigType } from '../core/Profile';
import { CoreSelectionStore, requiredCoreForProtocol, CORE_TYPE_SINGBOX } from '../core/CoreSelection';
import { DELAY_TEST_BATCH_PORT_BASE, normalizeOutboundInput } from '../core/XrayConfig';
import { DeepLinkControlAction, DeepLinkIntent, parseDeepLink, subscriptionNameFromDeepLink } from '../core/DeepLink';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { consumeRuntimeSettingsRestartDecision } from '../core/SettingsChange';
import { resolveImportedNodeName } from '../core/ImportedNodeNames';
import { shouldShowProxySharingStartWarning } from '../core/ProxySharingWarning';
import { DelayTester, DelayTestResult, DELAY_STATUS_UDP_ONLY } from '../services/DelayTester';
import { convertNativeShareTextToOutbounds } from '../services/NativeShareConverter';
import { CONTROL_CARD_MANAGER } from '../services/ControlCardManager';
import { calculateSpeedNotificationRates, sampleSpeedNotificationStats, SpeedNotificationSample } from '../core/SpeedNotification';
import { SPEED_NOTIFICATION_MANAGER } from '../services/SpeedNotificationManager';
import { SubscriptionBackgroundScheduler } from '../services/SubscriptionBackgroundScheduler';
import { SubscriptionManager } from '../services/SubscriptionManager';
import { NodeDelayUpdate, SubscriptionStore } from '../storage/SubscriptionStore';
import { TrafficTotals, TrafficTotalsStore } from '../storage/TrafficTotalsStore';
import { DEFAULT_APP_SETTINGS } from '../storage/SettingsStore';
import {
  applyDelayTestPostActionsToGroups,
  buildNodeDescription,
  dedupeVisibleNodesInGroups,
  exportNodesText,
  extractNodeEndpoint,
  filterNodes,
  findSelectedNodeLocation,
  formatEndpointDescription,
  moveNodeWithinGroup,
  removeVisibleNodesFromGroups,
  removeVisibleTestFailedNodesFromGroups,
  sortGroupsByDelayTargets
} from '../features/nodes/NodeOperations';
import { NODES_CONTROLLER, NodesControllerState, SaveProfileResult } from '../features/nodes/NodesController';
import { ServerNodeCard } from '../features/servers/ServerCard';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { RuntimeViewState, SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { SUBSCRIPTIONS_CONTROLLER, SubscriptionsControllerState } from '../features/subscriptions/SubscriptionsController';
import { AppRoute } from '../shell/AppRoute';
import { formatOne, formatTwo, localizeCoreMessage } from '../utils/LocalizationPresenter';
import { AppColor, Elevation, FontSz, Radius, Space } from '../theme/Theme';

const EMPTY_STATS: RuntimeStats = {
  uploadBytes: 0,
  downloadBytes: 0,
  xrayRunning: false,
  tunRunning: false,
  lastMessage: translate(DEFAULT_LANGUAGE, 'runtime.nativeBridgeNotQueried')
};
const AUTO_SUBSCRIPTION_CHECK_THROTTLE_MS: number = 60 * 1000;
const ALL_GROUP_ID: string = '__hey_all_groups__';

interface NodeDelayBatchResult {
  node: ProxyNode;
  result: DelayTestResult;
  testedAt: number;
}

type NodeDelayTestMode = 'tcp' | 'real';

interface ControlTargetSelectionResult {
  ok: boolean;
  changed: boolean;
  runningSwitch: boolean;
}

@Entry
@Component
struct Index {
  private timerId: number = -1;
  private currentSettings: AppSettings = DEFAULT_APP_SETTINGS;
  private tabsController: TabsController = new TabsController();
  private nodeListScroller: Scroller = new Scroller();
  private lastAutoSubscriptionCheckAt: number = 0;
  private pendingExternalIntentHandling: boolean = false;

  @State private currentTab: number = 0;
  @State private showSearch: boolean = false;
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  // 沉浸式安全区（状态栏 / 底部指示条高度，vp）
  @StorageProp(TOP_SAFE_HEIGHT_KEY) private topSafe: number = 0;
  @StorageProp(BOTTOM_SAFE_HEIGHT_KEY) private bottomSafe: number = 0;
  @State private outboundJson: string = '';
  private configType: XrayConfigType = 'outbound';
  @State private validationMessage: string = translate(DEFAULT_LANGUAGE, 'validation.initial');
  @State private validationOk: boolean = false;
  @State private lastError: string = '';
  @State private profileUpdatedAt: string = translate(DEFAULT_LANGUAGE, 'profile.notSaved');
  @State private profileUpdatedAtValue: number = 0;
  @State private subscriptionUrl: string = '';
  @State private nodes: Array<ProxyNode> = [];
  @State private selectedNodeId: string = '';
  @State private subscriptionMessage: string = translate(DEFAULT_LANGUAGE, 'subscription.none');
  @State private subscriptionUpdatedAt: number = 0;
  @State private subscriptionGroups: Array<SubscriptionGroup> = [];
  @State private selectedGroupId: string = '';
  @State private searchQuery: string = '';
  @State private subscriptionUpdating: boolean = false;
  @State private delayTesting: boolean = false;
  @State private status: ConnectionStatus = ConnectionStatus.IDLE;
  @State private runtimeMode: AppRuntimeMode = APP_MODE_VPN;
  @State private connectionOperationRunning: boolean = false;
  @State private elapsedText: string = '00:00';
  // 「当前连接」延迟（圆环下方点按测速胶囊），权威状态在 RuntimeController，随快照回填。
  @State private connectionDelayMs: number = -1;
  @State private connectionDelayTesting: boolean = false;
  @State private connectionDelayFailed: boolean = false;
  @State private egressIp: string = '';
  @State private egressIpChecking: boolean = false;
  // 首页自动测速调度：当前连接会话起始时间（用于识别新会话）与上次自动触发时刻。
  private connectionStartedAt: number = 0;
  private autoDelayTestSessionAt: number = 0;
  private lastAutoDelayTestAt: number = 0;
  @State private stats: RuntimeStats = EMPTY_STATS;
  @State private uploadSpeed: number = 0;
  @State private downloadSpeed: number = 0;
  private lastSpeedSample: SpeedNotificationSample | null = null;
  // 持久累计总量（跨重连/重启）。totalUpload/Download 用于显示；lastSession* 是上次看到的
  // 本会话计数，用来算增量 + 检测重连归零。trafficTotalsLoaded 防止首帧把持久值覆盖成 0。
  @State private totalUpload: number = 0;
  @State private totalDownload: number = 0;
  private lastSessionUpload: number = 0;
  private lastSessionDownload: number = 0;
  private lastTrafficPersistAt: number = 0;
  private trafficTotalsLoaded: boolean = false;
  @State private speedEnabled: boolean = false;
  @State private groupAllDisplay: boolean = false;
  @State private doubleColumnDisplay: boolean = false;
  @State private allGroupsSelected: boolean = false;
  @StorageLink('pendingDeepLink') @Watch('onPendingExternalIntentChanged') private pendingDeepLinkSignal: string = '';
  @StorageLink('pendingSharedTextImport') @Watch('onPendingExternalIntentChanged') private pendingSharedTextImportSignal: string = '';
  private initialStateLoading: boolean = false;
  private initialStateReady: boolean = false;

  aboutToAppear(): void {
    if (!this.initialStateLoading && !this.initialStateReady) {
      this.initialStateLoading = true;
      this.initializePageState();
    }
    if (this.timerId < 0) {
      this.timerId = setInterval(() => {
        if (this.initialStateReady) {
          this.refreshRuntime();
        }
      }, 1000);
    }
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.persistTrafficTotals(true);
  }

  onPageShow(): void {
    // 从订阅 / 导入等子页返回时，重新加载设置与节点，保证列表实时刷新
    if (this.initialStateReady) {
      this.refreshFromStorage();
    }
  }

  onPageHide(): void {
    // 退到后台 / 离开页面时立刻落盘累计总量，减少硬杀进程时的丢量。
    this.persistTrafficTotals(true);
  }

  private async refreshFromStorage(): Promise<void> {
    await this.loadSettings();
    await this.loadNodes();
    // 页面不可见期间 Extension 可能已停止或仍在后台健康运行。任何设置重启、开机动作或
    // 外部控制之前先恢复权威状态，不能根据离开页面前的旧枚举决定是否启动。
    await this.refreshRuntime();
    await this.handlePendingRuntimeSettingsRestart();
    await this.handlePendingAutoStartupLaunch();
    await this.handlePendingSharedTextImport();
    await this.handlePendingDeepLink();
    await this.refreshDueSubscriptions();
    await this.syncSubscriptionBackgroundSchedule();
    // 从后台或子页回到首页时重新确认真实出口。网络承载可能已经变化，旧 IP 不应继续显示。
    await this.recheckCurrentEgressIp();
  }

  private onPendingExternalIntentChanged(): void {
    if (!this.initialStateReady || !this.hasPendingExternalIntent()) {
      return;
    }
    this.consumePendingExternalIntentSoon();
  }

  private hasPendingExternalIntent(): boolean {
    return this.pendingDeepLinkSignal.trim().length > 0 || this.pendingSharedTextImportSignal.trim().length > 0;
  }

  private consumePendingExternalIntentSoon(): void {
    if (!this.initialStateReady || this.pendingExternalIntentHandling) {
      return;
    }
    this.pendingExternalIntentHandling = true;
    setTimeout(async () => {
      try {
        await this.loadSettings();
        await this.loadNodes();
        await this.refreshRuntime();
        await this.handlePendingSharedTextImport();
        await this.handlePendingDeepLink();
        await this.syncSubscriptionBackgroundSchedule();
      } finally {
        this.pendingExternalIntentHandling = false;
        if (this.hasPendingExternalIntent()) {
          this.consumePendingExternalIntentSoon();
        }
      }
    }, 0);
  }

  private async handlePendingRuntimeSettingsRestart(): Promise<void> {
    const decision = consumeRuntimeSettingsRestartDecision(this.isRunning(), this.isBusy());
    if (decision.keepPending) {
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.settingsRestartDeferred'));
      return;
    }
    if (!decision.shouldRestart) {
      return;
    }

    this.connectionOperationRunning = true;
    try {
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.settingsRestartRequested'));
      const stopped = await this.stopConnectionInternal();
      if (stopped) {
        await this.startConnectionInternal();
      }
    } finally {
      this.connectionOperationRunning = false;
    }
  }

  private async handlePendingAutoStartupLaunch(): Promise<void> {
    const pending = AppStorage.get<boolean>('pendingAutoStartupLaunch') ?? false;
    if (!pending) {
      return;
    }
    AppStorage.setOrCreate('pendingAutoStartupLaunch', false);
    if (!this.currentSettings.startOnBoot) {
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.autoStartupDisabled'));
      return;
    }
    await this.handleControlDeepLink('start');
    SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.autoStartupStartRequested'));
  }

  // Imports a stashed deep link (hey://add-source|add-endpoint?url=...) once
  // when the page shows after EntryAbility received it. No-op on normal returns.
  private async handlePendingDeepLink(): Promise<void> {
    const link = AppStorage.get<string>('pendingDeepLink');
    if (link === undefined || link.length === 0) {
      return;
    }
    AppStorage.setOrCreate('pendingDeepLink', '');
    const intent: DeepLinkIntent = parseDeepLink(link);
    if (intent.kind === 'none') {
      return;
    }
    if (intent.kind === 'control') {
      this.confirmControlDeepLink(intent.action ?? '', intent.targetNodeId ?? '');
      return;
    }
    // 深链来自应用外部（任意网页都能唤起），落地前必须展示不含凭据的来源/节点摘要
    // 并显式确认；完整 URL 可能含订阅 Token、UUID 或密码，不能直接放进可截图弹窗。
    if (intent.kind === 'sub') {
      const validationMessage = SubscriptionManager.validateSubscriptionUrl(intent.payload, false);
      if (validationMessage.length > 0) {
        this.lastError = localizeCoreMessage(this.language, validationMessage);
        SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
        return;
      }
    }
    this.confirmDeepLinkIntent(intent);
  }

  private confirmDeepLinkIntent(intent: DeepLinkIntent): void {
    const isSub = intent.kind === 'sub';
    const hint = isSub ? this.t('deepLink.confirm.sub') : this.t('deepLink.confirm.config');
    const summary = isSub ? this.safeSubscriptionImportSummary(intent.payload) : this.safeConfigImportSummary(intent.payload);
    try {
      this.getUIContext().showAlertDialog({
        title: this.t('deepLink.confirm.title'),
        message: `${hint}\n\n${summary}`,
        autoCancel: false,
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -20 },
        primaryButton: {
          value: this.t('action.add'),
          fontColor: AppColor.onBrand,
          backgroundColor: AppColor.brand,
          action: () => {
            this.applyDeepLinkIntent(intent);
          }
        },
        secondaryButton: {
          value: this.t('action.cancel'),
          fontColor: AppColor.textSecondary,
          backgroundColor: AppColor.bg,
          action: () => {
            SHARED_RUNTIME_CONTROLLER.appendLog(this.t('deepLink.confirm.declined'));
          }
        }
      });
    } catch (err) {
      // 弹不出确认框就放弃导入，绝不静默执行。
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('deepLink.confirm.declined'));
    }
  }

  private confirmControlDeepLink(action: DeepLinkControlAction, targetNodeId: string): void {
    if (action.length === 0) {
      return;
    }
    try {
      this.getUIContext().showAlertDialog({
        title: this.t('deepLink.control.confirm.title'),
        message: this.f1('deepLink.control.confirm.message', 'action', action),
        autoCancel: true,
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -20 },
        primaryButton: {
          value: this.t('action.confirm'),
          fontColor: AppColor.onBrand,
          backgroundColor: AppColor.brand,
          action: () => {
            this.handleControlDeepLink(action, targetNodeId);
          }
        },
        secondaryButton: {
          value: this.t('action.cancel'),
          fontColor: AppColor.textSecondary,
          backgroundColor: AppColor.bg,
          action: () => {
            SHARED_RUNTIME_CONTROLLER.appendLog(this.t('deepLink.control.confirm.declined'));
          }
        }
      });
    } catch (err) {
      // 外部控制入口无法展示确认框时必须拒绝，不能回退为静默执行。
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('deepLink.control.confirm.declined'));
    }
  }

  private async applyDeepLinkIntent(intent: DeepLinkIntent): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    try {
      if (intent.kind === 'sub') {
        const name = subscriptionNameFromDeepLink(intent.payload);
        // 只添加配置源，不自动联网拉取——拉取由用户在订阅页手动触发。
        const profile = await SubscriptionStore.load(context);
        const existing = SubscriptionStore.findGroupByUrl(profile.groups, intent.payload);
        if (existing !== null) {
          const selected = await SUBSCRIPTIONS_CONTROLLER.selectGroup(context, existing, this.language);
          this.applySubscriptionsState(selected);
          SHARED_RUNTIME_CONTROLLER.appendLog(this.t('scanner.subscriptionAlreadyAdded'));
          return;
        }
        const added = await SUBSCRIPTIONS_CONTROLLER.addGroup(context, name, intent.payload, '', '', '', '', false, this.language);
        if (SubscriptionStore.findGroupByUrl(added.subscriptionGroups, intent.payload) === null) {
          this.lastError = added.subscriptionMessage;
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }
        this.applySubscriptionsState(added);
        this.applyNodesState(await NODES_CONTROLLER.load(context, this.language));
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkSub', 'name', name));
      } else {
        const validation = NODES_CONTROLLER.validateConfig(intent.payload, this.language);
        if (!validation.valid) {
          this.lastError = validation.message;
          return;
        }
        const nodeName = this.nodeNameFromOutbound(validation.normalizedJson);
        if (!await this.addExternalNodeIfUnique(
          context,
          nodeName,
          validation.normalizedJson,
          validation.configType
        )) {
          this.lastError = this.f1('scanner.duplicateNode', 'name', nodeName);
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }
        this.applyNodesState(await NODES_CONTROLLER.load(context, this.language));
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkConfig', 'name', nodeName));
      }
    } catch (error) {
      this.lastError = this.f1('error.deepLinkImport', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    }
  }

  private async handlePendingSharedTextImport(): Promise<void> {
    const payload = AppStorage.get<string>('pendingSharedTextImport');
    if (payload === undefined || payload.trim().length === 0) {
      return;
    }
    AppStorage.setOrCreate('pendingSharedTextImport', '');
    this.confirmSharedTextImport(payload.trim());
  }

  private confirmSharedTextImport(payload: string): void {
    const summary = this.safeSharedImportSummary(payload);
    try {
      this.getUIContext().showAlertDialog({
        title: this.t('sharedText.confirm.title'),
        message: `${this.t('sharedText.confirm.message')}\n\n${summary}`,
        autoCancel: false,
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -20 },
        primaryButton: {
          value: this.t('action.add'),
          fontColor: AppColor.onBrand,
          backgroundColor: AppColor.brand,
          action: () => {
            this.importSharedTextPayload(payload);
          }
        },
        secondaryButton: {
          value: this.t('action.cancel'),
          fontColor: AppColor.textSecondary,
          backgroundColor: AppColor.bg,
          action: () => {
            SHARED_RUNTIME_CONTROLLER.appendLog(this.t('sharedText.confirm.declined'));
          }
        }
      });
    } catch (err) {
      // 无法显示确认框时安全失败，不能静默导入外部应用提供的内容。
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('sharedText.confirm.declined'));
    }
  }

  private safeSharedImportSummary(payload: string): string {
    const lines = this.uniqueImportLines(payload);
    const configLines = new Array<string>();
    let firstSubscription = '';
    let subscriptionCount = 0;
    for (let index = 0; index < lines.length; index++) {
      if (this.isSubscriptionImportLine(lines[index])) {
        subscriptionCount++;
        if (firstSubscription.length === 0) {
          firstSubscription = lines[index];
        }
      } else {
        configLines.push(lines[index]);
      }
    }

    const sections = new Array<string>();
    if (subscriptionCount > 0) {
      sections.push(this.safeSubscriptionImportSummary(firstSubscription, subscriptionCount));
    }
    const configPayload = configLines.length === lines.length ? payload : configLines.join('\n');
    if (configPayload.trim().length > 0) {
      sections.push(this.safeConfigImportSummary(configPayload));
    }
    return sections.length > 0 ? sections.join('\n\n') : this.t('scanner.previewInvalid');
  }

  private safeSubscriptionImportSummary(url: string, count: number = 1): string {
    const title = count > 1 ? this.f1('scanner.previewSubscriptions', 'count', count.toString()) :
      this.t('scanner.previewSubscription');
    const sourceHost = redactDiagnosticText(subscriptionNameFromDeepLink(url));
    return `${title}\n${sourceHost}\n${this.t('scanner.previewSubscriptionDetail')}`;
  }

  private safeConfigImportSummary(payload: string): string {
    const validation = NODES_CONTROLLER.validateConfig(payload, this.language);
    if (validation.valid) {
      const name = redactDiagnosticText(resolveImportedNodeName(
        validation.normalizedJson,
        this.t('import.sharedTextNodeName')
      ));
      const endpoint = extractNodeEndpoint(validation.normalizedJson);
      const endpointText = formatEndpointDescription(endpoint.address, endpoint.port);
      let detail = this.f1('scanner.previewProtocol', 'protocol', validation.protocol.toUpperCase());
      if (endpointText.length > 0) {
        detail += `\n${this.f1('scanner.previewEndpoint', 'endpoint', endpointText)}`;
      }
      return `${this.f1('scanner.previewNode', 'name', name)}\n${detail}`;
    }

    const parsedNodes = SubscriptionManager.parseSubscriptionContent(payload, '');
    if (parsedNodes.length > 0) {
      return `${this.f1('scanner.previewNodes', 'count', parsedNodes.length.toString())}\n${this.t('scanner.previewNodesDetail')}`;
    }
    return this.t('scanner.previewInvalid');
  }

  private async importSharedTextPayload(payload: string): Promise<void> {
    const value = payload.trim();
    if (value.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    const lines = this.uniqueImportLines(value);
    const configLines = new Array<string>();
    let subscriptionCount = 0;

    try {
      for (let index = 0; index < lines.length; index++) {
        const line = lines[index];
        if (this.isSubscriptionImportLine(line)) {
          if (await this.importSharedSubscriptionLine(context, line)) {
            subscriptionCount++;
          }
        } else {
          configLines.push(line);
        }
      }

      const configPayload = configLines.length === lines.length ? value : configLines.join('\n');
      const configCount = configPayload.trim().length > 0 ? await this.importSharedConfigPayload(context, configPayload) : 0;
      if (configCount > 0 || subscriptionCount > 0) {
        this.applyNodesState(await NODES_CONTROLLER.load(context, this.language));
        await this.syncSubscriptionBackgroundSchedule();
        const total = configCount + subscriptionCount;
        const message = total === 1 ? this.t('log.sharedTextImported') : this.f1('log.sharedTextImportedCount', 'count', `${total}`);
        SHARED_RUNTIME_CONTROLLER.appendLog(message);
        try {
          this.getUIContext().getPromptAction().showToast({ message });
        } catch (err) {
          // ignore
        }
      }
    } catch (error) {
      this.lastError = this.f1('error.deepLinkImport', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    }
  }

  private async importSharedSubscriptionLine(context: common.Context, url: string): Promise<boolean> {
    const validationMessage = SubscriptionManager.validateSubscriptionUrl(url, false);
    if (validationMessage.length > 0) {
      this.lastError = localizeCoreMessage(this.language, validationMessage);
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      return false;
    }

    const profile = await SubscriptionStore.load(context);
    const existing = SubscriptionStore.findGroupByUrl(profile.groups, url);
    if (existing !== null) {
      const selected = await SUBSCRIPTIONS_CONTROLLER.selectGroup(context, existing, this.language);
      this.applySubscriptionsState(selected);
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('scanner.subscriptionAlreadyAdded'));
      return false;
    }

    const name = subscriptionNameFromDeepLink(url);
    const added = await SUBSCRIPTIONS_CONTROLLER.addGroup(context, name, url, '', '', '', '', false, this.language);
    if (SubscriptionStore.findGroupByUrl(added.subscriptionGroups, url) === null) {
      this.lastError = added.subscriptionMessage;
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      return false;
    }
    this.applySubscriptionsState(added);
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.sharedSubscriptionAdded', 'name', name));
    return true;
  }

  private async importSharedConfigPayload(context: common.Context, payload: string): Promise<number> {
    const validation = NODES_CONTROLLER.validateConfig(payload, this.language);
    if (validation.valid) {
      const nodeName = resolveImportedNodeName(validation.normalizedJson, this.t('import.sharedTextNodeName'));
      if (!await this.addExternalNodeIfUnique(
        context,
        nodeName,
        validation.normalizedJson,
        validation.configType
      )) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('scanner.duplicateNode', 'name', nodeName));
        return 0;
      }
      SHARED_RUNTIME_CONTROLLER.appendLog(
        this.f1('log.deepLinkConfig', 'name', this.nodeNameFromOutbound(validation.normalizedJson))
      );
      return 1;
    }

    // 先用内置订阅解析器批量解析（支持 base64、多行分享链接、Clash YAML，涵盖 anytls/tuic
    // 等 sing-box 专属协议）。native(xray-core) 转换不认识 anytls/tuic，只作后备。
    const parsedNodes = SubscriptionManager.parseSubscriptionContent(payload, '');
    if (parsedNodes.length > 0) {
      let importedCount = 0;
      let duplicateCount = 0;
      let lastValidationError = '';
      for (let index = 0; index < parsedNodes.length; index++) {
        const parsedNode = parsedNodes[index];
        const imported = NODES_CONTROLLER.validateConfig(
          parsedNode.outboundJson,
          this.language,
          parsedNode.configType
        );
        if (!imported.valid) {
          lastValidationError = imported.message;
          continue;
        }
        if (await this.addExternalNodeIfUnique(
          context,
          parsedNode.name,
          imported.normalizedJson,
          imported.configType
        )) {
          importedCount++;
        } else {
          duplicateCount++;
        }
      }
      if (duplicateCount > 0) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('scanner.duplicateNodes', 'count', `${duplicateCount}`));
      }
      if (importedCount === 0 && duplicateCount === 0 && lastValidationError.length > 0) {
        this.lastError = lastValidationError;
        SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      }
      return importedCount;
    }

    const nativeResult = convertNativeShareTextToOutbounds(payload);
    if (!nativeResult.ok) {
      this.lastError = nativeResult.message.length > 0 ?
        `${validation.message}\n${nativeResult.message}` : validation.message;
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      return 0;
    }

    let importedCount = 0;
    let lastValidationError = '';
    for (let index = 0; index < nativeResult.outbounds.length; index++) {
      const outbound = nativeResult.outbounds[index];
      const imported = NODES_CONTROLLER.validateConfig(outbound.outboundJson, this.language, 'outbound');
      if (!imported.valid) {
        lastValidationError = imported.message;
        continue;
      }
      const nodeName = resolveImportedNodeName(imported.normalizedJson, outbound.name);
      if (!await this.addExternalNodeIfUnique(
        context,
        nodeName,
        imported.normalizedJson,
        imported.configType
      )) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('scanner.duplicateNode', 'name', nodeName));
        continue;
      }
      importedCount++;
    }

    if (importedCount === 0 && lastValidationError.length > 0) {
      this.lastError = lastValidationError;
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    }
    return importedCount;
  }

  private async addExternalNodeIfUnique(
    context: common.Context,
    name: string,
    outboundJson: string,
    configType?: XrayConfigType
  ): Promise<boolean> {
    if (await SubscriptionStore.findDuplicateNode(context, outboundJson, configType) !== null) {
      return false;
    }
    await SubscriptionStore.addManualNode(context, name, outboundJson, configType, false);
    return true;
  }

  private uniqueImportLines(value: string): Array<string> {
    const lines = value.split('\n');
    const seen = new Set<string>();
    const result = new Array<string>();
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index].trim();
      if (line.length === 0 || seen.has(line)) {
        continue;
      }
      seen.add(line);
      result.push(line);
    }
    return result.length > 0 ? result : [value.trim()];
  }

  private isSubscriptionImportLine(value: string): boolean {
    const lower = value.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  private async handleControlDeepLink(action: DeepLinkControlAction, targetNodeId: string = ''): Promise<void> {
    if (action === 'scan') {
      this.openScannerImmediately();
      SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControl', 'action', action));
      return;
    }

    if (this.isBusy()) {
      SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControlBusy', 'action', action));
      return;
    }

    if (action === 'start') {
      const target = await this.selectControlTargetNode(targetNodeId);
      if (!target.ok) {
        return;
      }
      if (target.runningSwitch) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControl', 'action', action));
        return;
      }
      if (this.isRunning()) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControlNoop', 'action', action));
        return;
      }
      await this.startConnection();
      SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControl', 'action', action));
      return;
    }

    if (action === 'stop') {
      if (!this.isRunning()) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControlNoop', 'action', action));
        return;
      }
      await this.stopConnection();
      SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControl', 'action', action));
      return;
    }

    if (action === 'toggle') {
      if (this.isRunning()) {
        await this.stopConnection();
      } else {
        const target = await this.selectControlTargetNode(targetNodeId);
        if (!target.ok) {
          return;
        }
        await this.startConnection();
      }
      SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.deepLinkControl', 'action', action));
    }
  }

  private async selectControlTargetNode(targetNodeId: string): Promise<ControlTargetSelectionResult> {
    const resolvedTargetNodeId = this.resolveControlTargetNodeId(targetNodeId);
    if (resolvedTargetNodeId.length === 0) {
      return { ok: true, changed: false, runningSwitch: false };
    }

    const node = this.findControlTargetNode(resolvedTargetNodeId);
    if (node === null) {
      this.lastError = this.f1('error.deepLinkControlNodeMissing', 'id', resolvedTargetNodeId);
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      return { ok: false, changed: false, runningSwitch: false };
    }
    if (node.id === this.selectedNodeId) {
      return { ok: true, changed: false, runningSwitch: false };
    }

    const wasRunning = this.isRunning();
    await this.selectNode(node);
    return { ok: this.lastError.length === 0, changed: true, runningSwitch: wasRunning };
  }

  private resolveControlTargetNodeId(targetNodeId: string): string {
    const value = targetNodeId.trim();
    return value.toLowerCase() === 'default' ? '' : value;
  }

  private findControlTargetNode(targetNodeId: string): ProxyNode | null {
    const activeNode = NODES_CONTROLLER.findNode(this.nodes, targetNodeId);
    if (activeNode !== null) {
      return activeNode;
    }
    for (let groupIndex = 0; groupIndex < this.subscriptionGroups.length; groupIndex++) {
      const nodes = this.subscriptionGroups[groupIndex].nodes;
      for (let nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
        if (nodes[nodeIndex].id === targetNodeId) {
          return nodes[nodeIndex];
        }
      }
    }
    return null;
  }

  private nodeNameFromOutbound(outboundJson: string): string {
    try {
      const obj = JSON.parse(outboundJson) as Record<string, Object>;
      const tag = obj.tag;
      if (typeof tag === 'string' && tag.trim().length > 0) {
        return tag.trim();
      }
      const remarks = obj.remarks;
      if (typeof remarks === 'string' && remarks.trim().length > 0) {
        return remarks.trim();
      }
      const name = obj.name;
      if (typeof name === 'string' && name.trim().length > 0) {
        return name.trim();
      }
    } catch (error) {
      // ignore and fall back
    }
    return this.t('import.linkNodeName');
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentTab, controller: this.tabsController }) {
      TabContent() {
        this.ConnectTab()
      }
      .tabBar(this.TabBarItem(this.t('tab.connect'), $r('app.media.ic_shield'), 0))

      TabContent() {
        this.NodesTab()
      }
      .tabBar(this.TabBarItem(this.t('tab.nodes'), $r('app.media.ic_globe'), 1))

      TabContent() {
        this.SettingsTab()
      }
      .tabBar(this.TabBarItem(this.t('tab.settings'), $r('app.media.ic_settings'), 2))
    }
    .barMode(BarMode.Fixed)
    // bar 高度由 Tabs 控制（默认固定），必须用 barHeight 撑高才能让出底部安全区/呼吸空间；
    // 在 cell(TabBarItem) 里加高度会被固定槽位裁掉。
    .barHeight(52 + this.tabBottomInset())
    .barBackgroundColor(AppColor.surface)
    .scrollable(false)
    .animationDuration(0)
    .divider({ strokeWidth: 0.5, color: AppColor.divider })
    .onChange((index: number) => {
      this.currentTab = index;
    })
    .backgroundColor(AppColor.bg)
    .width('100%')
    .height('100%')
  }

  @Builder
  private TabBarItem(label: string, icon: Resource, index: number) {
    Column({ space: 3 }) {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.currentTab === index ? AppColor.brand : AppColor.textTertiary)
      Text(label)
        .fontSize(FontSz.caption)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.currentTab === index ? AppColor.brand : AppColor.textTertiary)
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.tabBottomInset() })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // 底部 Tab 栏内衬：安全区高度之上再留一段固定呼吸空间，避免贴屏幕底边
  // （手势模式下导航指示条 avoid area 常为 0，仅靠 bottomSafe 会太靠底）
  private tabBottomInset(): number {
    return this.bottomSafe;
  }

  // ---------------------------------------------------------------------------
  // Tab 1 · 连接
  // ---------------------------------------------------------------------------

  @Builder
  private ConnectTab() {
    Column() {
      // 大标题
      Row() {
        Text('Hey')
          .fontSize(FontSz.display)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
      }
      .width('100%')
      .padding({ left: Space.xxl, right: Space.xxl, top: Space.xxl, bottom: Space.sm })

      if (this.lastError.length > 0) {
        Text(this.lastError)
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.danger)
          .width('100%')
          .padding({ left: Space.xxl, right: Space.xxl, top: Space.sm, bottom: Space.sm })
          .backgroundColor(AppColor.dangerTint)
          .margin({ left: Space.lg, right: Space.lg })
          .borderRadius(Radius.md)
      }

      // 连接核心区（垂直居中）
      Column({ space: Space.xl }) {
        this.ConnectRing()

        Column({ space: Space.xs }) {
          Text(this.statusLabel())
            .fontSize(FontSz.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isRunning() ? AppColor.brand : AppColor.textPrimary)
          Text(this.connectionSubtitle())
            .fontSize(FontSz.footnote)
            .fontColor(AppColor.textSecondary)
        }
        .alignItems(HorizontalAlign.Center)

        this.ConnectionDelayChip()
        this.EgressIpChip()
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // 当前节点选择器
      this.NodeSelectorRow()

      // 流量 / 时长统计
      this.StatsCard()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bg)
    .padding({ top: this.topSafe })
  }

  @Builder
  private ConnectRing() {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(168)
        .height(168)
        .fill(this.isRunning() ? AppColor.brandTint : AppColor.surfaceAlt)
        .opacity(this.isRunning() ? 1 : 0.6)

      Column() {
        if (this.isBusy()) {
          LoadingProgress()
            .width(44)
            .height(44)
            .color(this.isRunning() ? AppColor.onBrand : AppColor.brand)
        } else {
          Image(this.isRunning() ? $r('app.media.ic_stop') : $r('app.media.ic_play_arrow'))
            .width(44)
            .height(44)
            .fillColor(this.isRunning() ? AppColor.onBrand : AppColor.brand)
        }
      }
      .width(120)
      .height(120)
      .borderRadius(60)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.isRunning() ? AppColor.brand : AppColor.surface)
      .border(this.isRunning() ? { width: 0 } : { width: 1, color: AppColor.border })
      .shadow(this.isRunning()
        ? { radius: Elevation.glow, color: AppColor.shadowBrand, offsetX: 0, offsetY: 8 }
        : { radius: Elevation.card, color: AppColor.shadowCard, offsetX: 0, offsetY: 4 })
      .onClick(() => {
        if (this.isBusy()) {
          return;
        }
        if (this.isRunning()) {
          this.stopConnection();
        } else {
          this.confirmCoreSwitchAndConnect();
        }
      })
    }
  }

  // 「当前连接」测速胶囊（issue #7）：连接后自动测一次，点按随时复测。动态值一律在
  // builder 内部读 this.*。固定高度 + Hidden 占位：未连接时保留空间，避免圆环上下跳动。
  @Builder
  private ConnectionDelayChip() {
    Row({ space: 6 }) {
      if (this.connectionDelayTesting) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(AppColor.textSecondary)
      }
      Text(this.connectionDelayText())
        .fontSize(FontSz.footnote)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.connectionDelayColor())
    }
    .height(32)
    .padding({ left: Space.lg, right: Space.lg })
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.pill)
    .border({ width: 1, color: AppColor.border })
    .visibility(this.isRunning() ? Visibility.Visible : Visibility.Hidden)
    .onClick(() => {
      this.testCurrentConnectionDelay();
    })
  }

  @Builder
  private EgressIpChip() {
    Row({ space: 6 }) {
      if (this.egressIpChecking) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(AppColor.textSecondary)
      }
      Text(this.egressIpText())
        .fontSize(FontSz.footnote)
        .fontColor(this.egressIp.length > 0 ? AppColor.success : AppColor.textSecondary)
    }
    .height(32)
    .padding({ left: Space.lg, right: Space.lg })
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.pill)
    .border({ width: 1, color: AppColor.border })
    .visibility(this.isRunning() ? Visibility.Visible : Visibility.Hidden)
    .onClick(() => {
      this.recheckCurrentEgressIp();
    })
  }

  private egressIpText(): string {
    if (this.egressIpChecking) {
      return this.t('home.egressIpChecking');
    }
    if (this.egressIp.length > 0) {
      return this.f1('home.egressIp', 'value', this.egressIp);
    }
    return this.t('home.egressIpUnavailable');
  }

  private connectionDelayText(): string {
    if (this.connectionDelayTesting) {
      return this.t('node.delay.testing');
    }
    if (this.connectionDelayMs >= 0) {
      return this.f1('node.delay.ms', 'value', this.connectionDelayMs.toString());
    }
    if (this.connectionDelayFailed) {
      return this.t('home.testConnectionFailed');
    }
    return this.t('home.testConnection');
  }

  // 配色沿用节点列表的延迟阈值约定（≤300 绿 / ≤900 黄 / 其余红）。
  private connectionDelayColor(): ResourceColor {
    if (this.connectionDelayTesting) {
      return AppColor.textSecondary;
    }
    if (this.connectionDelayMs >= 0) {
      if (this.connectionDelayMs <= 300) {
        return AppColor.success;
      }
      if (this.connectionDelayMs <= 900) {
        return AppColor.warning;
      }
      return AppColor.danger;
    }
    if (this.connectionDelayFailed) {
      return AppColor.danger;
    }
    return AppColor.brand;
  }

  // 点按测试当前连接延迟。测速中的中间态先本地置位求即时反馈，权威结果由控制器快照回填。
  private async testCurrentConnectionDelay(): Promise<void> {
    if (!this.isRunning() || this.connectionDelayTesting) {
      return;
    }
    this.connectionDelayTesting = true;
    const context = this.getUIContext().getHostContext() as common.Context;
    await SHARED_RUNTIME_CONTROLLER.measureCurrentConnectionDelay(context, this.language);
    this.applyRuntimeState(SHARED_RUNTIME_CONTROLLER.snapshot());
  }

  // 出口胶囊可随时点按复测；先显示进行中，再由 RuntimeController 的会话保护写回结果。
  private async recheckCurrentEgressIp(): Promise<void> {
    if (!this.isRunning() || this.egressIpChecking) {
      return;
    }
    this.egressIpChecking = true;
    await SHARED_RUNTIME_CONTROLLER.recheckCurrentEgressIp(this.language);
    this.applyRuntimeState(SHARED_RUNTIME_CONTROLLER.snapshot());
  }

  @Builder
  private NodeSelectorRow() {
    Row({ space: Space.md }) {
      Column() {
        Image($r('app.media.ic_globe'))
          .width(20)
          .height(20)
          .fillColor(this.selectedNodeId.length > 0 ? AppColor.brand : AppColor.textTertiary)
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.selectedNodeId.length > 0 ? AppColor.brandTint : AppColor.surfaceAlt)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 2 }) {
        Text(this.t('home.currentNode'))
          .fontSize(FontSz.caption)
          .fontColor(AppColor.textTertiary)
        Text(this.selectedNodeId.length > 0 ? this.findSelectedNodeName() : this.t('home.noNodeSelected'))
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Image($r('app.media.ic_chevron_right'))
        .width(20)
        .height(20)
        .fillColor(AppColor.textTertiary)
    }
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .margin({ left: Space.lg, right: Space.lg, bottom: Space.md })
    .onClick(() => {
      this.tabsController.changeIndex(1);
      this.currentTab = 1;
    })
  }

  // 底部流量卡：时长已由圆环下方负责，这里专注「上传/下载 实时速度 + 累计总量」。
  // 仅在开启【显示速度/流量统计】时出现，避免和圆环下方时长重复。
  @Builder
  private StatsCard() {
    if (this.speedEnabled) {
      Row() {
        this.TrafficCell('upload', AppColor.brand)
        Divider().vertical(true).height(36).color(AppColor.divider)
        this.TrafficCell('download', AppColor.success)
      }
      .width('100%')
      .padding({ top: Space.md, bottom: Space.md })
      .backgroundColor(AppColor.surface)
      .borderRadius(Radius.lg)
      .margin({ left: Space.lg, right: Space.lg, bottom: Space.xl })
    }
  }

  // 主值=实时速度（每秒），副行=方向标签 + 累计总量。动态值一律在 builder 内部读 this.*，
  // 不按值传参（按值传进 private @Builder 会冻结，不随 @State 刷新）。
  @Builder
  private TrafficCell(kind: string, valueColor: ResourceColor) {
    Column({ space: 4 }) {
      Text(this.trafficSpeedText(kind))
        .fontSize(FontSz.callout)
        .fontWeight(FontWeight.Bold)
        .fontColor(valueColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.trafficTotalText(kind))
        .fontSize(FontSz.caption)
        .fontColor(AppColor.textTertiary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  private trafficSpeedText(kind: string): string {
    const bytesPerSecond = kind === 'download' ? this.downloadSpeed : this.uploadSpeed;
    return `${this.formatBytes(bytesPerSecond)}/s`;
  }

  private trafficTotalText(kind: string): string {
    if (kind === 'download') {
      return `${this.t('home.download')} ${this.formatBytes(this.totalDownload)}`;
    }
    return `${this.t('home.upload')} ${this.formatBytes(this.totalUpload)}`;
  }

  // ---------------------------------------------------------------------------
  // Tab 2 · 节点
  // ---------------------------------------------------------------------------

  @Builder
  private NodesTab() {
    Column() {
      // 标题栏 / 搜索栏（就地切换）
      this.NodesHeader()

      if (this.subscriptionGroups.length > 0) {
        this.GroupTabs()
      }

      if (this.subscriptionGroups.length === 0) {
        Scroll() {
          this.EmptyStateUI()
        }
        .layoutWeight(1)
        .width('100%')
      } else if (this.visibleNodes().length === 0) {
        Scroll() {
          if (this.displayedNodes().length > 0) {
            // 分组本身有节点，仅因搜索无匹配而为空
            this.EmptySearchNodesUI()
          } else {
            // 分组本身没有节点，引导更新订阅
            this.EmptyGroupNodesUI()
          }
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        this.NodeList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bg)
    .padding({ top: this.topSafe })
  }

  @Builder
  private NodesHeader() {
    if (this.showSearch) {
      Row({ space: Space.sm }) {
        Search({ value: this.searchQuery, placeholder: this.t('nodes.searchPlaceholder') })
          .layoutWeight(1)
          .height(40)
          .backgroundColor(AppColor.surfaceAlt)
          .placeholderColor(AppColor.textTertiary)
          .onChange((value: string) => {
            this.searchQuery = value;
          })

        Text(this.t('action.cancel'))
          .fontSize(FontSz.callout)
          .fontColor(AppColor.brand)
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
              this.showSearch = false;
              this.searchQuery = '';
            })
          })
      }
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg, top: Space.lg, bottom: Space.sm })
    } else {
      Row({ space: Space.xs }) {
        Text(this.t('tab.nodes'))
          .fontSize(FontSz.display)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)

        // 首页节点列表直接提供扫码入口，避免先进入设置或二级导入页。
        IconButton({
          icon: $r('app.media.ic_qr_code'),
          buttonSize: 44,
          iconSize: 24,
          iconColor: AppColor.brand,
          onAction: () => {
            this.openScannerImmediately();
          }
        })

        IconButton({
          icon: $r('app.media.ic_search'),
          buttonSize: 44,
          iconSize: 24,
          iconColor: AppColor.textSecondary,
          onAction: () => {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
              this.showSearch = true;
            })
          }
        })

        Column() {
          Image($r('app.media.ic_more_vert'))
            .width(24)
            .height(24)
            .fillColor(AppColor.textSecondary)
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .bindMenu(this.NodesMenu())
      }
      .width('100%')
      .padding({ left: Space.xxl, right: Space.lg, top: Space.xxl, bottom: Space.sm })
    }
  }

  @Builder
  private NodesMenu() {
    Menu() {
      MenuItem({ content: this.t('menu.updateSubscription') })
        .onClick(() => {
          this.updateSubscription();
        })
      MenuItem({ content: this.t('menu.testTcping') })
        .onClick(() => {
          this.testVisibleNodeDelay('tcp');
        })
      MenuItem({ content: this.t('menu.testRealConnection') })
        .onClick(() => {
          this.testVisibleNodeDelay('real');
        })
      MenuItem({ content: this.t('menu.sortByTestResult') })
        .onClick(() => {
          this.sortByTestResults();
        })
      MenuItem({ content: this.t('menu.deleteConfig') })
        .onClick(() => {
          this.confirmClearNodes();
        })
      MenuItem({ content: this.t('menu.deleteDuplicate') })
        .onClick(() => {
          this.dedupeNodes();
        })
      MenuItem({ content: this.t('menu.deleteInvalid') })
        .onClick(() => {
          this.removeInvalidNodes();
        })
      MenuItem({ content: this.t('menu.exportClipboard') })
        .onClick(() => {
          this.exportAllNodesToClipboard();
        })
      MenuItem({ content: this.t('menu.serviceRestart') })
        .onClick(() => {
          this.reconnectService();
        })
      MenuItem({ content: this.t('menu.locateSelected') })
        .onClick(() => {
          this.locateSelectedConfig();
        })
    }
  }

  @Builder
  private GroupTabs() {
    Row() {
      Scroll() {
        Row({ space: Space.sm }) {
          ForEach(this.displaySubscriptionGroups(), (group: SubscriptionGroup) => {
            this.GroupTab(group)
          }, (group: SubscriptionGroup, index: number) => `${index}-${group.id}`)
        }
        .padding({ left: Space.lg, right: Space.lg })
        .height(40)
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height(48)
  }

  @Builder
  private GroupTab(group: SubscriptionGroup) {
    Row() {
      Text(group.name.length > 0 ? group.name : 'Subscription')
        .fontSize(FontSz.body)
        .fontWeight(this.isGroupTabSelected(group) ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.isGroupTabSelected(group) ? AppColor.onBrand : AppColor.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(32)
    .padding({ left: Space.lg, right: Space.lg })
    .borderRadius(Radius.pill)
    .backgroundColor(this.isGroupTabSelected(group) ? AppColor.brand : AppColor.surfaceAlt)
    .onClick(() => {
      this.selectSubscriptionGroup(group);
    })
  }

  @Builder
  private NodeList() {
    List({ scroller: this.nodeListScroller }) {
      ForEach(this.visibleNodes(), (node: ProxyNode) => {
        ListItem() {
          ServerNodeCard({
            node,
            isSelected: node.id === this.selectedNodeId,
            sourceLabel: this.nodeEndpointText(node),
            delayText: this.nodeDelayText(node),
            delayColor: this.nodeDelayColor(node),
            onSelect: (selectedNode: ProxyNode) => {
              this.selectNode(selectedNode);
            }
          })
        }
        .swipeAction({ end: this.NodeSwipeActions(node) })
        // key 必须编码选中态与延迟值：否则列表内容不变时 ForEach 按 key 复用旧子组件、
        // 不重跑 item builder，导致切换选中节点（BUG-005）或延迟测完（BUG-003）后行不刷新。
      }, (node: ProxyNode, index: number) => `${index}-${node.id}-${node.id === this.selectedNodeId ? 'S' : 'U'}-${node.delayStatus}-${node.delayMs}`)
    }
    .layoutWeight(1)
    .width('100%')
    .lanes(this.doubleColumnDisplay ? 2 : 1)
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .clip(true)
    .divider({ strokeWidth: 0.5, color: AppColor.divider, startMargin: 56 })
    .scrollBar(BarState.Off)
    .margin({ left: Space.lg, right: Space.lg, top: Space.xs, bottom: Space.lg })
  }

  @Builder
  private NodeSwipeActions(node: ProxyNode) {
    Row() {
      this.SwipeButton($r('app.media.ic_share'), this.t('action.share'), AppColor.brand, () => {
        this.shareNode(node);
      })
      this.SwipeButton($r('app.media.ic_edit'), this.t('action.detail'), AppColor.textSecondary, () => {
        this.openNodeDetail(node);
      })
      if (this.canMoveNode(node, -1)) {
        this.SwipeButton($r('app.media.ic_arrow_upward'), this.t('action.moveUp'), AppColor.textSecondary, () => {
          this.moveNode(node, -1);
        })
      }
      if (this.canMoveNode(node, 1)) {
        this.SwipeButton($r('app.media.ic_arrow_downward'), this.t('action.moveDown'), AppColor.textSecondary, () => {
          this.moveNode(node, 1);
        })
      }
      this.SwipeButton($r('app.media.ic_delete'), this.t('action.delete'), AppColor.danger, () => {
        this.removeNode(node);
      })
    }
    .height('100%')
  }

  @Builder
  private SwipeButton(icon: Resource, label: string, bg: ResourceColor, action: () => void) {
    Column({ space: 3 }) {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(Color.White)
      Text(label)
        .fontSize(FontSz.caption)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(bg)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      action();
    })
  }

  @Builder
  private EmptyStateUI() {
    Column({ space: Space.xxl }) {
      Column({ space: Space.md }) {
        Image($r('app.media.ic_subscriptions'))
          .width(72)
          .height(72)
          .fillColor(AppColor.textTertiary)
          .opacity(0.4)

        Text(this.t('home.empty.title'))
          .fontSize(FontSz.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .margin({ top: Space.sm })

        Text(this.t('home.empty.detail'))
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
          .textAlign(TextAlign.Center)
          .padding({ left: Space.xxxl, right: Space.xxxl })
          .lineHeight(20)
      }
      .alignItems(HorizontalAlign.Center)
      .width('100%')

      Column({ space: Space.md }) {
        Button(this.t('home.empty.addSubscription'))
          .width(200)
          .height(44)
          .backgroundColor(AppColor.brand)
          .fontColor(AppColor.onBrand)
          .fontWeight(FontWeight.Medium)
          .borderRadius(Radius.pill)
          .onClick(() => {
            this.openRoute(AppRoute.SUBSCRIPTIONS);
          })

        Button(this.t('screen.import.title'))
          .width(200)
          .height(44)
          .backgroundColor(AppColor.surfaceAlt)
          .fontColor(AppColor.textSecondary)
          .fontWeight(FontWeight.Medium)
          .borderRadius(Radius.pill)
          .onClick(() => {
            this.openRoute(AppRoute.IMPORT);
          })
      }
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding({ top: 72, bottom: 72 })
  }

  @Builder
  private EmptyGroupNodesUI() {
    Column({ space: Space.xl }) {
      Image($r('app.media.ic_cloud_download'))
        .width(64)
        .height(64)
        .fillColor(AppColor.textTertiary)
        .opacity(0.4)

      Text(this.t('nodes.emptyGroup.title'))
        .fontSize(FontSz.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textSecondary)

      Text(this.t('nodes.emptyGroup.detail'))
        .fontSize(FontSz.footnote)
        .fontColor(AppColor.textTertiary)
        .textAlign(TextAlign.Center)
        .padding({ left: 40, right: 40 })

      Button(this.t('nodes.emptyGroup.update'))
        .height(38)
        .padding({ left: Space.xxl, right: Space.xxl })
        .backgroundColor(AppColor.brand)
        .fontColor(AppColor.onBrand)
        .borderRadius(Radius.pill)
        .onClick(() => {
          this.updateSubscription();
        })
    }
    .width('100%')
    .padding({ top: 72, bottom: 72 })
  }

  @Builder
  private EmptySearchNodesUI() {
    Column({ space: Space.xl }) {
      Image($r('app.media.ic_search'))
        .width(64)
        .height(64)
        .fillColor(AppColor.textTertiary)
        .opacity(0.4)

      Text(this.t('nodes.searchEmpty.title'))
        .fontSize(FontSz.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textSecondary)

      Text(this.t('nodes.searchEmpty.detail'))
        .fontSize(FontSz.footnote)
        .fontColor(AppColor.textTertiary)
        .textAlign(TextAlign.Center)
        .padding({ left: 40, right: 40 })
    }
    .width('100%')
    .padding({ top: 72, bottom: 72 })
  }

  // ---------------------------------------------------------------------------
  // Tab 3 · 设置
  // ---------------------------------------------------------------------------

  @Builder
  private SettingsTab() {
    Column() {
      Row() {
        Text(this.t('tab.settings'))
          .fontSize(FontSz.display)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
      }
      .width('100%')
      .padding({ left: Space.xxl, right: Space.xxl, top: Space.xxl, bottom: Space.sm })

      Scroll() {
        Column({ space: Space.lg }) {
          this.SettingsGroup('settings.group.nodes', [
            new SettingsRowModel($r('app.media.ic_add'), 'screen.import.title', AppRoute.IMPORT),
            new SettingsRowModel($r('app.media.ic_subscriptions'), 'screen.subscriptions.title', AppRoute.SUBSCRIPTIONS),
            new SettingsRowModel($r('app.media.ic_qr_code'), 'screen.scanner.title', AppRoute.SCANNER)
          ])

          this.SettingsGroup('settings.group.network', [
            new SettingsRowModel($r('app.media.ic_route'), 'screen.routing.title', AppRoute.ROUTING),
            new SettingsRowModel($r('app.media.ic_apps'), 'screen.perApp.title', AppRoute.PER_APP),
            new SettingsRowModel($r('app.media.ic_folder'), 'screen.assets.title', AppRoute.ASSETS)
          ])

          this.SettingsGroup('settings.group.general', [
            new SettingsRowModel($r('app.media.ic_settings'), 'settings.row.preferences', AppRoute.SETTINGS),
            new SettingsRowModel($r('app.media.ic_article'), 'screen.logs.title', AppRoute.LOGS),
            new SettingsRowModel($r('app.media.ic_info'), 'screen.about.title', AppRoute.ABOUT)
          ])
        }
        .width('100%')
        .padding({ bottom: Space.xxl })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bg)
    .padding({ top: this.topSafe })
  }

  @Builder
  private SettingsGroup(titleKey: string, rows: Array<SettingsRowModel>) {
    Column({ space: 0 }) {
      Text(this.t(titleKey))
        .fontSize(FontSz.footnote)
        .fontColor(AppColor.textTertiary)
        .width('100%')
        .padding({ left: Space.lg, bottom: Space.sm })

      Column({ space: 0 }) {
        ForEach(rows, (row: SettingsRowModel, index: number) => {
          this.SettingsRow(row, index === rows.length - 1)
        }, (row: SettingsRowModel, index: number) => `${index}-${row.titleKey}`)
      }
      .width('100%')
      .backgroundColor(AppColor.surface)
      .borderRadius(Radius.lg)
      .clip(true)
    }
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg })
  }

  @Builder
  private SettingsRow(row: SettingsRowModel, isLast: boolean) {
    Column() {
      Row({ space: Space.md }) {
        Image(row.icon)
          .width(22)
          .height(22)
          .fillColor(AppColor.textSecondary)

        Text(this.t(row.titleKey))
          .fontSize(FontSz.callout)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Image($r('app.media.ic_chevron_right'))
          .width(20)
          .height(20)
          .fillColor(AppColor.textTertiary)
      }
      .width('100%')
      .height(52)
      .padding({ left: Space.lg, right: Space.lg })

      if (!isLast) {
        Divider()
          .strokeWidth(0.5)
          .color(AppColor.divider)
          .margin({ left: 50 })
      }
    }
    .width('100%')
    .onClick(() => {
      this.openRoute(row.route);
    })
  }

  // ---------------------------------------------------------------------------
  // 逻辑（沿用既有实现）
  // ---------------------------------------------------------------------------

  private formatBytes(bytes: number): string {
    if (bytes === 0) {
      return '0 B';
    }
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return (bytes / Math.pow(k, i)).toFixed(2) + ' ' + sizes[i];
  }

  private async loadInitialState(): Promise<void> {
    await this.loadSettings();
    await this.loadNodes();
    // 累计流量基线必须早于首次 refreshRuntime；运行态恢复又必须早于任何可能启停 VPN
    // 的自动启动或外部动作。
    await this.loadTrafficTotals();
    await this.refreshRuntime();
    await this.handlePendingAutoStartupLaunch();
    await this.handlePendingSharedTextImport();
    await this.handlePendingDeepLink();
    await this.refreshDueSubscriptions();
    await this.syncSubscriptionBackgroundSchedule();
  }

  private async initializePageState(): Promise<void> {
    try {
      await this.loadInitialState();
    } catch (error) {
      this.lastError = redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    } finally {
      this.initialStateLoading = false;
      this.initialStateReady = true;
      // Watch 可能在初始化期间到达；此时刻再消费，确保先完成运行态接管。
      if (this.hasPendingExternalIntent()) {
        this.consumePendingExternalIntentSoon();
      }
    }
  }

  // 读出持久化的累计总量与上次会话基线。必须在第一次 refreshRuntime（会触发累加）之前完成，
  // 否则首帧会以 0 基线累加、把历史值冲掉。
  private async loadTrafficTotals(): Promise<void> {
    if (this.trafficTotalsLoaded) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const totals = await TrafficTotalsStore.load(context);
      this.totalUpload = totals.lifetimeUpload;
      this.totalDownload = totals.lifetimeDownload;
      this.lastSessionUpload = totals.lastSessionUpload;
      this.lastSessionDownload = totals.lastSessionDownload;
    } catch (error) {
      // 读失败就从 0 起，不阻断启动
    } finally {
      this.trafficTotalsLoaded = true;
    }
  }

  private async loadSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      this.currentSettings = await SETTINGS_CONTROLLER.load(context);
      this.language = this.currentSettings.language;
      this.speedEnabled = this.currentSettings.speedEnabled;
      this.groupAllDisplay = this.currentSettings.groupAllDisplay;
      this.doubleColumnDisplay = this.currentSettings.doubleColumnDisplay;
      if (!this.groupAllDisplay) {
        this.allGroupsSelected = false;
      }
    } catch (error) {
      this.lastError = this.f1('error.loadSettings', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    }
  }

  private async loadNodes(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      this.applyNodesState(await NODES_CONTROLLER.load(context, this.language));
    } catch (error) {
      this.lastError = this.f1('error.loadSubscription', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    }
  }

  private async refreshDueSubscriptions(): Promise<void> {
    const now = Date.now();
    if (now - this.lastAutoSubscriptionCheckAt < AUTO_SUBSCRIPTION_CHECK_THROTTLE_MS || this.subscriptionUpdating) {
      return;
    }

    this.lastAutoSubscriptionCheckAt = now;
    this.subscriptionUpdating = true;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const result = await SUBSCRIPTIONS_CONTROLLER.updateDue(context, this.language, now, this.subscriptionProxyPort());
      if (result.updatedCount === 0 && result.failedCount === 0) {
        return;
      }
      this.applySubscriptionsState(result.state);
      SHARED_RUNTIME_CONTROLLER.appendLog(result.state.subscriptionMessage);
      this.applyNodesState(await NODES_CONTROLLER.load(context, this.language));
    } catch (error) {
      this.lastError = this.f1('error.updateSubscription', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    } finally {
      this.subscriptionUpdating = false;
    }
  }

  private async syncSubscriptionBackgroundSchedule(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      await SubscriptionBackgroundScheduler.sync(context);
    } catch (error) {
      SHARED_RUNTIME_CONTROLLER.appendLog(
        `Subscription background schedule sync failed: ${redactDiagnosticText(JSON.stringify(error))}`
      );
    }
  }

  // 手动点连接时：若当前内核跑不了该节点协议（如 Xray 内核 + anytls/tuic/hysteria2），
  // 弹窗征询是否用所需内核建立本次连接（仅本次生效，不改全局内核设置）；确认后照常连接，
  // ConnectionController 会为这些协议强制切到 sing-box。
  private async confirmCoreSwitchAndConnect(): Promise<void> {
    if (this.isBusy()) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    const currentCore = await CoreSelectionStore.load(context);
    // 用当前待连接的 outbound 推协议（与 ConnectionController 判定 forceSingbox 的口径一致），
    // 不依赖 this.nodes 是否包含当前节点（当前节点是全局值，可能不在正浏览的组里）。
    const protocol = normalizeOutboundInput(this.outboundJson).protocol;
    const requiredCore = requiredCoreForProtocol(currentCore, protocol);
    if (requiredCore === null) {
      await this.startConnection();
      return;
    }
    const coreLabel = requiredCore === CORE_TYPE_SINGBOX ? 'sing-box' : 'Xray';
    AlertDialog.show({
      title: this.t('coreSwitch.title'),
      message: this.f2('coreSwitch.message', 'protocol', protocol.toUpperCase(), 'core', coreLabel),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      offset: { dx: 0, dy: -20 },
      primaryButton: {
        value: this.t('coreSwitch.confirm'),
        fontColor: AppColor.onBrand,
        backgroundColor: AppColor.brand,
        action: () => {
          this.startConnection();
        }
      },
      secondaryButton: {
        value: this.t('action.cancel'),
        fontColor: AppColor.textSecondary,
        backgroundColor: AppColor.bg,
        action: () => {
        }
      }
    });
  }

  private async startConnection(): Promise<void> {
    if (this.isBusy()) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('home.busy') });
      } catch (err) {
        // ignore
      }
      return;
    }

    this.connectionOperationRunning = true;
    try {
      await this.startConnectionInternal();
    } finally {
      this.connectionOperationRunning = false;
    }
  }

  private async startConnectionInternal(): Promise<boolean> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const saved = await NODES_CONTROLLER.saveProfile(context, this.outboundJson, this.language, this.configType);
    this.applySaveProfileResult(saved);
    if (saved.profile === null) {
      SHARED_RUNTIME_CONTROLLER.appendLog(saved.lastError);
      return false;
    }

    try {
      this.runtimeMode = normalizeAppRuntimeMode(this.currentSettings.mode, APP_MODE_VPN);
      this.status = ConnectionStatus.STARTING;
      this.syncControlCard();
      const state = await SHARED_RUNTIME_CONTROLLER.start(context, saved.profile, this.currentSettings, this.language);
      this.applyRuntimeState(state);
      this.showProxySharingStartWarning(state.status);
      return state.status === ConnectionStatus.RUNNING;
    } catch (error) {
      this.status = ConnectionStatus.ERROR;
      this.lastError = this.f1('vpn.startFailed', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      this.syncControlCard();
      return false;
    }
  }

  private showProxySharingStartWarning(status: ConnectionStatus): void {
    if (!shouldShowProxySharingStartWarning(this.currentSettings, status)) {
      return;
    }
    const message = this.t('log.proxySharingWarning');
    SHARED_RUNTIME_CONTROLLER.appendLog(message);
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (err) {
      // ignore
    }
  }

  private async stopConnection(): Promise<void> {
    if (this.isBusy()) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('home.busy') });
      } catch (err) {
        // ignore
      }
      return;
    }

    this.connectionOperationRunning = true;
    try {
      await this.stopConnectionInternal();
    } finally {
      this.connectionOperationRunning = false;
    }
  }

  private async stopConnectionInternal(): Promise<boolean> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      this.status = ConnectionStatus.STOPPING;
      this.syncControlCard();
      const state = await SHARED_RUNTIME_CONTROLLER.stop(context, this.language);
      this.applyRuntimeState(state);
      return state.status === ConnectionStatus.IDLE;
    } catch (error) {
      this.status = ConnectionStatus.ERROR;
      this.lastError = this.f1('vpn.stopFailed', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      this.syncControlCard();
      return false;
    }
  }

  private async updateSubscription(): Promise<void> {
    if (this.subscriptionUpdating) {
      return;
    }
    this.subscriptionUpdating = true;
    this.subscriptionMessage = this.t('log.updatingSubscription');
    SHARED_RUNTIME_CONTROLLER.appendLog(this.subscriptionMessage);
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const state = await SUBSCRIPTIONS_CONTROLLER.update(context, this.selectedGroupId, this.subscriptionUrl, this.selectedNodeId, this.language, this.subscriptionProxyPort());
      this.applySubscriptionsState(state);
      SHARED_RUNTIME_CONTROLLER.appendLog(state.subscriptionMessage);
      // 更新完成后弹出可见提示（成功含节点数，失败含原因），避免用户只能翻日志才知道结果
      if (state.subscriptionMessage.length > 0) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: state.subscriptionMessage, duration: 3000 });
        } catch (err) {
          // ignore
        }
      }
      this.applyNodesState(await NODES_CONTROLLER.load(context, this.language));
    } finally {
      this.subscriptionUpdating = false;
    }
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    if (this.isBusy()) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('home.busy') });
      } catch (err) {
        // ignore
      }
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    const shouldSwitchConnection = this.isRunning() && node.id !== this.selectedNodeId;
    this.selectedNodeId = node.id;
    this.outboundJson = node.outboundJson;

    if (shouldSwitchConnection) {
      this.connectionOperationRunning = true;
    }

    try {
      const state = await NODES_CONTROLLER.selectNode(context, node, this.language);
      this.applyNodesState(state);
      const message = state.lastError.length > 0 ? state.lastError : this.f1('log.selectedNode', 'name', node.name);
      SHARED_RUNTIME_CONTROLLER.appendLog(message);

      if (shouldSwitchConnection && state.lastError.length === 0) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.switchNodeReconnect'));
        const stopped = await this.stopConnectionInternal();
        if (stopped) {
          await this.startConnectionInternal();
        }
      }
    } finally {
      if (shouldSwitchConnection) {
        this.connectionOperationRunning = false;
      }
    }
  }

  private shareNode(node: ProxyNode): void {
    this.getUIContext().getRouter().pushUrl({
      url: AppRoute.EXPORT,
      params: {
        nodeId: node.id
      }
    }).catch((err: Error) => {});
  }

  private removeNode(node: ProxyNode): void {
    if (this.currentSettings.confirmRemove) {
      try {
        this.getUIContext().showAlertDialog({
        title: this.t('menu.deleteConfig'),
        message: this.f1('node.deleteConfirm', 'name', node.name),
        autoCancel: true,
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -20 },
        primaryButton: {
          value: this.t('action.delete'),
          fontColor: AppColor.onBrand,
          backgroundColor: AppColor.danger,
          action: () => {
            this.removeNodeImmediately(node);
          }
        },
        secondaryButton: {
          value: this.t('action.cancel'),
          fontColor: AppColor.textSecondary,
          backgroundColor: AppColor.bg,
          action: () => {}
        }
      });
      } catch (err) {
        // ignore
      }
      return;
    }
    this.removeNodeImmediately(node);
  }

  private async moveNode(node: ProxyNode, delta: number): Promise<void> {
    const result = moveNodeWithinGroup(this.subscriptionGroups, this.selectedGroupId, node.id, delta, Date.now());
    if (!result.moved) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    const subscription = await SubscriptionStore.saveGroups(context, result.groups);
    this.applySubscriptionsState(this.subscriptionStateFromProfile(subscription));
    const message = this.f1('log.nodeReordered', 'name', node.name);
    SHARED_RUNTIME_CONTROLLER.appendLog(message);
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (err) {
      // ignore
    }
  }

  private async removeNodeImmediately(node: ProxyNode): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const state = await NODES_CONTROLLER.removeNode(context, node.id, this.language);
    this.applyNodesState(state);
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.nodeRemoved', 'name', node.name));
  }

  private async selectSubscriptionGroup(group: SubscriptionGroup): Promise<void> {
    if (group.id === ALL_GROUP_ID) {
      this.allGroupsSelected = true;
      SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.openedSubscriptionGroup', 'name', group.name));
      return;
    }
    this.allGroupsSelected = false;
    const context = this.getUIContext().getHostContext() as common.Context;
    const state = await SUBSCRIPTIONS_CONTROLLER.selectGroup(context, group, this.language);
    this.applySubscriptionsState(state);
    SHARED_RUNTIME_CONTROLLER.appendLog(state.subscriptionMessage);
  }

  private async dedupeNodes(): Promise<void> {
    const targets = this.visibleNodes();
    if (targets.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    const result = dedupeVisibleNodesInGroups(this.subscriptionGroups, targets, Date.now());
    this.applySubscriptionsState(this.subscriptionStateFromProfile(await SubscriptionStore.saveGroups(context, result.groups)));
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.nodesDeduped', 'count', result.removedCount.toString()));
  }

  private async removeInvalidNodes(): Promise<void> {
    const targets = this.visibleNodes();
    if (targets.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    const result = removeVisibleTestFailedNodesFromGroups(this.subscriptionGroups, targets, Date.now());
    this.applySubscriptionsState(this.subscriptionStateFromProfile(await SubscriptionStore.saveGroups(context, result.groups)));
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.invalidNodesRemoved', 'count', result.removedCount.toString()));
  }

  private async sortByTestResults(): Promise<void> {
    const targets = this.allGroupsSelected ? this.displayedNodes() : this.nodes;
    if (targets.length === 0) {
      return;
    }
    const result = sortGroupsByDelayTargets(this.subscriptionGroups, targets, Date.now());
    if (result.sortedGroupCount === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    this.applySubscriptionsState(this.subscriptionStateFromProfile(await SubscriptionStore.saveGroups(context, result.groups)));
    const message = this.f1('log.nodesSortedByTestResult', 'count', result.sortedGroupCount.toString());
    SHARED_RUNTIME_CONTROLLER.appendLog(message);
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (err) {
      // ignore
    }
  }

  private confirmClearNodes(): void {
    if (this.visibleNodes().length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.noNodesToDelete') });
      } catch (err) {
        // ignore
      }
      return;
    }
    try {
      this.getUIContext().showAlertDialog({
      title: this.t('menu.deleteConfig'),
      message: this.t('node.deleteAllConfirm'),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      offset: { dx: 0, dy: -20 },
      primaryButton: {
        value: this.t('action.delete'),
        fontColor: AppColor.onBrand,
        backgroundColor: AppColor.danger,
        action: () => {
          this.clearActiveGroupNodes();
        }
      },
      secondaryButton: {
        value: this.t('action.cancel'),
        fontColor: AppColor.textSecondary,
        backgroundColor: AppColor.bg,
        action: () => {}
      }
    });
    } catch (err) {
      // ignore
    }
  }

  private async clearActiveGroupNodes(): Promise<void> {
    const targets = this.visibleNodes();
    const result = removeVisibleNodesFromGroups(this.subscriptionGroups, targets, Date.now());
    const context = this.getUIContext().getHostContext() as common.Context;
    this.applySubscriptionsState(this.subscriptionStateFromProfile(await SubscriptionStore.saveGroups(context, result.groups)));
    const message = this.f1('log.nodesCleared', 'count', result.removedCount.toString());
    SHARED_RUNTIME_CONTROLLER.appendLog(message);
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (err) {
      // ignore
    }
  }

  private async testVisibleNodeDelay(mode: NodeDelayTestMode = 'real'): Promise<void> {
    if (this.delayTesting) {
      // 已有一轮测速在跑：给出提示，避免点击"完全没反应"被误判为功能坏掉（BUG-002）。
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('home.delayTesting') });
      } catch (err) {
        // ignore
      }
      return;
    }
    const targets = this.visibleNodes();
    if (targets.length === 0) {
      return;
    }

    this.delayTesting = true;
    SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.delayQueued'));
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const concurrency = normalizeRealPingConcurrency(this.currentSettings.realPingConcurrency);
      if (mode === 'real') {
        // 真实延迟走原生批量：一次 cgo 调用、Go 内并发测全部，避免逐节点串行（BUG-001）。
        await this.runRealDelayBatch(context, targets, concurrency);
      } else {
        // TCP 延迟是纯 ArkTS socket，本就轻量，沿用逐批并发。
        await this.runTcpDelayLoop(context, targets, concurrency);
      }
      await this.applyPostTestActions(context, targets);
    } catch (error) {
      this.lastError = this.f1('error.delayTest', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    } finally {
      this.delayTesting = false;
    }
  }

  // 真实延迟流式测速：N 个并发"槽"各占一个固定 socks 端口（base+槽号），槽内顺序
  // 领取节点测速。每个节点一测完就立刻刷新它那一行（内存态，逐个更新），落库则按
  // 阈值后台批量进行（避免逐节点反复读写 preferences）。相比旧实现共享端口/配置文件
  // 被迫串行，这里真正并发且渐进反馈（BUG-001）。
  private async runRealDelayBatch(context: common.Context, targets: Array<ProxyNode>, concurrency: number): Promise<void> {
    const startedAt = Date.now();
    for (let index = 0; index < targets.length; index++) {
      this.markNodeDelay(targets[index].id, -1, 'testing', startedAt);
    }
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.delayTestingNode', 'name', `×${targets.length}`));

    const url = resolveDelayTestUrl(this.currentSettings.delayTestUrl);
    const datDir = context.filesDir;
    // 每个并发 ping 会起一个临时 Xray 实例（比 TCP socket 重得多），把并发上限收紧到
    // 32 防 OOM。槽 w 固定用端口 base+w：槽内顺序处理，故并发的 ping 不会撞端口。
    const slots = Math.min(Math.max(concurrency, 1), 32);

    let nextIndex = 0;
    const pending = new Array<NodeDelayUpdate>();
    let flushing = false;
    const flush = async (): Promise<void> => {
      if (flushing || pending.length === 0) {
        return;
      }
      flushing = true;
      const toSave = pending.splice(0, pending.length);
      try {
        await SubscriptionStore.saveNodeDelays(context, toSave);
      } catch (error) {
        // 持久化失败不影响已显示的内存态；下一轮 flush 或结束时再试。
      }
      flushing = false;
    };

    const runSlot = async (slotPort: number): Promise<void> => {
      while (true) {
        const index = nextIndex;
        nextIndex = nextIndex + 1;
        if (index >= targets.length) {
          return;
        }
        const node = targets[index];
        const result = await DelayTester.measureNodeOutbound(node.outboundJson, datDir, url, 8000, node.configType, slotPort);
        // 逐个更新：该节点一测完立即刷新它那一行（内存态，含"全部"视图）。
        this.markNodeDelay(node.id, result.ok ? result.delayMs : -1, result.ok ? 'ok' : result.status, Date.now());
        pending.push({
          nodeId: node.id,
          delayMs: result.ok ? result.delayMs : -1,
          delayStatus: result.ok ? 'ok' : result.status,
          delayTestAt: Date.now()
        });
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f2('log.delayResult', 'name', node.name, 'result', this.delayResultText(result)));
        if (pending.length >= 24) {
          await flush();
        }
      }
    };

    const workers = new Array<Promise<void>>();
    for (let w = 0; w < slots; w++) {
      workers.push(runSlot(DELAY_TEST_BATCH_PORT_BASE + w));
    }
    await Promise.all(workers);
    // 收尾：把剩余未落库的结果一次性写入。
    flushing = false;
    if (pending.length > 0) {
      await SubscriptionStore.saveNodeDelays(context, pending.splice(0, pending.length));
    }
  }

  // TCP 延迟逐批并发（纯 ArkTS socket）。保留原有逐节点路径。
  private async runTcpDelayLoop(context: common.Context, targets: Array<ProxyNode>, concurrency: number): Promise<void> {
    for (let start = 0; start < targets.length; start += concurrency) {
      const batch = targets.slice(start, Math.min(targets.length, start + concurrency));
      for (let index = 0; index < batch.length; index++) {
        const node = batch[index];
        const startedAt = Date.now();
        this.markNodeDelay(node.id, -1, 'testing', startedAt);
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.delayTestingNode', 'name', node.name));
      }

      const results = await this.measureNodeDelayBatch(batch, context, 'tcp');
      for (let index = 0; index < results.length; index++) {
        const item = results[index];
        const result = item.result;
        const delayMs = result.ok ? result.delayMs : -1;
        const status = result.ok ? 'ok' : result.status;
        const subscription = await SubscriptionStore.saveNodeDelay(context, item.node.id, delayMs, status, item.testedAt);
        this.applySubscriptionsState({
          subscriptionUrl: subscription.url,
          nodes: subscription.nodes,
          selectedNodeId: subscription.selectedNodeId,
          subscriptionMessage: this.subscriptionMessage,
          subscriptionUpdatedAt: subscription.updatedAt,
          subscriptionGroups: subscription.groups,
          selectedGroupId: subscription.selectedGroupId
        });
        SHARED_RUNTIME_CONTROLLER.appendLog(this.f2('log.delayResult', 'name', item.node.name, 'result', this.delayResultText(result)));
      }
    }
  }

  // After a batch delay test, optionally drop timed-out nodes and/or reorder by
  // latency, controlled by the auto-test settings. Persists the active group.
  private async applyPostTestActions(context: common.Context, testedNodes: Array<ProxyNode>): Promise<void> {
    const autoRemove = this.currentSettings.autoRemoveInvalidAfterTest;
    const autoSort = this.currentSettings.autoSortAfterTest;
    if (!autoRemove && !autoSort) {
      return;
    }
    const sortTargets = this.allGroupsSelected ? this.displayedNodes() : this.nodes;
    const result = applyDelayTestPostActionsToGroups(this.subscriptionGroups, testedNodes, sortTargets, autoRemove, autoSort, Date.now());
    const subscription = await SubscriptionStore.saveGroups(context, result.groups);
    this.applySubscriptionsState(this.subscriptionStateFromProfile(subscription));
  }

  private async measureNodeTcpDelay(node: ProxyNode, timeoutMs: number): Promise<DelayTestResult> {
    const endpoint = extractNodeEndpoint(node.outboundJson);
    return DelayTester.measureTcp(endpoint.address, Number(endpoint.port), timeoutMs);
  }

  private async measureNodeRealDelay(node: ProxyNode, context: common.Context, timeoutMs: number): Promise<DelayTestResult> {
    const url = resolveDelayTestUrl(this.currentSettings.delayTestUrl);
    return DelayTester.measureNodeOutbound(node.outboundJson, context.filesDir, url, timeoutMs, node.configType);
  }

  private async measureNodeDelayBatch(batch: Array<ProxyNode>, context: common.Context, mode: NodeDelayTestMode): Promise<Array<NodeDelayBatchResult>> {
    const tasks = new Array<Promise<NodeDelayBatchResult>>();
    for (let index = 0; index < batch.length; index++) {
      tasks.push(this.measureNodeDelayForBatch(batch[index], context, mode));
    }
    return Promise.all(tasks);
  }

  private async measureNodeDelayForBatch(node: ProxyNode, context: common.Context, mode: NodeDelayTestMode): Promise<NodeDelayBatchResult> {
    try {
      return {
        node,
        result: mode === 'real'
          ? await this.measureNodeRealDelay(node, context, 8000)
          : await this.measureNodeTcpDelay(node, 8000),
        testedAt: Date.now()
      };
    } catch (_error) {
      return {
        node,
        result: {
          ok: false,
          delayMs: -1,
          status: 'test-failed'
        },
        testedAt: Date.now()
      };
    }
  }

  private markNodeDelay(nodeId: string, delayMs: number, delayStatus: string, delayTestAt: number): void {
    this.nodes = this.patchNodeDelay(this.nodes, nodeId, delayMs, delayStatus, delayTestAt);
    // "全部"视图的列表来自 subscriptionGroups，故同步更新对应分组里的节点，
    // 否则批量测速期间该视图看不到"测速中"态（BUG-004）。
    const nextGroups = new Array<SubscriptionGroup>();
    let changed = false;
    for (let index = 0; index < this.subscriptionGroups.length; index++) {
      const group = this.subscriptionGroups[index];
      const patchedNodes = this.patchNodeDelay(group.nodes, nodeId, delayMs, delayStatus, delayTestAt);
      if (patchedNodes !== group.nodes) {
        changed = true;
        nextGroups.push({
          id: group.id,
          name: group.name,
          url: group.url,
          enabled: group.enabled,
          selectedNodeId: group.selectedNodeId,
          nodes: patchedNodes,
          updatedAt: group.updatedAt,
          userAgent: group.userAgent,
          filter: group.filter,
          prevProfile: group.prevProfile,
          nextProfile: group.nextProfile,
          allowInsecureUrl: group.allowInsecureUrl,
          autoUpdate: group.autoUpdate,
          updateIntervalMinutes: group.updateIntervalMinutes
        });
      } else {
        nextGroups.push(group);
      }
    }
    if (changed) {
      this.subscriptionGroups = nextGroups;
    }
  }

  private patchNodeDelay(nodes: Array<ProxyNode>, nodeId: string, delayMs: number, delayStatus: string, delayTestAt: number): Array<ProxyNode> {
    let found = false;
    const next = new Array<ProxyNode>();
    for (let index = 0; index < nodes.length; index++) {
      const node = nodes[index];
      if (node.id === nodeId) {
        found = true;
        next.push({
          id: node.id,
          name: node.name,
          protocol: node.protocol,
          outboundJson: node.outboundJson,
          configType: node.configType,
          sourceUrl: node.sourceUrl,
          rawLink: node.rawLink,
          updatedAt: node.updatedAt,
          delayMs,
          delayTestAt,
          delayStatus
        });
      } else {
        next.push(node);
      }
    }
    return found ? next : nodes;
  }

  private async refreshRuntime(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      let state = await SHARED_RUNTIME_CONTROLLER.refresh(context, this.language);
      if (state.status === ConnectionStatus.RUNNING && this.outboundJson.trim().length > 0) {
        const profile: ProxyProfile = {
          outboundJson: this.outboundJson,
          updatedAt: this.profileUpdatedAtValue,
          configType: this.configType
        };
        state = SHARED_RUNTIME_CONTROLLER.attachRecoveredSession(
          context, profile, this.currentSettings, this.language);
      }
      this.applyRuntimeState(state);
      this.scheduleHomeAutoDelayTest();
    } catch (error) {
      this.lastError = redactDiagnosticText(JSON.stringify(error));
    }
  }

  // 首页「当前连接」按设置间隔自动复测。间隔 0=关闭；连接时控制器已自动测一次，故新会话
  // 以「连接那一刻」为计时起点，之后每隔 N 分钟触发一次（复用手动测速入口，含防重入）。
  // 由每秒的 refreshRuntime 驱动，无需独立定时器。
  private scheduleHomeAutoDelayTest(): void {
    const intervalMinutes = normalizeHomeDelayTestInterval(this.currentSettings.homeDelayTestInterval);
    if (!this.isRunning() || intervalMinutes <= 0) {
      this.autoDelayTestSessionAt = 0;
      return;
    }
    if (this.autoDelayTestSessionAt !== this.connectionStartedAt) {
      // 新连接会话：连接时的自动测速刚发生，从现在起算下一次间隔。
      this.autoDelayTestSessionAt = this.connectionStartedAt;
      this.lastAutoDelayTestAt = Date.now();
      return;
    }
    if (this.connectionDelayTesting) {
      return;
    }
    if (Date.now() - this.lastAutoDelayTestAt < intervalMinutes * 60 * 1000) {
      return;
    }
    this.lastAutoDelayTestAt = Date.now();
    this.testCurrentConnectionDelay();
  }

  private applyNodesState(state: NodesControllerState): void {
    this.outboundJson = state.outboundJson;
    this.configType = state.configType;
    this.validationOk = state.validationOk;
    this.validationMessage = state.validationMessage;
    this.profileUpdatedAt = state.profileUpdatedAt;
    this.profileUpdatedAtValue = state.profileUpdatedAtValue;
    this.subscriptionUrl = state.subscriptionUrl;
    this.nodes = state.nodes;
    this.selectedNodeId = state.selectedNodeId;
    this.subscriptionMessage = state.subscriptionMessage;
    this.subscriptionUpdatedAt = state.subscriptionUpdatedAt;
    this.subscriptionGroups = state.subscriptionGroups;
    this.selectedGroupId = state.selectedGroupId;
    this.reconcileAllGroupsSelection();
    this.lastError = state.lastError;
  }

  private applySaveProfileResult(result: SaveProfileResult): void {
    this.outboundJson = result.outboundJson;
    this.configType = result.configType;
    this.validationOk = result.validationOk;
    this.validationMessage = result.validationMessage;
    if (result.profile !== null) {
      this.profileUpdatedAt = result.profileUpdatedAt;
      this.profileUpdatedAtValue = result.profileUpdatedAtValue;
    }
    this.lastError = result.lastError;
  }

  private applySubscriptionsState(state: SubscriptionsControllerState): void {
    this.subscriptionUrl = state.subscriptionUrl;
    this.nodes = state.nodes;
    this.selectedNodeId = state.selectedNodeId;
    this.subscriptionMessage = state.subscriptionMessage;
    this.subscriptionUpdatedAt = state.subscriptionUpdatedAt;
    this.subscriptionGroups = state.subscriptionGroups;
    this.selectedGroupId = state.selectedGroupId;
    this.reconcileAllGroupsSelection();
  }

  private subscriptionStateFromProfile(subscription: SubscriptionProfile): SubscriptionsControllerState {
    return {
      subscriptionUrl: subscription.url,
      nodes: subscription.nodes,
      selectedNodeId: subscription.selectedNodeId,
      subscriptionMessage: this.subscriptionMessage,
      subscriptionUpdatedAt: subscription.updatedAt,
      subscriptionGroups: subscription.groups,
      selectedGroupId: subscription.selectedGroupId
    };
  }

  private applyRuntimeState(state: RuntimeViewState): void {
    this.status = state.status;
    this.runtimeMode = state.runtimeMode;
    this.elapsedText = state.elapsedText;
    this.connectionStartedAt = state.startedAt;
    this.connectionDelayMs = state.connectionDelayMs;
    this.connectionDelayTesting = state.connectionDelayTesting;
    this.connectionDelayFailed = state.connectionDelayFailed;
    this.egressIp = state.egressIp;
    this.egressIpChecking = state.egressIpChecking;
    this.stats = state.stats;
    this.updateRealtimeSpeed();
    this.accumulateTraffic();
    this.lastError = state.lastError;
    this.syncSpeedNotification();
    this.syncControlCard();
  }

  // 用累计字节差算实时速度（每秒）。VPN 扩展每 2s 才写一次统计，UI 每秒刷新，所以按
  // 两次「累计值真正发生变化」的样本之间的真实时间差计算，避免出现 0/峰值 来回跳。
  private updateRealtimeSpeed(): void {
    if (this.status !== ConnectionStatus.RUNNING) {
      this.uploadSpeed = 0;
      this.downloadSpeed = 0;
      this.lastSpeedSample = null;
      return;
    }
    const now = Date.now();
    const sample = sampleSpeedNotificationStats(this.stats, now);
    if (this.lastSpeedSample === null) {
      this.lastSpeedSample = sample;
      return;
    }
    const changed = sample.uploadBytes !== this.lastSpeedSample.uploadBytes
      || sample.downloadBytes !== this.lastSpeedSample.downloadBytes;
    if (changed) {
      const rates = calculateSpeedNotificationRates(this.lastSpeedSample, sample);
      this.uploadSpeed = rates.uploadBytesPerSecond;
      this.downloadSpeed = rates.downloadBytesPerSecond;
      this.lastSpeedSample = sample;
      return;
    }
    // 累计值未变：在一个统计周期内保持上次速率（平滑掉 2s 采样间隔的空档），超过即判
    // 空闲、速度归零，避免流量停止后数字卡死在最后的峰值。
    const IDLE_RESET_MS: number = 3000;
    if (now - this.lastSpeedSample.at >= IDLE_RESET_MS) {
      this.uploadSpeed = 0;
      this.downloadSpeed = 0;
    }
  }

  // 把本会话的新增字节累加进持久化的历史总量。会话计数（this.stats.*）每次重连从 0 起，
  // 所以用「当前会话计数 - 上次会话计数」算增量；若当前值比上次小，说明换了新会话（重连/
  // 重启核），增量即为当前值本身。
  private accumulateTraffic(): void {
    if (!this.trafficTotalsLoaded) {
      return;
    }
    const sessionUpload = Math.max(0, Math.floor(this.stats.uploadBytes));
    const sessionDownload = Math.max(0, Math.floor(this.stats.downloadBytes));
    const deltaUpload = sessionUpload >= this.lastSessionUpload
      ? sessionUpload - this.lastSessionUpload : sessionUpload;
    const deltaDownload = sessionDownload >= this.lastSessionDownload
      ? sessionDownload - this.lastSessionDownload : sessionDownload;
    this.lastSessionUpload = sessionUpload;
    this.lastSessionDownload = sessionDownload;
    if (deltaUpload <= 0 && deltaDownload <= 0) {
      return;
    }
    this.totalUpload += deltaUpload;
    this.totalDownload += deltaDownload;
    this.persistTrafficTotals(false);
  }

  // 持久化累计。每秒写盘太频繁，平时节流（每 10s 一次）；force=true 用于退到后台/离开页面
  // 时立刻落盘。硬杀进程最多丢 10s 增量，对流量计数可接受。
  private persistTrafficTotals(force: boolean): void {
    if (!this.trafficTotalsLoaded) {
      return;
    }
    const now = Date.now();
    if (!force && now - this.lastTrafficPersistAt < 10000) {
      return;
    }
    this.lastTrafficPersistAt = now;
    const totals: TrafficTotals = {
      lifetimeUpload: this.totalUpload,
      lifetimeDownload: this.totalDownload,
      lastSessionUpload: this.lastSessionUpload,
      lastSessionDownload: this.lastSessionDownload
    };
    const context = this.getUIContext().getHostContext() as common.Context;
    TrafficTotalsStore.save(context, totals).catch((error: Error) => {
      SHARED_RUNTIME_CONTROLLER.appendLog(redactDiagnosticText(JSON.stringify(error)));
    });
  }

  private syncSpeedNotification(): void {
    const context = this.getUIContext().getHostContext() as common.Context;
    SPEED_NOTIFICATION_MANAGER.sync(context, this.status, this.speedEnabled, this.stats, this.elapsedText, this.language)
      .catch((error: Error) => {
        SHARED_RUNTIME_CONTROLLER.appendLog(redactDiagnosticText(JSON.stringify(error)));
      });
  }

  private syncControlCard(): void {
    const context = this.getUIContext().getHostContext() as common.Context;
    CONTROL_CARD_MANAGER.sync(
      context,
      this.status,
      this.elapsedText,
      this.language,
      this.lastError,
      SHARED_RUNTIME_CONTROLLER.isVpnRunning(),
      this.runtimeMode
    )
      .catch((error: Error) => {
        SHARED_RUNTIME_CONTROLLER.appendLog(redactDiagnosticText(JSON.stringify(error)));
      });
  }

  private visibleNodes(): Array<ProxyNode> {
    return filterNodes(this.displayedNodes(), this.searchQuery);
  }

  private displayedNodes(): Array<ProxyNode> {
    if (!this.allGroupsSelected) {
      return this.nodes;
    }
    const result = new Array<ProxyNode>();
    for (let groupIndex = 0; groupIndex < this.subscriptionGroups.length; groupIndex++) {
      const group = this.subscriptionGroups[groupIndex];
      for (let nodeIndex = 0; nodeIndex < group.nodes.length; nodeIndex++) {
        result.push(group.nodes[nodeIndex]);
      }
    }
    return result;
  }

  private displaySubscriptionGroups(): Array<SubscriptionGroup> {
    if (!this.groupAllDisplay || this.subscriptionGroups.length === 0) {
      return this.subscriptionGroups;
    }
    const groups = new Array<SubscriptionGroup>();
    groups.push({
      id: ALL_GROUP_ID,
      name: this.t('nodes.groupAll'),
      url: '',
      enabled: true,
      selectedNodeId: '',
      nodes: [],
      updatedAt: 0
    });
    for (let index = 0; index < this.subscriptionGroups.length; index++) {
      groups.push(this.subscriptionGroups[index]);
    }
    return groups;
  }

  private isGroupTabSelected(group: SubscriptionGroup): boolean {
    if (group.id === ALL_GROUP_ID) {
      return this.allGroupsSelected;
    }
    return !this.allGroupsSelected && group.id === this.selectedGroupId;
  }

  private reconcileAllGroupsSelection(): void {
    if (!this.groupAllDisplay || this.subscriptionGroups.length === 0) {
      this.allGroupsSelected = false;
    }
  }

  private canMoveNode(node: ProxyNode, delta: number): boolean {
    if (this.allGroupsSelected || this.searchQuery.trim().length > 0) {
      return false;
    }
    const index = this.activeNodeIndex(node.id);
    const target = index + delta;
    return index >= 0 && target >= 0 && target < this.nodes.length;
  }

  private activeNodeIndex(nodeId: string): number {
    for (let index = 0; index < this.nodes.length; index++) {
      if (this.nodes[index].id === nodeId) {
        return index;
      }
    }
    return -1;
  }

  private nodeEndpointText(node: ProxyNode): string {
    const description = buildNodeDescription(node);
    if (description.length > 0) {
      return description;
    }
    return node.sourceUrl.length > 0 ? this.t('node.source.subscription') : this.t('node.source.manual');
  }

  private openRoute(route: AppRoute): void {
    if (route === AppRoute.SCANNER) {
      this.openScannerImmediately();
      return;
    }
    this.getUIContext().getRouter().pushUrl({ url: route }).catch((err: Error) => {});
  }

  private openScannerImmediately(): void {
    this.getUIContext().getRouter().pushUrl({
      url: AppRoute.SCANNER,
      params: {
        startImmediately: true
      }
    }).catch((err: Error) => {});
  }

  private openNodeDetail(node: ProxyNode): void {
    this.getUIContext().getRouter().pushUrl({
      url: AppRoute.NODE_DETAIL,
      params: {
        nodeId: node.id
      }
    }).catch((err: Error) => {});
  }

  private nodeDelayText(node: ProxyNode): string {
    if (node.delayStatus === 'testing') {
      return this.t('node.delay.testing');
    }
    if (node.delayMs >= 0) {
      return this.f1('node.delay.ms', 'value', node.delayMs.toString());
    }
    if (node.delayStatus === DELAY_STATUS_UDP_ONLY) {
      return this.t('node.delay.udpOnly');
    }
    if (node.delayStatus.length > 0) {
      return this.t('node.delay.failed');
    }
    return this.t('node.delay.pending');
  }

  private nodeDelayColor(node: ProxyNode): ResourceColor {
    if (node.delayStatus === 'testing') {
      return AppColor.textSecondary;
    }
    if (node.delayMs >= 0) {
      if (node.delayMs <= 300) {
        return AppColor.success;
      }
      if (node.delayMs <= 900) {
        return AppColor.warning;
      }
    }
    if (node.delayStatus === DELAY_STATUS_UDP_ONLY) {
      return AppColor.textSecondary;
    }
    if (node.delayStatus.length > 0) {
      return AppColor.danger;
    }
    return AppColor.textTertiary;
  }

  private delayResultText(result: DelayTestResult): string {
    if (result.ok) {
      return this.f1('node.delay.ms', 'value', result.delayMs.toString());
    }
    if (result.status === DELAY_STATUS_UDP_ONLY) {
      return this.t('node.delay.udpOnly');
    }
    return `${this.t('node.delay.failed')} ${result.status}`;
  }

  private statusLabel(): string {
    if (this.status === ConnectionStatus.RUNNING) {
      const proxyOnly = isProxyOnlyRuntimeMode(this.runtimeMode);
      if (this.egressIpChecking) {
        return this.t(proxyOnly ?
          'home.proxyConnectionVerifying' : 'home.connectionVerifying');
      }
      if (this.egressIp.length === 0) {
        return this.t(proxyOnly ?
          'home.proxyConnectionUnverified' : 'home.connectionUnverified');
      }
      return this.t(proxyOnly ?
        'home.proxyConnected' : 'home.tunConnected');
    }
    return this.t('status.' + this.status);
  }

  private connectionSubtitle(): string {
    if (this.isRunning()) {
      return this.elapsedText;
    }
    const mode = this.t(isProxyOnlyRuntimeMode(this.currentSettings.mode) ?
      'settings.mode.proxyOnly' : 'settings.mode.vpn');
    return `${this.t('home.ready')} · ${mode}`;
  }

  private t(key: string): string {
    return translate(this.language, key);
  }

  private f1(key: string, name: string, value: string): string {
    return formatOne(this.language, key, name, value);
  }

  private f2(key: string, name1: string, value1: string, name2: string, value2: string): string {
    return formatTwo(this.language, key, name1, value1, name2, value2);
  }

  private isRunning(): boolean {
    return this.status === ConnectionStatus.RUNNING;
  }

  private isBusy(): boolean {
    return this.connectionOperationRunning || this.status === ConnectionStatus.STARTING || this.status === ConnectionStatus.STOPPING;
  }

  private subscriptionProxyPort(): number {
    return SubscriptionManager.resolveSubscriptionProxyPort(
      this.runtimeMode,
      this.status !== ConnectionStatus.IDLE
    );
  }

  private async reconnectService(): Promise<void> {
    if (this.isBusy()) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('home.busy') });
      } catch (err) {
        // ignore
      }
      return;
    }

    this.connectionOperationRunning = true;
    try {
      if (this.isRunning()) {
        SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.restartingService'));
        const stopped = await this.stopConnectionInternal();
        if (stopped) {
          await this.startConnectionInternal();
        }
      } else {
        await this.startConnectionInternal();
      }
    } finally {
      this.connectionOperationRunning = false;
    }
  }

  private async exportAllNodesToClipboard(): Promise<void> {
    const targets = this.visibleNodes();
    if (targets.length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('export.empty') });
      } catch (err) {
        // ignore
      }
      return;
    }
    const text = exportNodesText(targets);
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteData);
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.copiedToClipboard') });
      } catch (err) {
        // ignore
      }
      SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.exportCopied', 'count', targets.length.toString()));
    } catch (error) {
      const message = this.f1('export.copyFailed', 'error', redactDiagnosticText(JSON.stringify(error)));
      try {
        this.getUIContext().getPromptAction().showToast({ message: message });
      } catch (err) {
        // ignore
      }
      SHARED_RUNTIME_CONTROLLER.appendLog(message);
    }
  }

  private async locateSelectedConfig(): Promise<void> {
    if (this.selectedNodeId.length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.noNodeToLocate') });
      } catch (err) {
        // ignore
      }
      return;
    }
    const location = findSelectedNodeLocation(this.subscriptionGroups, this.selectedNodeId, this.searchQuery);
    if (!location.found || location.node === null) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.noNodeToLocate') });
      } catch (err) {
        // ignore
      }
      return;
    }
    const targetGroup = this.findSubscriptionGroup(location.groupId);
    if (targetGroup === null) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.noNodeToLocate') });
      } catch (err) {
        // ignore
      }
      return;
    }
    if (this.allGroupsSelected || this.selectedGroupId !== location.groupId) {
      await this.selectSubscriptionGroup(targetGroup);
    }
    if (location.visibleIndex < 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.selectedNodeNotVisible') });
      } catch (err) {
        // ignore
      }
      return;
    }
    setTimeout(() => {
      this.nodeListScroller.scrollToIndex(location.visibleIndex, true, ScrollAlign.CENTER);
    }, 200);
    const msg = this.f1('prompt.locatedNode', 'name', location.node.name);
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (err) {
      // ignore
    }
    SHARED_RUNTIME_CONTROLLER.appendLog(msg);
  }

  private findSelectedNodeName(): string {
    // 当前节点是全局值，可能不在当前浏览的活动组里 —— 跨所有组查找它的名称。
    const location = findSelectedNodeLocation(this.subscriptionGroups, this.selectedNodeId);
    if (location.found && location.node !== null) {
      return location.node.name;
    }
    return this.t('home.noNodeSelected');
  }

  private findSubscriptionGroup(groupId: string): SubscriptionGroup | null {
    for (let index = 0; index < this.subscriptionGroups.length; index++) {
      if (this.subscriptionGroups[index].id === groupId) {
        return this.subscriptionGroups[index];
      }
    }
    return null;
  }
}

class SettingsRowModel {
  icon: Resource;
  titleKey: string;
  route: AppRoute;

  constructor(icon: Resource, titleKey: string, route: AppRoute) {
    this.icon = icon;
    this.titleKey = titleKey;
    this.route = route;
  }
}
