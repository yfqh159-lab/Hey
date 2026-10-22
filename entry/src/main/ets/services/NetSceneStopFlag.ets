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
import { isValidVpnSessionId } from '../vpn/VpnConstants';

const FLAG_FILE_NAME: string = 'net_scene_stopped_at';
const FLAG_TEMP_FILE_NAME: string = 'net_scene_stopped_at.tmp';
const FLAG_BACKUP_FILE_NAME: string = 'net_scene_stopped_at.bak';
const MAX_NET_SCENE_STOP_FLAG_BYTES: number = 4096;

export interface NetSceneStopRecord {
  sessionId: string;
  stoppedAt: number;
}

function flagPath(context: common.Context, fileName: string = FLAG_FILE_NAME): string {
  return `${context.filesDir}/${fileName}`;
}

function writeFlag(context: common.Context, record: NetSceneStopRecord): void {
  if (!isValidVpnSessionId(record.sessionId) || !Number.isFinite(record.stoppedAt) ||
    Math.floor(record.stoppedAt) !== record.stoppedAt || record.stoppedAt < 0) {
    throw new Error('Invalid network scene stop record.');
  }
  const targetPath = flagPath(context);
  const tempPath = flagPath(context, FLAG_TEMP_FILE_NAME);
  const backupPath = flagPath(context, FLAG_BACKUP_FILE_NAME);
  let file: fs.File | null = null;
  try {
    recoverInterruptedWrite(targetPath, tempPath, backupPath);
    file = fs.openSync(tempPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    const content = JSON.stringify(record);
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
    throw new Error(error instanceof Error ? error.message : JSON.stringify(error));
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
  static async markStopped(context: common.Context, at: number, sessionId: string): Promise<void> {
    writeFlag(context, { sessionId: sessionId, stoppedAt: at });
  }

  /** VPN 启动成功时调用：清除标志（此后若再置位即代表本次启动后的自动断开）。 */
  static async clear(context: common.Context, sessionId: string): Promise<void> {
    writeFlag(context, { sessionId: sessionId, stoppedAt: 0 });
  }

  /** 主进程前台读取：本次启动后是否发生过后台自动断开。 */
  static async wasStopped(
    context: common.Context,
    sessionStartedAt: number = 0,
    expectedSessionId: string = ''
  ): Promise<boolean> {
    try {
      const record = selectNetSceneStopRecord(
        readTextIfExists(flagPath(context)),
        readTextIfExists(flagPath(context, FLAG_TEMP_FILE_NAME)),
        readTextIfExists(flagPath(context, FLAG_BACKUP_FILE_NAME))
      );
      return record !== null && wasNetSceneStoppedForSession(record, sessionStartedAt, expectedSessionId);
    } catch (_error) {
      return false;
    }
  }
}

export function parseNetSceneStopRecord(content: string | null): NetSceneStopRecord | null {
  if (content === null || content.length > MAX_NET_SCENE_STOP_FLAG_BYTES || content.trim().length === 0) {
    return null;
  }
  const trimmed = content.trim();
  if (trimmed.startsWith('{')) {
    try {
      const record = JSON.parse(trimmed) as NetSceneStopRecord;
      if (typeof record.sessionId !== 'string' || !isValidVpnSessionId(record.sessionId) ||
        !Number.isFinite(record.stoppedAt) || Math.floor(record.stoppedAt) !== record.stoppedAt ||
        record.stoppedAt < 0) {
        return null;
      }
      return { sessionId: record.sessionId, stoppedAt: record.stoppedAt };
    } catch (_error) {
      return null;
    }
  }
  const legacyTimestamp = parseNetSceneStopTimestamp(trimmed);
  return legacyTimestamp === null ? null : { sessionId: '', stoppedAt: legacyTimestamp };
}

export function parseNetSceneStopTimestamp(content: string | null): number | null {
  if (content === null || content.length > MAX_NET_SCENE_STOP_FLAG_BYTES || content.trim().length === 0) {
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
  const record = selectNetSceneStopRecord(primaryContent, tempContent, backupContent);
  return record === null ? null : record.stoppedAt;
}

export function selectNetSceneStopRecord(
  primaryContent: string | null,
  tempContent: string | null,
  backupContent: string | null
): NetSceneStopRecord | null {
  const temp = parseNetSceneStopRecord(tempContent);
  if (temp !== null) {
    return temp;
  }
  const primary = parseNetSceneStopRecord(primaryContent);
  if (primary !== null) {
    return primary;
  }
  return parseNetSceneStopRecord(backupContent);
}

export function wasNetSceneStoppedAfter(stoppedAt: number, sessionStartedAt: number): boolean {
  return Number.isFinite(stoppedAt) && stoppedAt > 0 &&
    Number.isFinite(sessionStartedAt) && stoppedAt > Math.max(0, sessionStartedAt);
}

export function wasNetSceneStoppedForSession(
  record: NetSceneStopRecord,
  sessionStartedAt: number,
  expectedSessionId: string
): boolean {
  if (expectedSessionId.length > 0) {
    return isValidVpnSessionId(expectedSessionId) && isValidVpnSessionId(record.sessionId) &&
      record.sessionId === expectedSessionId && Number.isFinite(record.stoppedAt) && record.stoppedAt > 0;
  }
  return wasNetSceneStoppedAfter(record.stoppedAt, sessionStartedAt);
}

function recoverInterruptedWrite(targetPath: string, tempPath: string, backupPath: string): void {
  if (fs.accessSync(tempPath)) {
    let temp: NetSceneStopRecord | null = null;
    try {
      temp = parseNetSceneStopRecord(readBoundedText(tempPath));
    } catch (_error) {
      // Oversized/unreadable temp is an incomplete transaction, not a reason to
      // prevent a new stop marker from replacing it.
    }
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
  return readBoundedText(path);
}

function readBoundedText(path: string): string {
  const stat = fs.statSync(path);
  if (!Number.isFinite(stat.size) || stat.size < 0 || stat.size > MAX_NET_SCENE_STOP_FLAG_BYTES) {
    throw new Error('Network scene stop flag is too large.');
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
