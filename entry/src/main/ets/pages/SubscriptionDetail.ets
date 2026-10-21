import { common } from '@kit.AbilityKit';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { AppLanguage, ProxyNode, SubscriptionGroup } from '../core/Profile';
import { NODES_CONTROLLER, NodesControllerState } from '../features/nodes/NodesController';
import { SubscriptionNodeListRow } from '../features/subscriptions/SubscriptionRows';
import { SUBSCRIPTIONS_CONTROLLER, SubscriptionsControllerState } from '../features/subscriptions/SubscriptionsController';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';
import { PageHeader } from '../shell/PageHeader';
import { formatOne } from '../utils/LocalizationPresenter';
import { ensureReadPasteboardPermission } from '../utils/ClipboardPermission';
import { isScanCancelled, requestCameraPermission, scanQrCode } from '../utils/QrScan';
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { scanCore } from '@kit.ScanKit';
import { SubscriptionManager } from '../services/SubscriptionManager';

interface SubscriptionNodeRowModel {
  node: ProxyNode;
  isSelected: boolean;
  delayText: string;
}

@Entry
@Component
struct SubscriptionDetailPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private groupId: string = '';
  @State private groupName: string = translate(DEFAULT_LANGUAGE, 'subscription.detail.title');
  @State private subscriptionUrl: string = '';
  @State private nodes: Array<ProxyNode> = [];
  @State private selectedNodeId: string = '';
  @State private subscriptionMessage: string = '';
  @State private isUpdating: boolean = false;
  @State private isBusy: boolean = false;

  // 状态卡片展示控制
  @State private showCard: boolean = false;
  @State private cardType: 'success' | 'error' | 'info' = 'info';
  private timerId: number = -1;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.groupId = (params?.groupId as string) ?? '';
    this.loadState();
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
    }
  }

  // 紧凑分组标题，对齐 UI 稿（左右 18 / 底 8，加粗三级文字）
  @Builder
  private GroupLabel(title: string) {
    Text(title)
      .fontSize(FontSz.footnote)
      .fontWeight(FontWeight.Bold)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ left: 2, right: 2, bottom: Space.sm })
  }

  @Builder
  private ToolbarIcon(icon: Resource, action: () => void) {
    Button() {
      Image(icon)
        .width(18)
        .height(18)
        .fillColor(AppColor.textTertiary)
    }
    .type(ButtonType.Normal)
    .backgroundColor(Color.Transparent)
    .width(34)
    .height(34)
    .borderRadius(Radius.sm)
    .onClick(() => {
      action();
    })
  }

  build() {
    Column() {
      PageHeader({
        title: this.groupName,
        summary: this.f1('subscription.detail.summary', 'count', this.nodes.length.toString()),
        showBack: true
      })

      Column() {
        Scroll() {
          Column() {
          // 订阅链接工具栏：链接图标 + 输入 + 粘贴/扫码/分享
          this.GroupLabel(this.t('subscription.detail.link'))
          Row() {
            Image($r('app.media.ic_link'))
              .width(18)
              .height(18)
              .fillColor(AppColor.textTertiary)
              .margin({ left: 14, right: Space.sm })

            TextInput({
              placeholder: this.t('placeholder.subscriptionUrl'),
              text: this.subscriptionUrl
            })
              .layoutWeight(1)
              .height(48)
              .fontSize(FontSz.body)
              .fontColor(AppColor.textPrimary)
              .placeholderColor(AppColor.textTertiary)
              .backgroundColor(Color.Transparent)
              .onChange((value: string) => {
                this.onSubscriptionUrlChanged(value);
              })

            Row() {
              this.ToolbarIcon($r('app.media.ic_article'), () => {
                this.pasteFromClipboard();
              })
              this.ToolbarIcon($r('app.media.ic_qr_code'), () => {
                this.scanSubscriptionUrl();
              })
              if (this.subscriptionUrl.trim().length > 0) {
                this.ToolbarIcon($r('app.media.ic_copy'), () => {
                  this.copySubscriptionLink();
                })
              }
            }
            .margin({ right: Space.xs })
          }
          .width('100%')
          .height(50)
          .alignItems(VerticalAlign.Center)
          .backgroundColor(AppColor.surface)
          .borderRadius(Radius.lg)
          .border({ width: 0.5, color: AppColor.border })
          .margin({ bottom: Space.md })

          // 获取并更新按钮
          Button() {
            Row({ space: Space.sm }) {
              if (this.isUpdating) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(AppColor.onBrand)
              }
              Text(this.isUpdating ? this.t('subscription.detail.updating') : this.t('subscription.detail.update'))
                .fontSize(FontSz.callout)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isButtonEnabled() ? AppColor.onBrand : AppColor.textTertiary)
            }
          }
          .width('100%')
          .height(46)
          .borderRadius(Radius.pill)
          .enabled(this.isButtonEnabled())
          .backgroundColor(this.isButtonEnabled() ? AppColor.brand : AppColor.surfaceAlt)
          .shadow(this.isButtonEnabled() ? { radius: 12, color: AppColor.shadowBrand, offsetX: 0, offsetY: 6 } : undefined)
          .margin({ bottom: Space.md })
          .onClick(() => {
            this.updateSubscription();
          })

          // 成功/失败状态反馈卡片（内联，无边框，自动消失）
          if (this.showCard) {
            Row({ space: Space.sm }) {
              Image(this.cardType === 'success' ? $r('app.media.ic_check') : $r('app.media.ic_info'))
                .width(18)
                .height(18)
                .fillColor(this.cardType === 'success' ? AppColor.success : this.cardType === 'error' ? AppColor.danger : AppColor.brand)

              Text(this.subscriptionMessage)
                .fontSize(FontSz.body)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.cardType === 'success' ? AppColor.success : this.cardType === 'error' ? AppColor.danger : AppColor.brand)
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: Space.md, bottom: Space.md })
            .borderRadius(Radius.md)
            .backgroundColor(this.cardType === 'success' ? AppColor.successTint : this.cardType === 'error' ? AppColor.dangerTint : AppColor.brandTint)
            .margin({ bottom: Space.md })
          }

          // 节点列表组：国旗 + 名称/协议 + 延迟信号点 + 当前项勾选
          this.GroupLabel(this.t('subscription.detail.nodes'))
          if (this.nodes.length > 0) {
            Column() {
              // key 需覆盖行内会变化的展示值（选中态/名称/延迟），否则 ForEach
              // 按稳定 key 复用旧行，更新订阅后列表不刷新
              ForEach(this.subscriptionNodeRows(), (row: SubscriptionNodeRowModel, index: number) => {
                SubscriptionNodeListRow({
                  node: row.node,
                  isSelected: row.isSelected,
                  isBusy: this.isBusy,
                  delayText: row.delayText,
                  showDivider: index < this.nodes.length - 1,
                  onSelect: (node) => {
                    this.selectNode(node);
                  }
                })
              }, (row: SubscriptionNodeRowModel) => `${row.isSelected ? 'on' : 'off'}-${row.node.id}-${row.node.name}-${row.delayText}`)
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
          } else {
            Column() {
              Text(this.t('subscription.detail.emptyNodes'))
                .fontSize(FontSz.body)
                .fontColor(AppColor.textTertiary)
            }
            .width('100%')
            .height(160)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .padding({ left: Space.lg, right: Space.lg, top: 14, bottom: Space.xxl })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .height('100%')
    .width('100%')
    .backgroundColor(AppColor.bg)
  }

  private isButtonEnabled(): boolean {
    return this.subscriptionUrl.trim().length > 0 && !this.isUpdating && !this.isBusy;
  }

  private onSubscriptionUrlChanged(value: string): void {
    this.subscriptionUrl = value;
  }



  private async loadState(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const settings = await SETTINGS_CONTROLLER.load(context);
    this.language = settings.language;
    this.groupName = this.t('subscription.detail.title');
    let state = await SUBSCRIPTIONS_CONTROLLER.load(context, this.language);

    // 寻找对应的分组，激活它以加载节点
    let currentGroup: SubscriptionGroup | null = null;
    for (let i = 0; i < state.subscriptionGroups.length; i++) {
      if (state.subscriptionGroups[i].id === this.groupId) {
        currentGroup = state.subscriptionGroups[i];
        break;
      }
    }

    if (currentGroup !== null) {
      this.groupName = currentGroup.name;
      if (state.selectedGroupId !== this.groupId) {
        state = await SUBSCRIPTIONS_CONTROLLER.selectGroup(context, currentGroup, this.language);
      }
    }

    this.applySubscriptionsState(state);
  }

  private applySubscriptionsState(state: SubscriptionsControllerState): void {
    this.onSubscriptionUrlChanged(state.subscriptionUrl);
    this.nodes = state.nodes;
    this.selectedNodeId = state.selectedNodeId;
    this.subscriptionMessage = state.subscriptionMessage;

    // 更新消息通知卡片状态
    this.onMessageChange();
  }

  private async updateSubscription(): Promise<void> {
    if (this.isUpdating) {
      return;
    }
    this.isUpdating = true;
    this.subscriptionMessage = this.t('log.updatingSubscription');
    this.onMessageChange();

    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const runtime = SHARED_RUNTIME_CONTROLLER.snapshot();
      const proxyPort = SubscriptionManager.resolveSubscriptionProxyPort(
        runtime.runtimeMode,
        SHARED_RUNTIME_CONTROLLER.mayOwnNetwork()
      );
      const state = await SUBSCRIPTIONS_CONTROLLER.update(
        context, this.groupId, this.subscriptionUrl, this.selectedNodeId, this.language, proxyPort);
      this.applySubscriptionsState(state);
      SHARED_RUNTIME_CONTROLLER.appendLog(state.subscriptionMessage);
    } finally {
      this.isUpdating = false;
    }
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    this.selectedNodeId = node.id;
    const context = this.getUIContext().getHostContext() as common.Context;
    const state: NodesControllerState = await NODES_CONTROLLER.selectNode(context, node, this.language);
    this.nodes = state.nodes;
    this.selectedNodeId = state.selectedNodeId;
    SHARED_RUNTIME_CONTROLLER.appendLog(state.lastError.length > 0 ? state.lastError : this.f1('log.selectedNode', 'name', node.name));
  }

  private onMessageChange() {
    if (!this.subscriptionMessage || this.subscriptionMessage.trim().length === 0) {
      this.showCard = false;
      return;
    }

    if (this.subscriptionMessage.includes('正在') || this.subscriptionMessage.includes('Updating') || this.subscriptionMessage.includes('updating')) {
      this.showCard = false;
      return;
    }

    this.showCard = true;
    if (this.subscriptionMessage.includes('失败') || this.subscriptionMessage.includes('Failed') || this.subscriptionMessage.includes('错误') || this.subscriptionMessage.includes('error')) {
      this.cardType = 'error';
    } else if (this.subscriptionMessage.includes('成功') || this.subscriptionMessage.includes('Success') || this.subscriptionMessage.includes('完成') || this.subscriptionMessage.includes('Complete') || this.subscriptionMessage.includes('保存')) {
      this.cardType = 'success';
    } else {
      this.cardType = 'info';
    }

    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
    }
    this.timerId = setTimeout(() => {
      this.showCard = false;
      this.timerId = -1;
    }, 4000);
  }

  private async pasteFromClipboard() {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      if (!await ensureReadPasteboardPermission(context)) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.clipboardReadFailed') });
        } catch (err) {
          // ignore
        }
        return;
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (systemPasteboard.hasDataSync()) {
        const pasteData = await systemPasteboard.getData();
        const text = pasteData.getPrimaryText();
        if (text && text.trim().length > 0) {
          this.subscriptionUrl = text.trim();
          try {
            this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.pastedSubscriptionUrl') });
          } catch (err) {
            // ignore
          }
        } else {
          try {
            this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.clipboardEmpty') });
          } catch (err) {
            // ignore
          }
        }
      } else {
        try {
          this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.clipboardNoData') });
        } catch (err) {
          // ignore
        }
      }
    } catch (error) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('prompt.clipboardReadFailed') });
      } catch (err) {
        // ignore
      }
    }
  }

  // 直接拉起相机扫码，将结果填入订阅链接输入框，扫码后仍停留在当前页面。
  private async scanSubscriptionUrl(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!await requestCameraPermission(context)) {
        this.getUIContext().getPromptAction().showToast({ message: this.t('scanner.cameraPermissionRequired') });
        return;
      }
      const value = await scanQrCode(context);
      if (value.length > 0) {
        this.subscriptionUrl = value;
      }
    } catch (error) {
      if (!isScanCancelled(error)) {
        try {
          this.getUIContext().getPromptAction().showToast({
            message: this.f1('scanner.scanFailed', 'error', redactDiagnosticText(JSON.stringify(error)))
          });
        } catch (err) {
          // ignore
        }
      }
    }
  }

  private copySubscriptionLink(): void {
    const url = this.subscriptionUrl.trim();
    if (url.length === 0) {
      return;
    }
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      systemPasteboard.setDataSync(pasteData);
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('subscription.detail.copied') });
      } catch (err) {
        // ignore
      }
    } catch (error) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('subscription.detail.copied') });
      } catch (err) {
        // ignore
      }
    }
  }



  private subscriptionNodeRows(): Array<SubscriptionNodeRowModel> {
    const rows: Array<SubscriptionNodeRowModel> = [];
    for (let index = 0; index < this.nodes.length; index++) {
      const node = this.nodes[index];
      rows.push({
        node,
        isSelected: node.id === this.selectedNodeId,
        delayText: this.nodeDelayText(node)
      });
    }
    return rows;
  }

  private nodeDelayText(node: ProxyNode): string {
    if (node.delayStatus === 'testing') {
      return this.t('node.delay.testing');
    }
    if (node.delayMs >= 0) {
      return this.f1('node.delay.ms', 'value', node.delayMs.toString());
    }
    if (node.delayStatus.length > 0) {
      return this.t('node.delay.failed');
    }
    return this.t('node.delay.pending');
  }

  private t(key: string): string {
    return translate(this.language, key);
  }

  private f1(key: string, name: string, value: string): string {
    return formatOne(this.language, key, name, value);
  }
}
