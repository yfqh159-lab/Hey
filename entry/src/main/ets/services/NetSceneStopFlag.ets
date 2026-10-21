// 网络场景后台自动断开的跨进程标志位。
//
// VPN 扩展进程(HeyVpnAbility)在后台自动拆隧道后，主进程(UIAbility)的 ConnectionController
// 状态会滞留「运行中」。扩展拆隧道时写此标志，主进程回前台读它来校正显示状态。
//
// ⚠️ 用「文件」而非 preferences：preferences 每进程独立内存缓存，主进程 clear 后缓存里是 0，
// 读不到扩展进程写到磁盘的新值。文件每次从磁盘新读，才能真正跨进程可见。
// 也不用 isVpnActive()(getAllNets 找 BEARER_VPN)——检测不到 Hey 自身的 TUN、会误判。

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const FLAG_FILE_NAME: string = 'net_scene_stopped_at';
const FLAG_TEMP_FILE_NAME: string = 'net_scene_stopped_at.tmp';
const FLAG_BACKUP_FILE_NAME: string = 'net_scene_stopped_at.bak';

function flagPath(context: common.Context, fileName: string = FLAG_FILE_NAME): string {
  return `${context.filesDir}/${fileName}`;
}

function writeFlag(context: common.Context, value: number): void {
  if (!Number.isFinite(value) || Math.floor(value) !== value || value < 0) {
    throw new Error('Invalid network scene stop timestamp.');
  }
  const targetPath = flagPath(context);
  const tempPath = flagPath(context, FLAG_TEMP_FILE_NAME);
  const backupPath = flagPath(context, FLAG_BACKUP_FILE_NAME);
  let file: fs.File | null = null;
  try {
    recoverInterruptedWrite(targetPath, tempPath, backupPath);
    file = fs.openSync(tempPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    const content = value.toString();
    const written = fs.writeSync(file.fd, content);
    if (written !== content.length) {
      throw new Error('Short network scene stop flag write.');
    }
    fs.fsyncSync(file.fd);
    fs.closeSync(file);
    file = null;

    removeIfExists(backupPath);
    if (fs.accessSync(targetPath)) {
      fs.renameSync(targetPath, backupPath);
    }
    fs.renameSync(tempPath, targetPath);
  } catch (error) {
    removeIfExistsSafely(tempPath);
    try {
      if (!fs.accessSync(targetPath) && fs.accessSync(backupPath)) {
        fs.renameSync(backupPath, targetPath);
      }
    } catch (_restoreError) {
      // Preserve the original write failure for the caller.
    }
    throw error;
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (_closeError) {
        // The original write result remains authoritative.
      }
    }
  }
}

export class NetSceneStopFlag {
  /** 扩展进程自动断开时调用：标记「本次启动后发生过自动断开」。 */
  static async markStopped(context: common.Context, at: number): Promise<void> {
    writeFlag(context, at);
  }

  /** VPN 启动成功时调用：清除标志（此后若再置位即代表本次启动后的自动断开）。 */
  static async clear(context: common.Context): Promise<void> {
    writeFlag(context, 0);
  }

  /** 主进程前台读取：本次启动后是否发生过后台自动断开。 */
  static async wasStopped(context: common.Context, sessionStartedAt: number = 0): Promise<boolean> {
    try {
      const stoppedAt = selectNetSceneStopTimestamp(
        readTextIfExists(flagPath(context)),
        readTextIfExists(flagPath(context, FLAG_TEMP_FILE_NAME)),
        readTextIfExists(flagPath(context, FLAG_BACKUP_FILE_NAME))
      );
      return stoppedAt !== null && wasNetSceneStoppedAfter(stoppedAt, sessionStartedAt);
    } catch (_error) {
      return false;
    }
  }
}

export function parseNetSceneStopTimestamp(content: string | null): number | null {
  if (content === null || content.trim().length === 0) {
    return null;
  }
  const value = Number(content.trim());
  if (!Number.isFinite(value) || Math.floor(value) !== value || value < 0) {
    return null;
  }
  return value;
}

export function selectNetSceneStopTimestamp(
  primaryContent: string | null,
  tempContent: string | null,
  backupContent: string | null
): number | null {
  const temp = parseNetSceneStopTimestamp(tempContent);
  if (temp !== null) {
    return temp;
  }
  const primary = parseNetSceneStopTimestamp(primaryContent);
  if (primary !== null) {
    return primary;
  }
  return parseNetSceneStopTimestamp(backupContent);
}

export function wasNetSceneStoppedAfter(stoppedAt: number, sessionStartedAt: number): boolean {
  return !Number.isNaN(stoppedAt) && stoppedAt > 0 &&
    !Number.isNaN(sessionStartedAt) && stoppedAt > Math.max(0, sessionStartedAt);
}

function recoverInterruptedWrite(targetPath: string, tempPath: string, backupPath: string): void {
  if (fs.accessSync(tempPath)) {
    const temp = parseNetSceneStopTimestamp(fs.readTextSync(tempPath));
    if (temp !== null) {
      removeIfExists(backupPath);
      if (fs.accessSync(targetPath)) {
        fs.renameSync(targetPath, backupPath);
      }
      fs.renameSync(tempPath, targetPath);
      return;
    }
    removeIfExists(tempPath);
  }
  if (!fs.accessSync(targetPath) && fs.accessSync(backupPath)) {
    fs.renameSync(backupPath, targetPath);
  }
}

function readTextIfExists(path: string): string | null {
  if (!fs.accessSync(path)) {
    return null;
  }
  return fs.readTextSync(path);
}

function removeIfExists(path: string): void {
  if (fs.accessSync(path)) {
    fs.unlinkSync(path);
  }
}

function removeIfExistsSafely(path: string): void {
  try {
    removeIfExists(path);
  } catch (_error) {
    // Best effort only; a future read validates every candidate before use.
  }
}
