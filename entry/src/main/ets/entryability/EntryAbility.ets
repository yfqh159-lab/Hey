import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { applyColorMode } from '../core/ColorMode';
import { setupImmersive } from '../core/Immersive';
import { deepLinkUriFromWant } from '../core/DeepLink';
import { UI_MODE_NIGHT_SYSTEM } from '../core/Profile';
import { extractSharedTextFromWant } from '../core/SharedTextImport';
import { APP_LANGUAGE_STORAGE_KEY, DEFAULT_LANGUAGE } from '../core/I18n';
import { SettingsStore } from '../storage/SettingsStore';
import { NETWORK_SCENE_MANAGER } from '../services/NetworkSceneManager';
import { prepareNativeXrayAssets } from '../native/HeyNative';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 必须早于扫码/分享解析等任何可能懒加载 Go c-shared 核心的页面逻辑。
    // Go runtime 初始化后再由 musl setenv 改写 environ 可能触发原生崩溃。
    const assetInit = prepareNativeXrayAssets(this.context.filesDir);
    if (!assetInit.ok) {
      hilog.error(DOMAIN, 'testTag', 'Failed to initialize Xray assets before native core load: %{public}s', assetInit.message);
    }
    this.applyStoredColorMode();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.stashDeepLink(want);
    this.stashSharedTextImport(want);
    this.stashAutoStartupLaunch(launchParam);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.stashDeepLink(want);
    this.stashSharedTextImport(want);
  }

  // Stash a deep-link Want uri (hey://add-source|add-endpoint?url=...) or
  // declared shortcut parameters for the Index page to pick up on show. Set
  // before the window stage loads on cold start, and on every onNewWant for
  // warm starts.
  private stashDeepLink(want: Want): void {
    const uri = deepLinkUriFromWant({
      uri: want.uri,
      parameters: want.parameters
    });
    if (uri.length > 0) {
      AppStorage.setOrCreate('pendingDeepLink', uri);
    }
  }

  private stashSharedTextImport(want: Want): void {
    const payload = extractSharedTextFromWant({
      action: want.action,
      type: want.type,
      parameters: want.parameters
    });
    if (payload.length > 0) {
      AppStorage.setOrCreate('pendingSharedTextImport', payload);
    }
  }

  private stashAutoStartupLaunch(launchParam: AbilityConstant.LaunchParam): void {
    if (launchParam.launchReason === AbilityConstant.LaunchReason.AUTO_STARTUP) {
      AppStorage.setOrCreate('pendingAutoStartupLaunch', true);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // Seed the globally-observable app language (AppStorage 'appLanguage') from
    // the persisted settings BEFORE loading the first page, so every page's
    // @StorageProp/@StorageLink('appLanguage') renders in the saved language on
    // the very first frame instead of the default. Once seeded, switching the
    // language anywhere updates this single source and re-renders all pages live.
    this.seedLanguageThenLoad(windowStage);
  }

  private seedLanguageThenLoad(windowStage: window.WindowStage): void {
    SettingsStore.load(this.context).then((settings) => {
      AppStorage.setOrCreate(APP_LANGUAGE_STORAGE_KEY, settings.language);
      // 全屏沉浸 + 采集安全区 + 系统栏配色，须在首帧加载前就绪
      setupImmersive(windowStage, this.context, settings.uiModeNight);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to seed language. Cause: %{public}s', JSON.stringify(err));
      AppStorage.setOrCreate(APP_LANGUAGE_STORAGE_KEY, DEFAULT_LANGUAGE);
      setupImmersive(windowStage, this.context, UI_MODE_NIGHT_SYSTEM);
    }).then(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      });
      this.startNetSceneIfEnabled();
    });
  }

  // 网络场景自动化：App 启动时若总开关已开则启动监听（幂等）。
  private startNetSceneIfEnabled(): void {
    SettingsStore.load(this.context).then((settings) => {
      if (settings.netAutomationEnabled) {
        NETWORK_SCENE_MANAGER.ensureStarted(this.context);
      }
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'net scene start failed: %{public}s', JSON.stringify(err));
    });
  }

  // 进入前台时补判一次，覆盖后台错过的网络变化。
  private refreshNetScene(): void {
    SettingsStore.load(this.context).then((settings) => {
      if (settings.netAutomationEnabled) {
        NETWORK_SCENE_MANAGER.ensureStarted(this.context);
        NETWORK_SCENE_MANAGER.refreshNow(true);
      }
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'net scene refresh failed: %{public}s', JSON.stringify(err));
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    this.applyStoredColorMode();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.refreshNetScene();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private applyStoredColorMode(): void {
    SettingsStore.load(this.context).then((settings) => {
      applyColorMode(this.context, settings.uiModeNight);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to load colorMode. Cause: %{public}s', JSON.stringify(err));
      try {
        applyColorMode(this.context, UI_MODE_NIGHT_SYSTEM);
      } catch (fallbackErr) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set fallback colorMode. Cause: %{public}s', JSON.stringify(fallbackErr));
      }
    });
  }
}
