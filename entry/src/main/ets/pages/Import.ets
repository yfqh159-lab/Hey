import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { resolveImportedNodeName } from '../core/ImportedNodeNames';
import { AppLanguage, XrayConfigType } from '../core/Profile';
import { markRuntimeSettingsRestartNeeded } from '../core/SettingsChange';
import { NODES_CONTROLLER } from '../features/nodes/NodesController';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { AppRoute } from '../shell/AppRoute';
import { SectionHeader } from '../components/SectionHeader';
import { PageHeader } from '../shell/PageHeader';
import { SubscriptionStore } from '../storage/SubscriptionStore';
import { convertNativeShareTextToOutbounds } from '../services/NativeShareConverter';
import { formatOne } from '../utils/LocalizationPresenter';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';

@Entry
@Component
struct ImportPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private importBuffer: string = '';
  @State private lastError: string = '';
  @State private isBusy: boolean = false;

  aboutToAppear(): void {
    this.loadState();
  }

  build() {
    Column() {
      PageHeader({
        title: this.t('screen.import.title'),
        showBack: true
      })
      Scroll() {
        Column({ space: Space.lg }) {
          // 模块一：解析协议链接 / 扫码
          this.LinkImportSection()

          // 模块二：手动协议配置
          this.ManualGridSection()

          // 项目默认只创建单节点、单跳配置。代理链/策略组的底层兼容与既有节点编辑保留，
          // 但不再在日常“添加节点”路径提供新建入口。

          // 模块三：自定义 JSON 配置
          this.JsonImportSection()

          if (this.lastError.length > 0) {
            Text(this.lastError)
              .fontSize(FontSz.footnote)
              .fontColor(AppColor.danger)
              .width('100%')
              .padding(Space.md)
              .backgroundColor(AppColor.dangerTint)
              .borderRadius(Radius.md)
          }
        }
        .width('100%')
        .padding({ left: Space.lg, right: Space.lg, top: Space.sm, bottom: Space.xxl })
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

  // 1. 扫码与链接导入区
  @Builder
  private LinkImportSection() {
    SectionHeader({ title: this.t('import.linkSection'), sidePadding: 0 })
    Column() {
      Row() {
        Image($r('app.media.ic_link'))
          .width(20)
          .height(20)
          .fillColor(AppColor.textSecondary)
          .margin({ left: Space.lg, right: Space.sm })

        TextInput({
          placeholder: this.t('import.linkPlaceholder'),
          text: this.importBuffer
        })
          .layoutWeight(1)
          .height(48)
          .fontSize(FontSz.body)
          .fontColor(AppColor.textPrimary)
          .placeholderColor(AppColor.textTertiary)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.importBuffer = value;
          })

        if (this.importBuffer.length > 0) {
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
          .margin({ right: Space.md })
          .onClick(() => {
            this.importBuffer = '';
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .clip(true)
    Text(this.t('import.linkDetail'))
      .fontSize(FontSz.footnote)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .lineHeight(16)
      .padding({ left: Space.xs, right: Space.xs })

    Row({ space: Space.md }) {
      Button() {
        Row() {
          if (this.isBusy) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(AppColor.onBrand)
              .margin({ right: Space.xs + 2 })
          }
          Text(this.t('import.parseButton'))
            .fontSize(FontSz.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.importBuffer.trim().length > 0 ? AppColor.onBrand : AppColor.textTertiary)
        }
      }
      .height(46)
      .layoutWeight(1)
      .enabled(!this.isBusy && this.importBuffer.trim().length > 0)
      .backgroundColor(this.importBuffer.trim().length > 0 ? AppColor.brand : AppColor.surfaceAlt)
      .borderRadius(Radius.pill)
      .onClick(() => {
        this.importLink();
      })

      Button() {
        Row({ space: Space.xs + 2 }) {
          Image($r('app.media.ic_qr_code'))
            .width(18)
            .height(18)
            .fillColor(AppColor.textSecondary)
          Text(this.t('import.scanButton'))
            .fontSize(FontSz.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textSecondary)
        }
      }
      .height(46)
      .padding({ left: Space.lg, right: Space.lg })
      .backgroundColor(AppColor.surfaceAlt)
      .borderRadius(Radius.pill)
      .onClick(() => {
        this.getUIContext().getRouter().pushUrl({
          url: AppRoute.SCANNER,
          params: {
            startImmediately: true
          }
        });
      })
    }
    .width('100%')  }

  // 2. 手动协议配置列表
  @Builder
  private ManualGridSection() {
    SectionHeader({ title: this.t('import.manualSection'), sidePadding: 0 })
    Column() {
      this.ProtocolRow('vless')
      this.RowDivider()
      this.ProtocolRow('vmess')
      this.RowDivider()
      this.ProtocolRow('trojan')
      this.RowDivider()
      this.ProtocolRow('ss')
      this.RowDivider()
      this.ProtocolRow('socks')
      this.RowDivider()
      this.ProtocolRow('http')
      this.RowDivider()
      this.ProtocolRow('wireguard')
      this.RowDivider()
      this.ProtocolRow('hysteria2')
    }
    .width('100%')
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .clip(true)  }

  @Builder
  private ProtocolRow(protocol: string) {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(this.protocolDisplayTitle(protocol))
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(this.f1('import.protocolDetail', 'protocol', this.protocolDisplayName(protocol)))
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Image($r('app.media.ic_chevron_right'))
        .width(20)
        .height(20)
        .fillColor(AppColor.textTertiary)
    }
    .width('100%')
    .padding(Space.lg)
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({
        url: AppRoute.NODE_EDIT,
        params: { protocol: protocol }
      })
    })
  }

  // 3. 代理链 / 策略组配置入口
  @Builder
  private AdvancedConfigSection() {
    SectionHeader({ title: this.t('import.advancedSection'), sidePadding: 0 })
    Column() {
      this.AdvancedOutboundRow(
        'advancedOutbound.proxyChain',
        'advancedOutbound.proxyChain.detail',
        'proxy-chain'
      )
      this.RowDivider()
      this.AdvancedOutboundRow(
        'advancedOutbound.policyGroup',
        'advancedOutbound.policyGroup.detail',
        'policy-group'
      )
    }
    .width('100%')
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .clip(true)  }

  @Builder
  private AdvancedOutboundRow(titleKey: string, detailKey: string, mode: string) {
    Row({ space: Space.md }) {
      Image($r('app.media.ic_route'))
        .width(20)
        .height(20)
        .fillColor(AppColor.brand)

      Column({ space: 3 }) {
        Text(this.t(titleKey))
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(this.t(detailKey))
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
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
    .padding(Space.lg)
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({
        url: AppRoute.ADVANCED_OUTBOUND,
        params: { mode: mode }
      })
    })
  }

  // 4. 自定义 JSON 导入入口
  @Builder
  private JsonImportSection() {
    SectionHeader({ title: this.t('import.jsonSection'), sidePadding: 0 })
    Column() {
      Row({ space: Space.md }) {
        Column({ space: 3 }) {
          Text(this.t('import.jsonTitle'))
            .fontSize(FontSz.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
          Text(this.t('import.jsonDetail'))
            .fontSize(FontSz.footnote)
            .fontColor(AppColor.textTertiary)
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
      .padding(Space.lg)
      .onClick(() => {
        this.getUIContext().getRouter().pushUrl({ url: AppRoute.JSON_IMPORT });
      })
    }
    .width('100%')
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .clip(true)  }

  private async loadState(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      this.language = (await SETTINGS_CONTROLLER.load(context)).language;
    } catch (error) {
      this.lastError = this.f1('import.loadStateFailed', 'error', JSON.stringify(error));
    }
  }

  private async importLink(): Promise<void> {
    const value = this.importBuffer.trim();
    if (value.length === 0) {
      this.lastError = this.t('error.emptyImport');
      return;
    }

    this.isBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      if (value.toLowerCase().startsWith('http://') || value.toLowerCase().startsWith('https://')) {
        this.lastError = this.t('error.importSubscriptionNotAllowed');
        return;
      }

      const saved = await NODES_CONTROLLER.saveProfile(context, value, this.language);
      if (saved.profile === null) {
        const nativeResult = convertNativeShareTextToOutbounds(value);
        if (!nativeResult.ok) {
          this.lastError = nativeResult.message.length > 0 ? `${saved.lastError}\n${nativeResult.message}` : saved.lastError;
          return;
        }

        let importedCount = 0;
        let duplicateCount = 0;
        let lastValidationError = '';
        for (let index = 0; index < nativeResult.outbounds.length; index++) {
          const outbound = nativeResult.outbounds[index];
          const imported = await NODES_CONTROLLER.saveProfile(context, outbound.outboundJson, this.language, 'outbound');
          if (imported.profile === null) {
            lastValidationError = imported.lastError;
            continue;
          }
          if (!await this.addManualNodeIfUnique(
            context,
            resolveImportedNodeName(imported.profile.outboundJson, outbound.name),
            imported.profile.outboundJson,
            imported.profile.configType
          )) {
            duplicateCount++;
            continue;
          }
          importedCount++;
        }

        if (importedCount === 0) {
          this.lastError = duplicateCount > 0 ?
            this.f1('scanner.duplicateNodes', 'count', duplicateCount.toString()) :
            (lastValidationError.length > 0 ? lastValidationError : saved.lastError);
          return;
        }

        markRuntimeSettingsRestartNeeded();
        try {
          this.getUIContext().getPromptAction().showToast({
          message: importedCount === 1 ? this.t('import.nodeImported') : this.f1('import.nodesImported', 'count', importedCount.toString())
        });
        } catch (err) {
          // ignore
        }
        this.getUIContext().getRouter().back();
        return;
      }

      const nodeName = resolveImportedNodeName(saved.profile.outboundJson, this.t('import.linkNodeName'));
      if (!await this.addManualNodeIfUnique(context, nodeName, saved.profile.outboundJson, saved.profile.configType)) {
        this.lastError = this.f1('scanner.duplicateNode', 'name', nodeName);
        return;
      }
      markRuntimeSettingsRestartNeeded();
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('import.nodeImported') });
      } catch (err) {
        // ignore
      }
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.lastError = this.f1('import.parseFailed', 'error', JSON.stringify(error));
    } finally {
      this.isBusy = false;
    }
  }

  private t(key: string): string {
    return translate(this.language, key);
  }

  private f1(key: string, name: string, value: string): string {
    return formatOne(this.language, key, name, value);
  }

  private async addManualNodeIfUnique(
    context: common.Context,
    name: string,
    outboundJson: string,
    configType?: XrayConfigType
  ): Promise<boolean> {
    if (await SubscriptionStore.findDuplicateNode(context, outboundJson, configType) !== null) {
      return false;
    }
    await SubscriptionStore.addManualNode(context, name, outboundJson, configType);
    return true;
  }

  private protocolDisplayTitle(protocol: string): string {
    return protocol === 'hysteria2' ? 'HY2' : protocol.toUpperCase();
  }

  private protocolDisplayName(protocol: string): string {
    if (protocol === 'ss') {
      return 'Shadowsocks';
    }
    if (protocol === 'wireguard') {
      return 'WireGuard';
    }
    if (protocol === 'hysteria2') {
      return 'Hysteria 2';
    }
    return protocol.toUpperCase();
  }
}
