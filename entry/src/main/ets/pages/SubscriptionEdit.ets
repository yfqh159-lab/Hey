import { common } from '@kit.AbilityKit';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { AppLanguage } from '../core/Profile';
import {
  DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES,
  MIN_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
} from '../core/SubscriptionGroups';
import { SUBSCRIPTIONS_CONTROLLER, SubscriptionsControllerState } from '../features/subscriptions/SubscriptionsController';
import { DEFAULT_SUBSCRIPTION_USER_AGENT } from '../services/SubscriptionManager';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { PageHeader } from '../shell/PageHeader';
import { ensureReadPasteboardPermission } from '../utils/ClipboardPermission';
import { isScanCancelled, requestCameraPermission, scanQrCode } from '../utils/QrScan';
import { formatOne, formatTwo } from '../utils/LocalizationPresenter';
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';

@Entry
@Component
struct SubscriptionEditPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private groupId: string = '';
  @State private groupName: string = '';
  @State private subscriptionUrl: string = '';
  @State private userAgent: string = '';
  @State private filter: string = '';
  @State private prevProfile: string = '';
  @State private nextProfile: string = '';
  @State private allowInsecureUrl: boolean = false;
  @State private autoUpdate: boolean = false;
  @State private updateInterval: string = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES.toString();
  @State private isBusy: boolean = false;
  private originalUpdateIntervalMinutes: number = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.groupId = (params?.groupId as string) ?? '';
    this.loadState();
  }

  @Builder
  private SaveAction() {
    Button() {
      if (this.isBusy) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(AppColor.brand)
      } else {
        Text(this.t('action.save'))
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isSaveEnabled() ? AppColor.brand : AppColor.textTertiary)
      }
    }
    .type(ButtonType.Normal)
    .backgroundColor(Color.Transparent)
    .height(44)
    .padding({ left: Space.md, right: Space.md })
    .enabled(this.isSaveEnabled())
    .onClick(() => {
      this.saveGroup();
    })
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

  // 字段下方帮助文字：卡片底部 8 提供与卡片的间距，自身底部 16 衔接下一分组
  @Builder
  private FieldHint(text: string) {
    Text(text)
      .fontSize(FontSz.footnote)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .lineHeight(16)
      .padding({ left: 2, right: 2 })
      .margin({ bottom: Space.lg })
  }

  build() {
    Column() {
      PageHeader({
        title: this.pageTitleText(),
        showBack: true,
        rightActions: () => {
          this.SaveAction()
        }
      })

      Column() {
        Scroll() {
          Column() {

            // 卡片一：分组名称
            this.GroupLabel(this.t('subscription.edit.groupName'))
            Column() {
              TextInput({ text: this.groupName, placeholder: this.t('subscription.edit.groupName.placeholder') })
                .height(48)
                .width('100%')
                .fontSize(FontSz.body)
                .fontColor(AppColor.textPrimary)
                .placeholderColor(AppColor.textTertiary)
                .backgroundColor(Color.Transparent)
                .borderRadius(0)
                .padding({ left: 14, right: 14 })
                .onChange((val) => {
                  this.groupName = val;
                })
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
            .margin({ bottom: Space.sm })

            this.FieldHint(this.t('subscription.edit.groupName.detail'))

            // 卡片二：订阅链接
            this.GroupLabel(this.t('subscription.edit.url'))
            Column() {
              Row() {
                Image($r('app.media.ic_link'))
                  .width(20)
                  .height(20)
                  .fillColor(AppColor.textSecondary)
                  .margin({ left: 14, right: Space.sm })

                TextInput({
                  placeholder: this.t('subscription.edit.url.placeholder'),
                  text: this.subscriptionUrl
                })
                  .layoutWeight(1)
                  .height(48)
                  .fontSize(FontSz.body)
                  .fontColor(AppColor.textPrimary)
                  .placeholderColor(AppColor.textTertiary)
                  .backgroundColor(Color.Transparent)
                  .onChange((value: string) => {
                    this.subscriptionUrl = value;
                  })

                // 右侧小操作按钮
                Row({ space: Space.xs + 2 }) {
                  if (this.subscriptionUrl.length > 0) {
                    Button() {
                      Text('✕')
                        .fontSize(FontSz.footnote)
                        .fontColor(AppColor.textSecondary)
                        .fontWeight(FontWeight.Bold)
                    }
                    .backgroundColor(AppColor.surfaceAlt)
                    .width(28)
                    .height(28)
                    .borderRadius(14)
                    .onClick(() => {
                      this.subscriptionUrl = '';
                    })
                  }

                  Button() {
                    Image($r('app.media.ic_article'))
                      .width(15)
                      .height(15)
                      .fillColor(AppColor.textSecondary)
                  }
                  .backgroundColor(AppColor.surfaceAlt)
                  .width(28)
                  .height(28)
                  .borderRadius(14)
                  .onClick(() => {
                    this.pasteFromClipboard();
                  })

                  Button() {
                    Image($r('app.media.ic_qr_code'))
                      .width(15)
                      .height(15)
                      .fillColor(AppColor.textSecondary)
                  }
                  .backgroundColor(AppColor.surfaceAlt)
                  .width(28)
                  .height(28)
                  .borderRadius(14)
                  .onClick(() => {
                    this.scanSubscriptionUrl();
                  })
                }
                .margin({ right: Space.md })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
            .margin({ bottom: Space.sm })

            this.FieldHint(this.t('subscription.edit.url.detail'))

            // 允许不安全：轻量裸行（对齐 UI 稿，左右 4 内边距、单行说明）
            Row() {
              Text(this.t('subscription.edit.allowInsecure'))
                .fontSize(13)
                .fontColor(AppColor.textSecondary)
                .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.allowInsecureUrl })
                .selectedColor(AppColor.brand)
                .switchPointColor(AppColor.onBrand)
                .onChange((isOn: boolean) => {
                  this.allowInsecureUrl = isOn;
                })
            }
            .width('100%')
            .padding({ left: Space.xs, right: Space.xs })
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: Space.lg })

            this.GroupLabel(this.t('subscription.edit.autoUpdate'))
            Column() {
              Row() {
                Column({ space: 4 }) {
                  Text(this.t('subscription.edit.autoUpdate.enable'))
                    .fontSize(FontSz.body)
                    .fontColor(AppColor.textPrimary)
                  Text(this.t('subscription.edit.autoUpdate.enable.detail'))
                    .fontSize(FontSz.footnote)
                    .fontColor(AppColor.textTertiary)
                    .maxLines(2)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.autoUpdate })
                  .selectedColor(AppColor.brand)
                  .switchPointColor(AppColor.onBrand)
                  .onChange((isOn: boolean) => {
                    this.autoUpdate = isOn;
                  })
              }
              .width('100%')
              .padding({
                left: Space.lg,
                right: Space.lg,
                top: Space.lg,
                bottom: this.autoUpdate ? Space.md : Space.lg
              })
              .alignItems(VerticalAlign.Center)

              // 开启自动更新后展开「更新间隔」
              if (this.autoUpdate) {
                Divider()
                  .strokeWidth(0.5)
                  .color(AppColor.divider)
                  .margin({ left: Space.lg })

                Row() {
                  Column({ space: 4 }) {
                    Text(this.t('subscription.edit.updateInterval'))
                      .fontSize(FontSz.body)
                      .fontColor(AppColor.textPrimary)
                    Text(this.f2('subscription.edit.updateInterval.detail',
                      'min', MIN_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES.toString(),
                      'default', DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES.toString()))
                      .fontSize(FontSz.footnote)
                      .fontColor(AppColor.textTertiary)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  TextInput({ text: this.updateInterval, placeholder: DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES.toString() })
                    .width(104)
                    .height(40)
                    .type(InputType.Number)
                    .fontSize(FontSz.body)
                    .fontColor(AppColor.textPrimary)
                    .placeholderColor(AppColor.textTertiary)
                    .backgroundColor(AppColor.surfaceAlt)
                    .borderRadius(Radius.md)
                    .padding({ left: Space.md, right: Space.md })
                    .onChange((val) => {
                      this.updateInterval = val;
                    })
                }
                .width('100%')
                .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.lg })
                .alignItems(VerticalAlign.Center)
              }
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
            .margin({ bottom: Space.lg })

            // 卡片四：自定义 User-Agent
            this.GroupLabel(this.t('subscription.edit.userAgent'))
            Column() {
              TextInput({
                text: this.userAgent,
                placeholder: this.f1('subscription.edit.userAgent.placeholder', 'userAgent', DEFAULT_SUBSCRIPTION_USER_AGENT)
              })
                .height(48)
                .width('100%')
                .fontSize(FontSz.body)
                .fontColor(AppColor.textPrimary)
                .placeholderColor(AppColor.textTertiary)
                .backgroundColor(Color.Transparent)
                .borderRadius(0)
                .padding({ left: 14, right: 14 })
                .onChange((val) => {
                  this.userAgent = val;
                })
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
            .margin({ bottom: Space.sm })

            this.FieldHint(this.t('subscription.edit.userAgent.detail'))

            // 卡片五：节点过滤（正则）
            this.GroupLabel(this.t('subscription.edit.filter'))
            Column() {
              TextInput({ text: this.filter, placeholder: this.t('subscription.edit.filter.placeholder') })
                .height(48)
                .width('100%')
                .fontSize(FontSz.body)
                .fontColor(AppColor.textPrimary)
                .placeholderColor(AppColor.textTertiary)
                .backgroundColor(Color.Transparent)
                .borderRadius(0)
                .padding({ left: 14, right: 14 })
                .onChange((val) => {
                  this.filter = val;
                })
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
            .margin({ bottom: Space.sm })

            this.FieldHint(this.t('subscription.edit.filter.detail'))

            this.GroupLabel(this.t('subscription.edit.profilePair'))
            Column() {
              TextInput({ text: this.prevProfile, placeholder: this.t('subscription.edit.prevProfile.placeholder') })
                .height(48)
                .width('100%')
                .fontSize(FontSz.body)
                .fontColor(AppColor.textPrimary)
                .placeholderColor(AppColor.textTertiary)
                .backgroundColor(Color.Transparent)
                .borderRadius(0)
                .padding({ left: 14, right: 14 })
                .onChange((val) => {
                  this.prevProfile = val;
                })
              this.RowDivider()
              TextInput({ text: this.nextProfile, placeholder: this.t('subscription.edit.nextProfile.placeholder') })
                .height(48)
                .width('100%')
                .fontSize(FontSz.body)
                .fontColor(AppColor.textPrimary)
                .placeholderColor(AppColor.textTertiary)
                .backgroundColor(Color.Transparent)
                .borderRadius(0)
                .padding({ left: 14, right: 14 })
                .onChange((val) => {
                  this.nextProfile = val;
                })
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
            .margin({ bottom: Space.sm })

            this.FieldHint(this.t('subscription.edit.profilePair.detail'))

          }
          .width('100%')
          .padding({ left: Space.lg, right: Space.lg, top: 14, bottom: Space.sm })
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

  @Builder
  private RowDivider() {
    Divider()
      .strokeWidth(0.5)
      .color(AppColor.divider)
      .margin({ left: Space.lg })
  }

  private isSaveEnabled(): boolean {
    return this.groupName.trim().length > 0 && !this.isBusy;
  }

  private async loadState(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    this.language = (await SETTINGS_CONTROLLER.load(context)).language;

    if (this.groupId.length > 0) {
      const state = await SUBSCRIPTIONS_CONTROLLER.load(context, this.language);
      for (let i = 0; i < state.subscriptionGroups.length; i++) {
        if (state.subscriptionGroups[i].id === this.groupId) {
          const group = state.subscriptionGroups[i];
          this.groupName = group.name;
          this.subscriptionUrl = group.url;
          this.userAgent = group.userAgent ?? '';
          this.filter = group.filter ?? '';
          this.prevProfile = group.prevProfile ?? '';
          this.nextProfile = group.nextProfile ?? '';
          this.allowInsecureUrl = group.allowInsecureUrl ?? false;
          this.autoUpdate = group.autoUpdate ?? false;
          this.originalUpdateIntervalMinutes = group.updateIntervalMinutes ?? DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES;
          this.updateInterval = this.originalUpdateIntervalMinutes.toString();
          break;
        }
      }
    } else {
      this.originalUpdateIntervalMinutes = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES;
      this.updateInterval = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES.toString();
    }
  }

  private async saveGroup(): Promise<void> {
    const name = this.groupName.trim();
    const url = this.subscriptionUrl.trim();
    if (name.length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('subscription.edit.groupName.empty') });
      } catch (err) {
        // ignore
      }
      return;
    }

    const userAgent = this.userAgent.trim();
    const filter = this.filter.trim();
    const prevProfile = this.prevProfile.trim();
    const nextProfile = this.nextProfile.trim();
    const updateIntervalMinutes = this.resolveUpdateIntervalForSave();
    if (updateIntervalMinutes < 0) {
      return;
    }
    this.isBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      let state: SubscriptionsControllerState;
      if (this.groupId.length === 0) {
        state = await SUBSCRIPTIONS_CONTROLLER.addGroup(context, name, url, userAgent, filter, prevProfile, nextProfile, this.allowInsecureUrl, this.language, this.autoUpdate, updateIntervalMinutes);
      } else {
        state = await SUBSCRIPTIONS_CONTROLLER.updateGroup(context, this.groupId, name, url, userAgent, filter, prevProfile, nextProfile, this.allowInsecureUrl, this.language, this.autoUpdate, updateIntervalMinutes);
      }
      try {
        this.getUIContext().getPromptAction().showToast({ message: state.subscriptionMessage });
      } catch (err) {
        // ignore
      }
      this.getUIContext().getRouter().back();
    } catch (err) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('subscription.edit.saveFailed') });
      } catch (err) {
        // ignore
      }
    } finally {
      this.isBusy = false;
    }
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

  private resolveUpdateIntervalForSave(): number {
    const parsed = this.parseUpdateIntervalInput();
    if (this.autoUpdate) {
      if (parsed === null) {
        return DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES;
      }
      if (parsed < MIN_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES) {
        try {
          this.getUIContext().getPromptAction().showToast({
          message: this.f1('subscription.edit.updateInterval.tooSmall',
            'min', MIN_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES.toString())
        });
        } catch (err) {
          // ignore
        }
        return -1;
      }
      return parsed;
    }

    if (parsed !== null && parsed >= MIN_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES) {
      return parsed;
    }
    return this.originalUpdateIntervalMinutes;
  }

  private parseUpdateIntervalInput(): number | null {
    const value = this.updateInterval.trim();
    if (value.length === 0) {
      return null;
    }
    const parsed = Number(value);
    if (Number.isNaN(parsed) || Math.floor(parsed) !== parsed) {
      return null;
    }
    return parsed;
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

  private pageTitleText(): string {
    return this.groupId.length > 0 ? this.t('subscription.edit.title.edit') : this.t('subscription.edit.title.new');
  }
}
