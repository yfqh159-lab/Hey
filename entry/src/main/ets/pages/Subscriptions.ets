import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { IconButton } from '../components/IconButton';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { AppLanguage, SubscriptionGroup } from '../core/Profile';
import { SUBSCRIPTIONS_CONTROLLER, SubscriptionsControllerState } from '../features/subscriptions/SubscriptionsController';
import { avatarColor, monogram } from '../features/subscriptions/SubscriptionVisuals';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { AppRoute } from '../shell/AppRoute';
import { PageHeader } from '../shell/PageHeader';
import { formatOne } from '../utils/LocalizationPresenter';
import { router, promptAction } from '@kit.ArkUI';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';
import { SubscriptionManager } from '../services/SubscriptionManager';

@Entry
@Component
struct SubscriptionsPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private subscriptionGroups: Array<SubscriptionGroup> = [];
  @State private selectedGroupId: string = '';
  @State private isUpdatingAll: boolean = false;
  @State private isBusy: boolean = false;
  private confirmRemove: boolean = false;

  aboutToAppear(): void {
    this.loadState();
  }

  onPageShow(): void {
    this.loadState();
  }

  build() {
    Column() {
      PageHeader({
        title: this.t('screen.subscriptions.title'),
        summary: this.subscriptionSummaryText(),
        showBack: true,
        rightActions: () => {
          this.HeaderActions()
        }
      })

      if (this.subscriptionGroups.length === 0) {
        Column({ space: Space.lg }) {
          Image($r('app.media.ic_subscriptions'))
            .width(64)
            .height(64)
            .fillColor(AppColor.textTertiary)
            .opacity(0.4)
          Text(this.t('subscription.list.emptyHint'))
            .fontSize(FontSz.footnote)
            .fontColor(AppColor.textTertiary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: Space.md }) {
          ForEach(this.subscriptionGroups, (group: SubscriptionGroup) => {
            ListItem() {
              this.GroupRow(group)
            }
            .swipeAction({ end: this.GroupSwipeActions(group) })
          }, (group: SubscriptionGroup) => this.groupRowKey(group))
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .padding({ left: Space.lg, right: Space.lg, top: 14, bottom: Space.xxl })
      }
    }
    .height('100%')
    .width('100%')
    .backgroundColor(AppColor.bg)
  }

  @Builder
  private HeaderActions() {
    Row({ space: Space.xs }) {
      if (this.isUpdatingAll) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color(AppColor.brand)
      } else {
        IconButton({
          icon: $r('app.media.ic_refresh'),
          buttonSize: 40,
          iconSize: 24,
          iconColor: AppColor.textSecondary,
          onAction: () => {
            this.updateAllSubscriptions();
          }
        })
      }

      IconButton({
        icon: $r('app.media.ic_add'),
        buttonSize: 40,
        iconSize: 24,
        iconColor: AppColor.brand,
        onAction: () => {
          this.openAddPage();
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private GroupRow(group: SubscriptionGroup) {
    Row({ space: Space.md }) {
      // 圆角字母方块头像 + 右下角云/设备角标
      Stack({ alignContent: Alignment.BottomEnd }) {
        Text(monogram(group.name))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .width(42)
          .height(42)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.isRemoteGroup(group) ? avatarColor(group.name) : '#64748B')
          .opacity(this.isRemoteGroup(group) && !group.enabled ? 0.4 : 1)

        Stack() {
          Image(this.isRemoteGroup(group) ? $r('app.media.ic_cloud_download') : $r('app.media.ic_folder'))
            .width(10)
            .height(10)
            .fillColor(Color.White)
        }
        .width(16)
        .height(16)
        .borderRadius(8)
        .backgroundColor(this.isRemoteGroup(group) ? AppColor.brand : '#64748B')
        .border({ width: 2, color: AppColor.surface })
        .offset({ x: 3, y: 3 })
      }
      .width(42)
      .height(42)

      // 文本（名称 / 来源 / 更新时间 三级信息）
      Column({ space: 3 }) {
        Text(group.name)
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.subtitleOf(group))
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.formatDateTime(group.updatedAt))
          .fontSize(FontSz.caption)
          .fontColor(AppColor.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 右侧：开关（订阅组）/ 箭头（本地）
      if (this.isRemoteGroup(group)) {
        Toggle({ type: ToggleType.Switch, isOn: group.enabled })
          .selectedColor(AppColor.brand)
          .switchPointColor(AppColor.onBrand)
          .onChange(() => {
            this.toggleSubscriptionGroup(group);
          })
      } else {
        Image($r('app.media.ic_chevron_right'))
          .width(20)
          .height(20)
          .fillColor(AppColor.textTertiary)
      }
    }
    .width('100%')
    .padding(14)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
    .onClick(() => {
      this.selectSubscriptionGroup(group);
    })
  }

  private isRemoteGroup(group: SubscriptionGroup): boolean {
    return group.url.trim().length > 0;
  }

  // ForEach 按 key 复用列表项：key 稳定时行内容不会重渲染，
  // 因此把会变化的展示值（更新时间/节点数/开关/名称/链接）编码进 key。
  private groupRowKey(group: SubscriptionGroup): string {
    return `${group.id}_${group.updatedAt}_${group.nodes.length}_${group.enabled ? 1 : 0}_${group.name}_${group.url}`;
  }

  @Builder
  private GroupSwipeActions(group: SubscriptionGroup) {
    Row() {
      if (group.id !== 'sub-local') {
        this.SwipeButton($r('app.media.ic_arrow_downward'), this.t('action.moveUp'), AppColor.textSecondary, () => {
          this.moveSubscriptionGroup(group, -1);
        }, this.canMoveGroup(group.id, -1), true)
        this.SwipeButton($r('app.media.ic_arrow_downward'), this.t('action.moveDown'), AppColor.textSecondary, () => {
          this.moveSubscriptionGroup(group, 1);
        }, this.canMoveGroup(group.id, 1), false)
        if (group.url.trim().length > 0) {
          this.SwipeButton($r('app.media.ic_copy'), this.t('action.copy'), AppColor.brand, () => {
            this.copySubscriptionGroupUrl(group);
          }, true, false)
        }
        this.SwipeButton($r('app.media.ic_edit'), this.t('action.edit'), AppColor.textSecondary, () => {
          this.openEditPage(group);
        }, true, false)
        this.SwipeButton($r('app.media.ic_delete'), this.t('action.delete'), AppColor.danger, () => {
          this.removeSubscriptionGroup(group);
        }, true, false)
      }
    }
    .height('100%')
  }

  @Builder
  private SwipeButton(icon: Resource, label: string, bg: ResourceColor, action: () => void, enabled: boolean, rotateUp: boolean) {
    Column({ space: 3 }) {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(Color.White)
        .rotate({ angle: rotateUp ? 180 : 0 })
      Text(label)
        .fontSize(FontSz.caption)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(bg)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.35)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      action();
    })
  }

  private subtitleOf(group: SubscriptionGroup): string {
    if (group.url.trim().length > 0) {
      return group.url;
    }
    if (group.id === 'sub-local') {
      return this.f1('subscription.list.localNodeCount', 'count', group.nodes.length.toString());
    }
    return this.f1('node.count', 'count', group.nodes.length.toString());
  }

  private formatDateTime(timestamp: number): string {
    if (timestamp <= 0) {
      return this.t('subscription.list.neverUpdated');
    }
    const date = new Date(timestamp);
    const year = date.getFullYear();
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hours = date.getHours().toString().padStart(2, '0');
    const minutes = date.getMinutes().toString().padStart(2, '0');
    return `${year}-${month}-${day} ${hours}:${minutes}`;
  }

  private async loadState(): Promise<void> {
    this.isBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const settings = await SETTINGS_CONTROLLER.load(context);
      this.language = settings.language;
      this.confirmRemove = settings.confirmRemove;
      this.applySubscriptionsState(await SUBSCRIPTIONS_CONTROLLER.load(context, this.language));
    } finally {
      this.isBusy = false;
    }
  }

  private applySubscriptionsState(state: SubscriptionsControllerState): void {
    this.subscriptionGroups = state.subscriptionGroups;
    this.selectedGroupId = state.selectedGroupId;
  }

  private async selectSubscriptionGroup(group: SubscriptionGroup): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const state = await SUBSCRIPTIONS_CONTROLLER.selectGroup(context, group, this.language);
    this.applySubscriptionsState(state);
    this.getUIContext().getRouter().pushUrl({
      url: AppRoute.SUBSCRIPTION_DETAIL,
      params: { groupId: group.id }
    }).catch((err: Error) => {});
  }

  private async toggleSubscriptionGroup(group: SubscriptionGroup): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const state = await SUBSCRIPTIONS_CONTROLLER.toggleGroup(context, group, this.language);
    this.applySubscriptionsState(state);
    try {
      this.getUIContext().getPromptAction().showToast({ message: state.subscriptionMessage });
    } catch (err) {
      // ignore
    }
  }

  private removeSubscriptionGroup(group: SubscriptionGroup): void {
    if (this.confirmRemove) {
      try {
        this.getUIContext().showAlertDialog({
        title: this.t('menu.deleteConfig'),
        message: this.f1('subscription.deleteConfirm', 'name', group.name),
        autoCancel: true,
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -20 },
        primaryButton: {
          value: this.t('action.delete'),
          fontColor: AppColor.onBrand,
          backgroundColor: AppColor.danger,
          action: () => {
            this.removeSubscriptionGroupImmediately(group);
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
    this.removeSubscriptionGroupImmediately(group);
  }

  private async removeSubscriptionGroupImmediately(group: SubscriptionGroup): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const state = await SUBSCRIPTIONS_CONTROLLER.removeGroup(context, group, this.language);
    this.applySubscriptionsState(state);
    try {
      this.getUIContext().getPromptAction().showToast({ message: state.subscriptionMessage });
    } catch (err) {
      // ignore
    }
  }

  private async moveSubscriptionGroup(group: SubscriptionGroup, delta: number): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const state = await SUBSCRIPTIONS_CONTROLLER.moveGroup(context, group, delta, this.language);
    this.applySubscriptionsState(state);
    try {
      this.getUIContext().getPromptAction().showToast({ message: state.subscriptionMessage });
    } catch (err) {
      // ignore
    }
  }

  private async updateAllSubscriptions(): Promise<void> {
    if (this.isUpdatingAll) {
      return;
    }
    this.isUpdatingAll = true;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const runtime = SHARED_RUNTIME_CONTROLLER.snapshot();
      const proxyPort = SubscriptionManager.resolveSubscriptionProxyPort(
        runtime.runtimeMode,
        SHARED_RUNTIME_CONTROLLER.mayOwnNetwork()
      );
      const state = await SUBSCRIPTIONS_CONTROLLER.updateAll(context, this.language, proxyPort);
      this.applySubscriptionsState(state);
      try {
        this.getUIContext().getPromptAction().showToast({ message: state.subscriptionMessage });
      } catch (err) {
        // ignore
      }
    } finally {
      this.isUpdatingAll = false;
    }
  }

  private openAddPage() {
    this.getUIContext().getRouter().pushUrl({
      url: AppRoute.SUBSCRIPTION_EDIT
    }).catch((err: Error) => {});
  }

  private openEditPage(group: SubscriptionGroup) {
    this.getUIContext().getRouter().pushUrl({
      url: AppRoute.SUBSCRIPTION_EDIT,
      params: { groupId: group.id }
    }).catch((err: Error) => {});
  }

  private groupIndex(groupId: string): number {
    for (let index = 0; index < this.subscriptionGroups.length; index++) {
      if (this.subscriptionGroups[index].id === groupId) {
        return index;
      }
    }
    return -1;
  }

  private canMoveGroup(groupId: string, delta: number): boolean {
    const index = this.groupIndex(groupId);
    const target = index + delta;
    return index >= 0 && target >= 0 && target < this.subscriptionGroups.length;
  }

  private async copySubscriptionGroupUrl(group: SubscriptionGroup): Promise<void> {
    const url = group.url.trim();
    if (url.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      await pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({ message: this.t('subscription.detail.copied') });
    } catch (err) {
      // ignore
    }
  }


  private t(key: string): string {
    return translate(this.language, key);
  }

  private f1(key: string, name: string, value: string): string {
    return formatOne(this.language, key, name, value);
  }

  private subscriptionSummaryText(): string {
    if (this.subscriptionGroups.length === 0) {
      return this.t('subscription.list.emptySummary');
    }
    if (this.subscriptionGroups.length === 1) {
      return this.t('subscription.list.groupCount.one');
    }
    return this.f1('subscription.list.groupCount', 'count', this.subscriptionGroups.length.toString());
  }
}
