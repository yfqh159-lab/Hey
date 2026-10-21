import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { AppLanguage, ProxyNode, SubscriptionGroup } from '../core/Profile';
import { formatOutboundJsonToShareLink } from '../core/ShareLinkParser';
import { buildNodeExportModel, NodeExportModel } from '../features/nodes/NodeOperations';
import { buildNodeDetailSections, NodeDetailSection } from '../features/nodes/NodeDetailFields';
import { NODES_CONTROLLER } from '../features/nodes/NodesController';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { shareText, TextShareResult } from '../services/SystemShare';
import { PageHeader } from '../shell/PageHeader';
import { formatOne } from '../utils/LocalizationPresenter';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';

interface ExportRouteParams {
  nodeId?: string;
}

interface ExportLine {
  n: string;
  text: string;
}

const MAX_PREVIEW_LINES: number = 14;
const CODE_BG: string = '#0E1116';
const CODE_LINE_NO: string = '#444B55';
const CODE_TEXT: string = '#8B94A3';

@Entry
@Component
struct ExportPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private isStateLoaded: boolean = false;
  @State private mode: string = 'all';
  @State private base64Mode: boolean = false;
  // 全部导出
  @State private exportContent: string = '';
  @State private exportBase64: string = '';
  @State private exportCount: number = 0;
  @State private exportTitle: string = '';
  private nodes: Array<ProxyNode> = [];
  // 单节点分享
  @State private singleAvailable: boolean = false;
  @State private nodeName: string = '';
  @State private nodeProtocol: string = '';
  @State private nodeSecurity: string = '';
  @State private shareLink: string = '';
  @State private qrImage: image.PixelMap | undefined = undefined;
  private nodeId: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as ExportRouteParams;
    this.nodeId = params?.nodeId ?? '';
    this.loadState();
  }

  build() {
    Stack() {
      if (!this.isStateLoaded) {
        Column() {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(AppColor.brand)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(AppColor.bg)
      } else {
        Column() {
          PageHeader({
            title: this.mode === 'single' ? this.t('export.shareTitle') : this.t('export.title'),
            showBack: true
          })

          if (this.singleAvailable) {
            this.Segment()
          }

          Scroll() {
            Column() {
              if (this.mode === 'single') {
                this.SingleContent()
              } else {
                this.AllContent()
              }
            }
            .width('100%')
            .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.xxl })
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top)
        }
        .height('100%')
        .width('100%')
      }
    }
    .height('100%')
    .width('100%')
    .backgroundColor(AppColor.bg)
  }

  // ===== 顶部分段切换 =====
  @Builder
  private Segment() {
    Row({ space: 3 }) {
      this.SegTab('single')
      this.SegTab('all')
    }
    .width('100%')
    .padding(3)
    .backgroundColor(AppColor.surfaceAlt)
    .borderRadius(Radius.md)
    .margin({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.xs })
  }

  @Builder
  private SegTab(seg: string) {
    Row() {
      Text(seg === 'single' ? this.t('export.segSingle') : this.t('export.segAll'))
        .fontSize(FontSz.body)
        .fontWeight(600)
        .fontColor(this.mode === seg ? AppColor.brand : AppColor.textSecondary)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .borderRadius(9)
    .backgroundColor(this.mode === seg ? AppColor.surface : Color.Transparent)
    .shadow(this.mode === seg ? { radius: 4, color: AppColor.shadowCard, offsetX: 0, offsetY: 1 } : undefined)
    .onClick(() => {
      this.mode = seg;
    })
  }

  // ===== 单节点分享 =====
  @Builder
  private SingleContent() {
    Column() {
      Column() {
        if (this.qrImage !== undefined) {
          Image(this.qrImage)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        } else {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(AppColor.brand)
        }
      }
      .width(210)
      .height(210)
      .padding(13)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(Color.White)
      .borderRadius(Radius.lg)
      .border({ width: 0.5, color: AppColor.border })
      .shadow({ radius: 20, color: AppColor.shadowCard, offsetX: 0, offsetY: 6 })
      Text(this.nodeName.length > 0 ? this.nodeName : this.t('export.shareTitle'))
        .fontSize(FontSz.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: Space.lg })
      Row({ space: Space.xs + 2 }) {
        Text(this.nodeProtocol.toUpperCase())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.brand)
          .backgroundColor(AppColor.brandTint)
          .borderRadius(6)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
        if (this.nodeSecurity.length > 0) {
          Text(this.nodeSecurity)
            .fontSize(10.5)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textSecondary)
            .backgroundColor(AppColor.surfaceAlt)
            .borderRadius(6)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
        }
      }
      .margin({ top: 6 })
      Text(this.t('node.detail.qr.hint'))
        .fontSize(FontSz.footnote)
        .fontColor(AppColor.textTertiary)
        .textAlign(TextAlign.Center)
        .margin({ top: 10 })
    }
    .width('100%')
    .padding(22)
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.xl)
    .border({ width: 0.5, color: AppColor.border })
    .clip(true)
    .margin({ bottom: Space.lg })
    .alignItems(HorizontalAlign.Center)

    this.GroupTitle(this.t('node.detail.rawLink'))
    Row({ space: 10 }) {
      Text(this.shareLink.length > 0 ? this.shareLink : this.t('export.empty'))
        .fontFamily('monospace')
        .fontSize(11.5)
        .lineHeight(18)
        .fontColor(this.shareLink.length > 0 ? AppColor.textSecondary : AppColor.textTertiary)
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
      Image($r('app.media.ic_copy'))
        .width(18)
        .height(18)
        .fillColor(AppColor.brand)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(14)
    .backgroundColor(AppColor.surface)
    .borderRadius(14)
    .border({ width: 0.5, color: AppColor.border })
    .margin({ bottom: Space.lg })
    .onClick(() => {
      this.copyShareLink();
    })

    Row({ space: 10 }) {
      Row({ space: 7 }) {
        Image($r('app.media.ic_copy'))
          .width(17)
          .height(17)
          .fillColor(AppColor.onBrand)
        Text(this.t('node.detail.copyLink'))
          .fontSize(FontSz.callout)
          .fontWeight(600)
          .fontColor(AppColor.onBrand)
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(AppColor.brand)
      .borderRadius(Radius.pill)
      .shadow({ radius: 16, color: AppColor.shadowBrand, offsetX: 0, offsetY: 6 })
      .onClick(() => {
        this.copyShareLink();
      })

      Row({ space: 7 }) {
        Image($r('app.media.ic_share'))
          .width(17)
          .height(17)
          .fillColor(AppColor.textPrimary)
        Text(this.t('export.systemShare'))
          .fontSize(FontSz.callout)
          .fontWeight(600)
          .fontColor(AppColor.textPrimary)
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(AppColor.surfaceAlt)
      .borderRadius(Radius.pill)
      .border({ width: 0.5, color: AppColor.border })
      .onClick(() => {
        this.shareSingleNode();
      })
    }
    .width('100%')
  }

  // ===== 全部导出 =====
  @Builder
  private AllContent() {
    Row({ space: 10 }) {
      Row() {
        Text(this.f1('export.nodeCount', 'count', this.exportCount.toString()))
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.brand)
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(AppColor.brandTint)
      .borderRadius(Radius.pill)

      Blank()

      Row() {
        this.FmtTab('plain')
        this.FmtTab('base64')
      }
      .padding(2)
      .backgroundColor(AppColor.surfaceAlt)
      .borderRadius(9)
    }
    .width('100%')
    .padding({ left: 2, right: 2, bottom: 10 })

    // 代码块
    Column() {
      if (this.base64Mode) {
        Text(this.exportBase64.length > 0 ? this.exportBase64 : this.t('export.empty'))
          .fontFamily('monospace')
          .fontSize(10.5)
          .fontColor(CODE_TEXT)
          .width('100%')
          .maxLines(MAX_PREVIEW_LINES)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else if (this.exportCount === 0) {
        Text(this.t('export.empty'))
          .fontFamily('monospace')
          .fontSize(10.5)
          .fontColor(CODE_TEXT)
          .width('100%')
      } else {
        ForEach(this.previewLines(), (line: ExportLine, index: number) => {
          Row({ space: 10 }) {
            Text(line.n)
              .fontFamily('monospace')
              .fontSize(10)
              .fontColor(CODE_LINE_NO)
              .width(16)
              .textAlign(TextAlign.End)
            // break-all：分享链接是无空格长串，默认按词断行会让单行只剩 "ss://…"，需允许任意字符断行
            Text(line.text)
              .fontFamily('monospace')
              .fontSize(10.5)
              .fontColor(CODE_TEXT)
              .layoutWeight(1)
              .maxLines(1)
              .wordBreak(WordBreak.BREAK_ALL)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 3, bottom: 3 })
        }, (line: ExportLine, index: number) => `${index}-${line.n}`)

        if (this.totalLineCount() > MAX_PREVIEW_LINES) {
          Text(this.f1('export.totalLines', 'count', this.totalLineCount().toString()))
            .fontSize(11)
            .fontColor(CODE_LINE_NO)
            .margin({ top: Space.sm })
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(CODE_BG)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
    .clip(true)
    .margin({ bottom: Space.md })

    Text(this.t('export.copyHint'))
      .fontSize(FontSz.footnote)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 14 })

    Row({ space: Space.sm }) {
      Column({ space: 3 }) {
        Image($r('app.media.ic_copy'))
          .width(18)
          .height(18)
          .fillColor(AppColor.textSecondary)
        Text(this.t('export.btnCopy'))
          .fontSize(11.5)
          .fontWeight(600)
          .fontColor(AppColor.textPrimary)
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(AppColor.surfaceAlt)
      .borderRadius(Radius.pill)
      .border({ width: 0.5, color: AppColor.border })
      .onClick(() => {
        this.copyExportContent();
      })

      Column({ space: 3 }) {
        Image($r('app.media.ic_article'))
          .width(18)
          .height(18)
          .fillColor(AppColor.textSecondary)
        Text(this.t('export.btnFile'))
          .fontSize(11.5)
          .fontWeight(600)
          .fontColor(AppColor.textPrimary)
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(AppColor.surfaceAlt)
      .borderRadius(Radius.pill)
      .border({ width: 0.5, color: AppColor.border })
      .onClick(() => {
        this.saveExportFile();
      })

      Row({ space: 7 }) {
        Image($r('app.media.ic_share'))
          .width(17)
          .height(17)
          .fillColor(AppColor.onBrand)
        Text(this.t('action.share'))
          .fontSize(FontSz.body)
          .fontWeight(600)
          .fontColor(AppColor.onBrand)
      }
      .layoutWeight(1.4)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(AppColor.brand)
      .borderRadius(Radius.pill)
      .shadow({ radius: 16, color: AppColor.shadowBrand, offsetX: 0, offsetY: 6 })
      .onClick(() => {
        this.shareExportContent();
      })
    }
    .width('100%')
  }

  @Builder
  private FmtTab(fmt: string) {
    Text(fmt === 'base64' ? this.t('export.base64') : this.t('export.plain'))
      .fontSize(FontSz.footnote)
      .fontWeight(this.isFmt(fmt) ? 600 : FontWeight.Normal)
      .fontColor(this.isFmt(fmt) ? AppColor.textPrimary : AppColor.textTertiary)
      .padding({ left: 11, right: 11, top: 4, bottom: 4 })
      .borderRadius(7)
      .backgroundColor(this.isFmt(fmt) ? AppColor.surface : Color.Transparent)
      .shadow(this.isFmt(fmt) ? { radius: 3, color: AppColor.shadowCard, offsetX: 0, offsetY: 1 } : undefined)
      .onClick(() => {
        this.base64Mode = (fmt === 'base64');
      })
  }

  @Builder
  private GroupTitle(title: string) {
    Text(title)
      .fontSize(FontSz.footnote)
      .fontWeight(FontWeight.Bold)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ left: 2, right: 2, top: 2, bottom: Space.sm })
  }

  // ===== 数据 =====
  private isFmt(fmt: string): boolean {
    return (fmt === 'base64') === this.base64Mode;
  }

  private showToast(text: string): void {
    promptAction.showToast({ message: text });
  }

  private previewLines(): Array<ExportLine> {
    const lines = this.contentLines();
    const limit = Math.min(lines.length, MAX_PREVIEW_LINES);
    const result: Array<ExportLine> = [];
    for (let i = 0; i < limit; i++) {
      result.push({ n: (i + 1).toString(), text: lines[i] });
    }
    return result;
  }

  private totalLineCount(): number {
    return this.contentLines().length;
  }

  private contentLines(): Array<string> {
    const raw = this.exportContent.split('\n');
    const result: Array<string> = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].trim().length > 0) {
        result.push(raw[i]);
      }
    }
    return result;
  }

  private currentContent(): string {
    return this.base64Mode ? this.exportBase64 : this.exportContent;
  }

  private async loadState(): Promise<void> {
    this.isStateLoaded = false;
    const context = getContext(this) as common.Context;
    this.language = (await SETTINGS_CONTROLLER.load(context)).language;
    const state = await NODES_CONTROLLER.load(context, this.language);

    // 始终准备好「全部导出」内容
    this.nodes = state.nodes;
    const model: NodeExportModel = buildNodeExportModel(this.t('export.nodesTitle'), this.nodes);
    this.exportTitle = model.title;
    this.exportContent = model.content;
    this.exportCount = model.count;
    this.exportBase64 = this.encodeBase64(model.content);

    // 单节点分享（带 nodeId 进入）
    if (this.nodeId.length > 0) {
      const node = this.findNode(state.subscriptionGroups, this.nodeId);
      if (node !== null) {
        this.singleAvailable = true;
        this.mode = 'single';
        this.nodeName = node.name;
        this.nodeProtocol = node.protocol;
        this.nodeSecurity = this.extractSecurity(node);
        this.shareLink = formatOutboundJsonToShareLink(node.outboundJson, node.name);
        this.isStateLoaded = true;
        this.generateQr(this.shareLink);
        return;
      }
    }

    this.mode = 'all';
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.exportPrepared', 'count', this.exportCount.toString()));
    this.isStateLoaded = true;
  }

  private extractSecurity(node: ProxyNode): string {
    const sections: Array<NodeDetailSection> = buildNodeDetailSections(node.outboundJson, node.protocol);
    for (let i = 0; i < sections.length; i++) {
      const fields = sections[i].fields;
      for (let j = 0; j < fields.length; j++) {
        if (fields[j].labelKey === 'node.field.security') {
          return fields[j].value;
        }
      }
    }
    return '';
  }

  private findNode(groups: Array<SubscriptionGroup>, nodeId: string): ProxyNode | null {
    for (let i = 0; i < groups.length; i++) {
      const group = groups[i];
      for (let j = 0; j < group.nodes.length; j++) {
        if (group.nodes[j].id === nodeId) {
          return group.nodes[j];
        }
      }
    }
    return null;
  }

  private encodeBase64(text: string): string {
    if (text.length === 0) {
      return '';
    }
    try {
      const bytes = new util.TextEncoder().encodeInto(text);
      return new util.Base64Helper().encodeToStringSync(bytes);
    } catch (error) {
      return '';
    }
  }

  private async generateQr(link: string): Promise<void> {
    if (link.length === 0) {
      return;
    }
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        height: 600,
        width: 600
      };
      this.qrImage = await generateBarcode.createBarcode(link, options);
    } catch (error) {
      this.showToast(this.f1('error.qrGenerate', 'error', redactDiagnosticText(JSON.stringify(error))));
    }
  }

  private copyShareLink(): void {
    if (this.shareLink.length === 0) {
      this.showToast(this.t('export.empty'));
      return;
    }
    this.writeClipboard(this.shareLink);
    this.showToast(this.t('node.detail.copied'));
  }

  private async shareSingleNode(): Promise<void> {
    if (this.shareLink.length === 0) {
      this.showToast(this.t('export.empty'));
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const result = await shareText(context, this.nodeName, this.shareLink);
    this.handleShareResult(result);
  }

  private copyExportContent(): void {
    const content = this.currentContent();
    if (content.trim().length === 0) {
      this.showToast(this.t('export.empty'));
      return;
    }
    this.writeClipboard(content.trim());
    this.showToast(this.t('prompt.copiedToClipboard'));
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.exportCopied', 'count', this.exportCount.toString()));
  }

  private async saveExportFile(): Promise<void> {
    const content = this.currentContent();
    if (content.trim().length === 0) {
      this.showToast(this.t('export.empty'));
      return;
    }
    try {
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [this.defaultExportFileName()];
      saveOptions.fileSuffixChoices = ['.txt'];
      const documentPicker = new picker.DocumentViewPicker();
      const uris = await documentPicker.save(saveOptions);
      if (!uris || uris.length === 0) {
        return;
      }
      this.writeTextToUri(uris[0], content.trim() + '\n');
      this.showToast(this.t('export.fileSuccess'));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('export.fileSuccess'));
    } catch (error) {
      this.showToast(this.f1('export.fileFailed', 'error', redactDiagnosticText(JSON.stringify(error))));
    }
  }

  private async shareExportContent(): Promise<void> {
    const content = this.currentContent();
    if (content.trim().length === 0) {
      this.showToast(this.t('export.empty'));
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const result = await shareText(context, this.exportTitle, content);
    this.handleShareResult(result);
  }

  private handleShareResult(result: TextShareResult): void {
    if (result.systemShareStarted) {
      this.showToast(this.t('share.started'));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('share.started'));
      return;
    }
    if (result.copiedToClipboard) {
      this.showToast(this.t('share.fallbackCopied'));
      SHARED_RUNTIME_CONTROLLER.appendLog(this.t('share.fallbackCopied'));
      return;
    }
    this.showToast(this.f1('share.failed', 'error', result.errorMessage));
  }

  private writeClipboard(value: string): void {
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      pasteboard.getSystemPasteboard().setDataSync(pasteData);
    } catch (error) {
      // 复制失败仍给出反馈
    }
  }

  private writeTextToUri(uri: string, content: string): void {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  private defaultExportFileName(): string {
    const date = new Date();
    const stamp = `${date.getFullYear()}${this.pad2(date.getMonth() + 1)}${this.pad2(date.getDate())}-${this.pad2(date.getHours())}${this.pad2(date.getMinutes())}${this.pad2(date.getSeconds())}`;
    const suffix = this.base64Mode ? '-base64' : '';
    return `hey-nodes-${stamp}${suffix}.txt`;
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : value.toString();
  }

  private t(key: string): string {
    return translate(this.language, key);
  }

  private f1(key: string, name: string, value: string): string {
    return formatOne(this.language, key, name, value);
  }
}
