import { common, Want, bundleManager } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { AppLanguage } from '../core/Profile';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { BUNDLED_XRAY_VERSION, BUNDLED_SINGBOX_VERSION } from '../core/CoreInfo';
// sing-box remains an explicitly labelled preview; this probe reports packaged ABI readiness.
import { SectionHeader } from '../components/SectionHeader';
import { PageHeader } from '../shell/PageHeader';
import { formatOne } from '../utils/LocalizationPresenter';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';

const REPO_URL: string = 'https://github.com/popsiclelmlm/Hey';
const REPO_ISSUES_URL: string = 'https://github.com/popsiclelmlm/Hey/issues';
const REPO_DOCS_URL: string = 'https://github.com/popsiclelmlm/Hey#readme';
const REPO_LICENSE_URL: string = 'https://github.com/popsiclelmlm/Hey/blob/main/LICENSE';
const AUTHOR_URL: string = 'https://github.com/popsiclelmlm';

// 检查更新行的状态机：闲置 → 检查中 → 已是最新。

@Entry
@Component
struct AboutPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private isStateLoaded: boolean = false;
  @State private versionName: string = '1.2.0';
  @State private versionCode: string = '1020000';
  @State private bundleId: string = 'com.lmlm.hey';

  aboutToAppear(): void {
    this.loadState();
  }

  build() {
    Column() {
      if (this.isStateLoaded) {
        PageHeader({
          title: this.t('screen.about.title'),
          showBack: true
        })
        Scroll() {
          Column({ space: Space.lg }) {
            this.BrandHeader()
            Column() {
            }
            .width('100%')
            .padding({ left: Space.lg, right: Space.lg })

            SectionHeader({ title: this.t('about.section.core') })
            Column() {
              this.CoreCard()
            }
            .width('100%')
            .padding({ left: Space.lg, right: Space.lg })

            SectionHeader({ title: this.t('about.section.openSource') })
            Column() {
              this.CommunityCard()
            }
            .width('100%')
            .padding({ left: Space.lg, right: Space.lg })

            Column() {
              this.LegalCard()
            }
            .width('100%')
            .padding({ left: Space.lg, right: Space.lg })

            this.Footer()
          }
          .width('100%')
          .padding({ top: Space.sm, bottom: Space.xxl })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      } else {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(AppColor.brand)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .height('100%')
    .width('100%')
    .backgroundColor(AppColor.bg)
  }

  // 品牌头：应用图标 + 名称 + 标语 + 版本胶囊。
  @Builder
  private BrandHeader() {
    Column() {
      Image($r('app.media.startIcon'))
        .width(92)
        .height(92)
        .borderRadius(22)
        .clip(true)
        .shadow({ radius: 24, color: AppColor.shadowBrand, offsetX: 0, offsetY: 12 })

      Text('Hey')
        .fontSize(FontSz.title + 4)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .margin({ top: Space.lg })

      Text(this.t('about.brand.tagline'))
        .fontSize(FontSz.body)
        .fontColor(AppColor.textSecondary)
        .margin({ top: Space.xs })

      Row({ space: Space.sm }) {
        Text(`${this.t('about.version.label')} ${this.versionName}`)
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textSecondary)
        Column()
          .width(3)
          .height(3)
          .borderRadius(Radius.pill)
          .backgroundColor(AppColor.textTertiary)
        Text(`Build ${this.versionCode}`)
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
      }
      .padding({ left: Space.md, right: Space.md, top: 5, bottom: 5 })
      .backgroundColor(AppColor.surface)
      .border({ width: 0.5, color: AppColor.border })
      .borderRadius(Radius.pill)
      .margin({ top: Space.md })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: Space.xl, bottom: Space.sm })
  }


  // 内核引擎：键值对展示 + sing-box 诊断探测。
  @Builder
  private CoreCard() {
    Column() {
      CoreRow({
        label: this.t('about.core.xray'),
        value: BUNDLED_XRAY_VERSION.length > 0 ? BUNDLED_XRAY_VERSION : this.t('about.core.unknown'),
        showDivider: true
      })
      CoreRow({
        label: this.t('about.core.singbox'),
        value: BUNDLED_SINGBOX_VERSION.length > 0 ? BUNDLED_SINGBOX_VERSION : this.t('about.core.unknown'),
        showDivider: true
      })
      CoreRow({
        label: this.t('about.core.protocols'),
        value: this.t('about.core.protocols.value'),
        showDivider: true
      })
      CoreRow({
        label: this.t('about.core.mode'),
        value: this.t('about.core.mode.value'),
        showDivider: false
      })
    }
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
    .clip(true)
    .width('100%')
  }

  // 开源与社区：带彩色图标的外链行。
  @Builder
  private CommunityCard() {
    Column() {
      LinkRow({
        icon: $r('app.media.ic_github'),
        iconBg: '#24292F',
        title: this.t('about.repo.title'),
        detail: this.t('about.repo.detail'),
        showDivider: true,
        onAction: () => {
          this.openUrl(REPO_URL, this.t('about.repo.title'));
        }
      })
      LinkRow({
        icon: $r('app.media.ic_article'),
        iconBg: '#0EA5E9',
        title: this.t('about.docs.title'),
        detail: this.t('about.docs.detail'),
        showDivider: true,
        onAction: () => {
          this.openUrl(REPO_DOCS_URL, this.t('about.docs.title'));
        }
      })
      LinkRow({
        icon: $r('app.media.ic_info'),
        iconBg: '#16A34A',
        title: this.t('about.feedback.title'),
        detail: this.t('about.feedback.detail'),
        showDivider: true,
        onAction: () => {
          this.openUrl(REPO_ISSUES_URL, this.t('about.feedback.title'));
        }
      })
      LinkRow({
        icon: $r('app.media.ic_github'),
        iconBg: '#8B5CF6',
        title: this.t('about.author.title'),
        detail: this.t('about.author.detail'),
        showDivider: false,
        onAction: () => {
          this.openUrl(AUTHOR_URL, this.t('about.author.title'));
        }
      })
    }
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
    .clip(true)
    .width('100%')
  }

  // 法律与开源声明：标题 + 右向箭头。
  @Builder
  private LegalCard() {
    Column() {
      LegalRow({
        title: this.t('about.legal.license.title'),
        showDivider: true,
        onAction: () => {
          this.openUrl(REPO_LICENSE_URL, this.t('about.legal.license.title'));
        }
      })
      LegalRow({
        title: this.t('about.license.title'),
        showDivider: false,
        onAction: () => {
          SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.presetOpened', 'title', this.t('about.license.title')));
          promptAction.showToast({ message: this.t('about.license.detail') });
        }
      })
    }
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
    .clip(true)
    .width('100%')
  }

  @Builder
  private Footer() {
    Column({ space: Space.xs }) {
      Text(this.t('about.footer.copyright'))
        .fontSize(FontSz.footnote)
        .fontColor(AppColor.textTertiary)
        .textAlign(TextAlign.Center)
      Text(this.bundleId)
        .fontSize(FontSz.caption)
        .fontColor(AppColor.textTertiary)
        .opacity(0.8)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: Space.xxl, right: Space.xxl })
    .margin({ top: Space.sm })
  }


  private async openUrl(url: string, title: string): Promise<void> {
    SHARED_RUNTIME_CONTROLLER.appendLog(this.f1('log.presetOpened', 'title', title));
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      await context.startAbility(want);
    } catch (error) {
      // Fallback: Copy to clipboard if cannot start ability in current runtime environment
      try {
        const systemPasteboard = pasteboard.getSystemPasteboard();
        const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
        systemPasteboard.setDataSync(pasteData);
        promptAction.showToast({ message: this.t('about.action.copied') });
      } catch (clipboardError) {
        promptAction.showToast({ message: this.t('about.action.failed') });
      }
    }
  }


  private async loadState(): Promise<void> {
    const context = getContext(this) as common.Context;
    const settings = await SETTINGS_CONTROLLER.load(context);
    this.language = settings.language;
    this.loadAppInfo();
    this.isStateLoaded = true;
  }

  private loadAppInfo(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
      );
      if (info.versionName.length > 0) {
        this.versionName = info.versionName;
      }
      this.versionCode = info.versionCode.toString();
      if (info.name.length > 0) {
        this.bundleId = info.name;
      }
    } catch (error) {
      // Keep the compile-time fallbacks when bundle info is unavailable (e.g. preview).
    }
  }


  private t(key: string): string {
    return translate(this.language, key);
  }

  private f1(key: string, name: string, value: string): string {
    return formatOne(this.language, key, name, value);
  }
}


// 内核引擎键值行（仅展示）。
@Component
struct CoreRow {
  @Prop label: string = '';
  @Prop value: string = '';
  showDivider: boolean = false;

  build() {
    Column() {
      Row({ space: Space.md }) {
        Text(this.label)
          .fontSize(FontSz.callout)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Text(this.value)
          .fontSize(FontSz.body)
          .fontColor(AppColor.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '60%' })
      }
      .width('100%')
      .constraintSize({ minHeight: 50 })
      .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })

      if (this.showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(AppColor.divider)
          .margin({ left: Space.lg })
      }
    }
    .width('100%')
  }
}

// 开源与社区外链行：彩色图标 + 标题 + 描述 + 外链箭头。
@Component
struct LinkRow {
  icon: Resource = $r('app.media.ic_link');
  iconBg: ResourceColor = AppColor.brand;
  @Prop title: string = '';
  @Prop detail: string = '';
  showDivider: boolean = false;
  onAction: () => void = () => {};

  @State private isPressed: boolean = false;

  build() {
    Column() {
      Row({ space: Space.md }) {
        Stack() {
          Image(this.icon)
            .width(17)
            .height(17)
            .fillColor(Color.White)
        }
        .width(30)
        .height(30)
        .borderRadius(8)
        .backgroundColor(this.iconBg)

        Column({ space: 1 }) {
          Text(this.title)
            .fontSize(FontSz.callout)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.detail.length > 0) {
            Text(this.detail)
              .fontSize(FontSz.caption)
              .fontColor(AppColor.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Image($r('app.media.ic_open_in_new'))
          .width(17)
          .height(17)
          .fillColor(AppColor.textTertiary)
      }
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
      .backgroundColor(this.isPressed ? AppColor.surfaceAlt : AppColor.surface)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.isPressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.isPressed = false;
        }
      })
      .onClick(() => {
        this.onAction();
      })

      if (this.showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(AppColor.divider)
          .margin({ left: Space.lg })
      }
    }
    .width('100%')
  }
}

// 法律与开源声明行：标题 + 右向箭头。
@Component
struct LegalRow {
  @Prop title: string = '';
  showDivider: boolean = false;
  onAction: () => void = () => {};

  @State private isPressed: boolean = false;

  build() {
    Column() {
      Row({ space: Space.md }) {
        Text(this.title)
          .fontSize(FontSz.callout)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Image($r('app.media.ic_chevron_right'))
          .width(20)
          .height(20)
          .fillColor(AppColor.textTertiary)
      }
      .width('100%')
      .constraintSize({ minHeight: 50 })
      .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
      .backgroundColor(this.isPressed ? AppColor.surfaceAlt : AppColor.surface)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.isPressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.isPressed = false;
        }
      })
      .onClick(() => {
        this.onAction();
      })

      if (this.showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(AppColor.divider)
          .margin({ left: Space.lg })
      }
    }
    .width('100%')
  }
}
