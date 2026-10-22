import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DEFAULT_PROFILE_ID, ProxyProfile, XrayConfigType } from '../core/Profile';

const PREFERENCES_NAME: string = 'hey_vpn_profile';
const PROFILE_KEY: string = 'default_profile';
const PROFILE_BACKUP_KEY: string = 'default_profile_backup';

export interface StoredProfileSelection {
  profile: ProxyProfile | null;
  source: string;
}

export class ProfileStore {
  private static operationTail: Promise<void> = Promise.resolve();

  static load(context: common.Context): Promise<ProxyProfile> {
    return ProfileStore.enqueueOperation(async (): Promise<ProxyProfile> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const primaryRaw = (await store.get(PROFILE_KEY, '')).toString();
      const backupRaw = (await store.get(PROFILE_BACKUP_KEY, '')).toString();
      const selection = ProfileStore.selectStoredProfile(primaryRaw, backupRaw);
      if (selection.profile !== null && selection.source !== 'backup') {
        return selection.profile;
      }
      if (selection.profile !== null) {
        try {
          await store.put(PROFILE_KEY, JSON.stringify(selection.profile));
          await store.flush();
        } catch (_error) {
          // keep recovered in-memory value
        }
        return selection.profile;
      }
      throw new Error('Stored selected profile is unreadable; the existing data was not overwritten.');
    });
  }

  static selectStoredProfile(primaryRaw: string, backupRaw: string): StoredProfileSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { profile: ProfileStore.createEmptyProfile(), source: 'empty' };
    }
    const primary = ProfileStore.parseStoredProfile(primaryRaw);
    if (primary !== null) {
      return { profile: primary, source: 'primary' };
    }
    const backup = ProfileStore.parseStoredProfile(backupRaw);
    if (backup !== null) {
      return { profile: backup, source: 'backup' };
    }
    return { profile: null, source: 'invalid' };
  }

  static save(context: common.Context, outboundJson: string, configType: XrayConfigType = 'outbound'): Promise<ProxyProfile> {
    if (typeof outboundJson !== 'string') {
      return Promise.reject(new Error('Selected profile payload must be a string.'));
    }
    const profile: ProxyProfile = {
      id: DEFAULT_PROFILE_ID,
      name: 'Default Xray Profile',
      outboundJson,
      configType: ProfileStore.normalizeConfigType(configType),
      updatedAt: Date.now()
    };
    return ProfileStore.enqueueOperation(async (): Promise<ProxyProfile> => {
      // Profile 决定下一次手动连接使用哪个配置，其持久化失败不能伪装成成功。
      // 调用方已有面向用户的错误处理；让 ArkData 错误向上传递，避免 UI/订阅库已经
      // 指向新节点，而重启应用后又静默回到旧 Profile。
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const nextRaw = JSON.stringify(profile);
      const currentRaw = (await store.get(PROFILE_KEY, '')).toString();
      if (ProfileStore.parseStoredProfile(currentRaw) !== null) {
        await store.put(PROFILE_BACKUP_KEY, currentRaw);
      } else {
        const backupRaw = (await store.get(PROFILE_BACKUP_KEY, '')).toString();
        if (ProfileStore.parseStoredProfile(backupRaw) === null) {
          await store.put(PROFILE_BACKUP_KEY, nextRaw);
        }
      }
      await store.put(PROFILE_KEY, nextRaw);
      await store.flush();
      return profile;
    });
  }

  private static enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = ProfileStore.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    ProfileStore.operationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static parseStoredProfile(raw: string): ProxyProfile | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const profile = JSON.parse(raw) as ProxyProfile;
      if (profile === null || typeof profile !== 'object' || typeof profile.id !== 'string' || profile.id.length === 0 ||
        (profile.outboundJson !== undefined && typeof profile.outboundJson !== 'string')) {
        return null;
      }
      return {
        id: profile.id,
        name: typeof profile.name === 'string' ? profile.name : 'Default Xray Profile',
        outboundJson: profile.outboundJson ?? '',
        configType: ProfileStore.normalizeConfigType(profile.configType, profile.outboundJson ?? ''),
        updatedAt: typeof profile.updatedAt === 'number' && Number.isFinite(profile.updatedAt) ?
          Math.floor(profile.updatedAt) : 0
      };
    } catch (_error) {
      return null;
    }
  }

  private static createEmptyProfile(): ProxyProfile {
    return {
      id: DEFAULT_PROFILE_ID,
      name: 'Default Xray Profile',
      outboundJson: '',
      configType: 'outbound',
      updatedAt: 0
    };
  }

  private static normalizeConfigType(configType?: XrayConfigType, configJson: string = ''): XrayConfigType {
    if (configType === 'full') {
      return 'full';
    }
    if (configType === 'proxy-chain') {
      return 'proxy-chain';
    }
    if (configType === 'policy-group') {
      return 'policy-group';
    }
    if (configType === 'outbound') {
      return 'outbound';
    }
    const detected = ProfileStore.detectConfigType(configJson);
    return detected ?? 'outbound';
  }

  private static detectConfigType(configJson: string): XrayConfigType | null {
    try {
      const parsed = JSON.parse(configJson) as Record<string, Object>;
      if (Array.isArray(parsed) || (Array.isArray(parsed['outbounds']) &&
        parsed['inbounds'] === undefined &&
        parsed['routing'] === undefined &&
        parsed['dns'] === undefined &&
        parsed['log'] === undefined)) {
        const type = typeof parsed['type'] === 'string' ? (parsed['type'] as string).toLowerCase() : '';
        const configType = typeof parsed['configType'] === 'string' ? (parsed['configType'] as string).toLowerCase() : '';
        if (type === 'policy-group' || configType === 'policy-group' ||
          parsed['strategy'] !== undefined || parsed['policyGroupType'] !== undefined) {
          return 'policy-group';
        }
        return 'proxy-chain';
      }
      return parsed['inbounds'] !== undefined || parsed['outbounds'] !== undefined ? 'full' : null;
    } catch (error) {
      return null;
    }
  }
}
