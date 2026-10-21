import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';

const VPN_RUNTIME_STATE_FILE: string = 'hey-vpn-runtime-state.json';
const VPN_RUNTIME_STATE_TEMP_FILE: string = 'hey-vpn-runtime-state.tmp';
const VPN_RUNTIME_STATE_BACKUP_FILE: string = 'hey-vpn-runtime-state.bak';
export const VPN_RUNTIME_HEARTBEAT_STALE_MS: number = 30000;

export interface PersistedVpnRuntimeState {
  sessionId: string;
  active: boolean;
  startedAt: number;
  heartbeatAt: number;
  coreType: string;
  xrayRunning: boolean;
  tunRunning: boolean;
}

export function parsePersistedVpnRuntimeState(content: string): PersistedVpnRuntimeState | null {
  try {
    const value = JSON.parse(content) as PersistedVpnRuntimeState;
    if (typeof value.sessionId !== 'string' || value.sessionId.length === 0 ||
      typeof value.active !== 'boolean' || typeof value.startedAt !== 'number' ||
      typeof value.heartbeatAt !== 'number' || typeof value.coreType !== 'string' ||
      typeof value.xrayRunning !== 'boolean' || typeof value.tunRunning !== 'boolean' ||
      value.startedAt <= 0 || value.heartbeatAt < 0 ||
      (value.coreType !== 'xray' && value.coreType !== 'singbox')) {
      return null;
    }
    return value;
  } catch (error) {
    return null;
  }
}

export function isPersistedVpnRuntimeHealthy(
  state: PersistedVpnRuntimeState,
  now: number,
  staleAfterMs: number = VPN_RUNTIME_HEARTBEAT_STALE_MS
): boolean {
  return state.active && state.xrayRunning && state.tunRunning &&
    state.heartbeatAt >= state.startedAt && now >= state.heartbeatAt &&
    now - state.heartbeatAt <= staleAfterMs;
}

export function selectPersistedVpnRuntimeState(
  primaryContent: string | null,
  backupContent: string | null
): PersistedVpnRuntimeState | null {
  const primary = primaryContent === null ? null : parsePersistedVpnRuntimeState(primaryContent);
  const backup = backupContent === null ? null : parsePersistedVpnRuntimeState(backupContent);
  if (primary === null) {
    return backup;
  }
  // 主文件只有在临时文件完整关闭并完成 rename 后才出现，因此它始终是已提交状态；
  // 备份仅用于主文件缺失/损坏时兜底，不能按墙钟时间反客为主（系统时间可能被校准）。
  return primary;
}

export class VpnRuntimeStateStore {
  static write(context: common.Context, state: PersistedVpnRuntimeState): void {
    const targetPath = VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_FILE);
    const tempPath = VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_TEMP_FILE);
    const backupPath = VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_BACKUP_FILE);
    let file: fs.File | null = null;
    try {
      VpnRuntimeStateStore.recoverInterruptedWrite(targetPath, tempPath, backupPath);
      file = fs.openSync(tempPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const content = JSON.stringify(state);
      const bytes = new util.TextEncoder().encodeInto(content);
      const written = fs.writeSync(file.fd, bytes.buffer);
      if (written !== bytes.byteLength) {
        throw new Error('short VPN runtime state write');
      }
      fs.closeSync(file);
      file = null;

      VpnRuntimeStateStore.removeIfExists(backupPath);
      if (fs.accessSync(targetPath)) {
        fs.renameSync(targetPath, backupPath);
      }
      fs.renameSync(tempPath, targetPath);
    } catch (error) {
      console.error(`VPN runtime state write failed: ${JSON.stringify(error)}`);
      try {
        VpnRuntimeStateStore.removeIfExists(tempPath);
      } catch (cleanupError) {
        console.error(`VPN runtime state temp cleanup failed: ${JSON.stringify(cleanupError)}`);
      }
      try {
        if (!fs.accessSync(targetPath) && fs.accessSync(backupPath)) {
          fs.renameSync(backupPath, targetPath);
        }
      } catch (restoreError) {
        console.error(`VPN runtime state restore failed: ${JSON.stringify(restoreError)}`);
      }
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  static read(context: common.Context): PersistedVpnRuntimeState | null {
    try {
      const primary = VpnRuntimeStateStore.readTextIfExists(
        VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_FILE)
      );
      const backup = VpnRuntimeStateStore.readTextIfExists(
        VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_BACKUP_FILE)
      );
      return selectPersistedVpnRuntimeState(primary, backup);
    } catch (error) {
      return null;
    }
  }

  static stopped(sessionId: string, startedAt: number, coreType: string): PersistedVpnRuntimeState {
    return {
      sessionId,
      active: false,
      startedAt,
      heartbeatAt: Date.now(),
      coreType: coreType === 'singbox' ? 'singbox' : 'xray',
      xrayRunning: false,
      tunRunning: false
    };
  }

  private static recoverInterruptedWrite(targetPath: string, tempPath: string, backupPath: string): void {
    VpnRuntimeStateStore.removeIfExists(tempPath);
    if (!fs.accessSync(targetPath) && fs.accessSync(backupPath)) {
      fs.renameSync(backupPath, targetPath);
    }
  }

  private static readTextIfExists(path: string): string | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      return fs.readTextSync(path);
    } catch (error) {
      return null;
    }
  }

  private static removeIfExists(path: string): void {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  }

  private static path(context: common.Context, fileName: string): string {
    return `${context.filesDir}/${fileName}`;
  }
}
