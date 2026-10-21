import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import fs from '@ohos.file.fs';
import {
  BUILTIN_GEO_DATA_FILE_NAMES,
  DEFAULT_GEO_RELEASE_API,
  GEO_UPDATE_BACKUP_SUFFIX,
  GEO_UPDATE_COMMIT_FILE,
  GEO_UPDATE_STATE_FILE,
  GEO_UPDATE_TEMP_SUFFIX,
  GeoRecoveryAction,
  GeoTransactionState,
  MAX_GEO_DATA_BYTES,
  MAX_GEO_HTTP_DATA_BYTES,
  MAX_GEO_TEXT_BYTES,
  areAllowedGeoAssetRedirects,
  buildGeoChecksumUrl,
  encodeGeoTransactionState,
  isAllowedGeoAssetRedirect,
  isPlausibleGeoData,
  isValidGeoCommitMarker,
  parseGeoTransactionState,
  parseHttpRedirectLocation,
  parseDefaultGeoRelease,
  parseSha256Checksum,
  normalizeGeoAssetDownloadUrl,
  resolveGeoRecoveryAction,
  resolveStandaloneAssetRecoveryAction
} from '../../core/GeoAssets';
import { redactDiagnosticText } from '../../core/DiagnosticRedaction';
import { APP_HTTP_USER_AGENT } from '../../core/HttpDefaults';
import { AppLanguage, isProxyOnlyRuntimeMode } from '../../core/Profile';
import {
  LOCAL_HTTP_PROXY_HOST,
  PROXY_ONLY_INTERNAL_HTTP_PROXY_PORT,
  VPN_INTERNAL_HTTP_PROXY_PORT
} from '../../core/XrayConfig';
import { translate } from '../../core/I18n';
import { formatTwo } from '../../utils/LocalizationPresenter';
import { AssetStore, CustomAssetUrl, GeoAssetMetadata, GeoUpdateMetadata } from '../../storage/AssetStore';
import { SHARED_RUNTIME_CONTROLLER } from '../runtime/RuntimeController';

export interface AssetDownloadProxyPlan {
  proxyPort: number;
}

export function buildAssetDownloadProxyPorts(proxyPort: number): Array<number> {
  if (!isValidAssetDownloadProxyPort(proxyPort)) {
    return [0];
  }
  return [Math.floor(proxyPort)];
}

export function resolveAssetDownloadProxyPlan(
  mode: string | undefined,
  runtimeMayOwnNetwork: boolean
): AssetDownloadProxyPlan {
  if (!runtimeMayOwnNetwork) {
    return { proxyPort: 0 };
  }
  return {
    proxyPort: isProxyOnlyRuntimeMode(mode) ? PROXY_ONLY_INTERNAL_HTTP_PROXY_PORT : VPN_INTERNAL_HTTP_PROXY_PORT
  };
}

export interface BuiltinGeoUpdateResult {
  changed: boolean;
  version: string;
  checkedAt: number;
  assets: Array<GeoAssetMetadata>;
  metadataSaved: boolean;
}

interface StagedGeoAsset {
  fileName: string;
  targetPath: string;
  tempPath: string;
  backupPath: string;
  hadOriginal: boolean;
  installed: boolean;
}

const GEO_METADATA_INVALID_FILE: string = '.geo-metadata.invalid';
const MAX_ASSET_REDIRECTS: number = 5;
const GEO_TEXT_HTTP_DEADLINE_MS: number = 45000;
const GEO_DATA_HTTP_DEADLINE_MS: number = 75000;
const GEO_METADATA_STORE_DEADLINE_MS: number = 5000;

function withAssetRequestTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timerId = setTimeout(() => reject(new Error('Geo HTTP request timed out')), timeoutMs);
    promise.then((value: T) => {
      clearTimeout(timerId);
      resolve(value);
    }, (error: Object) => {
      clearTimeout(timerId);
      reject(error);
    });
  });
}

function withAssetStoreTimeout<T>(promise: Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timerId = setTimeout(() => reject(new Error('Asset storage timed out')),
      GEO_METADATA_STORE_DEADLINE_MS);
    promise.then((value: T) => {
      clearTimeout(timerId);
      resolve(value);
    }, (error: Object) => {
      clearTimeout(timerId);
      reject(error);
    });
  });
}

function isValidAssetDownloadProxyPort(proxyPort: number): boolean {
  return typeof proxyPort === 'number' && Math.floor(proxyPort) === proxyPort && proxyPort > 0 && proxyPort <= 65535;
}

export class AssetsController {
  // 所有 .dat 文件替换/删除共用一把进程内互斥锁。页面离开后重新进入会丢失本地
  // downloadingFile 状态，因此不能只依赖 UI 防止双文件事务与单文件操作竞争。
  private assetMutationRunning: boolean = false;
  // Preferences 调用超时只会结束本轮等待，不能取消 ArkData 底层任务。保留原 Promise
  // 直到真正结算，期间不再向同一串行存储队列叠加失败/成功元数据任务。
  private geoMetadataStoreInFlight: Promise<void> | null = null;
  private geoMetadataLoadInFlight: Promise<GeoUpdateMetadata> | null = null;
  private customAssetsLoadInFlight: Promise<Array<CustomAssetUrl>> | null = null;
  private obsoleteGeoSourceCleanupInFlight: Promise<void> | null = null;

  isGeoMetadataStorePending(): boolean {
    return this.geoMetadataStoreInFlight !== null;
  }

  isAssetMutationRunning(): boolean {
    return this.assetMutationRunning;
  }

  async loadGeoUpdateMetadata(context: common.Context): Promise<GeoUpdateMetadata> {
    if (this.geoMetadataLoadInFlight === null) {
      const promise = AssetStore.loadGeoUpdateMetadata(context);
      this.geoMetadataLoadInFlight = promise;
      promise.then(
        (_metadata: GeoUpdateMetadata): void => this.releaseGeoMetadataLoad(promise),
        (_error: Object): void => this.releaseGeoMetadataLoad(promise)
      );
    }
    const pending = this.geoMetadataLoadInFlight;
    if (pending === null) {
      throw new Error('Geo metadata read did not start');
    }
    return await withAssetStoreTimeout(pending);
  }

  private releaseGeoMetadataLoad(promise: Promise<GeoUpdateMetadata>): void {
    if (this.geoMetadataLoadInFlight === promise) {
      this.geoMetadataLoadInFlight = null;
    }
  }

  async loadCustomAssets(context: common.Context): Promise<Array<CustomAssetUrl>> {
    if (this.customAssetsLoadInFlight === null) {
      const promise = AssetStore.load(context);
      this.customAssetsLoadInFlight = promise;
      promise.then(
        (_assets: Array<CustomAssetUrl>): void => this.releaseCustomAssetsLoad(promise),
        (_error: Object): void => this.releaseCustomAssetsLoad(promise)
      );
    }
    const pending = this.customAssetsLoadInFlight;
    if (pending === null) {
      throw new Error('Custom Geo source read did not start');
    }
    const assets = await withAssetStoreTimeout(pending);
    return assets.map((item: CustomAssetUrl): CustomAssetUrl => ({
      id: item.id,
      name: item.name,
      url: item.url
    }));
  }

  async clearGeoUpdateMetadata(context: common.Context): Promise<void> {
    // 清理与保存必须共用同一个单任务闩锁和截止时间。ArkData
    // Promise 超时不代表底层操作已取消；在它真正结算前拒绝再次
    // 写入，避免迟到的清理删掉之后一次成功检查的新记录。
    await this.runGeoMetadataStoreOperation(
      (): Promise<void> => AssetStore.clearGeoUpdateMetadata(context)
    );
  }

  private releaseCustomAssetsLoad(promise: Promise<Array<CustomAssetUrl>>): void {
    if (this.customAssetsLoadInFlight === promise) {
      this.customAssetsLoadInFlight = null;
    }
  }

  scheduleObsoleteGeoSourceCleanup(context: common.Context): void {
    if (this.obsoleteGeoSourceCleanupInFlight !== null) {
      return;
    }
    const promise = this.cleanupObsoleteGeoSource(context);
    this.obsoleteGeoSourceCleanupInFlight = promise;
    promise.then(
      (): void => this.releaseObsoleteGeoSourceCleanup(promise),
      (_error: Object): void => this.releaseObsoleteGeoSourceCleanup(promise)
    );
  }

  private async cleanupObsoleteGeoSource(context: common.Context): Promise<void> {
    const store = await preferences.getPreferences(context, 'hey_vpn_assets');
    if (await store.has('geo_source_url')) {
      await store.delete('geo_source_url');
      await store.flush();
    }
  }

  private releaseObsoleteGeoSourceCleanup(promise: Promise<void>): void {
    if (this.obsoleteGeoSourceCleanupInFlight === promise) {
      this.obsoleteGeoSourceCleanupInFlight = null;
    }
  }
  
  private pad(val: number): string {
    return val < 10 ? `0${val}` : `${val}`;
  }

  private t(language: AppLanguage, key: string): string {
    return translate(language, key);
  }

  // 获取本地 dat 文件大小和修改日期
  getFileStatus(context: common.Context, fileName: string, language: AppLanguage): string {
    const path = `${context.filesDir}/${fileName}`;
    try {
      if (fs.accessSync(path)) {
        const stat = fs.statSync(path);
        const sizeMb = (stat.size / (1024 * 1024)).toFixed(2);
        const date = new Date(stat.mtime * 1000);
        const timeStr = `${date.getFullYear()}/${this.pad(date.getMonth() + 1)}/${this.pad(date.getDate())} ${this.pad(date.getHours())}:${this.pad(date.getMinutes())}:${this.pad(date.getSeconds())}`;
        return formatTwo(language, 'assets.fileStatus', 'size', sizeMb, 'time', timeStr);
      }
    } catch (e) {}
    return this.t(language, 'assets.notDownloaded');
  }

  // 获取自定义资源的大小
  getCustomFileStatus(context: common.Context, name: string, language: AppLanguage): string {
    const path = `${context.filesDir}/${name}.dat`;
    try {
      if (fs.accessSync(path)) {
        const stat = fs.statSync(path);
        const sizeMb = (stat.size / (1024 * 1024)).toFixed(2);
        return `${sizeMb} MB`;
      }
    } catch (e) {}
    return this.t(language, 'assets.notDownloaded');
  }

  // Preferences 中的版本/哈希只是上次检查记录，不能脱离沙箱中的实际文件直接展示。
  // 文件替换成功但元数据保存失败、用户导入/覆盖中途进程退出等情况下，重新计算两个
  // 核心文件的摘要；只有文件名、大小和 SHA-256 全部一致才承认记录仍代表当前资源。
  async isBuiltinGeoMetadataCurrent(
    context: common.Context,
    metadata: GeoUpdateMetadata
  ): Promise<boolean> {
    if (this.fileExists(`${context.filesDir}/${GEO_METADATA_INVALID_FILE}`)) {
      return false;
    }
    if (metadata.assets.length === 0) {
      return metadata.version.length === 0;
    }
    if (metadata.assets.length !== BUILTIN_GEO_DATA_FILE_NAMES.length) {
      return false;
    }
    try {
      for (let index = 0; index < BUILTIN_GEO_DATA_FILE_NAMES.length; index++) {
        const fileName = BUILTIN_GEO_DATA_FILE_NAMES[index];
        let matched: GeoAssetMetadata | null = null;
        for (let assetIndex = 0; assetIndex < metadata.assets.length; assetIndex++) {
          if (metadata.assets[assetIndex].fileName === fileName) {
            if (matched !== null) {
              return false;
            }
            matched = metadata.assets[assetIndex];
          }
        }
        if (matched === null || !/^[0-9a-f]{64}$/.test(matched.sha256) ||
          !Number.isFinite(matched.size) || Math.floor(matched.size) !== matched.size) {
          return false;
        }
        const data = this.readFileData(`${context.filesDir}/${fileName}`);
        if (data === null || !isPlausibleGeoData(data, matched.size) ||
          await this.sha256(data) !== matched.sha256) {
          return false;
        }
      }
      return true;
    } catch (error) {
      return false;
    }
  }

  // 检查可信默认发布源。两个核心文件全部通过版本、大小、格式和 SHA-256 校验后才一起替换。
  // 若安装阶段失败，则回滚本次已替换的文件；进程中断留下的事务状态会在下次检查时恢复。
  async checkAndUpdateBuiltinGeo(context: common.Context): Promise<BuiltinGeoUpdateResult> {
    if (this.assetMutationRunning) {
      throw new Error('Asset update is already running');
    }
    this.assetMutationRunning = true;
    try {
      return await this.performBuiltinGeoUpdate(context);
    } catch (error) {
      // 失败记录只是可观察性元数据，ArkData 永久 pending 时不能反过来占住资源
      // 更新互斥锁。旧 Geo 文件仍是权威结果；记录迟到也没有文件系统副作用。
      try {
        await this.runGeoMetadataStoreOperation(
          (): Promise<void> => this.recordGeoUpdateFailure(context));
      } catch (_metadataError) {
        // keep the original download/check/install error
      }
      throw error;
    } finally {
      this.assetMutationRunning = false;
    }
  }

  private async performBuiltinGeoUpdate(context: common.Context): Promise<BuiltinGeoUpdateResult> {
    this.recoverInterruptedBuiltinGeoUpdate(context);
    const proxyPlan = this.resolveDownloadProxyPlan();
    const releaseText = await this.requestText(DEFAULT_GEO_RELEASE_API, proxyPlan);
    const parsed = parseDefaultGeoRelease(releaseText);
    if (!parsed.ok || parsed.manifest === null) {
      throw new Error(parsed.message.length > 0 ? parsed.message : 'invalid release metadata');
    }

    const manifest = parsed.manifest;
    const checkedAt = Date.now();
    const staged = new Array<StagedGeoAsset>();
    const metadata = new Array<GeoAssetMetadata>();
    let transactionCommitted = false;

    try {
      for (let index = 0; index < manifest.files.length; index++) {
        const releaseFile = manifest.files[index];
        const checksumText = await this.requestText(releaseFile.checksumUrl, proxyPlan);
        const expectedSha256 = parseSha256Checksum(checksumText, releaseFile.fileName);
        if (expectedSha256.length !== 64) {
          throw new Error(`${releaseFile.fileName}: invalid SHA-256 checksum`);
        }

        const targetPath = `${context.filesDir}/${releaseFile.fileName}`;
        const existing = this.readFileData(targetPath);
        const existingSha256 = existing === null ? '' : await this.sha256(existing);
        if (existingSha256 === expectedSha256) {
          metadata.push(this.geoMetadataForExisting(targetPath, releaseFile.fileName, expectedSha256));
          continue;
        }

        const data = await this.requestData(releaseFile.downloadUrl, proxyPlan);
        if (!isPlausibleGeoData(data, releaseFile.declaredSize)) {
          throw new Error(`${releaseFile.fileName}: downloaded data failed size or format validation`);
        }
        const actualSha256 = await this.sha256(data);
        if (actualSha256 !== expectedSha256) {
          throw new Error(`${releaseFile.fileName}: SHA-256 mismatch`);
        }

        const tempPath = `${targetPath}${GEO_UPDATE_TEMP_SUFFIX}`;
        this.removeFileIfExists(tempPath);
        this.writeFileData(tempPath, data);
        staged.push({
          fileName: releaseFile.fileName,
          targetPath,
          tempPath,
          backupPath: `${targetPath}${GEO_UPDATE_BACKUP_SUFFIX}`,
          hadOriginal: this.fileExists(targetPath),
          installed: false
        });
        metadata.push({
          fileName: releaseFile.fileName,
          sha256: expectedSha256,
          size: data.byteLength,
          updatedAt: checkedAt
        });
      }

      if (staged.length > 0) {
        this.installStagedGeoAssets(context, staged);
        transactionCommitted = true;
      }

      const updateMetadata: GeoUpdateMetadata = {
        version: manifest.version,
        source: manifest.source,
        checkedAt,
        result: staged.length > 0 ? 'updated' : 'latest',
        assets: metadata
      };
      let metadataSaved = true;
      try {
        await this.runGeoMetadataStoreOperation(
          (): Promise<void> => AssetStore.saveGeoUpdateMetadata(context, updateMetadata));
        // 上一次文件安装成功、Preferences 保存失败时可能留下失效标志。只有本次记录
        // 已持久化后才移除；移除失败同样视为记录未能安全启用。
        this.removeFileStrictIfExists(`${context.filesDir}/${GEO_METADATA_INVALID_FILE}`);
      } catch (error) {
        metadataSaved = false;
        try {
          this.writeFileData(`${context.filesDir}/${GEO_METADATA_INVALID_FILE}`, new Uint8Array([1]).buffer);
        } catch (markerError) {
          // 文件摘要复核仍能识别通常的内容变化；标志是相同内容跨版本时的额外防线。
        }
      }
      if (transactionCommitted) {
        this.finishGeoTransaction(context, staged);
      }
      return {
        changed: staged.length > 0,
        version: manifest.version,
        checkedAt,
        assets: metadata,
        metadataSaved
      };
    } catch (error) {
      if (!transactionCommitted) {
        this.rollbackGeoTransaction(context, staged);
      }
      for (let index = 0; index < staged.length; index++) {
        this.removeFileIfExists(staged[index].tempPath);
      }
      throw error;
    }
  }

  private async recordGeoUpdateFailure(context: common.Context): Promise<void> {
    try {
      const previous = await this.loadGeoUpdateMetadata(context);
      await AssetStore.saveGeoUpdateMetadata(context, {
        version: previous.version,
        source: previous.source,
        checkedAt: Date.now(),
        result: 'failed',
        assets: previous.assets
      });
    } catch (error) {
      // The original files are still authoritative; failure metadata is best effort only.
    }
  }

  private async runGeoMetadataStoreOperation(operation: () => Promise<void>): Promise<void> {
    if (this.geoMetadataStoreInFlight !== null) {
      throw new Error('Geo metadata storage is still pending');
    }
    const promise = operation();
    this.geoMetadataStoreInFlight = promise;
    promise.then(
      (): void => this.releaseGeoMetadataStoreOperation(promise),
      (_error: Object): void => this.releaseGeoMetadataStoreOperation(promise)
    );
    await withAssetStoreTimeout(promise);
  }

  private releaseGeoMetadataStoreOperation(promise: Promise<void>): void {
    if (this.geoMetadataStoreInFlight === promise) {
      this.geoMetadataStoreInFlight = null;
    }
  }

  // 执行资源网络更新下载
  async downloadAsset(
    context: common.Context,
    fileName: string,
    url: string,
    language: AppLanguage,
    onStart: () => void,
    onSuccess: () => void,
    onError: (errMsg: string) => void,
    onComplete: () => void
  ): Promise<void> {
    if (this.assetMutationRunning) {
      const busyMessage = this.t(language, 'assets.downloadBusy');
      promptAction.showToast({ message: busyMessage });
      onError(busyMessage);
      onComplete();
      return;
    }
    this.assetMutationRunning = true;

    const targetFileName = fileName.endsWith('.dat') ? fileName : `${fileName}.dat`;
    const targetPath = `${context.filesDir}/${targetFileName}`;
    // 临时文件始终从最终目标派生，便于冷启动统一识别和清理中断的单文件替换。
    const tempPath = `${targetPath}.tmp`;

    try {
      onStart();
      const proxyPlan = this.resolveDownloadProxyPlan();
      promptAction.showToast({ message: this.t(language, 'assets.downloading').replace('{title}', fileName) });
      // 内置文件的高级 URL 与自定义 .dat 使用同一条校验路径：远端必须在
      // 数据文件旁提供 `${url}.sha256sum`，任何失败都不会覆盖现有文件。
      await this.downloadVerifiedGeo(fileName, url, tempPath, targetPath, proxyPlan);
      promptAction.showToast({ message: this.t(language, 'assets.downloadSuccess').replace('{title}', fileName) });
      onSuccess();
    } catch (error) {
      try {
        if (fs.accessSync(tempPath)) {
          fs.unlinkSync(tempPath);
        }
      } catch (e) {}

      const errMsg = redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error));
      promptAction.showToast({
        message: this.t(language, 'assets.downloadFailed')
          .replace('{title}', fileName)
          .replace('{error}', errMsg)
      });
      onError(errMsg);
    } finally {
      this.assetMutationRunning = false;
      onComplete();
    }
  }

  // 逐个刷新用户添加的远程资源（http/https；local:// 本地导入跳过）。
  async downloadAllAssets(
    context: common.Context,
    language: AppLanguage,
    remoteCustomAssets: Array<CustomAssetUrl>,
    onProgress: (fileName: string) => void,
    onComplete: () => void
  ): Promise<void> {
    if (this.assetMutationRunning) {
      promptAction.showToast({ message: this.t(language, 'assets.downloadBusy') });
      onComplete();
      return;
    }
    this.assetMutationRunning = true;
    try {
      promptAction.showToast({ message: this.t(language, 'assets.updatingAll') });
      const proxyPlan = this.resolveDownloadProxyPlan();

      let total = 0;
      let success = 0;

      for (let index = 0; index < remoteCustomAssets.length; index++) {
        const asset = remoteCustomAssets[index];
        if (!this.isRemoteAssetUrl(asset.url)) {
          continue;
        }
        onProgress(asset.name);
        total++;
        if (await this.performDownload(context, `${asset.name}.dat`, asset.url.trim(), proxyPlan)) {
          success++;
        }
      }

      if (total > 0 && success === total) {
        promptAction.showToast({ message: this.t(language, 'assets.updateAllSuccess') });
      } else if (success > 0) {
        promptAction.showToast({ message: this.t(language, 'assets.partialUpdateSuccess') });
      } else {
        promptAction.showToast({ message: this.t(language, 'assets.updateAllFailed') });
      }
    } catch (error) {
      promptAction.showToast({
        message: this.t(language, 'assets.updateAllError')
          .replace('{error}', redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error)))
      });
    } finally {
      this.assetMutationRunning = false;
      onComplete();
    }
  }

  private isRemoteAssetUrl(url: string): boolean {
    return normalizeGeoAssetDownloadUrl(url).length > 0;
  }

  private async performDownload(
    context: common.Context,
    fileName: string,
    url: string,
    proxyPlan: AssetDownloadProxyPlan
  ): Promise<boolean> {
    const tempPath = `${context.filesDir}/${fileName}.tmp`;
    const targetPath = `${context.filesDir}/${fileName}`;
    try {
      await this.downloadVerifiedGeo(fileName, url, tempPath, targetPath, proxyPlan);
      return true;
    } catch (error) {
      try {
        if (fs.accessSync(tempPath)) {
          fs.unlinkSync(tempPath);
        }
      } catch (e) {}
    }
    return false;
  }

  private resolveDownloadProxyPlan(): AssetDownloadProxyPlan {
    const runtime = SHARED_RUNTIME_CONTROLLER.snapshot();
    // 必须使用当前会话的实际模式，而不是可能已保存、尚待重启才生效的新设置。
    // 已连接时代理入口失败就保留旧文件并报错，不能让被排除在 TUN 外的 Hey 静默直连泄漏。
    // STARTING/STOPPING 均按可能仍持有底层网络处理；ERROR 只有在清理尚未确认时才
    // fail-closed。配置校验等发生在创建数据面之前的普通错误允许直连更新。
    return resolveAssetDownloadProxyPlan(runtime.runtimeMode, SHARED_RUNTIME_CONTROLLER.mayOwnNetwork());
  }

  private async downloadVerifiedGeo(
    fileName: string,
    url: string,
    tempPath: string,
    targetPath: string,
    proxyPlan: AssetDownloadProxyPlan
  ): Promise<void> {
    const normalizedUrl = normalizeGeoAssetDownloadUrl(url);
    const checksumUrl = buildGeoChecksumUrl(normalizedUrl);
    if (normalizedUrl.length === 0 || checksumUrl.length === 0) {
      throw new Error(`${fileName}: Geo download URL must use HTTPS`);
    }
    const checksumText = await this.requestText(checksumUrl, proxyPlan);
    const expectedSha256 = parseSha256Checksum(checksumText);
    if (expectedSha256.length !== 64) {
      throw new Error(`${fileName}: invalid SHA-256 checksum`);
    }
    const data = await this.requestData(normalizedUrl, proxyPlan);
    if (!isPlausibleGeoData(data)) {
      throw new Error(`${fileName}: downloaded data failed size or format validation`);
    }
    const actualSha256 = await this.sha256(data);
    if (actualSha256 !== expectedSha256) {
      throw new Error(`${fileName}: SHA-256 mismatch`);
    }
    this.writeAssetData(tempPath, targetPath, data);
  }

  private async requestText(url: string, proxyPlan: AssetDownloadProxyPlan): Promise<string> {
    const ports = buildAssetDownloadProxyPorts(proxyPlan.proxyPort);
    let lastError = '';
    for (let index = 0; index < ports.length; index++) {
      try {
        return await this.requestAssetText(url, ports[index]);
      } catch (error) {
        lastError = error instanceof Error ? error.message : JSON.stringify(error);
      }
    }
    throw new Error(lastError.length > 0 ? lastError : 'request failed');
  }

  private async requestData(url: string, proxyPlan: AssetDownloadProxyPlan): Promise<ArrayBuffer> {
    const ports = buildAssetDownloadProxyPorts(proxyPlan.proxyPort);
    let lastError = '';
    for (let index = 0; index < ports.length; index++) {
      try {
        return await this.requestAssetData(url, ports[index]);
      } catch (error) {
        lastError = error instanceof Error ? error.message : JSON.stringify(error);
      }
    }
    throw new Error(lastError.length > 0 ? lastError : 'download failed');
  }

  private async requestAssetText(
    url: string,
    proxyPort: number,
    redirectCount: number = 0,
    originalUrl: string = url
  ): Promise<string> {
    if (redirectCount > MAX_ASSET_REDIRECTS) {
      throw new Error('HTTP redirect limit reached');
    }
    const request = http.createHttp();
    const observedRedirects = new Array<string>();
    let lastObservedRedirect = '';
    const redirectHeaderListener = (headers: Object): void => {
      const redirectUrl = parseHttpRedirectLocation(JSON.stringify(headers));
      if (redirectUrl.length > 0 && redirectUrl !== lastObservedRedirect) {
        observedRedirects.push(redirectUrl);
        lastObservedRedirect = redirectUrl;
      }
    };
    try {
      request.on('headersReceive', redirectHeaderListener);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        // request() 会把结果整体返回；在解析前由 Network Kit 硬性限制响应体，既防止
        // 异常元数据耗尽内存，也避免依赖实现默认值。
        maxLimit: MAX_GEO_TEXT_BYTES,
        readTimeout: 30000,
        connectTimeout: 15000,
        usingCache: false,
        header: {
          'User-Agent': APP_HTTP_USER_AGENT,
          'Accept': 'application/json, text/plain, application/octet-stream, */*',
          'Accept-Encoding': 'identity'
        }
      };
      if (isValidAssetDownloadProxyPort(proxyPort)) {
        options.usingProxy = {
          host: LOCAL_HTTP_PROXY_HOST,
          port: proxyPort,
          exclusionList: []
        };
      }
      // NetworkKit 参数超时在部分设备实现上不足以保证 Promise 结算。外层截止时间
      // 负责最终释放 assetMutationRunning；超时只失败并保留旧文件，不会改走直连。
      const response = await withAssetRequestTimeout(
        request.request(url, options), GEO_TEXT_HTTP_DEADLINE_MS);
      redirectHeaderListener(response.header);
      if (!areAllowedGeoAssetRedirects(originalUrl, observedRedirects,
        MAX_ASSET_REDIRECTS - redirectCount)) {
        throw new Error('HTTP redirect target is not allowed');
      }
      const responseCode = Number(response.responseCode);
      if (this.isRedirectCode(responseCode)) {
        const redirectUrl = parseHttpRedirectLocation(JSON.stringify(response.header));
        if (!isAllowedGeoAssetRedirect(originalUrl, redirectUrl)) {
          throw new Error('HTTP redirect target is not allowed');
        }
        return await this.requestAssetText(redirectUrl, proxyPort, redirectCount + 1, originalUrl);
      }
      if (responseCode < 200 || responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      if (typeof response.result === 'string') {
        if (response.result.length > MAX_GEO_TEXT_BYTES) {
          throw new Error('HTTP text response is too large');
        }
        return response.result;
      }
      if (response.result instanceof ArrayBuffer) {
        if (response.result.byteLength > MAX_GEO_TEXT_BYTES) {
          throw new Error('HTTP text response is too large');
        }
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(response.result));
      }
      const objectText = JSON.stringify(response.result);
      if (objectText === undefined) {
        return '';
      }
      if (objectText.length > MAX_GEO_TEXT_BYTES) {
        throw new Error('HTTP text response is too large');
      }
      return objectText;
    } finally {
      try {
        request.off('headersReceive', redirectHeaderListener);
      } catch (_error) {
        // destroy() is the authoritative cleanup even if a device rejects late listener removal.
      }
      request.destroy();
    }
  }

  private async requestAssetData(
    url: string,
    proxyPort: number,
    redirectCount: number = 0,
    originalUrl: string = url
  ): Promise<ArrayBuffer> {
    if (redirectCount > MAX_ASSET_REDIRECTS) {
      throw new Error('HTTP redirect limit reached');
    }
    const request = http.createHttp();
    const observedRedirects = new Array<string>();
    let lastObservedRedirect = '';
    const redirectHeaderListener = (headers: Object): void => {
      const redirectUrl = parseHttpRedirectLocation(JSON.stringify(headers));
      if (redirectUrl.length > 0 && redirectUrl !== lastObservedRedirect) {
        observedRedirects.push(redirectUrl);
        lastObservedRedirect = redirectUrl;
      }
    };
    try {
      request.on('headersReceive', redirectHeaderListener);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        // Geo 数据可能超过 Network Kit 的 5 MiB 默认上限。100 MiB 是该字段的官方
        // 最大值；完成后还会再次校验实际长度、发布声明大小、格式和 SHA-256。
        maxLimit: MAX_GEO_HTTP_DATA_BYTES,
        readTimeout: 60000,
        connectTimeout: 15000,
        usingCache: false,
        header: {
          'User-Agent': APP_HTTP_USER_AGENT,
          'Accept': 'application/octet-stream, */*',
          'Accept-Encoding': 'identity'
        }
      };
      if (isValidAssetDownloadProxyPort(proxyPort)) {
        options.usingProxy = {
          host: LOCAL_HTTP_PROXY_HOST,
          port: proxyPort,
          exclusionList: []
        };
      }
      const response = await withAssetRequestTimeout(
        request.request(url, options), GEO_DATA_HTTP_DEADLINE_MS);
      redirectHeaderListener(response.header);
      if (!areAllowedGeoAssetRedirects(originalUrl, observedRedirects,
        MAX_ASSET_REDIRECTS - redirectCount)) {
        throw new Error('HTTP redirect target is not allowed');
      }
      const responseCode = Number(response.responseCode);
      if (this.isRedirectCode(responseCode)) {
        const redirectUrl = parseHttpRedirectLocation(JSON.stringify(response.header));
        if (!isAllowedGeoAssetRedirect(originalUrl, redirectUrl)) {
          throw new Error('HTTP redirect target is not allowed');
        }
        return await this.requestAssetData(redirectUrl, proxyPort, redirectCount + 1, originalUrl);
      }
      if (responseCode < 200 || responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      if (!(response.result instanceof ArrayBuffer)) {
        throw new Error('HTTP response did not contain binary data');
      }
      if (response.result.byteLength > MAX_GEO_HTTP_DATA_BYTES) {
        throw new Error('HTTP binary response is too large');
      }
      return response.result;
    } finally {
      try {
        request.off('headersReceive', redirectHeaderListener);
      } catch (_error) {
        // destroy() is the authoritative cleanup even if a device rejects late listener removal.
      }
      request.destroy();
    }
  }

  private isRedirectCode(code: number): boolean {
    return code === 301 || code === 302 || code === 303 || code === 307 || code === 308;
  }

  private writeAssetData(tempPath: string, targetPath: string, data: ArrayBuffer): void {
    this.writeFileData(tempPath, data);
    this.replaceTempFileSafely(tempPath, targetPath);
  }

  private replaceTempFileSafely(tempPath: string, targetPath: string): void {
    const backupPath = `${targetPath}.update.bak`;
    try {
      if (this.fileExists(backupPath)) {
        if (this.fileExists(targetPath)) {
          this.removeFileStrictIfExists(backupPath);
        } else {
          fs.renameSync(backupPath, targetPath);
        }
      }
      const hadOriginal = this.fileExists(targetPath);
      if (hadOriginal) {
        fs.renameSync(targetPath, backupPath);
      }
      try {
        fs.renameSync(tempPath, targetPath);
        this.removeFileIfExists(backupPath);
      } catch (error) {
        this.removeFileStrictIfExists(targetPath);
        if (hadOriginal && this.fileExists(backupPath)) {
          fs.renameSync(backupPath, targetPath);
        }
        throw error;
      }
    } catch (error) {
      this.removeFileIfExists(tempPath);
      throw error;
    }
  }

  private async sha256(data: ArrayBuffer): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: new Uint8Array(data) });
    const result = await digest.digest();
    let hex = '';
    for (let index = 0; index < result.data.length; index++) {
      hex += result.data[index].toString(16).padStart(2, '0');
    }
    return hex;
  }

  private readFileData(path: string): ArrayBuffer | null {
    if (!this.fileExists(path)) {
      return null;
    }
    let file: fs.File | null = null;
    try {
      const stat = fs.statSync(path);
      if (Number(stat.size) > MAX_GEO_DATA_BYTES) {
        return null;
      }
      const data = new ArrayBuffer(Number(stat.size));
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const readLength = fs.readSync(file.fd, data);
      if (readLength !== data.byteLength) {
        throw new Error(`short read for ${path}`);
      }
      return data;
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  private writeFileData(path: string, data: ArrayBuffer): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const written = fs.writeSync(file.fd, data);
      if (written !== data.byteLength) {
        throw new Error(`short write for ${path}`);
      }
      // rename 前确保下载数据、事务状态或 commit 标记已经提交到底层文件系统。
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
  }

  private geoMetadataForExisting(targetPath: string, fileName: string, sha256: string): GeoAssetMetadata {
    const stat = fs.statSync(targetPath);
    return {
      fileName,
      sha256,
      size: Number(stat.size),
      updatedAt: Number(stat.mtime) * 1000
    };
  }

  private installStagedGeoAssets(context: common.Context, staged: Array<StagedGeoAsset>): void {
    const commitPath = `${context.filesDir}/${GEO_UPDATE_COMMIT_FILE}`;
    const statePath = `${context.filesDir}/${GEO_UPDATE_STATE_FILE}`;
    this.removeFileStrictIfExists(statePath);
    this.removeFileStrictIfExists(commitPath);
    let stagedMask = 0;
    let originalMask = 0;
    for (let index = 0; index < staged.length; index++) {
      const bit = this.geoTransactionBit(staged[index].fileName);
      stagedMask |= bit;
      if (staged[index].hadOriginal) {
        originalMask |= bit;
      }
    }
    // 在任何破坏性 rename 前持久化“哪些文件参与、哪些原本存在”。首次安装没有 .bak，
    // 进程若在两个文件之间退出，下次也能据此删除已装入的半套新文件。
    this.writeFileData(statePath, encodeGeoTransactionState(stagedMask, originalMask));
    for (let index = 0; index < staged.length; index++) {
      const asset = staged[index];
      this.removeFileStrictIfExists(asset.backupPath);
      if (asset.hadOriginal) {
        fs.renameSync(asset.targetPath, asset.backupPath);
      }
    }
    for (let index = 0; index < staged.length; index++) {
      const asset = staged[index];
      fs.renameSync(asset.tempPath, asset.targetPath);
      asset.installed = true;
    }
    this.writeFileData(commitPath, new Uint8Array([1]).buffer);
  }

  private finishGeoTransaction(context: common.Context, staged: Array<StagedGeoAsset>): void {
    let cleanupComplete = true;
    for (let index = 0; index < staged.length; index++) {
      try {
        this.removeFileStrictIfExists(staged[index].backupPath);
      } catch (error) {
        cleanupComplete = false;
      }
    }
    if (cleanupComplete) {
      const statePath = `${context.filesDir}/${GEO_UPDATE_STATE_FILE}`;
      try {
        this.removeFileStrictIfExists(statePath);
        // 提交标记必须最后删除。若两次删除之间进程退出，保留 committed 会让恢复逻辑
        // 继续保留已完整安装的新文件；反过来会把首次安装误判为未提交并删除新文件。
        this.removeFileStrictIfExists(`${context.filesDir}/${GEO_UPDATE_COMMIT_FILE}`);
      } catch (error) {
        // 清理标记失败不撤销已提交的新文件；下次检查会按 committed 状态继续清理。
      }
    }
  }

  private rollbackGeoTransaction(context: common.Context, staged: Array<StagedGeoAsset>): void {
    this.removeFileIfExists(`${context.filesDir}/${GEO_UPDATE_COMMIT_FILE}`);
    let firstError: Error | null = null;
    for (let index = 0; index < staged.length; index++) {
      const asset = staged[index];
      try {
        if (asset.installed || (!asset.hadOriginal && this.fileExists(asset.targetPath))) {
          this.removeFileStrictIfExists(asset.targetPath);
        }
        if (asset.hadOriginal && this.fileExists(asset.backupPath)) {
          fs.renameSync(asset.backupPath, asset.targetPath);
        }
      } catch (error) {
        if (firstError === null) {
          firstError = error instanceof Error ? error : new Error(JSON.stringify(error));
        }
      }
      this.removeFileIfExists(asset.tempPath);
    }
    if (firstError !== null) {
      throw firstError;
    }
    this.removeFileIfExists(`${context.filesDir}/${GEO_UPDATE_STATE_FILE}`);
  }

  // 必须能在 EntryAbility.onCreate 中同步执行，并且早于 prepareNativeXrayAssets：
  // 上次进程若在两个核心 Geo 文件替换之间退出，任何核心加载前都先恢复成完整的一组。
  recoverInterruptedBuiltinGeoUpdate(context: common.Context): void {
    const commitPath = `${context.filesDir}/${GEO_UPDATE_COMMIT_FILE}`;
    const statePath = `${context.filesDir}/${GEO_UPDATE_STATE_FILE}`;
    // 文件被 CREATE 后、内容写入并 fsync 前进程仍可能终止；空/损坏标记不能证明提交。
    const committed = isValidGeoCommitMarker(this.readFileData(commitPath));
    const transactionState = this.readGeoTransactionState(statePath);
    const names = BUILTIN_GEO_DATA_FILE_NAMES;
    for (let index = 0; index < names.length; index++) {
      const targetPath = `${context.filesDir}/${names[index]}`;
      const backupPath = `${targetPath}${GEO_UPDATE_BACKUP_SUFFIX}`;
      const tempPath = `${targetPath}${GEO_UPDATE_TEMP_SUFFIX}`;
      const action: GeoRecoveryAction = resolveGeoRecoveryAction(
        committed,
        transactionState,
        index,
        this.fileExists(backupPath)
      );
      if (action === 'discard-backup') {
        this.removeFileStrictIfExists(backupPath);
      } else if (action === 'restore-backup') {
        this.removeFileStrictIfExists(targetPath);
        fs.renameSync(backupPath, targetPath);
      } else if (action === 'remove-target') {
        this.removeFileStrictIfExists(targetPath);
      }
      this.removeFileStrictIfExists(tempPath);
    }
    this.removeFileStrictIfExists(statePath);
    // 与正常完成路径相同，提交标记最后删除，避免留下“有状态、无提交标记”的假回滚窗口。
    this.removeFileStrictIfExists(commitPath);
    this.recoverInterruptedStandaloneAssetReplacements(context);
  }

  // 高级单文件 URL 更新和自定义 .dat 更新走 target -> .update.bak -> temp -> target。
  // 若进程在中间退出：target 已存在说明新文件已经原子安装，丢弃旧备份；target 缺失则
  // 恢复旧备份。该恢复必须在 Xray 首次加载 Geo 文件之前完成。
  private recoverInterruptedStandaloneAssetReplacements(context: common.Context): void {
    const names = fs.listFileSync(context.filesDir);
    const backupSuffix = '.dat.update.bak';
    for (let index = 0; index < names.length; index++) {
      const backupName = names[index];
      if (!backupName.endsWith(backupSuffix)) {
        continue;
      }
      const targetName = backupName.substring(0, backupName.length - '.update.bak'.length);
      if (targetName.length <= '.dat'.length) {
        continue;
      }
      const targetPath = `${context.filesDir}/${targetName}`;
      const backupPath = `${context.filesDir}/${backupName}`;
      const action = resolveStandaloneAssetRecoveryAction(
        this.fileExists(targetPath),
        this.fileExists(backupPath)
      );
      if (action === 'discard-backup') {
        this.removeFileStrictIfExists(backupPath);
      } else if (action === 'restore-backup') {
        fs.renameSync(backupPath, targetPath);
      }
      this.removeFileStrictIfExists(`${targetPath}.tmp`);
    }

    // 没有旧文件的首次安装可能只留下 temp；它尚未提交，不能在启动时提升为正式文件。
    for (let index = 0; index < names.length; index++) {
      const tempName = names[index];
      if (tempName.endsWith('.dat.tmp')) {
        this.removeFileStrictIfExists(`${context.filesDir}/${tempName}`);
      }
    }
  }

  private geoTransactionBit(fileName: string): number {
    const index = BUILTIN_GEO_DATA_FILE_NAMES.indexOf(fileName);
    if (index < 0) {
      throw new Error(`unsupported Geo transaction file: ${fileName}`);
    }
    return 1 << index;
  }

  private readGeoTransactionState(path: string): GeoTransactionState | null {
    try {
      return parseGeoTransactionState(this.readFileData(path));
    } catch (error) {
      return null;
    }
  }

  private fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private removeFileIfExists(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      // best-effort cleanup; the caller's primary operation retains the useful error
    }
  }

  private removeFileStrictIfExists(path: string): void {
    if (this.fileExists(path)) {
      fs.unlinkSync(path);
    }
  }

  // 流式拷贝文件到沙箱
  async copyLocalFileToAssets(
    context: common.Context,
    srcUri: string,
    destFileName: string,
    language: AppLanguage,
    onSuccess: () => void,
    onError: (errMsg: string) => void
  ): Promise<boolean> {
    if (this.assetMutationRunning) {
      const message = this.t(language, 'assets.downloadBusy');
      promptAction.showToast({ message });
      onError(message);
      return false;
    }
    this.assetMutationRunning = true;
    const destPath = `${context.filesDir}/${destFileName}`;
    const tempPath = `${context.filesDir}/${destFileName}.tmp`;

    let srcFile: fs.File | null = null;
    let destFile: fs.File | null = null;
    try {
      srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      destFile = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);

      const buf = new ArrayBuffer(8192);
      let readLen = 0;
      let totalBytes = 0;
      while ((readLen = fs.readSync(srcFile.fd, buf)) > 0) {
        totalBytes += readLen;
        if (totalBytes > MAX_GEO_DATA_BYTES) {
          throw new Error(`${destFileName}: data file is too large`);
        }
        const written = fs.writeSync(destFile.fd, buf, { length: readLen });
        if (written !== readLen) {
          throw new Error(`${destFileName}: short write`);
        }
      }

      fs.fsyncSync(destFile.fd);
      fs.closeSync(srcFile);
      fs.closeSync(destFile);
      srcFile = null;
      destFile = null;

      const importedData = this.readFileData(tempPath);
      if (importedData === null || !isPlausibleGeoData(importedData)) {
        throw new Error(`${destFileName}: imported data failed size or format validation`);
      }
      this.replaceTempFileSafely(tempPath, destPath);

      promptAction.showToast({ message: this.t(language, 'assets.action.importLocal.success').replace('{title}', destFileName) });
      onSuccess();
      return true;
    } catch (error) {
      if (srcFile) fs.closeSync(srcFile);
      if (destFile) fs.closeSync(destFile);
      try {
        if (fs.accessSync(tempPath)) {
          fs.unlinkSync(tempPath);
        }
      } catch (e) {}

      const errMsg = error instanceof Error ? error.message : JSON.stringify(error);
      promptAction.showToast({ message: this.t(language, 'assets.action.importLocal.failed').replace('{error}', errMsg) });
      onError(errMsg);
      return false;
    } finally {
      this.assetMutationRunning = false;
    }
  }

  // 删除 Geo 资源
  deleteAsset(
    context: common.Context,
    fileName: string,
    language: AppLanguage,
    onComplete: (success: boolean) => void
  ): void {
    if (this.assetMutationRunning) {
      promptAction.showToast({ message: this.t(language, 'assets.downloadBusy') });
      onComplete(false);
      return;
    }
    this.assetMutationRunning = true;
    const targetPath = `${context.filesDir}/${fileName}`;
    let success = false;
    try {
      const existed = this.fileExists(targetPath);
      this.removeStandaloneAssetFiles(targetPath);
      success = true;
      if (existed) {
        promptAction.showToast({ message: this.t(language, 'assets.deleteSuccess').replace('{title}', fileName) });
      }
    } catch (error) {
      const message = redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error));
      promptAction.showToast({ message: this.t(language, 'assets.deleteFailed').replace('{error}', message) });
    } finally {
      this.assetMutationRunning = false;
      onComplete(success);
    }
  }

  // 删除自定义 URL 链接及本地 dat 文件
  async deleteCustomAsset(context: common.Context, item: CustomAssetUrl, customAssets: Array<CustomAssetUrl>, language: AppLanguage): Promise<Array<CustomAssetUrl>> {
    if (this.assetMutationRunning) {
      promptAction.showToast({ message: this.t(language, 'assets.downloadBusy') });
      return customAssets;
    }
    this.assetMutationRunning = true;
    const path = `${context.filesDir}/${item.name}.dat`;
    const updated = customAssets.filter(asset => asset.id !== item.id);
    try {
      // 先持久化“来源已删除”，再移除文件。反向顺序会在 Preferences 保存失败时
      // 留下一个仍可见但数据文件已永久丢失的条目。若文件删除失败则尽力恢复旧列表；
      // 回滚也失败时宁可保留未引用的孤立文件，也不能让 UI 指向不存在的资源。
      await AssetStore.save(context, updated);
      try {
        this.removeStandaloneAssetFiles(path);
      } catch (fileError) {
        let rollbackSucceeded = false;
        let rollbackErrorMessage = '';
        try {
          await AssetStore.save(context, customAssets);
          rollbackSucceeded = true;
        } catch (rollbackError) {
          rollbackErrorMessage = rollbackError instanceof Error ? rollbackError.message : JSON.stringify(rollbackError);
        }
        if (rollbackSucceeded) {
          throw fileError;
        }
        const fileMessage = fileError instanceof Error ? fileError.message : JSON.stringify(fileError);
        throw new Error(`Geo file deletion failed and source rollback was not confirmed: ${fileMessage}; ${rollbackErrorMessage}`);
      }
      promptAction.showToast({ message: this.t(language, 'assets.customDeleteSuccess') });
      return updated;
    } catch (error) {
      const message = redactDiagnosticText(error instanceof Error ? error.message : JSON.stringify(error));
      promptAction.showToast({ message: this.t(language, 'assets.deleteFailed').replace('{error}', message) });
      return customAssets;
    } finally {
      this.assetMutationRunning = false;
    }
  }

  private removeStandaloneAssetFiles(targetPath: string): void {
    // 先删备份再删正式文件。若备份清理失败则保留正式文件，避免下一次冷启动把用户
    // 已删除的资源从 .update.bak 意外恢复回来。
    this.removeFileStrictIfExists(`${targetPath}.update.bak`);
    this.removeFileStrictIfExists(`${targetPath}.tmp`);
    this.removeFileStrictIfExists(targetPath);
  }

}

export const ASSETS_CONTROLLER: AssetsController = new AssetsController();
