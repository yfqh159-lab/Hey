import { common } from '@kit.AbilityKit';
import { AppLanguage } from '../core/Profile';
import { DEFAULT_LANGUAGE, translate } from '../core/I18n';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';
import { SETTINGS_CONTROLLER, SettingsDraft } from '../features/settings/SettingsController';
import { NETWORK_SCENE_MANAGER } from '../services/NetworkSceneManager';
import { NetworkProbe, WifiScanEntry } from '../services/NetworkProbe';
import { PageHeader } from '../shell/PageHeader';
import { BOTTOM_SAFE_HEIGHT_KEY } from '../core/Immersive';
import { AppColor, FontSz, Radius, Space } from '../theme/Theme';
import { formatOne } from '../utils/LocalizationPresenter';

@Entry
@Component
struct NetworkScenarioPage {
  @StorageProp('appLanguage') private language: AppLanguage = DEFAULT_LANGUAGE;
  @StorageProp(BOTTOM_SAFE_HEIGHT_KEY) private bottomSafe: number = 0;
  @State private cellularTrusted: boolean = false;
  @State private trustedSsids: string[] = [];
  @State private manualInput: string = '';
  @State private showManualInput: boolean = false;
  @State private scanEntries: WifiScanEntry[] = [];
  @State private showScanResults: boolean = false;
  private draft: SettingsDraft | null = null;
  private settingsSaveInFlight: boolean = false;
  private settingsSavePending: boolean = false;

  aboutToAppear(): void {
    this.loadState();
  }

  build() {
    Column() {
      PageHeader({
        title: this.t('screen.netScenario.title'),
        showBack: true
      })
      Scroll() {
        Column({ space: Space.md }) {
          this.IntroCard()
          this.CellularCard()
          this.GroupLabel(this.t('netScenario.trustedWifi'))
          this.TrustedWifiCard()
          this.ActionButtons()
          if (this.showManualInput) {
            this.ManualAddCard()
          }
          if (this.showScanResults) {
            this.ScanResultsCard()
          }
        }
        .width('100%')
        .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.xxl + this.bottomSafe })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .height('100%')
    .width('100%')
    .backgroundColor(AppColor.bg)
  }

  @Builder
  private GroupLabel(text: string) {
    Text(text)
      .fontSize(FontSz.footnote)
      .fontWeight(FontWeight.Medium)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ left: Space.xs })
  }

  // 功能说明 + 后台限制提示
  @Builder
  private IntroCard() {
    Column({ space: Space.sm }) {
      Text(this.t('netScenario.intro'))
        .fontSize(FontSz.footnote)
        .fontColor(AppColor.textSecondary)
        .width('100%')
      Text(this.t('netScenario.backgroundNote'))
        .fontSize(FontSz.footnote)
        .fontColor(AppColor.textTertiary)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg, top: 13, bottom: 13 })
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
  }

  // 移动网络（蜂窝）可信开关
  @Builder
  private CellularCard() {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(this.t('netScenario.cellular'))
          .fontSize(FontSz.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(this.t('netScenario.cellular.detail'))
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.cellularTrusted })
        .selectedColor(AppColor.brand)
        .switchPointColor(AppColor.onBrand)
        .onChange((isOn: boolean) => {
          this.cellularTrusted = isOn;
          this.saveSettings();
        })
    }
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg, top: 13, bottom: 13 })
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
  }

  // 可信 Wi-Fi 列表（空列表显示占位提示）
  @Builder
  private TrustedWifiCard() {
    Column() {
      if (this.trustedSsids.length === 0) {
        Text(this.t('netScenario.empty'))
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .padding({ left: Space.lg, right: Space.lg, top: 16, bottom: 16 })
      } else {
        ForEach(this.trustedSsids, (ssid: string, index: number) => {
          this.SsidRow(ssid, index < this.trustedSsids.length - 1)
        }, (ssid: string) => ssid)
      }
    }
    .width('100%')
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
  }

  @Builder
  private SsidRow(ssid: string, showDivider: boolean) {
    Column() {
      Row({ space: Space.md }) {
        Text(ssid)
          .fontSize(FontSz.body)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.t('netScenario.remove'))
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.danger)
          .onClick(() => this.removeSsid(ssid))
      }
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg, top: 13, bottom: 13 })
      if (showDivider) {
        Divider().strokeWidth(0.5).color(AppColor.divider).margin({ left: Space.lg })
      }
    }
    .width('100%')
  }

  // 三个加入入口
  @Builder
  private ActionButtons() {
    Row({ space: Space.sm }) {
      this.ActionButton(this.t('netScenario.addCurrent'), () => this.addCurrentNetwork())
      this.ActionButton(this.t('netScenario.scan'), () => this.scanNearby())
      this.ActionButton(this.t('netScenario.manualAdd'), () => {
        this.showManualInput = !this.showManualInput;
      })
    }
    .width('100%')
  }

  @Builder
  private ActionButton(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(FontSz.footnote)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.brand)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(40)
    .backgroundColor(AppColor.surfaceAlt)
    .borderRadius(Radius.md)
    .onClick(action)
  }

  // 手动输入 SSID
  @Builder
  private ManualAddCard() {
    Row({ space: Space.sm }) {
      TextInput({ placeholder: this.t('netScenario.manualAddPlaceholder'), text: this.manualInput })
        .layoutWeight(1)
        .fontSize(FontSz.body)
        .onChange((value: string) => {
          this.manualInput = value;
        })
      Button(this.t('netScenario.manualAddConfirm'))
        .fontSize(FontSz.footnote)
        .backgroundColor(AppColor.brand)
        .fontColor(AppColor.onBrand)
        .height(40)
        .onClick(() => {
          this.addSsid(this.manualInput);
          this.manualInput = '';
          this.showManualInput = false;
        })
    }
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg, top: 13, bottom: 13 })
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
  }

  // 扫描结果列表
  @Builder
  private ScanResultsCard() {
    Column() {
      this.GroupLabel(this.t('netScenario.scanTitle'))
      Column() {
        ForEach(this.scanEntries, (entry: WifiScanEntry, index: number) => {
          Column() {
            Row() {
              Text(entry.ssid)
                .fontSize(FontSz.body)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: Space.lg, right: Space.lg, top: 13, bottom: 13 })
            .onClick(() => {
              this.addSsid(entry.ssid);
            })
            if (index < this.scanEntries.length - 1) {
              Divider().strokeWidth(0.5).color(AppColor.divider).margin({ left: Space.lg })
            }
          }
          .width('100%')
        }, (entry: WifiScanEntry) => entry.ssid)
      }
      .width('100%')
      .backgroundColor(AppColor.surface)
      .borderRadius(Radius.lg)
      .border({ width: 0.5, color: AppColor.border })
    }
    .width('100%')
  }

  private async loadState(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const settings = await SETTINGS_CONTROLLER.load(context);
      this.draft = SETTINGS_CONTROLLER.toDraft(settings);
      this.cellularTrusted = settings.netAutomationCellularTrusted;
      this.trustedSsids = (settings.netAutomationTrustedSsids ?? []).slice();
    } catch (error) {
      // ignore
    }
  }

  private async ensurePermissionThenScan(): Promise<boolean> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let granted = await NetworkProbe.hasLocationPermission();
    if (!granted) {
      granted = await NetworkProbe.requestLocationPermission(context);
    }
    if (!granted) {
      this.toast(this.t('netScenario.permissionNeeded'));
    }
    return granted;
  }

  private async addCurrentNetwork(): Promise<void> {
    const granted = await this.ensurePermissionThenScan();
    if (!granted) {
      return;
    }
    const ssid = await NetworkProbe.readCurrentSsid();
    if (ssid === undefined || ssid.length === 0) {
      this.toast(this.t('netScenario.currentUnavailable'));
      return;
    }
    this.addSsid(ssid);
  }

  private async scanNearby(): Promise<void> {
    const granted = await this.ensurePermissionThenScan();
    if (!granted) {
      return;
    }
    const list = NetworkProbe.readScanResults();
    if (list.length === 0) {
      this.showScanResults = false;
      this.scanEntries = [];
      this.toast(this.t('netScenario.scanEmpty'));
      return;
    }
    this.scanEntries = list;
    this.showScanResults = true;
  }

  private addSsid(ssid: string): void {
    const trimmed = ssid.trim();
    if (trimmed.length === 0) {
      return;
    }
    if (this.trustedSsids.includes(trimmed)) {
      this.toast(this.t('netScenario.duplicate'));
      return;
    }
    const next = this.trustedSsids.slice();
    next.push(trimmed);
    this.trustedSsids = next;
    this.saveSettings();
    this.toast(this.t('netScenario.currentAdded'));
  }

  private removeSsid(ssid: string): void {
    this.trustedSsids = this.trustedSsids.filter((item: string) => item !== ssid);
    this.saveSettings();
  }

  private saveSettings(): void {
    this.settingsSavePending = true;
    if (this.settingsSaveInFlight) {
      return;
    }
    this.drainSettingsSaves();
  }

  private async drainSettingsSaves(): Promise<void> {
    if (this.draft === null) {
      this.settingsSavePending = false;
      return;
    }
    this.settingsSaveInFlight = true;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      // 多次快速切换/增删只允许一个 Preferences 写入在途。写入完成后若期间又有编辑，
      // 用页面最新状态再写一次，避免较慢的旧请求最后覆盖新列表。
      while (this.settingsSavePending) {
        this.settingsSavePending = false;
        const draft = this.draft;
        if (draft === null) {
          break;
        }
        draft.netAutomationTrustedSsids = this.trustedSsids.slice();
        draft.netAutomationCellularTrusted = this.cellularTrusted;
        this.draft = SETTINGS_CONTROLLER.toDraft(await SETTINGS_CONTROLLER.save(context, draft));
      }
      // 可信集合只影响之后的自动断开决策，不进入核心、TUN 或监听配置，因此不能
      // 请求数据面重启。整批最新状态落盘后只补判一次当前网络。
      NETWORK_SCENE_MANAGER.ensureStarted(context);
      NETWORK_SCENE_MANAGER.refreshNow(true);
    } catch (error) {
      this.toast(formatOne(
        this.language,
        'error.saveSettings',
        'error',
        redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error))
      ));
    } finally {
      this.settingsSaveInFlight = false;
      // catch 执行期间仍可能收到新的用户编辑；交给一轮新的单飞写入，不递归并发。
      if (this.settingsSavePending) {
        this.saveSettings();
      }
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private t(key: string): string {
    return translate(this.language, key);
  }
}
