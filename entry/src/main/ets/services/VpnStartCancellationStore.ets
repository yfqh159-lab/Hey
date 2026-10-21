import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { isValidVpnSessionId } from '../vpn/VpnConstants';

const CANCELLATION_FILE: string = 'hey-vpn-start-cancelled';
const CANCELLATION_TEMP_FILE: string = 'hey-vpn-start-cancelled.tmp';
const CANCELLATION_BACKUP_FILE: string = 'hey-vpn-start-cancelled.bak';
const CANCELLATION_HISTORY_VERSION: number = 1;

interface StoredVpnStartCancellationHistory {
  version: number;
  sessionIds: string[];
}

export interface VpnStartCancellationCheck {
  cancelled: boolean;
  reliable: boolean;
}

/**
 * Decode the durable cancellation set. Older builds stored one bare session ID, so keep that
 * representation readable and migrate it on the next write. Invalid content is not equivalent
 * to an empty set: callers must fail closed instead of allowing an unknown delayed start.
 */
export function parseVpnStartCancellationHistory(raw: string): string[] | null {
  const trimmed = raw.trim();
  if (isValidVpnSessionId(trimmed)) {
    return [trimmed];
  }
  try {
    const parsed = JSON.parse(trimmed) as StoredVpnStartCancellationHistory;
    if (parsed === null || typeof parsed !== 'object' ||
      parsed.version !== CANCELLATION_HISTORY_VERSION || !Array.isArray(parsed.sessionIds) ||
      parsed.sessionIds.length === 0) {
      return null;
    }
    const result = new Array<string>();
    for (let index = 0; index < parsed.sessionIds.length; index++) {
      const sessionId = parsed.sessionIds[index];
      if (!isValidVpnSessionId(sessionId)) {
        return null;
      }
      if (!result.includes(sessionId)) {
        result.push(sessionId);
      }
    }
    return result;
  } catch (_error) {
    return null;
  }
}

export function appendVpnStartCancellation(
  sessionIds: string[],
  sessionId: string
): string[] | null {
  if (!isValidVpnSessionId(sessionId)) {
    return null;
  }
  const result = new Array<string>();
  for (let index = 0; index < sessionIds.length; index++) {
    const existing = sessionIds[index];
    if (!isValidVpnSessionId(existing)) {
      return null;
    }
    if (!result.includes(existing)) {
      result.push(existing);
    }
  }
  if (!result.includes(sessionId)) {
    result.push(sessionId);
  }
  return result;
}

/**
 * Cross-process, session-bound stop intent for a system start request that may return late.
 * The marker is intentionally retained: session IDs are unique, so a later explicit start is
 * unaffected while a delayed redelivery of the cancelled Want remains fail-closed.
 */
export class VpnStartCancellationStore {
  static markCancelled(context: common.Context, sessionId: string): boolean {
    if (!isValidVpnSessionId(sessionId)) {
      return false;
    }
    const targetPath = VpnStartCancellationStore.path(context, CANCELLATION_FILE);
    const tempPath = VpnStartCancellationStore.path(context, CANCELLATION_TEMP_FILE);
    const backupPath = VpnStartCancellationStore.path(context, CANCELLATION_BACKUP_FILE);
    let file: fs.File | null = null;
    try {
      VpnStartCancellationStore.recover(targetPath, tempPath, backupPath);
      let history = new Array<string>();
      if (fs.accessSync(targetPath)) {
        const parsed = parseVpnStartCancellationHistory(fs.readTextSync(targetPath));
        if (parsed === null) {
          return false;
        }
        history = parsed;
      }
      const nextHistory = appendVpnStartCancellation(history, sessionId);
      if (nextHistory === null) {
        return false;
      }
      const payload: StoredVpnStartCancellationHistory = {
        version: CANCELLATION_HISTORY_VERSION,
        sessionIds: nextHistory
      };
      const content = JSON.stringify(payload);
      file = fs.openSync(tempPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const written = fs.writeSync(file.fd, content);
      if (written !== content.length) {
        throw new Error('short VPN start cancellation write');
      }
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      file = null;
      VpnStartCancellationStore.removeIfExists(backupPath);
      if (fs.accessSync(targetPath)) {
        fs.renameSync(targetPath, backupPath);
      }
      fs.renameSync(tempPath, targetPath);
      return true;
    } catch (_error) {
      VpnStartCancellationStore.removeIfExistsSafely(tempPath);
      try {
        if (!fs.accessSync(targetPath) && fs.accessSync(backupPath)) {
          fs.renameSync(backupPath, targetPath);
        }
      } catch (_restoreError) {
      }
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (_closeError) {
        }
      }
    }
  }

  static check(context: common.Context, sessionId: string): VpnStartCancellationCheck {
    if (!isValidVpnSessionId(sessionId)) {
      return { cancelled: false, reliable: false };
    }
    const paths = [
      VpnStartCancellationStore.path(context, CANCELLATION_TEMP_FILE),
      VpnStartCancellationStore.path(context, CANCELLATION_FILE),
      VpnStartCancellationStore.path(context, CANCELLATION_BACKUP_FILE)
    ];
    try {
      for (let index = 0; index < paths.length; index++) {
        if (!fs.accessSync(paths[index])) {
          continue;
        }
        const stored = parseVpnStartCancellationHistory(fs.readTextSync(paths[index]));
        if (stored === null) {
          return { cancelled: false, reliable: false };
        }
        // temp > primary > backup. Once a higher-priority artifact is valid it is the
        // authoritative marker; an old lower-priority backup must not poison new sessions.
        return { cancelled: stored.includes(sessionId), reliable: true };
      }
      return { cancelled: false, reliable: true };
    } catch (_error) {
      return { cancelled: false, reliable: false };
    }
  }

  private static recover(targetPath: string, tempPath: string, backupPath: string): void {
    if (fs.accessSync(tempPath)) {
      const temp = parseVpnStartCancellationHistory(fs.readTextSync(tempPath));
      if (temp !== null) {
        VpnStartCancellationStore.removeIfExists(backupPath);
        if (fs.accessSync(targetPath)) {
          fs.renameSync(targetPath, backupPath);
        }
        fs.renameSync(tempPath, targetPath);
        return;
      }
      VpnStartCancellationStore.removeIfExists(tempPath);
    }
    if (!fs.accessSync(targetPath) && fs.accessSync(backupPath)) {
      fs.renameSync(backupPath, targetPath);
    }
  }

  private static removeIfExists(path: string): void {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  }

  private static removeIfExistsSafely(path: string): void {
    try {
      VpnStartCancellationStore.removeIfExists(path);
    } catch (_error) {
    }
  }

  private static path(context: common.Context, fileName: string): string {
    return `${context.filesDir}/${fileName}`;
  }
}
