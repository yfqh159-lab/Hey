import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { resolveImportedNodeName } from '../core/ImportedNodeNames';
import { AppLanguage, XrayConfigType } from '../core/Profile';
import { NODES_CONTROLLER } from '../features/nodes/NodesController';
import { extractNodeEndpoint, formatEndpointDescription } from '../features/nodes/NodeOperations';
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
  @State private linkPreviewTitle: string = '';
  @State private linkPreviewDetail: string = '';
  @State private linkPreviewValid: boolean = false;
  // 只有用户看到当前输入对应的脱敏摘要后，下一次点击才允许入库。输入一旦变化立即失效。
  private previewedImportValue: string = '';
  private pageActive: boolean = false;
  private pageGeneration: number = 0;

  aboutToAppear(): void {
    this.pageActive = true;
    this.isBusy = false;
    this.pageGeneration++;
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.pageGeneration++;
    // 分享链接的手动输入同样可能包含 UUID、密码或 Token。返回栈可能保留页面实例，
    // 因此离开时主动清除输入、预览和旧错误，而不是假设组件会立即销毁。
    this.clearManualImportValue();
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
          // 完整 JSON 配置的底层兼容与既有节点编辑同样保留，但不再在日常“添加节点”
          // 路径提供新建入口，避免引导普通用户创建多入站/多出站配置。

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
          .enabled(!this.isBusy)
          .onChange((value: string) => {
            this.importBuffer = value;
            this.lastError = '';
            this.clearLinkPreview();
          })

        if (this.importBuffer.length > 0) {
          Button() {
            Text('✕')
              .fontSize(FontSz.footnote)
              .fontColor(AppColor.textSecondary)
              .fontWeight(FontWeight.Bold)
          }
          .backgroundColor(AppColor.surfaceAlt)
          .enabled(!this.isBusy)
          .width(28)
          .height(28)
          .borderRadius(14)
          .margin({ right: Space.md })
          .onClick(() => {
            this.importBuffer = '';
            this.lastError = '';
            this.clearLinkPreview();
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

    if (this.linkPreviewTitle.length > 0) {
      Column({ space: Space.xs + 2 }) {
        Text(this.linkPreviewTitle)
          .fontSize(FontSz.body)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.linkPreviewValid ? AppColor.success : AppColor.danger)
          .width('100%')
        Text(this.linkPreviewDetail)
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textSecondary)
          .width('100%')
          .lineHeight(17)
      }
      .width('100%')
      .padding(Space.md)
      .backgroundColor(this.linkPreviewValid ? AppColor.successTint : AppColor.dangerTint)
      .borderRadius(Radius.md)
    }

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
          Text(this.t(this.linkPreviewValid ? 'action.importResult' : 'import.parseButton'))
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
        if (this.linkPreviewValid && this.previewedImportValue === this.importBuffer.trim()) {
          this.importLink();
        } else {
          this.previewLink();
        }
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

  private async importLink(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    const value = this.importBuffer.trim();
    if (value.length === 0) {
      this.lastError = this.t('error.emptyImport');
      return;
    }

    this.isBusy = true;
    const pageGeneration = this.pageGeneration;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      if (value.toLowerCase().startsWith('http://') || value.toLowerCase().startsWith('https://')) {
        this.lastError = this.t('error.importSubscriptionNotAllowed');
        this.clearLinkPreview();
        return;
      }

      // 任何未经过当前输入预览的调用都只能回到预览阶段，不能绕过二次确认。
      if (!this.linkPreviewValid || this.previewedImportValue !== value) {
        this.previewLink();
        return;
      }

      // 链接导入只做纯校验和节点入库，不提前改写当前 Profile。否则重复导入、解析失败或
      // 批量内容中的中间条目会悄悄切换正在使用的节点，甚至触发无意的运行中重连。
      const validation = NODES_CONTROLLER.validateConfig(value, this.language);
      if (!validation.valid) {
        const nativeResult = convertNativeShareTextToOutbounds(value);
        if (!nativeResult.ok) {
          this.lastError = nativeResult.message.length > 0 ?
            redactDiagnosticText(`${validation.message}\n${nativeResult.message}`) :
            redactDiagnosticText(validation.message);
          this.clearLinkPreview();
          return;
        }

        let importedCount = 0;
        let duplicateCount = 0;
        let lastValidationError = '';
        for (let index = 0; index < nativeResult.outbounds.length; index++) {
          const outbound = nativeResult.outbounds[index];
          const imported = NODES_CONTROLLER.validateConfig(outbound.outboundJson, this.language, 'outbound');
          if (!imported.valid) {
            lastValidationError = imported.message;
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
            redactDiagnosticText(lastValidationError.length > 0 ? lastValidationError : validation.message);
          return;
        }

        try {
          this.getUIContext().getPromptAction().showToast({
          message: importedCount === 1 ? this.t('import.nodeImported') : this.f1('import.nodesImported', 'count', importedCount.toString())
        });
        } catch (err) {
          // ignore
        }
        this.clearManualImportValue();
        this.getUIContext().getRouter().back();
        return;
      }

      const nodeName = resolveImportedNodeName(validation.normalizedJson, this.t('import.linkNodeName'));
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
        return;
      }
      if (!this.isCurrentPage(pageGeneration)) {
        return;
      }
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('import.nodeImported') });
      } catch (err) {
        // ignore
      }
      this.clearManualImportValue();
      this.getUIContext().getRouter().back();
    } catch (error) {
      if (this.isCurrentPage(pageGeneration)) {
        this.lastError = this.f1('import.parseFailed', 'error', redactDiagnosticText(JSON.stringify(error)));
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

  private previewLink(): void {
    const value = this.importBuffer.trim();
    this.lastError = '';
    this.clearLinkPreview();
    if (value.length === 0) {
      this.lastError = this.t('error.emptyImport');
      return;
    }
    if (value.toLowerCase().startsWith('http://') || value.toLowerCase().startsWith('https://')) {
      this.lastError = this.t('error.importSubscriptionNotAllowed');
      return;
    }

    const validation = NODES_CONTROLLER.validateConfig(value, this.language);
    if (validation.valid) {
      this.showSingleNodePreview(
        resolveImportedNodeName(validation.normalizedJson, this.t('import.linkNodeName')),
        validation.protocol,
        validation.normalizedJson
      );
      this.previewedImportValue = value;
      return;
    }

    // ArkTS 解析器不覆盖的兼容格式只在用户明确点击“解析”时调用一次 native 转换；
    // 这里只统计通过二次校验的结果，不落库、不切换节点，也不启动网络请求。
    const nativeResult = convertNativeShareTextToOutbounds(value);
    if (nativeResult.ok) {
      let validCount = 0;
      let firstName = '';
      let firstProtocol = '';
      let firstJson = '';
      for (let index = 0; index < nativeResult.outbounds.length; index++) {
        const outbound = nativeResult.outbounds[index];
        const imported = NODES_CONTROLLER.validateConfig(outbound.outboundJson, this.language, 'outbound');
        if (!imported.valid) {
          continue;
        }
        validCount++;
        if (validCount === 1) {
          firstName = resolveImportedNodeName(imported.normalizedJson, outbound.name);
          firstProtocol = imported.protocol;
          firstJson = imported.normalizedJson;
        }
      }
      if (validCount === 1) {
        this.showSingleNodePreview(firstName, firstProtocol, firstJson);
        this.previewedImportValue = value;
        return;
      }
      if (validCount > 1) {
        this.linkPreviewTitle = this.f1('scanner.previewNodes', 'count', validCount.toString());
        this.linkPreviewDetail = this.t('scanner.previewNodesDetail');
        this.linkPreviewValid = true;
        this.previewedImportValue = value;
        return;
      }
    }

    this.linkPreviewTitle = this.t('scanner.previewInvalid');
    this.linkPreviewDetail = nativeResult.message.length > 0 ?
      redactDiagnosticText(`${validation.message}\n${nativeResult.message}`) :
      redactDiagnosticText(validation.message);
    this.linkPreviewValid = false;
  }

  private showSingleNodePreview(name: string, protocol: string, normalizedJson: string): void {
    const endpoint = extractNodeEndpoint(normalizedJson);
    const endpointText = formatEndpointDescription(endpoint.address, endpoint.port);
    this.linkPreviewTitle = this.f1('scanner.previewNode', 'name', redactDiagnosticText(name));
    this.linkPreviewDetail = this.f1('scanner.previewProtocol', 'protocol', protocol.toUpperCase());
    if (endpointText.length > 0) {
      this.linkPreviewDetail += `\n${this.f1(
        'scanner.previewEndpoint', 'endpoint', redactDiagnosticText(endpointText))}`;
    }
    this.linkPreviewValid = true;
  }

  private clearLinkPreview(): void {
    this.linkPreviewTitle = '';
    this.linkPreviewDetail = '';
    this.linkPreviewValid = false;
    this.previewedImportValue = '';
  }

  private clearManualImportValue(): void {
    this.importBuffer = '';
    this.lastError = '';
    this.clearLinkPreview();
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
    // 去重与新增必须在节点库存储队列的同一事务中完成；页面先查再加仍有并发窗口。
    const result = await SubscriptionStore.addManualNodeIfUnique(
      context, name, outboundJson, configType, false);
    return result.added;
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
