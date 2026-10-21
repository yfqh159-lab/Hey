import { common } from '@kit.AbilityKit';
import { ProfileStore } from '../storage/ProfileStore';
import { SubscriptionStore } from '../storage/SubscriptionStore';
import { SettingsStore } from '../storage/SettingsStore';
import { AssetStore } from '../storage/AssetStore';
import { buildConfigBackup, ConfigBackup } from '../core/ConfigBackup';

// 全量配置备份的聚合层：把四块配置 Store 一次性读出/写回。
// 字段归一化交给各 Store 的 save/normalize，这里只负责协调读写顺序。
export class BackupManager {
  // 读取四块配置 Store，组装一份全量备份对象。
  static async collectBackup(context: common.Context): Promise<ConfigBackup> {
    const profile = await ProfileStore.load(context);
    const subscriptions = await SubscriptionStore.load(context);
    const settings = await SettingsStore.load(context);
    const assets = await AssetStore.load(context);
    return buildConfigBackup(profile, subscriptions, settings, assets, Date.now());
  }

  // 用备份覆盖现有配置（覆盖语义）。调用方应在此之前先留一份安全副本。
  static async applyBackup(context: common.Context, backup: ConfigBackup): Promise<void> {
    const previous = await BackupManager.collectBackup(context);
    try {
      await BackupManager.applyBackupParts(context, backup);
    } catch (_error) {
      const rollbackComplete = await BackupManager.rollbackBackupParts(context, previous);
      if (rollbackComplete) {
        throw new Error('Configuration restore failed; the previous configuration was restored.');
      }
      throw new Error('Configuration restore and rollback failed; restart the app and restore the pre-import backup.');
    }
  }

  private static async applyBackupParts(context: common.Context, backup: ConfigBackup): Promise<void> {
    // 先恢复节点数据库，再恢复与其对应的当前 Profile；两者中途失败会由调用方回滚。
    await SubscriptionStore.restoreProfile(context, backup.subscriptions);
    await ProfileStore.save(context, backup.profile.outboundJson, backup.profile.configType ?? 'outbound');
    await SettingsStore.save(context, backup.settings);
    await AssetStore.save(context, backup.assets);
  }

  private static async rollbackBackupParts(context: common.Context, backup: ConfigBackup): Promise<boolean> {
    // 每块独立尝试，避免第一项回滚失败后直接放弃其余仍可恢复的数据。
    let complete = true;
    try {
      await SubscriptionStore.restoreProfile(context, backup.subscriptions);
    } catch (_error) {
      complete = false;
    }
    try {
      await ProfileStore.save(context, backup.profile.outboundJson, backup.profile.configType ?? 'outbound');
    } catch (_error) {
      complete = false;
    }
    try {
      await SettingsStore.save(context, backup.settings);
    } catch (_error) {
      complete = false;
    }
    try {
      await AssetStore.save(context, backup.assets);
    } catch (_error) {
      complete = false;
    }
    return complete;
  }
}
