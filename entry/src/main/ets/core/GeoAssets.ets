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

export const BUILTIN_GEO_DATA_FILE_NAMES: Array<string> = [
  GEOSITE_FILE_NAME,
  GEOIP_FILE_NAME
];

export interface GeoTransactionState {
  stagedMask: number;
  originalMask: number;
}

export type GeoRecoveryAction = 'keep' | 'remove-target' | 'restore-backup' | 'discard-backup';
export type StandaloneAssetRecoveryAction = 'keep' | 'restore-backup' | 'discard-backup';

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
      if (declaredSize < MIN_GEO_DATA_BYTES || declaredSize > MAX_GEO_DATA_BYTES) {
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

export function parseSha256Checksum(content: string): string {
  const match = content.trim().toLowerCase().match(/^[0-9a-f]{64}(?=\s|$)/);
  return match === null ? '' : match[0];
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
  return !normalized.startsWith('<!doctype') &&
    !normalized.startsWith('<html') &&
    !normalized.startsWith('{') &&
    !normalized.startsWith('[');
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
