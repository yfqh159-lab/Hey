import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import { hasDuplicateAssetName, isEditableCustomAssetUrl, isSafeCustomAssetName, normalizeScannedAssetUrl } from '../core/AssetUrls';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { GEOIP_FILE_NAME, GEOSITE_FILE_NAME } from '../core/GeoAssets';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { AppLanguage } from '../core/Profile';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { PageHeader } from '../shell/PageHeader';
import { AssetStore, CustomAssetUrl, GeoUpdateMetadata } from '../storage/AssetStore';
import { ASSETS_CONTROLLER } from '../features/assets/AssetsController';
import { BOTTOM_SAFE_HEIGHT_KEY } from '../core/Immersive';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';
import { formatOne } from '../utils/LocalizationPresenter';
import { isScanCancelled, requestCameraPermission, scanQrCode } from '../utils/QrScan';

// 底部抽屉里渲染的单个选项（选择模式）。已按当前值算好高亮 / 置灰 / 危险色。
interface SheetOption {
  id: string;
  title: string;
  desc: string;
  selected: boolean;
  danger: boolean;
  disabled: boolean;
}

// 抽屉模式：'' 关闭 / 'importType' 导入类型 / 'geoMore' 单资源操作 / 'geoUrl' 自填下载地址 / 'edit' 添加编辑
type SheetKind = '' | 'importType' | 'geoMore' | 'geoUrl' | 'edit';

@Entry
@Component
struct AssetsPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  // 沉浸式底部安全区（home 指示条高度，vp）
  @StorageProp(BOTTOM_SAFE_HEIGHT_KEY) private bottomSafe: number = 0;

  @State private isStateLoaded: boolean = false;

  // 内置 Geo 文件状态
  @State private geositeStatus: string = '';
  @State private geoipStatus: string = '';
  @State private geoUpdateSummary: string = '';
  @State private geoAssetHashes: Record<string, string> = {};

  // 下载状态（正在下载的文件名，空=空闲）
  @State private downloadingFile: string = '';

  // 下载源

  // 自定义资源
  @State private customAssets: Array<CustomAssetUrl> = [];
  @State private customFileStatuses: Record<string, string> = {};
  @State private showCustomUrls: boolean = false;

  // 本地导入 / 扫码的临时暂存，用于编辑抽屉预填
  private tempImportUri: string = '';

  // ===== 底部抽屉状态 =====
  @State private sheetKind: SheetKind = '';
  @State private sheetTitle: string = '';
  @State private sheetHint: string = '';
  @State private sheetOptions: Array<SheetOption> = [];
  private geoMoreFile: string = '';

  // 编辑抽屉字段
  @State private editId: string = '';
  @State private editName: string = '';
  @State private editUrl: string = '';
  @State private editIsLocal: boolean = false;
  @State private geoUrlInput: string = '';

  aboutToAppear(): void {
    this.loadState();
    this.loadCustomAssets();
  }

  // 物理返回键：抽屉打开先关抽屉；在用户资源子页先退回主视图；
  // 否则放行默认返回（离开资源页）。返回 true 表示已消费本次返回。
  onBackPress(): boolean {
    if (this.sheetKind.length > 0) {
      this.closeSheet();
      return true;
    }
    if (this.showCustomUrls) {
      this.showCustomUrls = false;
      return true;
    }
    return false;
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
        // 主视图（资源）
        this.MainView()

        // 用户资源 URL 子页（从右侧滑入）
        this.CustomView()

        // 共享底部抽屉
        this.AssetSheet()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ========================= 主视图 =========================
  @Builder
  private MainView() {
    Column() {
      PageHeader({
        title: this.t('assets.section'),
        summary: this.t('assets.section.detail'),
        showBack: true
      })

      Scroll() {
        Column({ space: Space.lg }) {

          // —— 快捷操作 ——
          this.SectionLabel(this.t('assets.quickActions.title'))
          Column() {
            this.QuickRow(
              $r('app.media.ic_refresh'), AppColor.brand, AppColor.brandTint,
              this.t('assets.action.updateAll'), this.t('assets.action.updateAll.detail'),
              false, true, () => this.checkGeoUpdate()
            )
            this.RowDivider()
            this.QuickRow(
              $r('app.media.ic_folder'), AppColor.textSecondary, AppColor.surfaceAlt,
              this.t('assets.action.importLocal'), this.t('assets.action.importLocal.detail'),
              false, false, () => this.importLocalFile()
            )
            this.RowDivider()
            this.QuickRow(
              $r('app.media.ic_qr_code'), AppColor.success, AppColor.successTint,
              this.t('assets.action.scanQr'), this.t('assets.action.scanQr.detail'),
              false, false, () => this.scanAssetUrlFromQr()
            )
          }
          .width('100%')
          .backgroundColor(AppColor.surface)
          .borderRadius(Radius.lg)
          .border({ width: 0.5, color: AppColor.border })
          .clip(true)

          // —— 核心数据文件（默认可信源一键检查；单文件 URL 位于更多操作）——
          this.SectionLabel(this.t('assets.builtin.title'))
          Column() {
            this.GeoRow(GEOSITE_FILE_NAME, true)
            this.GeoRow(GEOIP_FILE_NAME, false)
            if (this.geoUpdateSummary.length > 0) {
              Divider()
                .strokeWidth(0.5)
                .color(AppColor.divider)
                .margin({ left: Space.lg, right: Space.lg })
              Text(this.geoUpdateSummary)
                .width('100%')
                .fontSize(FontSz.caption)
                .fontColor(AppColor.textTertiary)
                .padding({ left: Space.lg, right: Space.lg, top: Space.sm, bottom: Space.md })
            }
          }
          .width('100%')
          .backgroundColor(AppColor.surface)
          .borderRadius(Radius.lg)
          .border({ width: 0.5, color: AppColor.border })
          .clip(true)

          // —— 用户资源 URL ——
          this.SectionLabel(this.t('assets.userUrls.title'))
          Column() {
            Row({ space: Space.md }) {
              this.RoundIcon($r('app.media.ic_link'), AppColor.success, AppColor.successTint)
              Column({ space: 3 }) {
                Text(this.t('assets.userUrls.title'))
                  .fontSize(FontSz.callout)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.textPrimary)
                Text(this.f1('assets.userUrls.countDetail', 'count', this.customAssets.length.toString()))
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
            .onClick(() => this.openCustomView())
          }
          .width('100%')
          .backgroundColor(AppColor.surface)
          .borderRadius(Radius.lg)
          .border({ width: 0.5, color: AppColor.border })
          .clip(true)
        }
        .width('100%')
        .padding({ left: Space.lg, right: Space.lg, top: Space.sm, bottom: Space.xxl + this.bottomSafe })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bg)
    .translate({ x: this.showCustomUrls ? '-24%' : '0' })
    .animation({ duration: 320, curve: Curve.FastOutSlowIn })
  }

  // ===================== 用户资源 URL 子页 =====================
  @Builder
  private CustomView() {
    Column() {
      PageHeader({
        title: this.t('assets.userUrls.title'),
        summary: '',
        showBack: true,
        onBack: () => { this.showCustomUrls = false; }
      })

      List({ space: Space.md }) {
        ForEach(this.customAssets, (item: CustomAssetUrl) => {
          ListItem() {
            this.CustomRow(item)
          }
          .swipeAction({ end: this.CustomSwipeActions(item) })
        }, (item: CustomAssetUrl) => `${item.id}-${item.name}-${this.customStatusOf(item.name)}-${this.downloadingFile === item.name ? 1 : 0}`)

        ListItem() {
          Text(this.t('assets.userUrls.footerHint'))
            .fontSize(FontSz.footnote)
            .fontColor(AppColor.textTertiary)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.md, bottom: Space.sm })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .padding({ left: Space.lg, right: Space.lg, top: 14, bottom: Space.sm })

      // 底部添加按钮
      Column() {
        Button(this.t('assets.addUrlTitle'))
          .width('100%')
          .height(48)
          .backgroundColor(AppColor.brand)
          .fontColor(AppColor.onBrand)
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .borderRadius(Radius.pill)
          .shadow({ radius: 12, color: AppColor.shadowBrand, offsetX: 0, offsetY: 6 })
          .onClick(() => this.openAddSheet())
      }
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.xl + this.bottomSafe })
      .backgroundColor(AppColor.bg)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bg)
    .shadow(this.showCustomUrls ? { radius: 40, color: 'rgba(0,0,0,0.12)', offsetX: -12, offsetY: 0 } : undefined)
    .translate({ x: this.showCustomUrls ? '0' : '100%' })
    .animation({ duration: 320, curve: Curve.FastOutSlowIn })
  }

  // ===================== 复用小组件 =====================
  @Builder
  private SectionLabel(title: string) {
    Text(title)
      .fontSize(FontSz.footnote)
      .fontWeight(FontWeight.Bold)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ left: Space.xs, bottom: 0 })
  }

  @Builder
  private RowDivider() {
    Divider()
      .strokeWidth(0.5)
      .color(AppColor.divider)
      .margin({ left: 68 })
  }

  @Builder
  private RoundIcon(icon: Resource, color: ResourceColor, bg: ResourceColor) {
    Row() {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(color)
    }
    .width(40)
    .height(40)
    .borderRadius(Radius.pill)
    .backgroundColor(bg)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  // 快捷操作行。spinnerWhenBusy=true 时，下载进行中显示转圈（经 this 读状态，保响应性）。
  @Builder
  private QuickRow(icon: Resource, iconColor: ResourceColor, iconBg: ResourceColor,
                   title: string, subtitle: string, showChevron: boolean, spinnerWhenBusy: boolean,
                   onTap: () => void) {
    Row({ space: Space.md }) {
      this.RoundIcon(icon, iconColor, iconBg)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(subtitle)
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (spinnerWhenBusy && this.downloadingFile.length > 0) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(AppColor.brand)
      } else if (showChevron) {
        Image($r('app.media.ic_chevron_right'))
          .width(20)
          .height(20)
          .fillColor(AppColor.textTertiary)
      }
    }
    .width('100%')
    .padding(Space.lg)
    .onClick(() => onTap())
  }

  // 内置 Geo 资源行。fileName 是稳定标识；状态 / 下载态经 this 读取以保持响应性。
  @Builder
  private GeoRow(fileName: string, showDivider: boolean) {
    Column() {
      Row({ space: Space.md }) {
        this.RoundIcon($r('app.media.ic_article'), AppColor.brand, AppColor.brandTint)
        Column({ space: 3 }) {
          Text(fileName)
            .fontSize(FontSz.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.statusOf(fileName))
            .fontSize(FontSz.footnote)
            .fontColor(AppColor.textTertiary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.downloadingFile === fileName) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(AppColor.brand)
        } else {
          Button() {
            Image($r('app.media.ic_more_vert'))
              .width(20)
              .height(20)
              .fillColor(AppColor.textSecondary)
          }
          .type(ButtonType.Normal)
          .width(34)
          .height(34)
          .borderRadius(10)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.openGeoMoreSheet(fileName))
        }
      }
      .width('100%')
      .padding(Space.lg)

      if (showDivider) {
        this.RowDivider()
      }
    }
    .width('100%')
  }

  @Builder
  private CustomRow(item: CustomAssetUrl) {
    Row({ space: Space.md }) {
      this.RoundIcon($r('app.media.ic_article'), AppColor.success, AppColor.successTint)
      Column({ space: 3 }) {
        Text(item.name)
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.url.startsWith('local://') ? this.t('assets.localImportedLabel') : item.url)
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.customStatusOf(item.name))
          .fontSize(FontSz.caption)
          .fontColor(AppColor.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.downloadingFile === item.name) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(AppColor.brand)
      } else {
        Image($r('app.media.ic_chevron_right'))
          .width(20)
          .height(20)
          .fillColor(AppColor.textTertiary)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
    .onClick(() => this.openEditSheet(item))
  }

  @Builder
  private CustomSwipeActions(item: CustomAssetUrl) {
    Row() {
      if (item.url.startsWith('local://')) {
        this.SwipeButton($r('app.media.ic_folder'), this.t('assets.action.reimportLocal'), AppColor.brand, () => {
          this.reimportLocalCustomAsset(item);
        })
      } else {
        this.SwipeButton($r('app.media.ic_refresh'), this.t('action.update'), AppColor.brand, () => {
          this.downloadCustomAsset(item.name, item.url);
        })
      }
      if (isEditableCustomAssetUrl(item.url)) {
        this.SwipeButton($r('app.media.ic_edit'), this.t('action.edit'), AppColor.textSecondary, () => {
          this.openEditSheet(item);
        })
      }
      this.SwipeButton($r('app.media.ic_delete'), this.t('action.delete'), AppColor.danger, () => {
        this.deleteCustomAsset(item);
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
    .onClick(() => action())
  }

  // ===================== 底部抽屉 =====================
  @Builder
  private AssetSheet() {
    if (this.sheetKind.length > 0) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(AppColor.scrim)
          .onClick(() => this.closeSheet())
          .transition(TransitionEffect.OPACITY.animation({ duration: 240, curve: Curve.EaseOut }))

        Column() {
          // 下拉手柄
          Row()
            .width(38)
            .height(5)
            .borderRadius(Radius.pill)
            .backgroundColor(AppColor.border)
            .margin({ top: 9, bottom: Space.xs })

          // 标题 + 说明 + 关闭
          Row({ space: Space.md }) {
            Column({ space: 2 }) {
              Text(this.sheetTitle)
                .fontSize(FontSz.headline)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.sheetHint.length > 0) {
                Text(this.sheetHint)
                  .fontSize(FontSz.footnote)
                  .fontColor(AppColor.textTertiary)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Stack() {
              Text('✕')
                .fontSize(13)
                .fontColor(AppColor.textSecondary)
            }
            .width(30)
            .height(30)
            .borderRadius(Radius.pill)
            .backgroundColor(AppColor.surfaceAlt)
            .onClick(() => this.closeSheet())
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: Space.lg, right: Space.lg, top: Space.xs, bottom: Space.md })

          if (this.sheetKind === 'edit') {
            this.SheetEditBody()
          } else if (this.sheetKind === 'geoUrl') {
            this.SheetGeoUrlBody()
          } else {
            this.SheetSelectBody()
          }
        }
        .width('100%')
        .backgroundColor(AppColor.surface)
        .borderRadius({ topLeft: 22, topRight: 22 })
        .padding({ bottom: Space.xl + this.bottomSafe })
        .gesture(
          SwipeGesture({ direction: SwipeDirection.Vertical })
            .onAction((event: GestureEvent) => {
              if (event.angle > 45 && event.angle < 135) {
                this.closeSheet();
              }
            })
        )
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: 520 }))
          .animation({ duration: 320, curve: Curve.FastOutSlowIn }))
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  private SheetSelectBody() {
    Column({ space: Space.xs }) {
      ForEach(this.sheetOptions, (opt: SheetOption) => {
        Row({ space: Space.md }) {
          Column({ space: 2 }) {
            Text(opt.title)
              .fontSize(FontSz.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor(opt.disabled ? AppColor.textTertiary
                : opt.danger ? AppColor.danger
                : opt.selected ? AppColor.brand : AppColor.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (opt.desc.length > 0) {
              Text(opt.desc)
                .fontSize(FontSz.footnote)
                .fontColor(AppColor.textTertiary)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (opt.selected) {
            Image($r('app.media.ic_check'))
              .width(22)
              .height(22)
              .fillColor(AppColor.brand)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: Space.md, bottom: Space.md })
        .borderRadius(14)
        .backgroundColor(opt.selected ? AppColor.brandTint : Color.Transparent)
        .opacity(opt.disabled ? 0.5 : 1)
        .onClick(() => {
          if (!opt.disabled) {
            this.onSheetPick(opt.id);
          }
        })
      }, (opt: SheetOption) => `${opt.id}-${opt.selected ? 1 : 0}-${opt.disabled ? 1 : 0}`)
    }
    .width('100%')
    .padding({ left: Space.md, right: Space.md })
  }

  // 高级入口：允许为单个核心文件临时指定自定义下载地址。
  @Builder
  private SheetGeoUrlBody() {
    Column() {
      Text(this.t('assets.urlAddress'))
        .fontSize(FontSz.footnote)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textSecondary)
        .width('100%')
        .margin({ bottom: 6 })
      TextInput({ text: this.geoUrlInput, placeholder: 'https://example.com/geosite.dat' })
        .height(46)
        .fontSize(FontSz.callout)
        .fontColor(AppColor.textPrimary)
        .placeholderColor(AppColor.textTertiary)
        .backgroundColor(AppColor.surfaceAlt)
        .borderRadius(Radius.md)
        .onChange((value: string) => { this.geoUrlInput = value; })

      Button(this.t('action.update'))
        .width('100%')
        .height(48)
        .backgroundColor(AppColor.brand)
        .fontColor(AppColor.onBrand)
        .fontSize(FontSz.callout)
        .fontWeight(FontWeight.Medium)
        .borderRadius(Radius.pill)
        .margin({ top: Space.xl })
        .onClick(() => this.downloadGeoFromUrl())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.lg, right: Space.lg })
  }

  private async downloadGeoFromUrl(): Promise<void> {
    const url = this.geoUrlInput.trim();
    const fileName = this.geoMoreFile;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.toast(this.t('assets.scanInvalidUrl'));
      return;
    }
    this.closeSheet();
    if (this.downloadingFile.length > 0) {
      this.toast(this.t('assets.downloadBusy'));
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    await ASSETS_CONTROLLER.downloadAsset(
      context,
      fileName,
      url,
      this.language,
      () => {
        this.downloadingFile = fileName;
        this.updateFileStatus();
      },
      () => {
        // 单文件高级来源成功后，默认整组发布元数据不再适用；失败时必须保留
        // 旧文件及其最后一次有效校验信息，不能在请求前就清空。
        this.clearGeoMetadata();
        this.notifyGeoReloadRequiredIfRunning();
      },
      () => {},
      () => {
        this.downloadingFile = '';
        this.updateFileStatus();
      }
    );
  }

  @Builder
  private SheetEditBody() {
    Column() {
      Text(this.t('assets.urlName'))
        .fontSize(FontSz.footnote)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textSecondary)
        .width('100%')
        .margin({ bottom: 6 })
      TextInput({ text: this.editName, placeholder: 'e.g. custom_geo' })
        .height(46)
        .fontSize(FontSz.callout)
        .fontColor(AppColor.textPrimary)
        .placeholderColor(AppColor.textTertiary)
        .backgroundColor(AppColor.surfaceAlt)
        .borderRadius(Radius.md)
        .onChange((value: string) => { this.editName = value; })

      Text(this.t('assets.urlAddress'))
        .fontSize(FontSz.footnote)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textSecondary)
        .width('100%')
        .margin({ top: 14, bottom: 6 })

      if (this.editIsLocal) {
        Row({ space: Space.sm }) {
          Image($r('app.media.ic_folder'))
            .width(18)
            .height(18)
            .fillColor(AppColor.textTertiary)
          Text(this.t('assets.localUrlLocked'))
            .fontSize(FontSz.body)
            .fontColor(AppColor.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .height(46)
        .padding({ left: 14, right: 14 })
        .backgroundColor(AppColor.surfaceAlt)
        .borderRadius(Radius.md)
        .alignItems(VerticalAlign.Center)
      } else {
        TextInput({ text: this.editUrl, placeholder: 'https://...' })
          .height(46)
          .fontSize(FontSz.callout)
          .fontColor(AppColor.textPrimary)
          .placeholderColor(AppColor.textTertiary)
          .backgroundColor(AppColor.surfaceAlt)
          .borderRadius(Radius.md)
          .onChange((value: string) => { this.editUrl = value; })

        Text(this.t('assets.geo.updateFromUrl.desc'))
          .fontSize(FontSz.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .margin({ top: 6 })
      }

      Button(this.t('action.save'))
        .width('100%')
        .height(48)
        .backgroundColor(AppColor.brand)
        .fontColor(AppColor.onBrand)
        .fontSize(FontSz.callout)
        .fontWeight(FontWeight.Medium)
        .borderRadius(Radius.pill)
        .shadow({ radius: 12, color: AppColor.shadowBrand, offsetX: 0, offsetY: 6 })
        .margin({ top: Space.xl })
        .onClick(() => this.saveCustomAsset())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.lg, right: Space.lg })
  }

  // ===================== 抽屉：打开 / 关闭 / 分发 =====================
  private openImportTypeSheet(fileUri: string): void {
    this.tempImportUri = fileUri;
    const options: Array<SheetOption> = [
      { id: 'geosite', title: this.t('assets.importType.geosite'), desc: this.t('assets.importType.geosite.desc'), selected: false, danger: false, disabled: false },
      { id: 'geoip', title: this.t('assets.importType.geoip'), desc: this.t('assets.importType.geoip.desc'), selected: false, danger: false, disabled: false },
      { id: 'custom', title: this.t('assets.importType.custom'), desc: this.t('assets.importType.custom.desc'), selected: false, danger: false, disabled: false }
    ];
    this.sheetTitle = this.t('assets.selectImportType');
    this.sheetHint = '';
    this.sheetOptions = options;
    this.sheetKind = 'importType';
  }

  private openGeoMoreSheet(fileName: string): void {
    this.geoMoreFile = fileName;
    const exists = this.builtinFileExists(fileName);
    const options: Array<SheetOption> = [
      { id: 'urlUpdate', title: this.t('assets.geo.updateFromUrl'), desc: this.t('assets.geo.updateFromUrl.desc'), selected: false, danger: false, disabled: false },
      { id: 'delete', title: this.t('action.delete'), desc: '', selected: false, danger: true, disabled: !exists }
    ];
    this.sheetTitle = fileName;
    this.sheetHint = this.t('assets.sheet.geoUpdateHint');
    this.sheetOptions = options;
    this.sheetKind = 'geoMore';
  }

  private openAddSheet(): void {
    this.editId = '';
    this.editName = '';
    this.editUrl = '';
    this.editIsLocal = false;
    this.tempImportUri = '';
    this.sheetTitle = this.t('assets.addUrlTitle');
    this.sheetHint = '';
    this.sheetKind = 'edit';
  }

  private openEditSheet(item: CustomAssetUrl): void {
    this.editId = item.id;
    this.editName = item.name;
    this.editUrl = item.url;
    this.editIsLocal = item.url.startsWith('local://');
    this.tempImportUri = '';
    this.sheetTitle = this.t('assets.editUrlTitle');
    this.sheetHint = '';
    this.sheetKind = 'edit';
  }

  private closeSheet(): void {
    this.sheetKind = '';
    this.sheetOptions = [];
  }

  private onSheetPick(optionId: string): void {
    const kind = this.sheetKind;
    if (kind === 'importType') {
      this.applyImportType(optionId);
    } else if (kind === 'geoMore') {
      const file = this.geoMoreFile;
      this.closeSheet();
      if (optionId === 'urlUpdate') {
        this.geoMoreFile = file;
        this.geoUrlInput = '';
        this.sheetTitle = file;
        this.sheetHint = this.t('assets.geo.updateFromUrl.desc');
        this.sheetKind = 'geoUrl';
      } else if (optionId === 'delete') {
        this.deleteAsset(file);
      }
    }
  }

  private async checkGeoUpdate(): Promise<void> {
    if (this.downloadingFile.length > 0) {
      this.toast(this.t('assets.downloadBusy'));
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    this.downloadingFile = GEOSITE_FILE_NAME;
    this.toast(this.t('assets.updatingAll'));
    try {
      const result = await ASSETS_CONTROLLER.checkAndUpdateBuiltinGeo(context);
      await this.loadGeoMetadata();
      this.updateFileStatus();
      let message = '';
      if (!result.metadataSaved) {
        message = this.t('assets.geo.metadataWarning');
      } else if (!result.changed) {
        message = this.f1('assets.geo.latest', 'version', result.version);
      } else if (SHARED_RUNTIME_CONTROLLER.isRunning()) {
        message = this.f1('assets.geo.updatedReconnect', 'version', result.version);
      } else {
        message = this.f1('assets.geo.updated', 'version', result.version);
      }
      SHARED_RUNTIME_CONTROLLER.appendLog(message);
      this.toast(message);
    } catch (error) {
      const message = redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error));
      await this.loadGeoMetadata();
      const localized = this.f1('assets.geo.checkFailed', 'error', message);
      SHARED_RUNTIME_CONTROLLER.appendLog(localized);
      this.toast(localized);
    } finally {
      this.downloadingFile = '';
      this.updateFileStatus();
    }
  }

  private deleteAsset(fileName: string): void {
    const context = this.getUIContext().getHostContext() as common.Context;
    ASSETS_CONTROLLER.deleteAsset(context, fileName, this.language, (success: boolean) => {
      this.updateFileStatus();
      if (success) {
        this.clearGeoMetadata();
        this.notifyGeoReloadRequiredIfRunning();
      }
    });
  }

  // ===================== 导入本地 / 扫码 =====================
  private async importLocalFile(): Promise<void> {
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.fileSuffixFilters = ['.dat'];
      documentSelectOptions.maxSelectNumber = 1;
      const documentPicker = new picker.DocumentViewPicker();
      const uris = await documentPicker.select(documentSelectOptions);
      if (!uris || uris.length === 0) {
        return;
      }
      this.openImportTypeSheet(uris[0]);
    } catch (error) {
      this.toast(this.f1('assets.openPickerFailed', 'error', JSON.stringify(error)));
    }
  }

  private async applyImportType(optionId: string): Promise<void> {
    const fileUri = this.tempImportUri;
    if (optionId === 'custom') {
      // 存为自定义资源：切到编辑抽屉预填，本地 URL 锁定
      this.editId = '';
      this.editName = '';
      this.editUrl = 'local://import';
      this.editIsLocal = true;
      this.sheetTitle = this.t('assets.addUrlTitle');
      this.sheetHint = '';
      this.sheetKind = 'edit';
      return;
    }

    this.closeSheet();
    const context = this.getUIContext().getHostContext() as common.Context;
    let target = '';
    if (optionId === 'geosite') {
      target = GEOSITE_FILE_NAME;
    } else if (optionId === 'geoip') {
      target = GEOIP_FILE_NAME;
    }
    if (target.length === 0) {
      return;
    }
    const imported = await ASSETS_CONTROLLER.copyLocalFileToAssets(
      context,
      fileUri,
      target,
      this.language,
      () => this.updateFileStatus(),
      () => {}
    );
    if (imported) {
      await this.clearGeoMetadata();
      this.notifyGeoReloadRequiredIfRunning();
    }
    this.tempImportUri = '';
  }

  private async scanAssetUrlFromQr(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!await requestCameraPermission(context)) {
        this.toast(this.t('scanner.cameraPermissionRequired'));
        return;
      }
      const value = await scanQrCode(context);
      if (value.length === 0) {
        return;
      }
      const assetUrl = normalizeScannedAssetUrl(value);
      if (!assetUrl.valid) {
        this.toast(this.t('assets.scanInvalidUrl'));
        return;
      }
      // 扫码结果预填到编辑抽屉，并跳到自定义子页
      this.showCustomUrls = true;
      this.editId = '';
      this.editName = assetUrl.name;
      this.editUrl = assetUrl.url;
      this.editIsLocal = false;
      this.tempImportUri = '';
      this.sheetTitle = this.t('assets.addUrlTitle');
      this.sheetHint = '';
      this.sheetKind = 'edit';
    } catch (error) {
      if (isScanCancelled(error)) {
        return;
      }
      this.toast(this.f1('assets.scanFailed', 'error', JSON.stringify(error)));
    }
  }

  // ===================== 自定义资源 =====================
  private openCustomView(): void {
    this.showCustomUrls = true;
    this.refreshCustomStatuses();
  }

  private async downloadCustomAsset(name: string, url: string): Promise<void> {
    if (this.downloadingFile.length > 0) {
      this.toast(this.t('assets.downloadBusy'));
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context;
    await ASSETS_CONTROLLER.downloadAsset(
      context,
      name,
      url,
      this.language,
      () => { this.downloadingFile = name; },
      () => {},
      () => {},
      () => {
        this.downloadingFile = '';
        this.refreshCustomStatuses();
      }
    );
  }

  private async reimportLocalCustomAsset(item: CustomAssetUrl): Promise<void> {
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.fileSuffixFilters = ['.dat'];
      documentSelectOptions.maxSelectNumber = 1;
      const documentPicker = new picker.DocumentViewPicker();
      const uris = await documentPicker.select(documentSelectOptions);
      if (!uris || uris.length === 0) {
        return;
      }
      const context = this.getUIContext().getHostContext() as common.Context;
      await ASSETS_CONTROLLER.copyLocalFileToAssets(
        context,
        uris[0],
        `${item.name}.dat`,
        this.language,
        () => this.refreshCustomStatuses(),
        () => {}
      );
    } catch (error) {
      this.toast(this.f1('assets.reimportLocalFailed', 'error', JSON.stringify(error)));
    }
  }

  private async saveCustomAsset(): Promise<void> {
    const trimmedName = this.editName.trim();
    const trimmedUrl = this.editUrl.trim();

    if (trimmedName.length === 0) {
      this.toast(this.t('assets.urlNameEmpty'));
      return;
    }
    if (!isSafeCustomAssetName(trimmedName)) {
      this.toast(this.t('assets.urlNameInvalid'));
      return;
    }
    if (hasDuplicateAssetName(this.customAssets, trimmedName, this.editId)) {
      this.toast(this.t('assets.urlNameDuplicate'));
      return;
    }
    const isLocalImport = trimmedUrl.startsWith('local://');
    if (!isLocalImport && !trimmedUrl.startsWith('http://') && !trimmedUrl.startsWith('https://')) {
      this.toast(this.t('assets.urlAddressInvalid'));
      return;
    }

    const context = this.getUIContext().getHostContext() as common.Context;

    // 本地导入：先把暂存的 URI 拷贝为 {name}.dat
    if (isLocalImport && this.tempImportUri.length > 0) {
      const copySuccess = await ASSETS_CONTROLLER.copyLocalFileToAssets(
        context,
        this.tempImportUri,
        `${trimmedName}.dat`,
        this.language,
        () => {},
        () => {}
      );
      if (!copySuccess) {
        return;
      }
      this.tempImportUri = '';
    }

    if (this.editId.length > 0) {
      this.customAssets = this.customAssets.map(item => {
        if (item.id === this.editId) {
          return { id: item.id, name: trimmedName, url: trimmedUrl } as CustomAssetUrl;
        }
        return item;
      });
    } else {
      this.customAssets.push({ id: Date.now().toString(), name: trimmedName, url: trimmedUrl });
    }

    await AssetStore.save(context, this.customAssets);
    this.refreshCustomStatuses();
    // 从主视图触发的自定义导入，保存后带用户进入列表看到结果
    this.showCustomUrls = true;
    this.closeSheet();
    this.toast(this.t('assets.saveSuccess'));
  }

  private async deleteCustomAsset(item: CustomAssetUrl): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    this.customAssets = await ASSETS_CONTROLLER.deleteCustomAsset(context, item, this.customAssets, this.language);
    this.refreshCustomStatuses();
  }

  // ===================== 状态读取 =====================
  private statusOf(fileName: string): string {
    let status = this.t('assets.notDownloaded');
    if (fileName === GEOSITE_FILE_NAME) {
      status = this.geositeStatus;
    } else if (fileName === GEOIP_FILE_NAME) {
      status = this.geoipStatus;
    }
    const hash = this.geoAssetHashes[fileName];
    return hash !== undefined && hash.length >= 8 ? `${status} · SHA-256 ${hash.substring(0, 8)}…` : status;
  }

  private customStatusOf(name: string): string {
    const status = this.customFileStatuses[name];
    return status !== undefined ? status : this.t('assets.notDownloaded');
  }

  private builtinFileExists(fileName: string): boolean {
    const context = this.getUIContext().getHostContext() as common.Context;
    try {
      return fs.accessSync(`${context.filesDir}/${fileName}`);
    } catch (e) {
      return false;
    }
  }

  private updateFileStatus(): void {
    const context = this.getUIContext().getHostContext() as common.Context;
    this.geositeStatus = ASSETS_CONTROLLER.getFileStatus(context, GEOSITE_FILE_NAME, this.language);
    this.geoipStatus = ASSETS_CONTROLLER.getFileStatus(context, GEOIP_FILE_NAME, this.language);
  }

  private refreshCustomStatuses(): void {
    const context = this.getUIContext().getHostContext() as common.Context;
    const next: Record<string, string> = {};
    for (let index = 0; index < this.customAssets.length; index++) {
      const item = this.customAssets[index];
      next[item.name] = ASSETS_CONTROLLER.getCustomFileStatus(context, item.name, this.language);
    }
    this.customFileStatuses = next;
  }

  private async loadCustomAssets(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    this.customAssets = await AssetStore.load(context);
    this.refreshCustomStatuses();
  }

  private async loadState(): Promise<void> {
    this.isStateLoaded = false;
    const context = this.getUIContext().getHostContext() as common.Context;
    this.language = (await SETTINGS_CONTROLLER.load(context)).language;

    // 一次性迁移：清掉旧版本写入的内置下载源地址。
    try {
      const assetStore = await preferences.getPreferences(context, 'hey_vpn_assets');
      if (await assetStore.has('geo_source_url')) {
        await assetStore.delete('geo_source_url');
        await assetStore.flush();
      }
    } catch (err) {
      // ignore
    }
    await this.loadGeoMetadata();
    this.updateFileStatus();
    this.isStateLoaded = true;
  }

  private async loadGeoMetadata(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const metadata = await AssetStore.loadGeoUpdateMetadata(context);
    const hashes: Record<string, string> = {};
    for (let index = 0; index < metadata.assets.length; index++) {
      hashes[metadata.assets[index].fileName] = metadata.assets[index].sha256;
    }
    this.geoAssetHashes = hashes;
    this.geoUpdateSummary = this.formatGeoUpdateSummary(metadata);
  }

  private async clearGeoMetadata(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    try {
      await AssetStore.clearGeoUpdateMetadata(context);
    } catch (error) {
      // File operation already succeeded; stale verification metadata must not remain visible.
    }
    this.geoAssetHashes = {};
    this.geoUpdateSummary = this.t('assets.geo.defaultSource');
  }

  private notifyGeoReloadRequiredIfRunning(): void {
    if (!SHARED_RUNTIME_CONTROLLER.isRunning()) {
      return;
    }
    const message = this.t('assets.geo.changedReconnect');
    SHARED_RUNTIME_CONTROLLER.appendLog(message);
    this.toast(message);
  }

  private formatGeoUpdateSummary(metadata: GeoUpdateMetadata): string {
    if (metadata.checkedAt <= 0) {
      return this.t('assets.geo.defaultSource');
    }
    const checked = new Date(metadata.checkedAt);
    const time = `${checked.getFullYear()}/${this.padTwo(checked.getMonth() + 1)}/${this.padTwo(checked.getDate())} ` +
      `${this.padTwo(checked.getHours())}:${this.padTwo(checked.getMinutes())}`;
    if (metadata.result === 'failed') {
      if (metadata.version.length > 0) {
        return this.t('assets.geo.summaryFailedWithVersion')
          .replace('{version}', metadata.version)
          .replace('{time}', time);
      }
      return this.t('assets.geo.summaryFailed').replace('{time}', time);
    }
    if (metadata.version.length === 0) {
      return this.t('assets.geo.defaultSource');
    }
    return this.t('assets.geo.summary')
      .replace('{version}', metadata.version)
      .replace('{time}', time);
  }

  private padTwo(value: number): string {
    return value < 10 ? `0${value}` : value.toString();
  }

  // ===================== 工具 =====================
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message });
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
}
