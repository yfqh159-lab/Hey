import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

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
const GEO_UPDATE_METADATA_KEY: string = 'geo_update_metadata';

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
    try {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const rawValue = await store.get(CUSTOM_ASSETS_KEY, '');
      const raw = rawValue.toString();
      if (raw.length === 0) {
        return [];
      }
      return JSON.parse(raw) as Array<CustomAssetUrl>;
    } catch (error) {
      return [];
    }
  }

  static async save(context: common.Context, assets: Array<CustomAssetUrl>): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      await store.put(CUSTOM_ASSETS_KEY, JSON.stringify(assets));
      await store.flush();
    } catch (error) {
      // ignore
    }
  }

  static async loadGeoUpdateMetadata(context: common.Context): Promise<GeoUpdateMetadata> {
    try {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const rawValue = await store.get(GEO_UPDATE_METADATA_KEY, '');
      const raw = rawValue.toString();
      if (raw.length === 0) {
        return emptyGeoUpdateMetadata();
      }
      const parsed = JSON.parse(raw) as GeoUpdateMetadata;
      return {
        version: parsed.version ?? '',
        source: parsed.source ?? '',
        checkedAt: parsed.checkedAt ?? 0,
        result: parsed.result ?? '',
        assets: parsed.assets ?? []
      };
    } catch (error) {
      return emptyGeoUpdateMetadata();
    }
  }

  static async saveGeoUpdateMetadata(context: common.Context, metadata: GeoUpdateMetadata): Promise<void> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    await store.put(GEO_UPDATE_METADATA_KEY, JSON.stringify(metadata));
    await store.flush();
  }

  static async clearGeoUpdateMetadata(context: common.Context): Promise<void> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    await store.delete(GEO_UPDATE_METADATA_KEY);
    await store.flush();
  }
}
