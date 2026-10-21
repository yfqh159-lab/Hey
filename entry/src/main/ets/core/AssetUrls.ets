import { normalizeGeoAssetDownloadUrl } from './GeoAssets';

export interface ScannedAssetUrl {
  valid: boolean;
  name: string;
  url: string;
}

export interface AssetNameEntry {
  id: string;
  name: string;
}

export function normalizeScannedAssetUrl(value: string): ScannedAssetUrl {
  const url = normalizeGeoAssetDownloadUrl(value);
  if (url.length === 0) {
    return { valid: false, name: '', url: '' };
  }
  return { valid: true, name: deriveAssetNameFromUrl(url), url };
}

export function hasDuplicateAssetName(assets: Array<AssetNameEntry>, name: string, editingId: string = ''): boolean {
  const candidate = name.trim();
  if (candidate.length === 0) {
    return false;
  }
  for (let index = 0; index < assets.length; index++) {
    const asset = assets[index];
    if (asset.id !== editingId && asset.name.trim() === candidate) {
      return true;
    }
  }
  return false;
}

export function isEditableCustomAssetUrl(url: string): boolean {
  const normalized = url.trim().toLowerCase();
  return normalized !== 'file' && !normalized.startsWith('local://');
}

export function deriveAssetNameFromUrl(url: string): string {
  let clean = url.trim();
  const queryIndex = clean.indexOf('?');
  if (queryIndex >= 0) {
    clean = clean.substring(0, queryIndex);
  }
  const hashIndex = clean.indexOf('#');
  if (hashIndex >= 0) {
    clean = clean.substring(0, hashIndex);
  }
  const schemeIndex = clean.indexOf('://');
  if (schemeIndex >= 0) {
    const afterScheme = clean.substring(schemeIndex + 3);
    const pathStart = afterScheme.indexOf('/');
    clean = pathStart >= 0 ? afterScheme.substring(pathStart + 1) : '';
  }
  while (clean.endsWith('/')) {
    clean = clean.substring(0, clean.length - 1);
  }
  const slashIndex = clean.lastIndexOf('/');
  let name = slashIndex >= 0 ? clean.substring(slashIndex + 1) : clean;
  if (name.toLowerCase().endsWith('.dat')) {
    name = name.substring(0, name.length - 4);
  }
  let candidate = sanitizeAssetName(name.length > 0 ? name : 'asset');
  if (!isSafeCustomAssetName(candidate)) {
    candidate = `custom_${candidate}`;
  }
  if (candidate.length > 64) {
    candidate = candidate.substring(0, 64);
  }
  return isSafeCustomAssetName(candidate) ? candidate : 'asset';
}

/** 自定义名称会直接映射为 filesDir/{name}.dat，必须阻止路径字符和核心文件冲突。 */
export function isSafeCustomAssetName(name: string): boolean {
  const trimmed = name.trim();
  if (trimmed.length === 0 || trimmed.length > 64 || trimmed === '.' || trimmed === '..') {
    return false;
  }
  const lower = trimmed.toLowerCase();
  if (lower === 'geoip' || lower === 'geosite') {
    return false;
  }
  for (let index = 0; index < trimmed.length; index++) {
    const char = trimmed.substring(index, index + 1);
    if (isInvalidAssetNameChar(char) || trimmed.charCodeAt(index) < 32) {
      return false;
    }
  }
  return true;
}

function sanitizeAssetName(name: string): string {
  let result = '';
  for (let index = 0; index < name.length; index++) {
    const char = name.substring(index, index + 1);
    if (isInvalidAssetNameChar(char) || name.charCodeAt(index) < 32) {
      result = `${result}_`;
    } else {
      result = `${result}${char}`;
    }
  }
  const trimmed = result.trim();
  return trimmed.length > 0 ? trimmed : 'asset';
}

function isInvalidAssetNameChar(char: string): boolean {
  return char === '/' || char === '\\' || char === ':' || char === '*' || char === '?' ||
    char === '"' || char === '<' || char === '>' || char === '|';
}
