import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import fs from '@ohos.file.fs';
import {
  BUILTIN_GEO_DATA_FILE_NAMES,
  DEFAULT_GEO_RELEASE_API,
  GeoRecoveryAction,
  GeoTransactionState,
  MAX_GEO_DATA_BYTES,
  encodeGeoTransactionState,
  isAllowedGeoAssetRedirect,
  isPlausibleGeoData,
  parseGeoTransactionState,
  parseHttpRedirectLocation,
  parseDefaultGeoRelease,
  parseSha256Checksum,
  resolveGeoRecoveryAction
} from '../../core/GeoAssets';
import { APP_HTTP_USER_AGENT } from '../../core/HttpDefaults';
import { shouldExposeLocalHttpProxy } from '../../core/LocalProxy';
import { AppLanguage } from '../../core/Profile';
import { LOCAL_HTTP_PROXY_HOST, LOCAL_HTTP_PROXY_PORT } from '../../core/XrayConfig';
import { translate } from '../../core/I18n';
import { formatTwo } from '../../utils/LocalizationPresenter';
import { AssetStore, CustomAssetUrl, GeoAssetMetadata, GeoUpdateMetadata } from '../../storage/AssetStore';
import { SettingsStore } from '../../storage/SettingsStore';


export function buildAssetDownloadProxyPorts(proxyPort: number): Array<number> {
  if (!isValidAssetDownloadProxyPort(proxyPort)) {
    return [0];
  }
  return [Math.floor(proxyPort), 0];
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

const GEO_UPDATE_TEMP_SUFFIX: string = '.geo-update.tmp';
const GEO_UPDATE_BACKUP_SUFFIX: string = '.geo-update.bak';
const GEO_UPDATE_STATE_FILE: string = '.geo-update.state';
const GEO_UPDATE_COMMIT_FILE: string = '.geo-update.committed';
const MAX_ASSET_REDIRECTS: number = 5;

function isValidAssetDownloadProxyPort(proxyPort: number): boolean {
  return typeof proxyPort === 'number' && Math.floor(proxyPort) === proxyPort && proxyPort > 0 && proxyPort <= 65535;
}

export class AssetsController {
  private geoUpdateRunning: boolean = false;
  
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

  // 检查可信默认发布源。两个核心文件全部通过版本、大小、格式和 SHA-256 校验后才一起替换。
  // 若安装阶段失败，则回滚本次已替换的文件；进程中断留下的事务状态会在下次检查时恢复。
  async checkAndUpdateBuiltinGeo(context: common.Context): Promise<BuiltinGeoUpdateResult> {
    if (this.geoUpdateRunning) {
      throw new Error('Geo update is already running');
    }
    this.geoUpdateRunning = true;
    try {
      return await this.performBuiltinGeoUpdate(context);
    } catch (error) {
      await this.recordGeoUpdateFailure(context);
      throw error;
    } finally {
      this.geoUpdateRunning = false;
    }
  }

  private async performBuiltinGeoUpdate(context: common.Context): Promise<BuiltinGeoUpdateResult> {
    await this.recoverGeoTransaction(context);
    const proxyPort = await this.resolveDownloadProxyPort(context);
    const releaseText = await this.requestTextWithFallback(DEFAULT_GEO_RELEASE_API, proxyPort);
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
        const checksumText = await this.requestTextWithFallback(releaseFile.checksumUrl, proxyPort);
        const expectedSha256 = parseSha256Checksum(checksumText);
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

        const data = await this.requestDataWithFallback(releaseFile.downloadUrl, proxyPort);
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
        await AssetStore.saveGeoUpdateMetadata(context, updateMetadata);
      } catch (error) {
        metadataSaved = false;
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
      const previous = await AssetStore.loadGeoUpdateMetadata(context);
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
    onStart();

    const tempPath = `${context.filesDir}/${fileName}.tmp`;
    const targetPath = `${context.filesDir}/${fileName.endsWith('.dat') ? fileName : fileName + '.dat'}`;
    const proxyPort = await this.resolveDownloadProxyPort(context);

    try {
      promptAction.showToast({ message: this.t(language, 'assets.downloading').replace('{title}', fileName) });
      if (BUILTIN_GEO_DATA_FILE_NAMES.includes(fileName)) {
        await this.downloadVerifiedGeoWithFallback(fileName, url, tempPath, targetPath, proxyPort);
      } else {
        await this.downloadToFileWithFallback(url, tempPath, targetPath, proxyPort);
      }
      promptAction.showToast({ message: this.t(language, 'assets.downloadSuccess').replace('{title}', fileName) });
      onSuccess();
    } catch (error) {
      try {
        if (fs.accessSync(tempPath)) {
          fs.unlinkSync(tempPath);
        }
      } catch (e) {}

      const errMsg = error instanceof Error ? error.message : JSON.stringify(error);
      promptAction.showToast({
        message: this.t(language, 'assets.downloadFailed')
          .replace('{title}', fileName)
          .replace('{error}', errMsg)
      });
      onError(errMsg);
    } finally {
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
    try {
      promptAction.showToast({ message: this.t(language, 'assets.updatingAll') });
      const proxyPort = await this.resolveDownloadProxyPort(context);

      let total = 0;
      let success = 0;

      for (let index = 0; index < remoteCustomAssets.length; index++) {
        const asset = remoteCustomAssets[index];
        if (!this.isRemoteAssetUrl(asset.url)) {
          continue;
        }
        onProgress(asset.name);
        total++;
        if (await this.performDownload(context, `${asset.name}.dat`, asset.url.trim(), proxyPort)) {
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
      onComplete();
    } catch (error) {
      promptAction.showToast({ message: this.t(language, 'assets.updateAllError').replace('{error}', JSON.stringify(error)) });
      onComplete();
    }
  }

  private isRemoteAssetUrl(url: string): boolean {
    const lower = url.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  private async performDownload(context: common.Context, fileName: string, url: string, proxyPort: number): Promise<boolean> {
    const tempPath = `${context.filesDir}/${fileName}.tmp`;
    const targetPath = `${context.filesDir}/${fileName}`;
    try {
      await this.downloadToFileWithFallback(url, tempPath, targetPath, proxyPort);
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

  private async resolveDownloadProxyPort(context: common.Context): Promise<number> {
    try {
      const settings = await SettingsStore.load(context);
      return shouldExposeLocalHttpProxy(settings) ? LOCAL_HTTP_PROXY_PORT : 0;
    } catch (error) {
      return 0;
    }
  }

  private async downloadToFileWithFallback(url: string, tempPath: string, targetPath: string, proxyPort: number): Promise<void> {
    const ports = buildAssetDownloadProxyPorts(proxyPort);
    let lastError = '';
    for (let index = 0; index < ports.length; index++) {
      try {
        const data = await this.requestAssetData(url, ports[index]);
        this.writeAssetData(tempPath, targetPath, data);
        return;
      } catch (error) {
        lastError = error instanceof Error ? error.message : JSON.stringify(error);
        this.removeTempFile(tempPath);
      }
    }
    throw new Error(lastError.length > 0 ? lastError : 'download failed');
  }

  private async downloadVerifiedGeoWithFallback(
    fileName: string,
    url: string,
    tempPath: string,
    targetPath: string,
    proxyPort: number
  ): Promise<void> {
    const checksumText = await this.requestTextWithFallback(`${url}.sha256sum`, proxyPort);
    const expectedSha256 = parseSha256Checksum(checksumText);
    if (expectedSha256.length !== 64) {
      throw new Error(`${fileName}: invalid SHA-256 checksum`);
    }
    const data = await this.requestDataWithFallback(url, proxyPort);
    if (!isPlausibleGeoData(data)) {
      throw new Error(`${fileName}: downloaded data failed size or format validation`);
    }
    const actualSha256 = await this.sha256(data);
    if (actualSha256 !== expectedSha256) {
      throw new Error(`${fileName}: SHA-256 mismatch`);
    }
    this.writeAssetData(tempPath, targetPath, data);
  }

  private async requestTextWithFallback(url: string, proxyPort: number): Promise<string> {
    const ports = buildAssetDownloadProxyPorts(proxyPort);
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

  private async requestDataWithFallback(url: string, proxyPort: number): Promise<ArrayBuffer> {
    const ports = buildAssetDownloadProxyPorts(proxyPort);
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
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
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
      const response = await request.request(url, options);
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
        return response.result;
      }
      if (response.result instanceof ArrayBuffer) {
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(response.result));
      }
      const objectText = JSON.stringify(response.result);
      return objectText === undefined ? '' : objectText;
    } finally {
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
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
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
      const response = await request.request(url, options);
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
      return response.result;
    } finally {
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

  private removeTempFile(tempPath: string): void {
    this.removeFileIfExists(tempPath);
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

  private async recoverGeoTransaction(context: common.Context): Promise<void> {
    const commitPath = `${context.filesDir}/${GEO_UPDATE_COMMIT_FILE}`;
    const statePath = `${context.filesDir}/${GEO_UPDATE_STATE_FILE}`;
    const committed = this.fileExists(commitPath);
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
    const destPath = `${context.filesDir}/${destFileName}`;
    const tempPath = `${context.filesDir}/${destFileName}.tmp`;

    let srcFile: fs.File | null = null;
    let destFile: fs.File | null = null;
    try {
      srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      destFile = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);

      const buf = new ArrayBuffer(8192);
      let readLen = 0;
      while ((readLen = fs.readSync(srcFile.fd, buf)) > 0) {
        fs.writeSync(destFile.fd, buf, { length: readLen });
      }

      fs.closeSync(srcFile);
      fs.closeSync(destFile);
      srcFile = null;
      destFile = null;

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
    }
  }

  // 删除 Geo 资源
  deleteAsset(context: common.Context, fileName: string, language: AppLanguage, onComplete: () => void): void {
    const targetPath = `${context.filesDir}/${fileName}`;
    try {
      if (fs.accessSync(targetPath)) {
        fs.unlinkSync(targetPath);
        promptAction.showToast({ message: this.t(language, 'assets.deleteSuccess').replace('{title}', fileName) });
      }
    } catch (error) {
      promptAction.showToast({ message: this.t(language, 'assets.deleteFailed').replace('{error}', JSON.stringify(error)) });
    } finally {
      onComplete();
    }
  }

  // 删除自定义 URL 链接及本地 dat 文件
  async deleteCustomAsset(context: common.Context, item: CustomAssetUrl, customAssets: Array<CustomAssetUrl>, language: AppLanguage): Promise<Array<CustomAssetUrl>> {
    const path = `${context.filesDir}/${item.name}.dat`;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {}

    const updated = customAssets.filter(asset => asset.id !== item.id);
    await AssetStore.save(context, updated);
    promptAction.showToast({ message: this.t(language, 'assets.customDeleteSuccess') });
    return updated;
  }

}

export const ASSETS_CONTROLLER: AssetsController = new AssetsController();
