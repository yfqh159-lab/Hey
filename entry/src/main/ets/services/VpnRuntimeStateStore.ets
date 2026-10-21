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
  backupContent: string | null,
  tempContent: string | null = null
): PersistedVpnRuntimeState | null {
  const primary = primaryContent === null ? null : parsePersistedVpnRuntimeState(primaryContent);
  const temp = tempContent === null ? null : parsePersistedVpnRuntimeState(tempContent);
  const backup = backupContent === null ? null : parsePersistedVpnRuntimeState(backupContent);
  // temp 只有在一次新状态已经完整序列化、但尚未来得及完成原子 rename 时才会留下。
  // 它代表比主文件更新的意图（尤其常见于 active -> stopped）；只要结构完整就应优先，
  // 否则旧主文件会在异常退出后短暂把已停止的 VPN 恢复成“运行中”。半写 temp 解析失败，
  // 此时仍安全回退到已提交的主文件，再回退备份。
  if (temp !== null) {
    return temp;
  }
  return primary !== null ? primary : backup;
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
      // 先把完整 JSON 持久化，再进入 rename 事务；进程中断后只有通过解析的 temp 才会被采用。
      fs.fsyncSync(file.fd);
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
      const temp = VpnRuntimeStateStore.readTextIfExists(
        VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_TEMP_FILE)
      );
      return selectPersistedVpnRuntimeState(primary, backup, temp);
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
    if (fs.accessSync(targetPath)) {
      VpnRuntimeStateStore.removeIfExists(tempPath);
      return;
    }
    if (fs.accessSync(tempPath)) {
      const tempState = parsePersistedVpnRuntimeState(fs.readTextSync(tempPath));
      if (tempState !== null) {
        fs.renameSync(tempPath, targetPath);
        return;
      }
      VpnRuntimeStateStore.removeIfExists(tempPath);
    }
    if (fs.accessSync(backupPath)) {
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
