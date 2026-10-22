import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { isSafeCustomAssetName } from '../core/AssetUrls';
import { MAX_GEO_DATA_BYTES, normalizeGeoAssetDownloadUrl } from '../core/GeoAssets';

export const MAX_CUSTOM_ASSET_COUNT: number = 64;
const MAX_ASSET_ID_CHARS: number = 128;
const MAX_GEO_METADATA_TEXT_CHARS: number = 256;
const MAX_GEO_METADATA_ASSET_COUNT: number = 2;
const MAX_CUSTOM_ASSETS_RAW_CHARS: number = 1024 * 1024;
const MAX_GEO_METADATA_RAW_CHARS: number = 16 * 1024;
const GEO_METADATA_RESULTS: Array<string> = ['updated', 'latest', 'failed'];

export interface CustomAssetUrl {
  id: string;
  name: string;
  url: string;
}

export interface GeoAssetMetadata {
  fileName: string;
  sha256: string;
  size: number;
  updatedAt: number;
}

export interface GeoUpdateMetadata {
  version: string;
  source: string;
  checkedAt: number;
  result: string;
  assets: Array<GeoAssetMetadata>;
}

const PREFERENCES_NAME: string = 'hey_vpn_assets';
const CUSTOM_ASSETS_KEY: string = 'custom_assets';
const CUSTOM_ASSETS_BACKUP_KEY: string = 'custom_assets_backup';
const GEO_UPDATE_METADATA_KEY: string = 'geo_update_metadata';
const GEO_UPDATE_METADATA_BACKUP_KEY: string = 'geo_update_metadata_backup';

export interface StoredCustomAssetsSelection {
  assets: Array<CustomAssetUrl> | null;
  source: string;
}

export interface StoredGeoMetadataSelection {
  metadata: GeoUpdateMetadata | null;
  source: string;
}

function emptyGeoUpdateMetadata(): GeoUpdateMetadata {
  return {
    version: '',
    source: '',
    checkedAt: 0,
    result: '',
    assets: []
  };
}

export class AssetStore {
  private static operationTail: Promise<void> = Promise.resolve();

  static load(context: common.Context): Promise<Array<CustomAssetUrl>> {
    return AssetStore.enqueueOperation(async (): Promise<Array<CustomAssetUrl>> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const primaryRaw = (await store.get(CUSTOM_ASSETS_KEY, '')).toString();
      const backupRaw = (await store.get(CUSTOM_ASSETS_BACKUP_KEY, '')).toString();
      const selection = AssetStore.selectStoredCustomAssets(primaryRaw, backupRaw);
      if (selection.assets !== null && selection.source !== 'backup') {
        return selection.assets;
      }
      if (selection.assets !== null) {
        try {
          await store.put(CUSTOM_ASSETS_KEY, JSON.stringify(selection.assets));
          await store.flush();
        } catch (_error) {
          // keep recovered in-memory value
        }
        return selection.assets;
      }
      throw new Error('Stored custom Geo sources are unreadable; the existing data was not overwritten.');
    });
  }

  static selectStoredCustomAssets(primaryRaw: string, backupRaw: string): StoredCustomAssetsSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { assets: [], source: 'empty' };
    }
    const primary = AssetStore.parseStoredCustomAssets(primaryRaw);
    if (primary !== null) {
      return { assets: primary, source: 'primary' };
    }
    const backup = AssetStore.parseStoredCustomAssets(backupRaw);
    if (backup !== null) {
      return { assets: backup, source: 'backup' };
    }
    return { assets: null, source: 'invalid' };
  }

  static save(context: common.Context, assets: Array<CustomAssetUrl>): Promise<void> {
    const assetsSnapshot = AssetStore.normalizeCustomAssets(assets);
    if (assets.length > MAX_CUSTOM_ASSET_COUNT || assetsSnapshot.length !== assets.length ||
      !AssetStore.hasUniqueCustomAssets(assetsSnapshot)) {
      return Promise.reject(new Error('Custom Geo source list is invalid or exceeds the 64-source limit.'));
    }
    return AssetStore.enqueueOperation(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const nextRaw = JSON.stringify(assetsSnapshot);
      const currentRaw = (await store.get(CUSTOM_ASSETS_KEY, '')).toString();
      if (AssetStore.parseStoredCustomAssets(currentRaw) !== null) {
        await store.put(CUSTOM_ASSETS_BACKUP_KEY, currentRaw);
      } else {
        const backupRaw = (await store.get(CUSTOM_ASSETS_BACKUP_KEY, '')).toString();
        if (AssetStore.parseStoredCustomAssets(backupRaw) === null) {
          await store.put(CUSTOM_ASSETS_BACKUP_KEY, nextRaw);
        }
      }
      await store.put(CUSTOM_ASSETS_KEY, nextRaw);
      await store.flush();
    });
  }

  static loadGeoUpdateMetadata(context: common.Context): Promise<GeoUpdateMetadata> {
    return AssetStore.enqueueOperation(async (): Promise<GeoUpdateMetadata> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const primaryRaw = (await store.get(GEO_UPDATE_METADATA_KEY, '')).toString();
      const backupRaw = (await store.get(GEO_UPDATE_METADATA_BACKUP_KEY, '')).toString();
      const selection = AssetStore.selectStoredGeoMetadata(primaryRaw, backupRaw);
      if (selection.metadata !== null && selection.source !== 'backup') {
        return selection.metadata;
      }
      if (selection.metadata !== null) {
        try {
          await store.put(GEO_UPDATE_METADATA_KEY, JSON.stringify(selection.metadata));
          await store.flush();
        } catch (_error) {
          // keep recovered in-memory value
        }
        return selection.metadata;
      }
      throw new Error('Stored Geo update metadata is unreadable; the existing record was not overwritten.');
    });
  }

  static selectStoredGeoMetadata(primaryRaw: string, backupRaw: string): StoredGeoMetadataSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { metadata: emptyGeoUpdateMetadata(), source: 'empty' };
    }
    const primary = AssetStore.parseStoredGeoMetadata(primaryRaw);
    if (primary !== null) {
      return { metadata: primary, source: 'primary' };
    }
    const backup = AssetStore.parseStoredGeoMetadata(backupRaw);
    if (backup !== null) {
      return { metadata: backup, source: 'backup' };
    }
    return { metadata: null, source: 'invalid' };
  }

  static saveGeoUpdateMetadata(context: common.Context, metadata: GeoUpdateMetadata): Promise<void> {
    const metadataSnapshot = AssetStore.copyGeoUpdateMetadata(metadata);
    return AssetStore.enqueueOperation(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const nextRaw = JSON.stringify(metadataSnapshot);
      const currentRaw = (await store.get(GEO_UPDATE_METADATA_KEY, '')).toString();
      if (AssetStore.parseStoredGeoMetadata(currentRaw) !== null) {
        await store.put(GEO_UPDATE_METADATA_BACKUP_KEY, currentRaw);
      } else {
        const backupRaw = (await store.get(GEO_UPDATE_METADATA_BACKUP_KEY, '')).toString();
        if (AssetStore.parseStoredGeoMetadata(backupRaw) === null) {
          await store.put(GEO_UPDATE_METADATA_BACKUP_KEY, nextRaw);
        }
      }
      await store.put(GEO_UPDATE_METADATA_KEY, nextRaw);
      await store.flush();
    });
  }

  static clearGeoUpdateMetadata(context: common.Context): Promise<void> {
    return AssetStore.enqueueOperation(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      await store.delete(GEO_UPDATE_METADATA_KEY);
      await store.delete(GEO_UPDATE_METADATA_BACKUP_KEY);
      await store.flush();
    });
  }

  private static enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = AssetStore.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    AssetStore.operationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static copyGeoUpdateMetadata(metadata: GeoUpdateMetadata): GeoUpdateMetadata {
    const normalized = AssetStore.normalizeGeoUpdateMetadata(metadata);
    if (normalized === null) {
      throw new Error('Geo update metadata is invalid.');
    }
    const assets = new Array<GeoAssetMetadata>();
    for (let index = 0; index < normalized.assets.length; index++) {
      assets.push({
        fileName: normalized.assets[index].fileName,
        sha256: normalized.assets[index].sha256,
        size: normalized.assets[index].size,
        updatedAt: normalized.assets[index].updatedAt
      });
    }
    return {
      version: normalized.version,
      source: normalized.source,
      checkedAt: normalized.checkedAt,
      result: normalized.result,
      assets
    };
  }

  private static parseStoredCustomAssets(raw: string): Array<CustomAssetUrl> | null {
    if (raw.length === 0 || raw.length > MAX_CUSTOM_ASSETS_RAW_CHARS) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed) || parsed.length > MAX_CUSTOM_ASSET_COUNT) {
        return null;
      }
      const normalized = AssetStore.normalizeCustomAssets(parsed);
      return normalized.length === parsed.length && AssetStore.hasUniqueCustomAssets(normalized) ? normalized : null;
    } catch (_error) {
      return null;
    }
  }

  private static parseStoredGeoMetadata(raw: string): GeoUpdateMetadata | null {
    if (raw.length === 0 || raw.length > MAX_GEO_METADATA_RAW_CHARS) {
      return null;
    }
    try {
      return AssetStore.normalizeGeoUpdateMetadata(JSON.parse(raw) as GeoUpdateMetadata);
    } catch (_error) {
      return null;
    }
  }

  private static normalizeCustomAssets(assets: Object): Array<CustomAssetUrl> {
    if (!Array.isArray(assets)) {
      return [];
    }
    const items = assets as Array<Object>;
    const normalized = new Array<CustomAssetUrl>();
    for (let index = 0; index < items.length && normalized.length < MAX_CUSTOM_ASSET_COUNT; index++) {
      const raw: Object = items[index];
      if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const item = raw as CustomAssetUrl;
      if (typeof item.id !== 'string' || item.id.length === 0 || item.id.length > MAX_ASSET_ID_CHARS ||
        typeof item.name !== 'string' || typeof item.url !== 'string' || !isSafeCustomAssetName(item.name)) {
        continue;
      }
      const normalizedUrl = AssetStore.normalizeCustomAssetUrl(item.url);
      if (normalizedUrl.length === 0) {
        continue;
      }
      normalized.push({ id: item.id, name: item.name.trim(), url: normalizedUrl });
    }
    return normalized;
  }

  private static normalizeCustomAssetUrl(value: string): string {
    const trimmed = value.trim();
    if (trimmed.startsWith('local://')) {
      return trimmed.length <= MAX_GEO_METADATA_TEXT_CHARS ? trimmed : '';
    }
    return normalizeGeoAssetDownloadUrl(trimmed);
  }

  private static normalizeGeoUpdateMetadata(metadata: GeoUpdateMetadata): GeoUpdateMetadata | null {
    if (metadata === null || typeof metadata !== 'object' || !Array.isArray(metadata.assets) ||
      typeof metadata.version !== 'string' || metadata.version.length > MAX_GEO_METADATA_TEXT_CHARS ||
      typeof metadata.source !== 'string' || metadata.source.length > MAX_GEO_METADATA_TEXT_CHARS ||
      typeof metadata.result !== 'string' || metadata.result.length > MAX_GEO_METADATA_TEXT_CHARS ||
      !Number.isFinite(metadata.checkedAt) || metadata.checkedAt < 0 ||
      metadata.assets.length > MAX_GEO_METADATA_ASSET_COUNT ||
      (metadata.result.length > 0 && GEO_METADATA_RESULTS.indexOf(metadata.result) < 0)) {
      return null;
    }
    const assets = new Array<GeoAssetMetadata>();
    for (let index = 0; index < metadata.assets.length; index++) {
      const asset = metadata.assets[index];
      if (asset === null || typeof asset !== 'object' ||
        (asset.fileName !== 'geoip.dat' && asset.fileName !== 'geosite.dat') ||
        typeof asset.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(asset.sha256) ||
        !Number.isFinite(asset.size) || Math.floor(asset.size) !== asset.size ||
        asset.size <= 0 || asset.size > MAX_GEO_DATA_BYTES ||
        !Number.isFinite(asset.updatedAt) || asset.updatedAt < 0) {
        return null;
      }
      for (let duplicateIndex = 0; duplicateIndex < assets.length; duplicateIndex++) {
        if (assets[duplicateIndex].fileName === asset.fileName) {
          return null;
        }
      }
      assets.push({
        fileName: asset.fileName,
        sha256: asset.sha256,
        size: asset.size,
        updatedAt: asset.updatedAt
      });
    }
    return {
      version: metadata.version,
      source: metadata.source,
      checkedAt: metadata.checkedAt,
      result: metadata.result,
      assets
    };
  }

  private static hasUniqueCustomAssets(assets: Array<CustomAssetUrl>): boolean {
    for (let index = 0; index < assets.length; index++) {
      for (let otherIndex = 0; otherIndex < index; otherIndex++) {
        if (assets[otherIndex].id === assets[index].id || assets[otherIndex].name === assets[index].name) {
          return false;
        }
      }
    }
    return true;
  }
}
