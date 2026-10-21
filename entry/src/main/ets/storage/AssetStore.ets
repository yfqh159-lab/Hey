import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { isSafeCustomAssetName } from '../core/AssetUrls';

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
  static async load(context: common.Context): Promise<Array<CustomAssetUrl>> {
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

  static async save(context: common.Context, assets: Array<CustomAssetUrl>): Promise<void> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const nextRaw = JSON.stringify(AssetStore.normalizeCustomAssets(assets));
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
  }

  static async loadGeoUpdateMetadata(context: common.Context): Promise<GeoUpdateMetadata> {
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

  static async saveGeoUpdateMetadata(context: common.Context, metadata: GeoUpdateMetadata): Promise<void> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const nextRaw = JSON.stringify(metadata);
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
  }

  static async clearGeoUpdateMetadata(context: common.Context): Promise<void> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    await store.delete(GEO_UPDATE_METADATA_KEY);
    await store.delete(GEO_UPDATE_METADATA_BACKUP_KEY);
    await store.flush();
  }

  private static parseStoredCustomAssets(raw: string): Array<CustomAssetUrl> | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as Object;
      return Array.isArray(parsed) ? AssetStore.normalizeCustomAssets(parsed) : null;
    } catch (_error) {
      return null;
    }
  }

  private static parseStoredGeoMetadata(raw: string): GeoUpdateMetadata | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as GeoUpdateMetadata;
      if (parsed === null || typeof parsed !== 'object' || !Array.isArray(parsed.assets)) {
        return null;
      }
      const assets = new Array<GeoAssetMetadata>();
      for (let index = 0; index < parsed.assets.length; index++) {
        const asset = parsed.assets[index];
        if (asset === null || typeof asset !== 'object' || typeof asset.fileName !== 'string' ||
          typeof asset.sha256 !== 'string' || typeof asset.size !== 'number' || typeof asset.updatedAt !== 'number') {
          continue;
        }
        assets.push({
          fileName: asset.fileName,
          sha256: asset.sha256,
          size: asset.size,
          updatedAt: asset.updatedAt
        });
      }
      return {
        version: typeof parsed.version === 'string' ? parsed.version : '',
        source: typeof parsed.source === 'string' ? parsed.source : '',
        checkedAt: typeof parsed.checkedAt === 'number' ? parsed.checkedAt : 0,
        result: typeof parsed.result === 'string' ? parsed.result : '',
        assets
      };
    } catch (_error) {
      return null;
    }
  }

  private static normalizeCustomAssets(assets: Object): Array<CustomAssetUrl> {
    if (!Array.isArray(assets)) {
      return [];
    }
    const normalized = new Array<CustomAssetUrl>();
    for (let index = 0; index < assets.length; index++) {
      const raw = assets[index];
      if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const item = raw as CustomAssetUrl;
      if (typeof item.id !== 'string' || typeof item.name !== 'string' ||
        typeof item.url !== 'string' || !isSafeCustomAssetName(item.name)) {
        continue;
      }
      normalized.push({ id: item.id, name: item.name.trim(), url: item.url.trim() });
    }
    return normalized;
  }
}
