import { ProxyProfile, SubscriptionProfile, AppSettings } from './Profile';
import { CustomAssetUrl } from '../storage/AssetStore';

// 全量配置备份的数据模型与序列化/解析（纯函数，不依赖 context，便于单测）。
//
// 备份只覆盖「可迁移的配置」四块：手动节点 profile、订阅组、应用设置（含 per-app 列表与
// 路由规则）、自定义 geo 资源 URL。流量统计与桌面控制卡片属设备本地状态，迁移会污染目标
// 设备，故不纳入。
//
// 解析校验恢复必需的结构与关键载荷类型；可选字段的深度归一化交给各 Store，
// 避免在此重复一套版本兼容逻辑，同时不让错误类型把现有配置恢复成空值。

export const CONFIG_BACKUP_APP_TAG: string = 'hey-vpn';
export const CONFIG_BACKUP_VERSION: number = 1;

export interface ConfigBackup {
  app: string;
  version: number;
  exportedAt: number;
  profile: ProxyProfile;
  subscriptions: SubscriptionProfile;
  settings: AppSettings;
  assets: Array<CustomAssetUrl>;
}

export interface ConfigBackupParseResult {
  ok: boolean;
  // 失败原因码（已在 i18n 中映射为提示文案）：empty / invalid-json / invalid-format /
  // not-hey-backup / unsupported-version / missing-fields。
  error: string;
  backup: ConfigBackup | null;
}

// 组装备份对象。exportedAt 由调用方传入（collectBackup 传 Date.now()），保持纯函数可测。
export function buildConfigBackup(
  profile: ProxyProfile,
  subscriptions: SubscriptionProfile,
  settings: AppSettings,
  assets: Array<CustomAssetUrl>,
  exportedAt: number
): ConfigBackup {
  return {
    app: CONFIG_BACKUP_APP_TAG,
    version: CONFIG_BACKUP_VERSION,
    exportedAt: Number.isFinite(exportedAt) && exportedAt > 0 ? Math.floor(exportedAt) : 0,
    profile,
    subscriptions,
    settings,
    assets
  };
}

export function serializeConfigBackup(backup: ConfigBackup): string {
  return JSON.stringify(backup, null, 2);
}

export function parseConfigBackup(text: string): ConfigBackupParseResult {
  const trimmed = (text ?? '').trim();
  if (trimmed.length === 0) {
    return { ok: false, error: 'empty', backup: null };
  }

  let parsed: Record<string, Object>;
  try {
    parsed = JSON.parse(trimmed) as Record<string, Object>;
  } catch (error) {
    return { ok: false, error: 'invalid-json', backup: null };
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return { ok: false, error: 'invalid-format', backup: null };
  }

  const app = typeof parsed['app'] === 'string' ? parsed['app'] as string : '';
  if (app !== CONFIG_BACKUP_APP_TAG) {
    return { ok: false, error: 'not-hey-backup', backup: null };
  }

  const version = typeof parsed['version'] === 'number' ? parsed['version'] as number : 0;
  if (!Number.isFinite(version) || Math.floor(version) !== version || version !== CONFIG_BACKUP_VERSION) {
    return { ok: false, error: 'unsupported-version', backup: null };
  }

  const profile = parsed['profile'];
  const subscriptions = parsed['subscriptions'];
  const settings = parsed['settings'];
  const assets = parsed['assets'];
  if (!isPlainObject(profile) || !isPlainObject(subscriptions) || !isPlainObject(settings) || !Array.isArray(assets)) {
    return { ok: false, error: 'missing-fields', backup: null };
  }
  const profileRecord = profile as Record<string, Object>;
  const subscriptionRecord = subscriptions as Record<string, Object>;
  const settingsRecord = settings as Record<string, Object>;
  if (typeof profileRecord['id'] !== 'string' || (profileRecord['id'] as string).length === 0 ||
    typeof profileRecord['outboundJson'] !== 'string' ||
    !Array.isArray(subscriptionRecord['groups']) ||
    typeof settingsRecord['language'] !== 'string' || typeof settingsRecord['mode'] !== 'string' ||
    typeof settingsRecord['speedEnabled'] !== 'boolean' || !Array.isArray(settingsRecord['routingRules']) ||
    !isValidSubscriptionGroups(subscriptionRecord['groups'] as Array<Object>) ||
    !isValidAssetRecords(assets as Array<Object>)) {
    return { ok: false, error: 'missing-fields', backup: null };
  }

  const exportedAt = typeof parsed['exportedAt'] === 'number' ? parsed['exportedAt'] as number : 0;
  const backup: ConfigBackup = {
    app,
    version,
    exportedAt: Number.isFinite(exportedAt) && exportedAt > 0 ? Math.floor(exportedAt) : 0,
    profile: profile as ProxyProfile,
    subscriptions: subscriptions as SubscriptionProfile,
    settings: settings as AppSettings,
    assets: assets as Array<CustomAssetUrl>
  };
  return { ok: true, error: '', backup };
}

function isPlainObject(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isValidSubscriptionGroups(groups: Array<Object>): boolean {
  for (let groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    const group = groups[groupIndex];
    if (!isPlainObject(group)) {
      return false;
    }
    const record = group as Record<string, Object>;
    if (typeof record['id'] !== 'string' || typeof record['name'] !== 'string' ||
      typeof record['url'] !== 'string' || !Array.isArray(record['nodes'])) {
      return false;
    }
    const nodes = record['nodes'] as Array<Object>;
    for (let nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
      const node = nodes[nodeIndex];
      if (!isPlainObject(node)) {
        return false;
      }
      const nodeRecord = node as Record<string, Object>;
      if (typeof nodeRecord['id'] !== 'string' || typeof nodeRecord['name'] !== 'string' ||
        typeof nodeRecord['outboundJson'] !== 'string') {
        return false;
      }
    }
  }
  return true;
}

function isValidAssetRecords(assets: Array<Object>): boolean {
  for (let index = 0; index < assets.length; index++) {
    const asset = assets[index];
    if (!isPlainObject(asset)) {
      return false;
    }
    const record = asset as Record<string, Object>;
    if (typeof record['id'] !== 'string' || typeof record['name'] !== 'string' ||
      typeof record['url'] !== 'string') {
      return false;
    }
  }
  return true;
}
