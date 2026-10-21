import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import {
  APP_LANGUAGE_AUTO,
  APP_LANGUAGE_EN,
  APP_LANGUAGE_ZH_CN,
  APP_LANGUAGE_ZH_TW,
  AppLanguage
} from '../core/Profile';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { SettingsStore } from '../storage/SettingsStore';
import { SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { formatOne } from '../utils/LocalizationPresenter';
import { PageHeader } from '../shell/PageHeader';
import { SectionHeader } from '../components/SectionHeader';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';

// 各语言的英文/拼音副标题（母语名走 i18n 的 settings.language.* 文案）。
// 这些是语言自身的英文名，按惯例固定展示、不随界面语言变化。
const LANGUAGE_SUBTITLES: Record<string, string> = {
  'zh-rCN': 'Chinese, Simplified',
  'zh-rTW': 'Chinese, Traditional',
  'en': 'English',
  'vi': 'Vietnamese',
  'ru': 'Russian',
  'fa': 'Persian',
  'ar': 'Arabic',
  'bn': 'Bengali',
  'bqi-rIR': 'Luri Bakhtiari'
};

// 「选择语言」分组的展示顺序（中文在前，与设计稿一致）。
// 「跟随系统」单独置顶，不在此列。
const LANGUAGE_LIST: AppLanguage[] = [
  APP_LANGUAGE_ZH_CN,
  APP_LANGUAGE_ZH_TW,
  APP_LANGUAGE_EN,
  'vi',
  'ru',
  'fa',
  'ar',
  'bn',
  'bqi-rIR'
];

const RETURN_DELAY_MS: number = 520;

function languageKeySuffix(language: AppLanguage): string {
  switch (language) {
    case 'auto':
      return 'auto';
    case 'en':
      return 'en';
    case 'zh-rCN':
      return 'zhCn';
    case 'zh-rTW':
      return 'zhTw';
    case 'vi':
      return 'vi';
    case 'ru':
      return 'ru';
    case 'fa':
      return 'fa';
    case 'ar':
      return 'ar';
    case 'bn':
      return 'bn';
    default:
      return 'bqiIr';
  }
}

@Entry
@Component
struct LanguagePage {
  // 全局可观察语言源：选中即写入 AppStorage，所有页面实时刷新。
  @StorageLink('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @State private toastVisible: boolean = false;
  // 选中后进入 ~0.5s 返回流程，期间忽略再次点击，避免重复落盘 / 多次返回。
  private switching: boolean = false;
  private returnTimer: number = -1;

  aboutToDisappear(): void {
    // 若用户在自动返回前手动点了返回箭头，取消待触发的定时器，避免多退一页。
    if (this.returnTimer >= 0) {
      clearTimeout(this.returnTimer);
      this.returnTimer = -1;
    }
  }

  build() {
    Column() {
      PageHeader({
        title: this.t('settings.language.title'),
        showBack: true
      })

      Stack({ alignContent: Alignment.Bottom }) {
        Scroll() {
          Column() {
            // 跟随系统（独立置顶卡片）
            Column() {
              this.LanguageRow(APP_LANGUAGE_AUTO, false)
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)

            SectionHeader({ title: this.t('settings.language.listTitle'), sidePadding: 0 })

            // 其余语言
            Column() {
              ForEach(LANGUAGE_LIST, (code: AppLanguage, index: number) => {
                this.LanguageRow(code, index !== LANGUAGE_LIST.length - 1)
              }, (code: AppLanguage) => code)
            }
            .width('100%')
            .backgroundColor(AppColor.surface)
            .borderRadius(Radius.lg)
            .border({ width: 0.5, color: AppColor.border })
            .clip(true)
          }
          .width('100%')
          .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.xxl })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)

        if (this.toastVisible) {
          this.Toast()
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bg)
  }

  @Builder
  private LanguageRow(code: AppLanguage, showDivider: boolean) {
    Column() {
      Row({ space: Space.md }) {
        Column({ space: 3 }) {
          Text(this.nativeName(code))
            .fontSize(FontSz.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(code === this.language ? AppColor.brand : AppColor.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitle(code))
            .fontSize(FontSz.footnote)
            .fontColor(AppColor.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (code === this.language) {
          Image($r('app.media.ic_check'))
            .width(22)
            .height(22)
            .fillColor(AppColor.brand)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 62 })
      .padding({ left: Space.lg, right: Space.lg, top: 11, bottom: 11 })
      .backgroundColor(code === this.language ? AppColor.brandTint : Color.Transparent)
      .onClick(() => {
        this.selectLanguage(code);
      })

      if (showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(AppColor.divider)
          .margin({ left: Space.lg })
      }
    }
    .width('100%')
  }

  @Builder
  private Toast() {
    Row({ space: Space.sm }) {
      Image($r('app.media.ic_check'))
        .width(18)
        .height(18)
        .fillColor(AppColor.brand)
      Text(this.t('settings.language.switched'))
        .fontSize(FontSz.footnote)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
    }
    .padding({ left: Space.lg, right: Space.lg, top: 10, bottom: 10 })
    .backgroundColor(AppColor.surface)
    .border({ width: 0.5, color: AppColor.border })
    .borderRadius(Radius.pill)
    .shadow({ radius: 24, color: AppColor.shadowCard, offsetX: 0, offsetY: 8 })
    .margin({ bottom: 30 })
  }

  private async selectLanguage(code: AppLanguage): Promise<void> {
    if (this.switching) {
      return;
    }
    if (code === this.language) {
      this.getUIContext().getRouter().back();
      return;
    }
    this.switching = true;
    // 1) 立即写入全局源 → 本页打勾高亮 + 设置页/全 App 实时切换语言。
    this.language = code;
    // 2) 弹出「已切换 · 正在返回」提示。
    this.toastVisible = true;
    // 3) 持久化（仅改语言，保留其它设置），失败也不阻断返回。
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      await SettingsStore.saveLanguage(context, code);
      SHARED_RUNTIME_CONTROLLER.appendLog(
        formatOne(code, 'log.languageChanged', 'language', this.nativeName(code))
      );
    } catch (error) {
      SHARED_RUNTIME_CONTROLLER.appendLog(
        formatOne(code, 'error.saveSettings', 'error', redactDiagnosticText(JSON.stringify(error)))
      );
    }
    // 4) 约 0.5s 后自动滑回设置页。
    this.returnTimer = setTimeout(() => {
      this.returnTimer = -1;
      this.getUIContext().getRouter().back();
    }, RETURN_DELAY_MS);
  }

  private nativeName(code: AppLanguage): string {
    return translate(this.language, `settings.language.${languageKeySuffix(code)}`);
  }

  private subtitle(code: AppLanguage): string {
    if (code === APP_LANGUAGE_AUTO) {
      return this.t('settings.language.autoDetail');
    }
    return LANGUAGE_SUBTITLES[code] ?? '';
  }

  private t(key: string): string {
    return translate(this.language, key);
  }
}
