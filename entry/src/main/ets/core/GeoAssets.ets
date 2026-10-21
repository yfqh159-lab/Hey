import { normalizeHttpsUrl } from './HttpDefaults';

// Xray 核心的规则数据文件名。文件名是上游核心的既定约定，与任何地区策略无关。
export const GEOSITE_FILE_NAME: string = 'geosite.dat';
export const GEOIP_FILE_NAME: string = 'geoip.dat';
export const DEFAULT_GEO_RELEASE_API: string =
  'https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases/latest';
export const DEFAULT_GEO_SOURCE_LABEL: string = 'Loyalsoldier/v2ray-rules-dat';
export const DEFAULT_GEO_RELEASE_DOWNLOAD_PREFIX: string =
  'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/';
export const TRUSTED_GITHUB_ASSET_PREFIX: string = 'https://release-assets.githubusercontent.com/';
export const MIN_GEO_DATA_BYTES: number = 1024;
export const MAX_GEO_DATA_BYTES: number = 128 * 1024 * 1024;
// Network Kit HttpRequestOptions.maxLimit 的官方最大值是 100 MiB。远端下载使用该
// 边界；本地导入仍可在上面的 128 MiB 文件校验上限内工作。
export const MAX_GEO_HTTP_DATA_BYTES: number = 100 * 1024 * 1024;
// GitHub Release 元数据和单文件校验和都应是很小的文本。给 HTTP 层单独设置上限，
// 避免异常端点在 JSON/校验解析前把无界响应整体装入应用内存。
export const MAX_GEO_TEXT_BYTES: number = 2 * 1024 * 1024;
export const GEO_UPDATE_TEMP_SUFFIX: string = '.geo-update.tmp';
export const GEO_UPDATE_BACKUP_SUFFIX: string = '.geo-update.bak';
export const GEO_UPDATE_STATE_FILE: string = '.geo-update.state';
export const GEO_UPDATE_COMMIT_FILE: string = '.geo-update.committed';

export const BUILTIN_GEO_DATA_FILE_NAMES: Array<string> = [
  GEOSITE_FILE_NAME,
  GEOIP_FILE_NAME
];

/**
 * 独立 VPN Extension 进程不得在另一个进程正处于 Geo 原子替换窗口时加载核心。
 * `.tmp` 下载本身不影响仍在使用的正式文件；状态、提交或备份工件则表示 rename
 * 事务尚未由 UI 冷启动恢复/收尾，必须 fail-closed。
 */
export function hasPendingGeoReplacementArtifacts(fileNames: Array<string>): boolean {
  for (let index = 0; index < fileNames.length; index++) {
    const name = fileNames[index];
    if (name === GEO_UPDATE_STATE_FILE || name === GEO_UPDATE_COMMIT_FILE ||
      name.endsWith(GEO_UPDATE_BACKUP_SUFFIX) || name.endsWith('.dat.update.bak')) {
      return true;
    }
  }
  return false;
}

export interface GeoTransactionState {
  stagedMask: number;
  originalMask: number;
}

export interface GeoUpdateNotice {
  resultKey: string;
  appendMetadataWarning: boolean;
}

export type GeoRecoveryAction = 'keep' | 'remove-target' | 'restore-backup' | 'discard-backup';
export type StandaloneAssetRecoveryAction = 'keep' | 'restore-backup' | 'discard-backup';

export function resolveGeoUpdateNotice(
  changed: boolean,
  runtimeRunning: boolean,
  metadataSaved: boolean
): GeoUpdateNotice {
  let resultKey = 'assets.geo.latest';
  if (changed) {
    resultKey = runtimeRunning ? 'assets.geo.updatedReconnect' : 'assets.geo.updated';
  }
  return {
    resultKey,
    appendMetadataWarning: !metadataSaved
  };
}

export function encodeGeoTransactionState(stagedMask: number, originalMask: number): ArrayBuffer {
  const validMask = geoTransactionValidMask();
  if (stagedMask === 0 || (stagedMask & ~validMask) !== 0 || (originalMask & ~stagedMask) !== 0) {
    throw new Error('invalid Geo transaction state');
  }
  return new Uint8Array([stagedMask, originalMask]).buffer;
}

export function parseGeoTransactionState(data: ArrayBuffer | null): GeoTransactionState | null {
  if (data === null || data.byteLength !== 2) {
    return null;
  }
  const bytes = new Uint8Array(data);
  const stagedMask = bytes[0];
  const originalMask = bytes[1];
  const validMask = geoTransactionValidMask();
  if (stagedMask === 0 || (stagedMask & ~validMask) !== 0 || (originalMask & ~stagedMask) !== 0) {
    return null;
  }
  return { stagedMask, originalMask };
}

/**
 * 提交标记只有在完整写入固定内容后才有效。仅检查文件存在会把“刚创建但尚未写入/持久化”
 * 的空文件误当作提交完成，进程中断时可能留下半套 Geo 数据。
 */
export function isValidGeoCommitMarker(data: ArrayBuffer | null): boolean {
  if (data === null || data.byteLength !== 1) {
    return false;
  }
  return new Uint8Array(data)[0] === 1;
}

export function resolveGeoRecoveryAction(
  committed: boolean,
  transactionState: GeoTransactionState | null,
  fileIndex: number,
  backupExists: boolean
): GeoRecoveryAction {
  if (committed) {
    return backupExists ? 'discard-backup' : 'keep';
  }
  if (fileIndex >= 0 && fileIndex < BUILTIN_GEO_DATA_FILE_NAMES.length && transactionState !== null) {
    const bit = 1 << fileIndex;
    if ((transactionState.stagedMask & bit) !== 0) {
      if ((transactionState.originalMask & bit) === 0) {
        return 'remove-target';
      }
      return backupExists ? 'restore-backup' : 'keep';
    }
  }
  // 兼容尚未写入事务状态文件的旧版本：发现遗留备份时仍恢复旧文件。
  return backupExists ? 'restore-backup' : 'keep';
}

export function resolveStandaloneAssetRecoveryAction(
  targetExists: boolean,
  backupExists: boolean
): StandaloneAssetRecoveryAction {
  if (!backupExists) {
    return 'keep';
  }
  return targetExists ? 'discard-backup' : 'restore-backup';
}

export function buildAssetDownloadUrl(sourceUrl: string, fileName: string): string {
  const normalizedSource = sourceUrl.endsWith('/') ? sourceUrl : `${sourceUrl}/`;
  return `${normalizedSource}${fileName}`;
}

/** 远端 Geo 与其校验记录必须经过认证传输；本地文件导入不经过这个入口。 */
export function normalizeGeoAssetDownloadUrl(value: string): string {
  return normalizeHttpsUrl(value);
}

/** 在 URL 路径后追加校验文件后缀，同时保留签名查询参数或 fragment。 */
export function buildGeoChecksumUrl(value: string): string {
  const normalized = normalizeGeoAssetDownloadUrl(value);
  if (normalized.length === 0) {
    return '';
  }
  let suffixIndex = normalized.length;
  const queryIndex = normalized.indexOf('?');
  const fragmentIndex = normalized.indexOf('#');
  if (queryIndex >= 0 && queryIndex < suffixIndex) {
    suffixIndex = queryIndex;
  }
  if (fragmentIndex >= 0 && fragmentIndex < suffixIndex) {
    suffixIndex = fragmentIndex;
  }
  return `${normalized.substring(0, suffixIndex)}.sha256sum${normalized.substring(suffixIndex)}`;
}

interface ReleaseAssetPayload {
  name?: string;
  browser_download_url?: string;
  size?: number;
}

interface ReleasePayload {
  tag_name?: string;
  assets?: Array<ReleaseAssetPayload>;
}

export interface GeoReleaseFile {
  fileName: string;
  downloadUrl: string;
  checksumUrl: string;
  declaredSize: number;
}

export interface GeoReleaseManifest {
  version: string;
  source: string;
  files: Array<GeoReleaseFile>;
}

export interface GeoManifestParseResult {
  ok: boolean;
  message: string;
  manifest: GeoReleaseManifest | null;
}

interface ProtobufVarint {
  value: number;
  nextOffset: number;
}

export function parseDefaultGeoRelease(content: string): GeoManifestParseResult {
  try {
    const payload = JSON.parse(content) as ReleasePayload;
    const version = payload.tag_name?.trim() ?? '';
    const assets = payload.assets ?? [];
    if (!/^[0-9A-Za-z._-]+$/.test(version) || !Array.isArray(assets) || assets.length === 0) {
      return failedManifest('release metadata is incomplete');
    }
    const files = new Array<GeoReleaseFile>();
    for (let index = 0; index < BUILTIN_GEO_DATA_FILE_NAMES.length; index++) {
      const fileName = BUILTIN_GEO_DATA_FILE_NAMES[index];
      const dataAsset = findReleaseAsset(assets, fileName);
      const checksumAsset = findReleaseAsset(assets, `${fileName}.sha256sum`);
      if (dataAsset === null || checksumAsset === null) {
        return failedManifest(`release is missing ${fileName} or its checksum`);
      }
      const downloadUrl = dataAsset.browser_download_url?.trim() ?? '';
      const checksumUrl = checksumAsset.browser_download_url?.trim() ?? '';
      const declaredSize = normalizeDeclaredSize(dataAsset.size);
      if (!isTrustedReleaseAssetUrl(downloadUrl, version, fileName) ||
        !isTrustedReleaseAssetUrl(checksumUrl, version, `${fileName}.sha256sum`)) {
        return failedManifest(`release contains an untrusted URL for ${fileName}`);
      }
      if (declaredSize < MIN_GEO_DATA_BYTES || declaredSize > MAX_GEO_HTTP_DATA_BYTES) {
        return failedManifest(`release contains an invalid size for ${fileName}`);
      }
      files.push({
        fileName,
        downloadUrl,
        checksumUrl,
        declaredSize
      });
    }
    return {
      ok: true,
      message: '',
      manifest: {
        version,
        source: DEFAULT_GEO_SOURCE_LABEL,
        files
      }
    };
  } catch (error) {
    return failedManifest(`release metadata is not valid JSON: ${JSON.stringify(error)}`);
  }
}

export function parseSha256Checksum(content: string, expectedFileName: string = ''): string {
  // `.sha256sum` 应是单条校验记录。不能只截取开头 64 位后忽略其余行，否则一个
  // 聚合/错误响应也可能被误当成目标文件的校验信息。自定义源允许只返回哈希；可信
  // 默认 Release 传入 expectedFileName 后，还必须把校验记录绑定到对应资产名。
  const normalized = content.trim();
  if (normalized.length === 0 || normalized.includes('\n') || normalized.includes('\r')) {
    return '';
  }
  const match = normalized.match(/^([0-9A-Fa-f]{64})(?:[ \t]+[*]?([^ \t].*?))?[ \t]*$/);
  if (match === null) {
    return '';
  }
  const recordedFileName = (match[2] ?? '').trim();
  if (expectedFileName.length > 0 && recordedFileName !== expectedFileName) {
    return '';
  }
  return match[1].toLowerCase();
}

export function isPlausibleGeoData(data: ArrayBuffer, declaredSize: number = 0): boolean {
  if (data.byteLength < MIN_GEO_DATA_BYTES || data.byteLength > MAX_GEO_DATA_BYTES) {
    return false;
  }
  if (declaredSize > 0 && data.byteLength !== declaredSize) {
    return false;
  }
  const bytes = new Uint8Array(data, 0, Math.min(data.byteLength, 64));
  let prefix = '';
  for (let index = 0; index < bytes.length; index++) {
    prefix += String.fromCharCode(bytes[index]);
  }
  const normalized = prefix.trim().toLowerCase();
  if (normalized.startsWith('<!doctype') || normalized.startsWith('<html') ||
    normalized.startsWith('{') || normalized.startsWith('[')) {
    return false;
  }
  return isPlausibleGeoProtobuf(new Uint8Array(data));
}

// Xray 的 geoip.dat 与 geosite.dat 都是顶层 field 1 重复出现的 protobuf 列表，
// 每个列表项自身也必须是边界完整的 protobuf message，并包含非空的 field 1 标识。
// SHA-256 仍负责内容真实性；这里阻止错误页、随机二进制或截断文件在本地导入/替换时
// 仅凭大小看起来“像”数据文件。
function isPlausibleGeoProtobuf(bytes: Uint8Array): boolean {
  let offset = 0;
  let entryCount = 0;
  while (offset < bytes.length) {
    const tag = readProtobufVarint(bytes, offset, bytes.length);
    if (tag === null || tag.value !== 10) {
      return false;
    }
    const length = readProtobufVarint(bytes, tag.nextOffset, bytes.length);
    if (length === null || length.value <= 0 || length.value > bytes.length - length.nextOffset) {
      return false;
    }
    const entryEnd = length.nextOffset + length.value;
    if (!isPlausibleGeoEntry(bytes, length.nextOffset, entryEnd)) {
      return false;
    }
    entryCount++;
    offset = entryEnd;
  }
  return entryCount > 0;
}

function isPlausibleGeoEntry(bytes: Uint8Array, start: number, end: number): boolean {
  let offset = start;
  let hasIdentifier = false;
  while (offset < end) {
    const tag = readProtobufVarint(bytes, offset, end);
    if (tag === null || tag.value <= 0) {
      return false;
    }
    const fieldNumber = Math.floor(tag.value / 8);
    const wireType = tag.value % 8;
    if (fieldNumber <= 0) {
      return false;
    }
    offset = tag.nextOffset;
    if (wireType === 0) {
      const value = readProtobufVarint(bytes, offset, end);
      if (value === null) {
        return false;
      }
      offset = value.nextOffset;
    } else if (wireType === 1) {
      if (offset > end - 8) {
        return false;
      }
      offset += 8;
    } else if (wireType === 2) {
      const length = readProtobufVarint(bytes, offset, end);
      if (length === null || length.value > end - length.nextOffset) {
        return false;
      }
      const valueEnd = length.nextOffset + length.value;
      if (fieldNumber === 1) {
        if (hasIdentifier || length.value <= 0 || length.value > 256 ||
          !isPrintableGeoIdentifier(bytes, length.nextOffset, valueEnd)) {
          return false;
        }
        hasIdentifier = true;
      }
      offset = valueEnd;
    } else if (wireType === 5) {
      if (offset > end - 4) {
        return false;
      }
      offset += 4;
    } else {
      // Deprecated groups and unknown wire types are not emitted by the Geo schemas.
      return false;
    }
  }
  return offset === end && hasIdentifier;
}

function readProtobufVarint(bytes: Uint8Array, offset: number, end: number): ProtobufVarint | null {
  let value = 0;
  let multiplier = 1;
  for (let index = 0; index < 10 && offset < end; index++, offset++) {
    const current = bytes[offset];
    value += (current & 0x7f) * multiplier;
    if (!Number.isSafeInteger(value)) {
      return null;
    }
    if ((current & 0x80) === 0) {
      return { value, nextOffset: offset + 1 };
    }
    multiplier *= 128;
  }
  return null;
}

function isPrintableGeoIdentifier(bytes: Uint8Array, start: number, end: number): boolean {
  for (let index = start; index < end; index++) {
    if (bytes[index] < 0x21 || bytes[index] > 0x7e) {
      return false;
    }
  }
  return true;
}

export function parseHttpRedirectLocation(headerJson: string): string {
  const match = headerJson.match(/"(?:Location|location)"\s*:\s*(?:"([^"]+)"|\[\s*"([^"]+)")/);
  if (match === null) {
    return '';
  }
  return match[1] ?? match[2] ?? '';
}

export function isAllowedGeoAssetRedirect(originalUrl: string, redirectUrl: string): boolean {
  if (redirectUrl.length === 0) {
    return false;
  }
  if (originalUrl.startsWith(DEFAULT_GEO_RELEASE_DOWNLOAD_PREFIX)) {
    return redirectUrl.startsWith(TRUSTED_GITHUB_ASSET_PREFIX);
  }
  if (originalUrl === DEFAULT_GEO_RELEASE_API) {
    return redirectUrl.startsWith('https://api.github.com/');
  }
  if (originalUrl.startsWith('https://')) {
    return redirectUrl.startsWith('https://');
  }
  return redirectUrl.startsWith('https://') || redirectUrl.startsWith('http://');
}

/**
 * Network Kit currently follows redirects inside request() before returning the final response.
 * Validate every redirect target surfaced by headersReceive instead of relying only on a 3xx
 * responseCode, which normally represents the final response after automatic redirects.
 */
export function areAllowedGeoAssetRedirects(
  originalUrl: string,
  redirectUrls: Array<string>,
  maxRedirects: number
): boolean {
  if (redirectUrls.length > maxRedirects) {
    return false;
  }
  for (let index = 0; index < redirectUrls.length; index++) {
    if (!isAllowedGeoAssetRedirect(originalUrl, redirectUrls[index])) {
      return false;
    }
  }
  return true;
}

function findReleaseAsset(assets: Array<ReleaseAssetPayload>, name: string): ReleaseAssetPayload | null {
  for (let index = 0; index < assets.length; index++) {
    if (assets[index].name === name) {
      return assets[index];
    }
  }
  return null;
}

function isTrustedReleaseAssetUrl(url: string, version: string, fileName: string): boolean {
  return url === `${DEFAULT_GEO_RELEASE_DOWNLOAD_PREFIX}${version}/${fileName}`;
}

function normalizeDeclaredSize(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value) || value <= 0) {
    return 0;
  }
  return Math.floor(value);
}

function failedManifest(message: string): GeoManifestParseResult {
  return { ok: false, message, manifest: null };
}

function geoTransactionValidMask(): number {
  return (1 << BUILTIN_GEO_DATA_FILE_NAMES.length) - 1;
}
