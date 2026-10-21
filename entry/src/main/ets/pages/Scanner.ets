import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
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
import { ensureReadPasteboardPermission } from '../utils/ClipboardPermission';
import { isScanCancelled, requestCameraPermission, scanQrCode } from '../utils/QrScan';
import { SubscriptionStore } from '../storage/SubscriptionStore';
import { convertNativeShareTextToOutbounds } from '../services/NativeShareConverter';
import { SubscriptionManager } from '../services/SubscriptionManager';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { shouldStartScannerImmediately } from '../core/ScannerLaunch';
import { AppColor } from '../theme/Theme';

@Entry
@Component
struct ScannerPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private importBuffer: string = '';
  @State private hasPendingSensitiveImport: boolean = false;
  @State private lastError: string = '';
  @State private previewTitle: string = '';
  @State private previewDetail: string = '';
  @State private previewValid: boolean = false;
  @State private isBusy: boolean = false;
  @State private hasAutoScanned: boolean = false;
  @State private isPressedScanCard: boolean = false;
  @State private isPressedPhotoCard: boolean = false;
  @State private isPressedImportBtn: boolean = false;
  private startScanImmediate: boolean = false;
  private routeStartScanImmediate: boolean = false;
  private immediateScanTimerId: number = -1;
  // 相机、相册和剪贴板内容可能包含 UUID、密码或订阅 Token。原文只保存在页面实例内，
  // 默认不绑定到可截图的 TextArea；确认导入仍使用这份原始值。
  private pendingSensitiveImport: string = '';

  aboutToAppear(): void {
    try {
      this.routeStartScanImmediate = shouldStartScannerImmediately(
        router.getParams() as Record<string, Object>
      );
    } catch (error) {
      this.routeStartScanImmediate = false;
    }
    this.loadState();
  }

  onPageShow(): void {
    this.tryStartImmediateScan();
  }

  aboutToDisappear(): void {
    if (this.immediateScanTimerId >= 0) {
      clearTimeout(this.immediateScanTimerId);
      this.immediateScanTimerId = -1;
    }
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
                Button(this.t('action.paste'))
                  .fontSize(12)
                  .fontColor(AppColor.textSecondary)
                  .backgroundColor(AppColor.border)
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .borderRadius(6)
                  .onClick(() => {
                    this.pasteFromClipboard();
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
              placeholder: this.hasPendingSensitiveImport ?
                this.t('scanner.reviewBeforeImport') : this.t('placeholder.scannerPayload'),
              text: this.importBuffer
            })
              .height(160)
              .fontSize(13)
              .fontColor(AppColor.textPrimary)
              .backgroundColor(AppColor.surfaceAlt)
              .enabled(!this.hasPendingSensitiveImport)
              .opacity(this.hasPendingSensitiveImport ? 0.72 : 1.0)
              .borderRadius(10)
              .padding(12)
              .onChange((value: string) => {
                if (this.hasPendingSensitiveImport) {
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
              Text(this.t('action.importResult'))
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
    return this.hasImportValue() && !this.isBusy;
  }

  private hasImportValue(): boolean {
    return this.pendingSensitiveImport.length > 0 || this.importBuffer.trim().length > 0;
  }

  private importValue(): string {
    return this.pendingSensitiveImport.length > 0 ? this.pendingSensitiveImport : this.importBuffer.trim();
  }

  private setSensitiveImportValue(value: string): void {
    this.pendingSensitiveImport = value.trim();
    this.hasPendingSensitiveImport = this.pendingSensitiveImport.length > 0;
    this.importBuffer = '';
  }

  private clearImportValue(): void {
    this.pendingSensitiveImport = '';
    this.hasPendingSensitiveImport = false;
    this.importBuffer = '';
    this.lastError = '';
    this.updateImportPreview('');
  }

  private async loadState(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const settings = await SETTINGS_CONTROLLER.load(context);
      this.language = settings.language;
      this.startScanImmediate = this.routeStartScanImmediate || settings.startScanImmediate;
      this.tryStartImmediateScan();
    } catch (error) {
      this.lastError = this.f1('scanner.loadStateFailed', 'error', redactDiagnosticText(JSON.stringify(error)));
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
      this.startCameraScan();
    }, 300);
  }

  private async startCameraScan(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.lastError = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (!await requestCameraPermission(context)) {
        this.lastError = this.t('scanner.cameraPermissionDenied');
        return;
      }
      await this.importScannedValue(await scanQrCode(context));
    } catch (error) {
      console.error('Scan barcode failed or cancelled:', redactDiagnosticText(JSON.stringify(error)));
      if (!isScanCancelled(error)) {
        this.lastError = this.f1('scanner.scanFailed', 'error', this.errorMessage(error));
      }
    } finally {
      this.isBusy = false;
    }
  }

  private async selectPhotoQr(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.lastError = '';
    try {
      const photoSelectOptions = new picker.PhotoSelectOptions();
      photoSelectOptions.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      const photoPicker = new picker.PhotoViewPicker();
      const result = await photoPicker.select(photoSelectOptions);
      if (!result || !result.photoUris || result.photoUris.length === 0) {
        return;
      }

      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false
      };
      const results = await detectBarcode.decode({ uri: result.photoUris[0] }, options);
      await this.importScannedValue(this.firstScanValue(results), this.t('scanner.decodeFailed'));
    } catch (error) {
      console.error('Decode QR image failed or cancelled:', redactDiagnosticText(JSON.stringify(error)));
      if (!isScanCancelled(error)) {
        this.lastError = this.f1('scanner.photoImportFailed', 'error', this.errorMessage(error));
      }
    } finally {
      this.isBusy = false;
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
    this.setSensitiveImportValue(value);
    this.lastError = '';
    // A completed camera/photo result is stable input, so it is safe to run the
    // native compatibility fallback once. Do not do that for every keystroke.
    this.updateImportPreview(this.pendingSensitiveImport, true);
    // 扫码/相册只负责识别并展示脱敏摘要。必须由用户检查摘要后再次点击导入，
    // 才允许保存节点或订阅来源；订阅内容仍需在订阅页由用户主动更新。
    promptAction.showToast({ message: this.t('scanner.reviewBeforeImport') });
  }

  private async pasteFromClipboard(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      if (!await ensureReadPasteboardPermission(context)) {
        promptAction.showToast({ message: this.t('prompt.clipboardReadFailed') });
        return;
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (systemPasteboard.hasDataSync()) {
        const pasteData = await systemPasteboard.getData();
        const text = pasteData.getPrimaryText();
        if (text && text.trim().length > 0) {
          this.setSensitiveImportValue(text);
          this.lastError = '';
          this.updateImportPreview(this.pendingSensitiveImport, true);
          promptAction.showToast({ message: this.t('prompt.pastedConfig') });
        } else {
          promptAction.showToast({ message: this.t('prompt.clipboardTextEmpty') });
        }
      } else {
        promptAction.showToast({ message: this.t('prompt.clipboardNoData') });
      }
    } catch (error) {
      promptAction.showToast({ message: this.t('prompt.clipboardReadFailed') });
    }
  }

  private async importResult(): Promise<void> {
    const value = this.importValue();
    if (value.length === 0) {
      this.lastError = this.t('error.emptyImport');
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
      return;
    }

    this.isBusy = true;
    this.lastError = '';
    try {
      const context = getContext(this) as common.Context;
      // 判定是否是订阅地址
      if (value.toLowerCase().startsWith('http://') || value.toLowerCase().startsWith('https://')) {
        const validationMessage = SubscriptionManager.validateSubscriptionUrl(value, false);
        if (validationMessage.length > 0) {
          this.lastError = localizeCoreMessage(this.language, validationMessage);
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }

        const existingProfile = await SubscriptionStore.load(context);
        const existingGroup = SubscriptionStore.findGroupByUrl(existingProfile.groups, value);
        if (existingGroup !== null) {
          await SUBSCRIPTIONS_CONTROLLER.selectGroup(context, existingGroup, this.language);
          const duplicateMessage = this.t('scanner.subscriptionAlreadyAdded');
          SHARED_RUNTIME_CONTROLLER.appendLog(duplicateMessage);
          promptAction.showToast({ message: duplicateMessage });
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
        if (SubscriptionStore.findGroupByUrl(state.subscriptionGroups, value) === null) {
          this.lastError = state.subscriptionMessage;
          SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
          return;
        }
        const addedMessage = this.t('scanner.subscriptionAdded');
        SHARED_RUNTIME_CONTROLLER.appendLog(addedMessage);
        promptAction.showToast({ message: addedMessage });
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
          promptAction.showToast({ message: batchMessage });
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
        promptAction.showToast({ message: successMessage });
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
        this.lastError = this.f1('scanner.duplicateNode', 'name', nodeName);
        SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
        return;
      }
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('log.profileSaved'));
      promptAction.showToast({ message: this.t('scanner.nodeImported') });
      router.back();
    } catch (error) {
      this.lastError = this.f1('error.saveProfile', 'error', redactDiagnosticText(JSON.stringify(error)));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.lastError);
    } finally {
      this.isBusy = false;
    }
  }

  private updateImportPreview(value: string, allowNativeFallback: boolean = false): void {
    const input = value.trim();
    if (input.length === 0) {
      this.previewTitle = '';
      this.previewDetail = '';
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
      return;
    }
    const parsedNodes = SubscriptionManager.parseSubscriptionContent(input, '');
    if (parsedNodes.length > 0) {
      this.previewTitle = this.f1('scanner.previewNodes', 'count', parsedNodes.length.toString());
      this.previewDetail = this.t('scanner.previewNodesDetail');
      this.previewValid = true;
      return;
    }
    // libXray accepts a few compatibility formats beyond the ArkTS parser. A
    // completed scan/photo/clipboard result must not be labelled invalid when
    // the confirmation action can actually import it. This path is deliberately
    // skipped while the user is typing to avoid synchronous N-API work per key.
    if (allowNativeFallback) {
      const nativeResult = convertNativeShareTextToOutbounds(input);
      if (nativeResult.ok && nativeResult.outbounds.length > 0) {
        this.previewTitle = this.f1('scanner.previewNodes', 'count', nativeResult.outbounds.length.toString());
        this.previewDetail = this.t('scanner.previewNodesDetail');
        this.previewValid = true;
        return;
      }
    }
    this.previewTitle = this.t('scanner.previewInvalid');
    this.previewDetail = redactDiagnosticText(validation.message);
    this.previewValid = false;
  }

  private async addManualNodeIfUnique(
    context: common.Context,
    name: string,
    outboundJson: string,
    configType?: XrayConfigType
  ): Promise<boolean> {
    const duplicate = await SubscriptionStore.findDuplicateNode(context, outboundJson, configType);
    if (duplicate !== null) {
      return false;
    }
    await SubscriptionStore.addManualNode(context, name, outboundJson, configType, false);
    return true;
  }

  private t(key: string): string {
    return translate(this.language, key);
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
