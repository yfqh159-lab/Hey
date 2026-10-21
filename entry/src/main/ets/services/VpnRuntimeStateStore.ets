import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';

const VPN_RUNTIME_STATE_FILE: string = 'hey-vpn-runtime-state.json';
const VPN_RUNTIME_STATE_TEMP_FILE: string = 'hey-vpn-runtime-state.tmp';
const VPN_RUNTIME_STATE_BACKUP_FILE: string = 'hey-vpn-runtime-state.bak';
export const VPN_RUNTIME_HEARTBEAT_STALE_MS: number = 30000;
export const VPN_RUNTIME_STATE_WRITE_FAILURE_LIMIT: number = 3;

export interface PersistedVpnRuntimeState {
  sessionId: string;
  active: boolean;
  startedAt: number;
  heartbeatAt: number;
  coreType: string;
  profileUpdatedAt?: number;
  xrayRunning: boolean;
  tunRunning: boolean;
  cleanupComplete?: boolean;
  cleanupAttempted?: boolean;
}

export interface PersistedVpnRuntimeStateReadResult {
  state: PersistedVpnRuntimeState | null;
  authoritativeArtifactInvalid: boolean;
}

interface VpnRuntimeArtifactSnapshot {
  exists: boolean;
  content: string | null;
}

interface VpnRuntimeArtifactSet {
  primary: VpnRuntimeArtifactSnapshot;
  backup: VpnRuntimeArtifactSnapshot;
  temp: VpnRuntimeArtifactSnapshot;
}

export function parsePersistedVpnRuntimeState(content: string): PersistedVpnRuntimeState | null {
  try {
    const value = JSON.parse(content) as PersistedVpnRuntimeState;
    if (typeof value.sessionId !== 'string' || value.sessionId.length === 0 ||
      typeof value.active !== 'boolean' || typeof value.startedAt !== 'number' ||
      typeof value.heartbeatAt !== 'number' || typeof value.coreType !== 'string' ||
      typeof value.xrayRunning !== 'boolean' || typeof value.tunRunning !== 'boolean' ||
      (value.cleanupComplete !== undefined && typeof value.cleanupComplete !== 'boolean') ||
      (value.cleanupAttempted !== undefined && typeof value.cleanupAttempted !== 'boolean') ||
      (!value.active && (value.xrayRunning || value.tunRunning)) ||
      (value.cleanupComplete === true && (value.active || value.xrayRunning || value.tunRunning)) ||
      (value.cleanupAttempted === true && (value.active || value.xrayRunning || value.tunRunning)) ||
      value.startedAt <= 0 || value.heartbeatAt < 0 ||
      (value.profileUpdatedAt !== undefined &&
        (typeof value.profileUpdatedAt !== 'number' || Number.isNaN(value.profileUpdatedAt) ||
          value.profileUpdatedAt < 0 || Math.floor(value.profileUpdatedAt) !== value.profileUpdatedAt)) ||
      (value.coreType !== 'xray' && value.coreType !== 'singbox')) {
      return null;
    }
    return value;
  } catch (error) {
    return null;
  }
}

export function isPersistedVpnCleanupIncomplete(state: PersistedVpnRuntimeState): boolean {
  return state.cleanupAttempted === true && state.cleanupComplete !== true &&
    !state.active && !state.xrayRunning && !state.tunRunning;
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

export function shouldCleanupAfterVpnRuntimeStateWriteFailures(failureCount: number): boolean {
  return Number.isFinite(failureCount) && Math.floor(failureCount) === failureCount &&
    failureCount >= VPN_RUNTIME_STATE_WRITE_FAILURE_LIMIT;
}

// Date.now() can move backwards after automatic/network time correction. Persisting the original
// future startedAt beside a new lower heartbeatAt makes an otherwise healthy Extension look corrupt
// until wall time catches up. Keep the same session identity, but clamp its display/recovery origin
// to the heartbeat written by the still-running owner.
export function normalizeActiveVpnStartedAt(startedAt: number, heartbeatAt: number): number {
  const normalizedHeartbeat = Number.isFinite(heartbeatAt) && heartbeatAt > 0 ?
    Math.floor(heartbeatAt) : 1;
  if (!Number.isFinite(startedAt) || startedAt <= 0) {
    return normalizedHeartbeat;
  }
  return Math.min(Math.floor(startedAt), normalizedHeartbeat);
}

export function isPersistedVpnRuntimeSessionReady(
  state: PersistedVpnRuntimeState | null,
  expectedSessionId: string,
  requestedAt: number,
  now: number
): boolean {
  return state !== null && expectedSessionId.length > 0 && state.sessionId === expectedSessionId &&
    Number.isFinite(requestedAt) && requestedAt > 0 && state.startedAt >= requestedAt &&
    isPersistedVpnRuntimeHealthy(state, now);
}

export function isPersistedVpnRuntimeSessionStopped(
  state: PersistedVpnRuntimeState | null,
  expectedSessionId: string
): boolean {
  return state !== null && expectedSessionId.length > 0 && state.sessionId === expectedSessionId &&
    !state.active && !state.xrayRunning && !state.tunRunning && state.cleanupComplete === true;
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

export function hasInvalidPersistedVpnRuntimeArtifacts(
  primaryContent: string | null,
  backupContent: string | null,
  tempContent: string | null = null
): boolean {
  if (tempContent !== null) {
    return parsePersistedVpnRuntimeState(tempContent) === null;
  }
  if (primaryContent !== null) {
    return parsePersistedVpnRuntimeState(primaryContent) === null;
  }
  return backupContent !== null && parsePersistedVpnRuntimeState(backupContent) === null;
}

export function inspectPersistedVpnRuntimeArtifacts(
  primaryContent: string | null,
  backupContent: string | null,
  tempContent: string | null = null
): PersistedVpnRuntimeStateReadResult {
  return inspectVpnRuntimeArtifactSnapshots(
    { exists: primaryContent !== null, content: primaryContent },
    { exists: backupContent !== null, content: backupContent },
    { exists: tempContent !== null, content: tempContent }
  );
}

function inspectVpnRuntimeArtifactSnapshots(
  primary: VpnRuntimeArtifactSnapshot,
  backup: VpnRuntimeArtifactSnapshot,
  temp: VpnRuntimeArtifactSnapshot
): PersistedVpnRuntimeStateReadResult {
  const authoritative = temp.exists ? temp : (primary.exists ? primary : backup);
  const authoritativeContent = authoritative.content;
  return {
    // 读取失败的已存在工件以 null 参与选择，使调用方仍可看到低优先级恢复候选；
    // authoritativeArtifactInvalid 同时阻止它被当成可信的空闲/运行结论。
    state: selectPersistedVpnRuntimeState(primary.content, backup.content, temp.content),
    authoritativeArtifactInvalid: authoritative.exists &&
      (authoritativeContent === null || parsePersistedVpnRuntimeState(authoritativeContent) === null)
  };
}

export class VpnRuntimeStateStore {
  static write(context: common.Context, state: PersistedVpnRuntimeState): boolean {
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
      return true;
    } catch (error) {
      console.error(`VPN runtime state write failed: ${redactDiagnosticText(JSON.stringify(error))}`);
      try {
        VpnRuntimeStateStore.removeIfExists(tempPath);
      } catch (cleanupError) {
        console.error(`VPN runtime state temp cleanup failed: ${redactDiagnosticText(JSON.stringify(cleanupError))}`);
      }
      try {
        if (!fs.accessSync(targetPath) && fs.accessSync(backupPath)) {
          fs.renameSync(backupPath, targetPath);
        }
      } catch (restoreError) {
        console.error(`VPN runtime state restore failed: ${redactDiagnosticText(JSON.stringify(restoreError))}`);
      }
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          console.error(`VPN runtime state close failed: ${redactDiagnosticText(JSON.stringify(closeError))}`);
        }
      }
    }
  }

  static read(context: common.Context): PersistedVpnRuntimeState | null {
    return VpnRuntimeStateStore.readWithEvidence(context).state;
  }

  // 一次 API 调用复读并确认同一组 temp/主文件/备份，同时返回候选状态和可信度。调用方若先 read()
  // 再单独检查损坏标记，VPN Extension 恰好在两次读取间提交状态时可能形成自相矛盾的
  // “旧 inactive + 新文件有效”结论，后台订阅因而误走物理网络直连。
  static readWithEvidence(context: common.Context): PersistedVpnRuntimeStateReadResult {
    const first = VpnRuntimeStateStore.readArtifactSet(context);
    const confirmed = VpnRuntimeStateStore.readArtifactSet(context);
    const result = inspectVpnRuntimeArtifactSnapshots(
      confirmed.primary, confirmed.backup, confirmed.temp);
    if (!VpnRuntimeStateStore.sameArtifactSet(first, confirmed)) {
      // 状态事务恰好跨过本次读取，不能把不同提交代际拼成可用于直连或“已连接”的证据。
      return { state: result.state, authoritativeArtifactInvalid: true };
    }
    return result;
  }

  // 与 selectPersistedVpnRuntimeState 使用同一权威顺序：完整 temp > 主文件 > 备份。
  // 只有当前最高优先级的已存在工件损坏/不可读才算不可信；有效 temp 或主文件已经
  // 完整表达当前意图时，低优先级的旧损坏备份不能永久阻断空闲态网络请求。
  static hasInvalidStateArtifacts(context: common.Context): boolean {
    return VpnRuntimeStateStore.readWithEvidence(context).authoritativeArtifactInvalid;
  }

  static stopped(
    sessionId: string,
    startedAt: number,
    coreType: string,
    profileUpdatedAt: number = 0,
    cleanupComplete: boolean = false,
    cleanupAttempted: boolean = false
  ): PersistedVpnRuntimeState {
    return {
      sessionId,
      active: false,
      startedAt,
      heartbeatAt: Date.now(),
      coreType: coreType === 'singbox' ? 'singbox' : 'xray',
      profileUpdatedAt,
      xrayRunning: false,
      tunRunning: false,
      cleanupComplete,
      cleanupAttempted
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

  private static readArtifactSnapshot(path: string): VpnRuntimeArtifactSnapshot {
    try {
      if (!fs.accessSync(path)) {
        return { exists: false, content: null };
      }
      return { exists: true, content: fs.readTextSync(path) };
    } catch (error) {
      // 无法确认是瞬时访问错误还是损坏，涉及订阅凭据时必须保守处理。
      return { exists: true, content: null };
    }
  }

  private static readArtifactSet(context: common.Context): VpnRuntimeArtifactSet {
    return {
      // temp 是写事务中最新意图；其后仍复读整组并要求完全一致，避免 rename 跨越读取。
      temp: VpnRuntimeStateStore.readArtifactSnapshot(
        VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_TEMP_FILE)),
      primary: VpnRuntimeStateStore.readArtifactSnapshot(
        VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_FILE)),
      backup: VpnRuntimeStateStore.readArtifactSnapshot(
        VpnRuntimeStateStore.path(context, VPN_RUNTIME_STATE_BACKUP_FILE))
    };
  }

  private static sameArtifactSet(left: VpnRuntimeArtifactSet, right: VpnRuntimeArtifactSet): boolean {
    return VpnRuntimeStateStore.sameArtifact(left.temp, right.temp) &&
      VpnRuntimeStateStore.sameArtifact(left.primary, right.primary) &&
      VpnRuntimeStateStore.sameArtifact(left.backup, right.backup);
  }

  private static sameArtifact(left: VpnRuntimeArtifactSnapshot, right: VpnRuntimeArtifactSnapshot): boolean {
    return left.exists === right.exists && left.content === right.content;
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
