import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const VPN_RUNTIME_STATE_FILE: string = 'hey-vpn-runtime-state.json';
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

export class VpnRuntimeStateStore {
  static write(context: common.Context, state: PersistedVpnRuntimeState): void {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(VpnRuntimeStateStore.path(context),
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(state));
    } catch (error) {
      console.error(`VPN runtime state write failed: ${JSON.stringify(error)}`);
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  static read(context: common.Context): PersistedVpnRuntimeState | null {
    try {
      const path = VpnRuntimeStateStore.path(context);
      if (!fs.accessSync(path)) {
        return null;
      }
      return parsePersistedVpnRuntimeState(fs.readTextSync(path));
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

  private static path(context: common.Context): string {
    return `${context.filesDir}/${VPN_RUNTIME_STATE_FILE}`;
  }
}
