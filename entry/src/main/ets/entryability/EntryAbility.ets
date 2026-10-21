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
import { markNativeXrayAssetsUnavailable, prepareNativeXrayAssets } from '../native/HeyNative';
import { ASSETS_CONTROLLER } from '../features/assets/AssetsController';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Geo 双文件事务或高级单文件替换可能因上次进程被杀而中断。必须先同步恢复，
    // 再初始化 XRAY_LOCATION_ASSET/加载 Go runtime，避免核心观察到半新半旧或缺失的数据文件。
    let geoRecoveryReady = true;
    try {
      ASSETS_CONTROLLER.recoverInterruptedBuiltinGeoUpdate(this.context);
    } catch (error) {
      geoRecoveryReady = false;
      const message = redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error));
      markNativeXrayAssetsUnavailable(`Geo recovery failed: ${message}`);
      hilog.error(DOMAIN, 'testTag', 'Failed to recover interrupted Geo update before core initialization: %{public}s',
        message);
    }
    // 必须早于扫码/分享解析等任何可能懒加载 Go c-shared 核心的页面逻辑。
    // Go runtime 初始化后再由 musl setenv 改写 environ 可能触发原生崩溃。
    if (geoRecoveryReady) {
      try {
        const assetInit = prepareNativeXrayAssets(this.context.filesDir);
        if (!assetInit.ok) {
          hilog.error(DOMAIN, 'testTag', 'Failed to initialize Xray assets before native core load: %{public}s',
            redactDiagnosticText(assetInit.message));
        }
      } catch (error) {
        const message = redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error));
        markNativeXrayAssetsUnavailable(`Xray asset initialization failed: ${message}`);
        hilog.error(DOMAIN, 'testTag', 'Failed to initialize Xray assets before native core load: %{public}s',
          message);
      }
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
    // AUTO_STARTUP 通常发生在冷启动，但系统也可能把新的启动原因投递给仍存活的
    // Ability。与 onCreate 使用同一待办标志，由首页在恢复权威运行态后串行消费。
    this.stashAutoStartupLaunch(launchParam);
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
    NETWORK_SCENE_MANAGER.stop(this);
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
      hilog.error(DOMAIN, 'testTag', 'Failed to seed language. Cause: %{public}s',
        redactDiagnosticText(JSON.stringify(err)));
      AppStorage.setOrCreate(APP_LANGUAGE_STORAGE_KEY, DEFAULT_LANGUAGE);
      setupImmersive(windowStage, this.context, UI_MODE_NIGHT_SYSTEM);
    }).then(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s',
            redactDiagnosticText(JSON.stringify(err)));
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      });
      this.startNetworkObserver();
    });
  }

  // 网络变化观测与“可信网络自动断开”是两件事：观察器始终在 UIAbility 生命周期内运行，
  // 自动化开关只控制是否执行断开。这样关闭自动化时也能在承载变化后刷新真实出口。
  private startNetworkObserver(): void {
    NETWORK_SCENE_MANAGER.ensureStarted(this.context, this);
  }

  // 进入前台时强制补判一次，覆盖 UI 进程被挂起期间错过的承载变化。
  private refreshNetworkObserver(): void {
    NETWORK_SCENE_MANAGER.ensureStarted(this.context, this);
    NETWORK_SCENE_MANAGER.refreshNow(true);
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    this.applyStoredColorMode();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.refreshNetworkObserver();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private applyStoredColorMode(): void {
    SettingsStore.load(this.context).then((settings) => {
      applyColorMode(this.context, settings.uiModeNight);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to load colorMode. Cause: %{public}s',
        redactDiagnosticText(JSON.stringify(err)));
      try {
        applyColorMode(this.context, UI_MODE_NIGHT_SYSTEM);
      } catch (fallbackErr) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set fallback colorMode. Cause: %{public}s',
          redactDiagnosticText(JSON.stringify(fallbackErr)));
      }
    });
  }
}
