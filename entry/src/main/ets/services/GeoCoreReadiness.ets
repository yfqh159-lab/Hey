import fs from '@ohos.file.fs';
import { hasPendingGeoReplacementArtifacts } from '../core/GeoAssets';

/**
 * VPN Extension 可由系统在 UIAbility 之外单独创建。UI 冷启动会恢复中断的 Geo
 * 事务；扩展进程不能与仍在执行 rename 的 UI 进程并发“恢复”，因此这里只做同步
 * fail-closed 检查。用户重新打开主界面后，EntryAbility 会在任何核心加载前恢复。
 */
export function assertGeoAssetsStableForCore(filesDir: string): void {
  const names = fs.listFileSync(filesDir);
  if (hasPendingGeoReplacementArtifacts(names)) {
    throw new Error('Geo data replacement is incomplete; reopen Hey to recover it before reconnecting.');
  }
}
