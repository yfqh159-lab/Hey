import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { APP_MODE_VPN, AppLanguage, AppRuntimeMode, ConnectionStatus, RuntimeStats, isProxyOnlyRuntimeMode } from '../core/Profile';
import { LogConsole } from '../features/logs/LogPanel';
import { LogEntry, LogLevelFilter, logLevelLabel } from '../features/logs/LogModel';
import { countLogLevels, filterLogEntries, formatLogEntriesText } from '../features/logs/LogOperations';
import { RuntimeStatusBar } from '../features/runtime/RuntimePanel';
import { RuntimeViewState, SHARED_RUNTIME_CONTROLLER } from '../features/runtime/RuntimeController';
import { SETTINGS_CONTROLLER } from '../features/settings/SettingsController';
import { shareText, TextShareResult } from '../services/SystemShare';
import { PageHeader } from '../shell/PageHeader';
import { IconButton } from '../components/IconButton';
import { formatBytes } from '../utils/Formatters';
import { localizedConnectionStatus } from '../utils/LocalizationPresenter';
import { BOTTOM_SAFE_HEIGHT_KEY } from '../core/Immersive';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';

const EMPTY_STATS: RuntimeStats = {
  uploadBytes: 0,
  downloadBytes: 0,
  xrayRunning: false,
  tunRunning: false,
  lastMessage: translate(DEFAULT_LANGUAGE, 'runtime.nativeBridgeNotQueried')
};

/** 过滤胶囊的数据模型（标签 / 计数 / 等级圆点）。 */
interface LevelChip {
  id: LogLevelFilter;
  label: string;
  count: number;
  hasDot: boolean;
  dotColor: ResourceColor;
}

@Entry
@Component
struct LogsPage {
  private timerId: number = -1;

  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @StorageProp(BOTTOM_SAFE_HEIGHT_KEY) private bottomSafe: number = 0;
  @State private status: ConnectionStatus = ConnectionStatus.IDLE;
  @State private elapsedText: string = '00:00';
  @State private entries: Array<LogEntry> = [];
  @State private searchQuery: string = '';
  @State private levelFilter: LogLevelFilter = 'all';
  @State private paused: boolean = false;
  @State private stats: RuntimeStats = EMPTY_STATS;
  @State private speedEnabled: boolean = false;
  @State private runtimeMode: AppRuntimeMode = APP_MODE_VPN;
  // 运行内核名,随所选内核显示 Xray / sing-box(预览)。
  @State private coreLabel: string = 'Xray';

  aboutToAppear(): void {
    this.loadState();
    if (this.timerId < 0) {
      this.timerId = setInterval(() => {
        this.refreshRuntime();
      }, 1000);
    }
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Column() {
      PageHeader({
        title: this.t('screen.logs.title'),
        showBack: true
      })

      // 运行状态条
      Column() {
        RuntimeStatusBar({
          statusText: this.statusText(),
          statusDotColor: this.statusDotColor(),
          durationLabel: this.t('runtime.duration'),
          durationValue: this.elapsedText,
          showTraffic: this.speedEnabled,
          uploadLabel: this.t('runtime.upload'),
          uploadValue: formatBytes(this.stats.uploadBytes),
          downloadLabel: this.t('runtime.download'),
          downloadValue: formatBytes(this.stats.downloadBytes),
          xrayActive: this.stats.xrayRunning,
          dataPlaneLabel: isProxyOnlyRuntimeMode(this.runtimeMode) ? 'SOCKS/HTTP' : 'TUN',
          dataPlaneActive: isProxyOnlyRuntimeMode(this.runtimeMode) ?
            this.status === ConnectionStatus.RUNNING && this.stats.xrayRunning : this.stats.tunRunning,
          coreLabel: this.coreLabel
        })
      }
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg, top: Space.md })

      // 等级过滤胶囊
      Scroll() {
        Row({ space: Space.sm - 1 }) {
          ForEach(this.chips(), (chip: LevelChip) => {
            Row({ space: 6 }) {
              if (chip.hasDot) {
                Circle()
                  .width(7)
                  .height(7)
                  .fill(chip.dotColor)
              }
              Text(chip.label)
                .fontSize(FontSz.footnote)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.levelFilter === chip.id ? AppColor.onBrand : AppColor.textPrimary)
              Text(chip.count.toString())
                .fontSize(FontSz.caption)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.levelFilter === chip.id ? AppColor.onBrand : AppColor.textTertiary)
            }
            .padding({ left: Space.md, right: Space.md, top: 6, bottom: 6 })
            .backgroundColor(this.levelFilter === chip.id ? AppColor.brand : AppColor.surface)
            .border({ width: 1, color: this.levelFilter === chip.id ? AppColor.brand : AppColor.border })
            .borderRadius(Radius.pill)
            .onClick(() => {
              this.levelFilter = chip.id;
            })
            // key 必须含计数与选中态：ArkUI ForEach 对相同 key 会复用旧组件且不更新内部内容，
            // 若只用 chip.id（永不变），计数会冻结在首帧的 0、点击后高亮也不刷新。
          }, (chip: LevelChip) => `${chip.id}-${chip.count}-${this.levelFilter === chip.id ? '1' : '0'}`)
        }
        .padding({ left: Space.lg, right: Space.lg })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
      .padding({ top: Space.md, bottom: Space.sm })

      // 搜索
      Column() {
        Search({ value: this.searchQuery, placeholder: this.t('logs.searchPlaceholder') })
          .height(40)
          .backgroundColor(AppColor.surface)
          .borderRadius(Radius.md)
          .border({ width: 0.5, color: AppColor.border })
          .placeholderColor(AppColor.textTertiary)
          .placeholderFont({ size: FontSz.body })
          .onChange((value: string) => {
            this.searchQuery = value;
          })
      }
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg })
      .margin({ bottom: Space.sm })

      // 日志控制台
      Column() {
        LogConsole({
          entries: this.visibleEntries(),
          emptyTitle: this.emptyTitle(),
          emptyHint: this.emptyHint(),
          onCopyItem: (raw: string) => {
            this.copyLogText(raw);
          }
        })
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg })

      // 工具栏
      Row({ space: Space.sm }) {
        Row({ space: 6 }) {
          Image(this.paused ? $r('app.media.ic_play_arrow') : $r('app.media.ic_pause'))
            .width(15)
            .height(15)
            .fillColor(this.paused ? AppColor.brand : AppColor.textSecondary)
          Text(this.paused ? this.t('logs.paused') : this.t('logs.pause'))
            .fontSize(FontSz.footnote)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.paused ? AppColor.brand : AppColor.textSecondary)
        }
        .padding({ left: Space.md + 1, right: Space.md + 1, top: Space.sm, bottom: Space.sm })
        .backgroundColor(this.paused ? AppColor.brandTint : AppColor.surfaceAlt)
        .border({ width: 1, color: this.paused ? AppColor.brand : AppColor.border })
        .borderRadius(Radius.sm)
        .onClick(() => {
          this.togglePause();
        })

        Blank()

        IconButton({
          icon: $r('app.media.ic_copy'),
          buttonSize: 38,
          iconSize: 18,
          radius: Radius.sm,
          buttonBackground: AppColor.surfaceAlt,
          iconColor: AppColor.textSecondary,
          onAction: () => {
            this.copyVisibleLogs();
          }
        })
        IconButton({
          icon: $r('app.media.ic_share'),
          buttonSize: 38,
          iconSize: 18,
          radius: Radius.sm,
          buttonBackground: AppColor.surfaceAlt,
          iconColor: AppColor.textSecondary,
          onAction: () => {
            this.shareVisibleLogs();
          }
        })
        IconButton({
          icon: $r('app.media.ic_delete'),
          buttonSize: 38,
          iconSize: 18,
          radius: Radius.sm,
          buttonBackground: AppColor.surfaceAlt,
          iconColor: AppColor.danger,
          onAction: () => {
            this.clearLogs();
          }
        })
      }
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg, top: Space.sm, bottom: Space.sm + this.bottomSafe })
      .backgroundColor(AppColor.surface)
      .border({ width: { top: 0.5 }, color: AppColor.divider })
    }
    .height('100%')
    .width('100%')
    .backgroundColor(AppColor.bg)
  }

  private async loadState(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.Context;
    const settings = await SETTINGS_CONTROLLER.load(context);
    this.language = settings.language;
    this.speedEnabled = settings.speedEnabled;
    await this.refreshRuntime();
  }

  private async refreshRuntime(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      this.applyRuntimeState(await SHARED_RUNTIME_CONTROLLER.refresh(context, this.language));
      // 内核标签由运行时控制器统一给出（反映实际内核，anytls/tuic 会强制 sing-box）。
      this.coreLabel = SHARED_RUNTIME_CONTROLLER.coreLabelText();
    } catch (error) {
      // 刷新失败不阻断页面，保留上次状态，避免日志面板被异常清空。
      console.error(`Logs refresh failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    }
  }

  private togglePause(): void {
    this.paused = !this.paused;
    if (!this.paused) {
      // 恢复时立刻拉一次最新日志
      this.refreshRuntime();
    }
    try {
      this.getUIContext().getPromptAction().showToast({ message: this.paused ? this.t('logs.pauseToast') : this.t('logs.resumeToast') });
    } catch (err) {
      // ignore
    }
  }

  private clearLogs(): void {
    const context = this.getUIContext().getHostContext() as common.Context;
    const state = SHARED_RUNTIME_CONTROLLER.clearLogs(context, this.language);
    this.status = state.status;
    this.elapsedText = state.elapsedText;
    this.stats = state.stats;
    this.entries = state.entries; // 清空需立即反映，忽略暂停
    try {
      this.getUIContext().getPromptAction().showToast({ message: this.t('logs.cleared') });
    } catch (err) {
      // ignore
    }
  }

  private copyVisibleLogs(): void {
    this.copyLogText(this.visibleLogText());
  }

  private async shareVisibleLogs(): Promise<void> {
    const content = this.visibleLogText();
    if (content.trim().length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('logs.empty') });
      } catch (err) {
        // ignore
      }
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const result = await shareText(context, this.t('screen.logs.title'), content);
    this.handleShareResult(result);
  }

  private copyLogText(content: string): void {
    const text = content.trim();
    if (text.length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('logs.empty') });
      } catch (err) {
        // ignore
      }
      return;
    }
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      systemPasteboard.setDataSync(pasteData);
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('logs.copied') });
      } catch (err) {
        // ignore
      }
    } catch (error) {
      try {
        this.getUIContext().getPromptAction().showToast({
          message: this.f1('logs.copyFailed', 'error', redactDiagnosticText(JSON.stringify(error)))
        });
      } catch (err) {
        // ignore
      }
    }
  }

  private handleShareResult(result: TextShareResult): void {
    if (result.systemShareStarted) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('share.started') });
      } catch (err) {
        // ignore
      }
      return;
    }
    if (result.copiedToClipboard) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: this.t('share.fallbackCopied') });
      } catch (err) {
        // ignore
      }
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({ message: this.f1('share.failed', 'error', result.errorMessage) });
    } catch (err) {
      // ignore
    }
  }

  private chips(): Array<LevelChip> {
    const counts = countLogLevels(this.entries);
    return [
      { id: 'all', label: this.t('logs.filter.all'), count: counts.all, hasDot: false, dotColor: AppColor.textTertiary },
      { id: 'debug', label: logLevelLabel('debug'), count: counts.debug, hasDot: true, dotColor: AppColor.textSecondary },
      { id: 'info', label: logLevelLabel('info'), count: counts.info, hasDot: true, dotColor: AppColor.info },
      { id: 'warn', label: logLevelLabel('warn'), count: counts.warn, hasDot: true, dotColor: AppColor.warning },
      { id: 'error', label: logLevelLabel('error'), count: counts.error, hasDot: true, dotColor: AppColor.danger }
    ];
  }

  private visibleEntries(): Array<LogEntry> {
    return filterLogEntries(this.entries, this.levelFilter, this.searchQuery);
  }

  private visibleLogText(): string {
    return formatLogEntriesText(this.visibleEntries());
  }

  private emptyTitle(): string {
    return this.entries.length === 0 ? this.t('logs.empty') : this.t('logs.noMatchTitle');
  }

  private emptyHint(): string {
    return this.entries.length === 0 ? '' : this.t('logs.noMatchHint');
  }

  private statusText(): string {
    return localizedConnectionStatus(this.language, this.status);
  }

  private statusDotColor(): ResourceColor {
    if (this.status === ConnectionStatus.RUNNING) {
      return AppColor.success;
    }
    if (this.status === ConnectionStatus.ERROR) {
      return AppColor.danger;
    }
    if (this.status === ConnectionStatus.STARTING || this.status === ConnectionStatus.STOPPING) {
      return AppColor.warning;
    }
    return AppColor.textTertiary;
  }

  private applyRuntimeState(state: RuntimeViewState): void {
    this.status = state.status;
    this.runtimeMode = state.runtimeMode;
    this.elapsedText = state.elapsedText;
    this.stats = state.stats;
    // 暂停时冻结日志列表（状态条仍随刷新更新），恢复时再同步。
    if (!this.paused) {
      this.entries = state.entries;
    }
  }

  private t(key: string): string {
    return translate(this.language, key);
  }

  private f1(key: string, name: string, value: string): string {
    return translate(this.language, key).replace(`{${name}}`, value);
  }
}
