import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { scanBarcode, scanCore, detectBarcode } from '@kit.ScanKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { subscriptionNameFromDeepLink } from '../core/DeepLink';
import { resolveImportedNodeName } from '../core/ImportedNodeNames';
import { AppLanguage, XrayConfigType } from '../core/Profile';
import { NODES_CONTROLLER } from '../features/nodes/NodesController';
import { extractNodeEndpoint, formatEndpointDescription } from '../features/nodes/NodeOperations';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { SUBSCRIPTIONS_CONTROLLER } from '../features/subscriptions/SubscriptionsController';
import { AppRoute } from '../shell/AppRoute';
import { PageHeader } from '../shell/PageHeader';
import { formatOne, localizeCoreMessage } from '../utils/LocalizationPresenter';
import { isScanCancelled, requestCameraPermission, scanQrCode } from '../utils/QrScan';
import { SubscriptionStore } from '../storage/SubscriptionStore';
import { convertNativeShareTextToOutbounds } from '../services/NativeShareConverter';
import { SubscriptionManager } from '../services/SubscriptionManager';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { shouldStartScannerImmediately } from '../core/ScannerLaunch';
import { AppColor } from '../theme/Theme';
import {
  IMPORT_TEXT_TOO_LARGE_MESSAGE,
  isExternalImportTextTooLarge
} from '../core/ExternalInput';

@Entry
@Component
struct ScannerPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private importBuffer: string = '';
  // 系统扫码/相册面板返回时 ArkUI 可能重建页面组件。原文仍只保存在当前页面内存，
  // 不绑定任何可截图控件，但必须由 @State 接管重建恢复，否则会留下“预览存在、
  // 确认按钮不可用”的分裂状态。
  @State private pendingSensitiveImport: string = '';
  @State private lastError: string = '';
  @State private previewTitle: string = '';
  @State private previewDetail: string = '';
  @State private previewValid: boolean = false;
  @State private previewMatchesImport: boolean = false;
  @State private isBusy: boolean = false;
  @State private hasAutoScanned: boolean = false;
  @State private isPressedScanCard: boolean = false;
  @State private isPressedPhotoCard: boolean = false;
  @State private isPressedImportBtn: boolean = false;
  private startScanImmediate: boolean = false;
  private routeStartScanImmediate: boolean = false;
  private immediateScanTimerId: number = -1;
  private pageActive: boolean = false;
  private pageGeneration: number = 0;

  aboutToAppear(): void {
    this.pageActive = true;
    const pageGeneration = ++this.pageGeneration;
    // A previous page instance may have left while a system picker was pending; its
    // continuation is generation-invalid, so it must not leave the visible page busy.
    this.isBusy = false;
    try {
      this.routeStartScanImmediate = shouldStartScannerImmediately(
        router.getParams() as Record<string, Object>
      );
    } catch (error) {
      this.routeStartScanImmediate = false;
    }
    // 首页“扫码添加”是本次明确用户动作，不能被仅用于全局默认偏好的设置读取阻塞，
    // 也不应反复向已卡住的 ArkData 队列追加无用任务；语言已由 AppStorage 同步。
    this.startScanImmediate = this.routeStartScanImmediate;
    if (this.routeStartScanImmediate) {
      return;
    }
    this.loadState(pageGeneration);
  }

  onPageShow(): void {
    this.tryStartImmediateScan();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.pageGeneration++;
    if (this.immediateScanTimerId >= 0) {
      clearTimeout(this.immediateScanTimerId);
      this.immediateScanTimerId = -1;
    }
    // 返回栈可能保留页面实例。自动扫码只属于本次进入；若不重置，用户下一次从首页
    // 明确点击“扫码添加”时会被上一轮 hasAutoScanned 状态吞掉。
    this.hasAutoScanned = false;
    this.startScanImmediate = false;
    this.routeStartScanImmediate = false;
    // 所有入口都可能携带 UUID、密码或订阅 Token。离开页面时统一清除隐藏原文、
    // 手动输入、脱敏预览与旧错误，不能依赖返回栈实例一定会被 ArkUI 立即销毁。
    this.clearImportValue();
  }

  build() {
    Column() {
      PageHeader({
        title: this.t('screen.scanner.title'),
        showBack: true
      })

      Scroll() {
        Column({ space: 16 }) {
          // 模块一：相机扫码引导卡片
          Column({ space: 12 }) {
            Row() {
              Image($r('app.media.ic_qr_code'))
                .width(28)
                .height(28)
                .fillColor(AppColor.brand)
                .margin({ right: 12 })

              Column() {
                Text(this.t('scanner.camera.title'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.textPrimary)
                Text(this.t('scanner.camera.detail'))
                  .fontSize(12)
                  .fontColor(AppColor.textSecondary)
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Image($r('app.media.ic_chevron_right'))
                .width(18)
                .height(18)
                .fillColor(AppColor.textTertiary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.surface)
          .borderRadius(16)
          .shadow({ radius: 8, color: AppColor.shadowCard, offsetX: 0, offsetY: 2 })
          .scale({ x: this.isPressedScanCard ? 0.98 : 1.0, y: this.isPressedScanCard ? 0.98 : 1.0 })
          .animation({ duration: 100, curve: Curve.EaseOut })
          .onTouch((event) => {
            if (event.type === TouchType.Down) {
              this.isPressedScanCard = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.isPressedScanCard = false;
            }
          })
          .onClick(() => {
            this.startCameraScan();
          })

          // 模块二：从相册图片解码二维码
          Column({ space: 12 }) {
            Row() {
              Image($r('app.media.ic_folder'))
                .width(28)
                .height(28)
                .fillColor(AppColor.brand)
                .margin({ right: 12 })

              Column() {
                Text(this.t('scanner.photo.title'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.textPrimary)
                Text(this.t('scanner.photo.detail'))
                  .fontSize(12)
                  .fontColor(AppColor.textSecondary)
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Image($r('app.media.ic_chevron_right'))
                .width(18)
                .height(18)
                .fillColor(AppColor.textTertiary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.surface)
          .borderRadius(16)
          .shadow({ radius: 8, color: AppColor.shadowCard, offsetX: 0, offsetY: 2 })
          .scale({ x: this.isPressedPhotoCard ? 0.98 : 1.0, y: this.isPressedPhotoCard ? 0.98 : 1.0 })
          .animation({ duration: 100, curve: Curve.EaseOut })
          .onTouch((event) => {
            if (event.type === TouchType.Down) {
              this.isPressedPhotoCard = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.isPressedPhotoCard = false;
            }
          })
          .onClick(() => {
            this.selectPhotoQr();
          })

          // 模块三：手动粘贴与输入卡片
          Column({ space: 12 }) {
            Row() {
              Text(this.t('scanner.manual.title'))
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.textPrimary)

              Blank()

              Row({ space: 8 }) {
                PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
                  .fontSize(12)
                  .fontColor(AppColor.textSecondary)
                  .backgroundColor(AppColor.border)
                  .height(40)
                  .padding({ left: 10, right: 10 })
                  .borderRadius(6)
                  .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
                    if (result === PasteButtonOnClickResult.SUCCESS) {
                      this.pasteFromClipboard();
                    } else {
                      this.toast(this.t('prompt.clipboardReadFailed'));
                    }
                  })

                if (this.hasImportValue()) {
                  Button(this.t('action.clear'))
                    .fontSize(12)
                    .fontColor(AppColor.danger)
                    .backgroundColor(AppColor.dangerTint)
                    .height(28)
                    .padding({ left: 10, right: 10 })
                    .borderRadius(6)
                    .onClick(() => {
                      this.clearImportValue();
                    })
                }
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            TextArea({
              placeholder: this.hasPendingSensitiveImport() ?
                this.t('scanner.reviewBeforeImport') : this.t('placeholder.scannerPayload'),
              text: this.importBuffer
            })
              .height(160)
              .fontSize(13)
              .fontColor(AppColor.textPrimary)
              .backgroundColor(AppColor.surfaceAlt)
              .enabled(!this.hasPendingSensitiveImport())
              .opacity(this.hasPendingSensitiveImport() ? 0.72 : 1.0)
              .borderRadius(10)
              .padding(12)
              .onChange((value: string) => {
                if (this.hasPendingSensitiveImport()) {
                  return;
                }
                if (isExternalImportTextTooLarge(value)) {
                  this.importBuffer = '';
                  this.previewMatchesImport = false;
                  this.previewValid = false;
                  this.previewTitle = this.t('scanner.previewInvalid');
                  this.previewDetail = localizeCoreMessage(this.language, IMPORT_TEXT_TOO_LARGE_MESSAGE);
                  this.lastError = this.previewDetail;
                  return;
                }
                this.importBuffer = value;
                // 输入已经变化，上一轮导入错误不再描述当前内容；当前有效性由下方预览即时展示。
                this.lastError = '';
                this.updateImportPreview(value);
              })

            Text(this.t('scanner.supportedPayloads'))
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
              .width('100%')
              .lineHeight(16)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.surface)
          .borderRadius(16)
          .shadow({ radius: 8, color: AppColor.shadowCard, offsetX: 0, offsetY: 2 })

          if (this.previewTitle.length > 0) {
            Column({ space: 6 }) {
              Text(this.previewTitle)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.previewValid ? AppColor.success : AppColor.danger)
                .width('100%')
              Text(this.previewDetail)
                .fontSize(12)
                .fontColor(AppColor.textSecondary)
                .width('100%')
                .lineHeight(17)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.previewValid ? AppColor.successTint : AppColor.dangerTint)
            .borderRadius(12)
          }

          // 模块四：错误提示卡片
          if (this.lastError.length > 0) {
            Column({ space: 8 }) {
              Row({ space: 6 }) {
                Column()
                  .width(6)
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor(AppColor.danger)

                Text(this.t('scanner.importFailedTitle'))
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.danger)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text(this.lastError)
                .fontSize(12)
                .fontColor(AppColor.danger)
                .width('100%')
                .lineHeight(16)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(AppColor.dangerTint)
            .borderRadius(12)
            .borderWidth(1)
            .borderColor(AppColor.danger)
          }

          // 模块五：解析导入按钮
          Button() {
            Row() {
              if (this.isBusy) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(AppColor.onBrand)
                  .margin({ right: 8 })
              }
              Text(this.t(this.hasCurrentValidPreview() ? 'action.importResult' : 'import.parseButton'))
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.isImportEnabled() ? AppColor.onBrand : AppColor.textTertiary)
            }
          }
          .width('100%')
          .height(48)
          .borderRadius(12)
          .enabled(this.isImportEnabled())
          .opacity(this.isImportEnabled() ? 1.0 : 0.65)
          .linearGradient(this.isImportEnabled() ? {
            angle: 90,
            colors: [[AppColor.brandStrong, 0.0], [AppColor.brand, 1.0]]
          } : {
            angle: 90,
            colors: [[AppColor.border, 0.0], [AppColor.border, 1.0]]
          })
          .scale({ x: this.isPressedImportBtn ? 0.97 : 1.0, y: this.isPressedImportBtn ? 0.97 : 1.0 })
          .animation({ duration: 150, curve: Curve.EaseOut })
          .onTouch((event) => {
            if (event.type === TouchType.Down) {
              this.isPressedImportBtn = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.isPressedImportBtn = false;
            }
          })
          .onClick(() => {
            this.importResult();
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 32 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .height('100%')
    .width('100%')
    .backgroundColor(AppColor.bg)
  }

  private isImportEnabled(): boolean {
    // 相机、相册和剪贴板结果已经运行过完整兼容预览；无效摘要不得继续进入保存。
    // 手动输入仍允许点击后执行一次 native 兼容解析，避免按键期间反复调用 N-API。
    return this.hasImportValue() && !this.isBusy &&
      (!this.hasPendingSensitiveImport() || this.previewValid);
  }

  private hasPendingSensitiveImport(): boolean {
    return this.pendingSensitiveImport.length > 0;
  }

  private hasImportValue(): boolean {
    return this.pendingSensitiveImport.length > 0 || this.importBuffer.trim().length > 0;
  }

  private importValue(): string {
    return this.pendingSensitiveImport.length > 0 ? this.pendingSensitiveImport : this.importBuffer.trim();
  }

  private setSensitiveImportValue(value: string): void {
    this.pendingSensitiveImport = value.trim();
    this.importBuffer = '';
  }

  private clearImportValue(): void {
    this.pendingSensitiveImport = '';
    this.importBuffer = '';
    this.previewMatchesImport = false;
    this.lastError = '';
    this.updateImportPreview('');
  }

  private async loadState(pageGeneration: number): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const settings = await SETTINGS_CONTROLLER.load(context);
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      this.language = settings.language;
      this.startScanImmediate = this.routeStartScanImmediate || settings.startScanImmediate;
      this.tryStartImmediateScan();
    } catch (error) {
      if (this.isCurrentPage(pageGeneration)) {
        this.lastError = this.f1('scanner.loadStateFailed', 'error', redactDiagnosticText(JSON.stringify(error)));
      }
    }
  }

  private tryStartImmediateScan(): void {
    if (!this.startScanImmediate || this.hasAutoScanned) {
      return;
    }
    this.hasAutoScanned = true;
    // 延迟拉起扫码，确保转场动画完全结束后再加载扫码面板，体验更流畅。
    this.immediateScanTimerId = setTimeout(() => {
      this.immediateScanTimerId = -1;
      if (this.pageActive) {
        this.startCameraScan();
      }
    }, 300);
  }

  private async startCameraScan(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.lastError = '';
    const pageGeneration = this.pageGeneration;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (!await requestCameraPermission(context)) {
        if (this.isCurrentPage(pageGeneration)) {
          this.lastError = this.t('scanner.cameraPermissionDenied');
        }
        return;
      }
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      const value = await scanQrCode(context);
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      await this.importScannedValue(value);
    } catch (error) {
      console.error('Scan barcode failed or cancelled:', redactDiagnosticText(JSON.stringify(error)));
      if (this.isCurrentPage(pageGeneration) && !isScanCancelled(error)) {
        this.lastError = this.f1('scanner.scanFailed', 'error', this.errorMessage(error));
      }
    } finally {
      if (this.isCurrentPage(pageGeneration)) {
        this.isBusy = false;
      }
    }
  }

  private async selectPhotoQr(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.lastError = '';
    const pageGeneration = this.pageGeneration;
    try {
      const photoSelectOptions = new picker.PhotoSelectOptions();
      photoSelectOptions.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      const photoPicker = new picker.PhotoViewPicker();
      const result = await photoPicker.select(photoSelectOptions);
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      if (!result || !result.photoUris || result.photoUris.length === 0) {
        return;
      }

      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false
      };
      const results = await detectBarcode.decode({ uri: result.photoUris[0] }, options);
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      await this.importScannedValue(this.firstScanValue(results), this.t('scanner.decodeFailed'));
    } catch (error) {
      console.error('Decode QR image failed or cancelled:', redactDiagnosticText(JSON.stringify(error)));
      if (this.isCurrentPage(pageGeneration) && !isScanCancelled(error)) {
        this.lastError = this.f1('scanner.photoImportFailed', 'error', this.errorMessage(error));
      }
    } finally {
      if (this.isCurrentPage(pageGeneration)) {
        this.isBusy = false;
      }
    }
  }

  private firstScanValue(results: Array<scanBarcode.ScanResult>): string {
    for (let index = 0; index < results.length; index++) {
      const value = results[index].originalValue;
      if (value && value.trim().length > 0) {
        return value;
      }
    }
    return '';
  }

  private async importScannedValue(value: string | undefined, emptyMessage?: string): Promise<void> {
    if (!value || value.trim().length === 0) {
      if (emptyMessage && emptyMessage.length > 0) {
        this.lastError = emptyMessage;
      }
      return;
    }
    if (isExternalImportTextTooLarge(value)) {
      this.clearImportValue();
      this.lastError = localizeCoreMessage(this.language, IMPORT_TEXT_TOO_LARGE_MESSAGE);
      return;
    }
    this.setSensitiveImportValue(value);
    this.lastError = '';
    // A completed camera/photo result is stable input, so it is safe to run the
    // native compatibility fallback once. Do not do that for every keystroke.
    this.updateImportPreview(this.pendingSensitiveImport, true);
    // 扫码/相册只负责识别并展示脱敏摘要。必须由用户检查摘要后再次点击导入，
    // 才允许保存节点或订阅来源；订阅内容仍需在订阅页由用户主动更新。
    this.toast(this.t('scanner.reviewBeforeImport'));
  }

  private async pasteFromClipboard(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    const pageGeneration = this.pageGeneration;
    try {
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (systemPasteboard.hasDataSync()) {
        const pasteData = await systemPasteboard.getData();
        if (!this.isCurrentPage(pageGeneration)) {
          return;
        }
        const text = pasteData.getPrimaryText();
        if (text && text.trim().length > 0) {
          if (isExternalImportTextTooLarge(text)) {
            this.clearImportValue();
            this.lastError = localizeCoreMessage(this.language, IMPORT_TEXT_TOO_LARGE_MESSAGE);
            return;
          }
          this.setSensitiveImportValue(text);
          this.lastError = '';
          this.updateImportPreview(this.pendingSensitiveImport, true);
          this.toast(this.t('prompt.pastedConfig'));
        } else {
          this.toast(this.t('prompt.clipboardTextEmpty'));
        }
      } else {
        this.toast(this.t('prompt.clipboardNoData'));
      }
    } catch (error) {
      if (this.isCurrentPage(pageGeneration)) {
        this.toast(this.t('prompt.clipboardReadFailed'));
      }
    } finally {
      if (this.isCurrentPage(pageGeneration)) {
        this.isBusy = false;
      }
    }
  }

  private isCurrentPage(pageGeneration: number): boolean {
    return this.pageActive && pageGeneration === this.pageGeneration;
  }

  private async importResult(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    const value = this.importValue();
    if (value.length === 0) {
      this.lastError = this.t('error.emptyImport');
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      return;
    }
    if (isExternalImportTextTooLarge(value)) {
      this.clearImportValue();
      this.lastError = localizeCoreMessage(this.language, IMPORT_TEXT_TOO_LARGE_MESSAGE);
      return;
    }

    // 手动输入可能是只有 native 兼容解析器才识别的格式。第一次点击
    // 只允许生成脱敏预览；必须再次点击才保存。相机、相册和专用粘贴
    // 入口已经为同一原文建立预览，所以它们仍是“扫描 -> 确认”两步。
    if (!this.hasCurrentValidPreview()) {
      this.updateImportPreview(value, true);
      if (this.hasCurrentValidPreview()) {
        this.toast(this.t('scanner.reviewBeforeImport'));
      }
      return;
    }

    this.isBusy = true;
    this.lastError = '';
    const pageGeneration = this.pageGeneration;
    try {
      const context = getContext(this) as common.Context;
      // 判定是否是订阅地址
      if (value.toLowerCase().startsWith('http://') || value.toLowerCase().startsWith('https://')) {
        const validationMessage = SubscriptionManager.validateSubscriptionUrl(value, false);
        if (validationMessage.length > 0) {
          this.lastError = redactDiagnosticText(localizeCoreMessage(this.language, validationMessage));
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }

        const existingProfile = await SubscriptionStore.load(context);
        if (!this.isCurrentPage(pageGeneration)) {
          return;
        }
        const existingGroup = SubscriptionStore.findGroupByUrl(existingProfile.groups, value);
        if (existingGroup !== null) {
          await SUBSCRIPTIONS_CONTROLLER.selectGroup(context, existingGroup, this.language);
          if (!this.isCurrentPage(pageGeneration)) {
            return;
          }
          const duplicateMessage = this.t('scanner.subscriptionAlreadyAdded');
          SHARED_RUNTIME_CONTROLLER.appendLog(duplicateMessage);
          this.toast(duplicateMessage);
          this.clearImportValue();
          router.pushUrl({ url: AppRoute.SUBSCRIPTIONS });
          return;
        }

        const state = await SUBSCRIPTIONS_CONTROLLER.addGroup(
          context,
          subscriptionNameFromDeepLink(value),
          value,
          '',
          '',
          '',
          '',
          false,
          this.language
        );
        if (!this.isCurrentPage(pageGeneration)) {
          return;
        }
        if (SubscriptionStore.findGroupByUrl(state.subscriptionGroups, value) === null) {
          this.lastError = redactDiagnosticText(state.subscriptionMessage);
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }
        const addedMessage = this.t('scanner.subscriptionAdded');
        SHARED_RUNTIME_CONTROLLER.appendLog(addedMessage);
        this.toast(addedMessage);
        this.clearImportValue();
        router.pushUrl({ url: AppRoute.SUBSCRIPTIONS });
        return;
      }

      // 解析节点
      // 扫码确认只应新增节点，不应借“解析”之名先改写当前 Profile。否则重复导入或
      // 批量导入也会悄悄改变后续连接的回退配置。先做纯校验，真正去重成功后再落库。
      const validation = NODES_CONTROLLER.validateConfig(value, this.language);
      if (!validation.valid) {
        // 先用内置订阅解析器批量解析（支持 base64、多行分享链接、Clash YAML，涵盖 anytls/tuic
        // 等 sing-box 专属协议）。native(xray-core) 转换不认识 anytls/tuic，只作后备。
        const parsedNodes = SubscriptionManager.parseSubscriptionContent(value, '');
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
              lastValidationError = redactDiagnosticText(imported.message);
              continue;
            }
            if (await this.addManualNodeIfUnique(
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
          if (!this.isCurrentPage(pageGeneration)) {
            return;
          }
          if (importedCount === 0) {
            this.lastError = duplicateCount > 0 ?
              this.f1('scanner.duplicateNodes', 'count', duplicateCount.toString()) :
              (lastValidationError.length > 0 ? lastValidationError : redactDiagnosticText(validation.message));
            SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
            return;
          }
          const batchMessage = importedCount === 1 ?
            this.t('scanner.nodeImported') : this.f1('scanner.nodesImported', 'count', importedCount.toString());
          SHARED_RUNTIME_CONTROLLER.appendLog(batchMessage);
          if (duplicateCount > 0) {
            SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('scanner.duplicateNodes', 'count', duplicateCount.toString()));
          }
          this.toast(batchMessage);
          this.clearImportValue();
          router.back();
          return;
        }

        const nativeResult = convertNativeShareTextToOutbounds(value);
        if (!nativeResult.ok) {
          this.lastError = nativeResult.message.length > 0 ?
            redactDiagnosticText(`${validation.message}\n${nativeResult.message}`) :
            redactDiagnosticText(validation.message);
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }

        let importedCount = 0;
        let duplicateCount = 0;
        let lastValidationError = '';
        for (let index = 0; index < nativeResult.outbounds.length; index++) {
          const outbound = nativeResult.outbounds[index];
          const imported = NODES_CONTROLLER.validateConfig(outbound.outboundJson, this.language, 'outbound');
          if (!imported.valid) {
            lastValidationError = redactDiagnosticText(imported.message);
            continue;
          }
          if (!await this.addManualNodeIfUnique(
            context,
            resolveImportedNodeName(imported.normalizedJson, outbound.name),
            imported.normalizedJson,
            imported.configType
          )) {
            duplicateCount++;
            continue;
          }
          importedCount++;
        }

        if (!this.isCurrentPage(pageGeneration)) {
          return;
        }

        if (importedCount === 0) {
          this.lastError = duplicateCount > 0 ?
            this.f1('scanner.duplicateNodes', 'count', duplicateCount.toString()) :
            (lastValidationError.length > 0 ? lastValidationError : redactDiagnosticText(validation.message));
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }

        const successMessage = importedCount === 1 ?
          this.t('scanner.nodeImported') : this.f1('scanner.nodesImported', 'count', importedCount.toString());
        SHARED_RUNTIME_CONTROLLER.appendLog(successMessage);
        if (duplicateCount > 0) {
          SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('scanner.duplicateNodes', 'count', duplicateCount.toString()));
        }
        this.toast(successMessage);
        this.clearImportValue();
        router.back();
        return;
      }

      const nodeName = resolveImportedNodeName(validation.normalizedJson, this.t('scanner.defaultNodeName'));
      if (!await this.addManualNodeIfUnique(
        context,
        nodeName,
        validation.normalizedJson,
        validation.configType
      )) {
        if (!this.isCurrentPage(pageGeneration)) {
          return;
        }
        this.lastError = this.f1('scanner.duplicateNode', 'name', redactDiagnosticText(nodeName));
        SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
        return;
      }
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.profileSaved'));
      this.toast(this.t('scanner.nodeImported'));
      this.clearImportValue();
      router.back();
    } catch (error) {
      const message = this.f1('error.saveProfile', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(message);
      if (this.isCurrentPage(pageGeneration)) {
        this.lastError = message;
      }
    } finally {
      if (this.isCurrentPage(pageGeneration)) {
        this.isBusy = false;
      }
    }
  }

  private updateImportPreview(value: string, allowNativeFallback: boolean = false): void {
    const input = value.trim();
    this.previewMatchesImport = false;
    if (input.length === 0) {
      this.previewTitle = '';
      this.previewDetail = '';
      this.previewValid = false;
      return;
    }
    if (isExternalImportTextTooLarge(input)) {
      this.previewTitle = this.t('scanner.previewInvalid');
      this.previewDetail = localizeCoreMessage(this.language, IMPORT_TEXT_TOO_LARGE_MESSAGE);
      this.previewValid = false;
      return;
    }
    const lower = input.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      const validationMessage = SubscriptionManager.validateSubscriptionUrl(input, false);
      if (validationMessage.length > 0) {
        this.previewTitle = this.t('scanner.previewInvalid');
        this.previewDetail = localizeCoreMessage(this.language, validationMessage);
        this.previewValid = false;
        return;
      }
      this.previewTitle = this.t('scanner.previewSubscription');
      this.previewDetail = this.t('scanner.previewSubscriptionDetail');
      this.previewValid = true;
      this.previewMatchesImport = true;
      return;
    }
    const validation = NODES_CONTROLLER.validateConfig(input, this.language);
    if (validation.valid) {
      const name = resolveImportedNodeName(validation.normalizedJson, this.t('scanner.defaultNodeName'));
      const endpoint = extractNodeEndpoint(validation.normalizedJson);
      const endpointText = formatEndpointDescription(endpoint.address, endpoint.port);
      this.previewTitle = this.f1('scanner.previewNode', 'name', name);
      this.previewDetail = this.f1('scanner.previewProtocol', 'protocol', validation.protocol.toUpperCase());
      if (endpointText.length > 0) {
        this.previewDetail += `\n${this.f1(
          'scanner.previewEndpoint', 'endpoint', redactDiagnosticText(endpointText))}`;
      }
      this.previewValid = true;
      this.previewMatchesImport = true;
      return;
    }
    const parsedNodes = SubscriptionManager.parseSubscriptionContent(input, '');
    if (parsedNodes.length > 0) {
      let validNodeCount = 0;
      for (let index = 0; index < parsedNodes.length; index++) {
        const parsedNode = parsedNodes[index];
        if (NODES_CONTROLLER.validateConfig(
          parsedNode.outboundJson,
          this.language,
          parsedNode.configType
        ).valid) {
          validNodeCount++;
        }
      }
      if (validNodeCount > 0) {
        this.previewTitle = this.f1('scanner.previewNodes', 'count', validNodeCount.toString());
        this.previewDetail = this.t('scanner.previewNodesDetail');
        this.previewValid = true;
        this.previewMatchesImport = true;
        return;
      }
    }
    // libXray accepts a few compatibility formats beyond the ArkTS parser. A
    // completed scan/photo/clipboard result must not be labelled invalid when
    // the confirmation action can actually import it. This path is deliberately
    // skipped while the user is typing to avoid synchronous N-API work per key.
    if (allowNativeFallback) {
      const nativeResult = convertNativeShareTextToOutbounds(input);
      if (nativeResult.ok && nativeResult.outbounds.length > 0) {
        let validNativeCount = 0;
        for (let index = 0; index < nativeResult.outbounds.length; index++) {
          if (NODES_CONTROLLER.validateConfig(
            nativeResult.outbounds[index].outboundJson,
            this.language,
            'outbound'
          ).valid) {
            validNativeCount++;
          }
        }
        if (validNativeCount > 0) {
          this.previewTitle = this.f1('scanner.previewNodes', 'count', validNativeCount.toString());
          this.previewDetail = this.t('scanner.previewNodesDetail');
          this.previewValid = true;
          this.previewMatchesImport = true;
          return;
        }
      }
    }
    this.previewTitle = this.t('scanner.previewInvalid');
    this.previewDetail = redactDiagnosticText(validation.message);
    this.previewValid = false;
  }

  private hasCurrentValidPreview(): boolean {
    const value = this.importValue();
    return value.length > 0 && this.previewValid && this.previewMatchesImport;
  }

  private async addManualNodeIfUnique(
    context: common.Context,
    name: string,
    outboundJson: string,
    configType?: XrayConfigType
  ): Promise<boolean> {
    const result = await SubscriptionStore.addManualNodeIfUnique(
      context, name, outboundJson, configType, false);
    return result.added;
  }

  private t(key: string): string {
    return translate(this.language, key);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (_error) {
      // Import state and navigation remain authoritative if the page loses its
      // ArkUI window while a camera, album, clipboard, or save task completes.
    }
  }

  private f1(key: string, name: string, value: string): string {
    return formatOne(this.language, key, name, value);
  }

  private errorMessage(error: Object): string {
    const record = error as Record<string, Object>;
    const message = record['message'];
    if (typeof message === 'string' && message.length > 0) {
      return redactDiagnosticText(message);
    }
    return redactDiagnosticText(JSON.stringify(error));
  }
}
