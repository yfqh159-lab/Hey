import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import Want from '@ohos.app.ability.Want';
import {
  BUNDLE_NAME,
  VPN_ABILITY_NAME,
  VPN_CORE_TYPE_KEY,
  VPN_HANDOVER_CONFIG_KEY,
  VPN_HEALTH_PORT_KEY,
  VPN_PROFILE_UPDATED_AT_KEY,
  VPN_SESSION_ID_KEY,
  VPN_SETTINGS_SNAPSHOT_KEY,
  isValidVpnSessionId
} from '../vpn/VpnConstants';

const START_REQUEST_FILE: string = 'hey-vpn-start-request.json';
const START_REQUEST_TEMP_FILE: string = 'hey-vpn-start-request.tmp';
const START_REQUEST_VERSION: number = 1;
const MAX_START_REQUEST_AGE_MS: number = 2 * 60 * 1000;
const MAX_START_REQUEST_FILE_BYTES: number = 6 * 1024 * 1024;
const MAX_CORE_CONFIG_CHARS: number = 2 * 1024 * 1024;
const MAX_SETTINGS_SNAPSHOT_CHARS: number = 512 * 1024;

export interface PersistedVpnStartRequest {
  version: number;
  createdAt: number;
  sessionId: string;
  configJson: string;
  coreType: string;
  healthPort: number;
  profileUpdatedAt: number;
  handoverConfigJson: string;
  settingsSnapshotJson: string;
}

let claimedSessionId: string = '';

function parameterString(want: Want, key: string): string {
  const value = want.parameters?.[key];
  return value === undefined || value === null ? '' : value.toString();
}

function nonNegativeInteger(value: string): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : -1;
}

/**
 * The VPN framework on some HarmonyOS builds creates the extension with an empty Want after
 * the system consent dialog. Keep the exact, already-generated data-plane request in the app
 * sandbox so the extension can recover that one explicit user action without rebuilding it
 * from mutable preferences. Requests are short-lived and session-bound.
 */
export function parsePersistedVpnStartRequest(
  raw: string,
  now: number = Date.now()
): PersistedVpnStartRequest | null {
  try {
    const value = JSON.parse(raw) as PersistedVpnStartRequest;
    if (value === null || typeof value !== 'object' || value.version !== START_REQUEST_VERSION ||
      !Number.isFinite(value.createdAt) || value.createdAt <= 0 || value.createdAt > now + 30 * 1000 ||
      now - value.createdAt > MAX_START_REQUEST_AGE_MS ||
      typeof value.sessionId !== 'string' || !isValidVpnSessionId(value.sessionId) ||
      typeof value.configJson !== 'string' || value.configJson.length === 0 ||
      value.configJson.length > MAX_CORE_CONFIG_CHARS ||
      typeof value.coreType !== 'string' || value.coreType.length === 0 || value.coreType.length > 32 ||
      !Number.isFinite(value.healthPort) || value.healthPort <= 0 || value.healthPort > 65535 ||
      !Number.isFinite(value.profileUpdatedAt) || value.profileUpdatedAt < 0 ||
      typeof value.handoverConfigJson !== 'string' ||
      value.handoverConfigJson.length > MAX_CORE_CONFIG_CHARS ||
      typeof value.settingsSnapshotJson !== 'string' ||
      value.settingsSnapshotJson.length > MAX_SETTINGS_SNAPSHOT_CHARS) {
      return null;
    }
    return {
      version: START_REQUEST_VERSION,
      createdAt: Math.floor(value.createdAt),
      sessionId: value.sessionId,
      configJson: value.configJson,
      coreType: value.coreType,
      healthPort: Math.floor(value.healthPort),
      profileUpdatedAt: Math.floor(value.profileUpdatedAt),
      handoverConfigJson: value.handoverConfigJson,
      settingsSnapshotJson: value.settingsSnapshotJson
    };
  } catch (_error) {
    return null;
  }
}

export class VpnStartRequestStore {
  static write(context: common.Context, want: Want, createdAt: number = Date.now()): boolean {
    const request: PersistedVpnStartRequest = {
      version: START_REQUEST_VERSION,
      createdAt,
      sessionId: parameterString(want, VPN_SESSION_ID_KEY),
      configJson: parameterString(want, 'xrayConfigJson'),
      coreType: parameterString(want, VPN_CORE_TYPE_KEY),
      healthPort: nonNegativeInteger(parameterString(want, VPN_HEALTH_PORT_KEY)),
      profileUpdatedAt: nonNegativeInteger(parameterString(want, VPN_PROFILE_UPDATED_AT_KEY)),
      handoverConfigJson: parameterString(want, VPN_HANDOVER_CONFIG_KEY),
      settingsSnapshotJson: parameterString(want, VPN_SETTINGS_SNAPSHOT_KEY)
    };
    const content = JSON.stringify(request);
    if (parsePersistedVpnStartRequest(content, createdAt) === null) {
      return false;
    }
    const targetPath = VpnStartRequestStore.path(context, START_REQUEST_FILE);
    const tempPath = VpnStartRequestStore.path(context, START_REQUEST_TEMP_FILE);
    let file: fs.File | null = null;
    try {
      const bytes = new util.TextEncoder().encodeInto(content);
      if (bytes.byteLength > MAX_START_REQUEST_FILE_BYTES) {
        return false;
      }
      file = fs.openSync(tempPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const written = fs.writeSync(file.fd, bytes.buffer);
      if (written !== bytes.byteLength) {
        throw new Error('short VPN start request write');
      }
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      file = null;
      VpnStartRequestStore.removeIfExists(targetPath);
      fs.renameSync(tempPath, targetPath);
      return true;
    } catch (_error) {
      VpnStartRequestStore.removeIfExistsSafely(tempPath);
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

  static claimWant(context: common.Context, now: number = Date.now()): Want | null {
    const targetPath = VpnStartRequestStore.path(context, START_REQUEST_FILE);
    try {
      if (!fs.accessSync(targetPath)) {
        return null;
      }
      const stat = fs.statSync(targetPath);
      if (!Number.isFinite(stat.size) || stat.size <= 0 || stat.size > MAX_START_REQUEST_FILE_BYTES) {
        VpnStartRequestStore.removeIfExists(targetPath);
        return null;
      }
      const request = parsePersistedVpnStartRequest(fs.readTextSync(targetPath), now);
      if (request === null) {
        VpnStartRequestStore.removeIfExists(targetPath);
        return null;
      }
      // A duplicated empty onCreate for the same system request must not start a second core.
      // A later explicit click has a new session ID and remains claimable in this process.
      if (request.sessionId === claimedSessionId) {
        return null;
      }
      claimedSessionId = request.sessionId;
      VpnStartRequestStore.removeIfExists(targetPath);
      return {
        deviceId: '',
        bundleName: BUNDLE_NAME,
        abilityName: VPN_ABILITY_NAME,
        parameters: {
          xrayConfigJson: request.configJson as Object,
          coreType: request.coreType as Object,
          healthPort: request.healthPort as Object,
          profileUpdatedAt: request.profileUpdatedAt as Object,
          sessionId: request.sessionId as Object,
          handoverConfigJson: request.handoverConfigJson as Object,
          settingsSnapshotJson: request.settingsSnapshotJson as Object
        }
      };
    } catch (_error) {
      return null;
    }
  }

  static clear(context: common.Context, sessionId: string): void {
    if (!isValidVpnSessionId(sessionId)) {
      return;
    }
    const targetPath = VpnStartRequestStore.path(context, START_REQUEST_FILE);
    try {
      if (!fs.accessSync(targetPath)) {
        return;
      }
      const stat = fs.statSync(targetPath);
      if (!Number.isFinite(stat.size) || stat.size <= 0 || stat.size > MAX_START_REQUEST_FILE_BYTES) {
        VpnStartRequestStore.removeIfExists(targetPath);
        return;
      }
      const request = parsePersistedVpnStartRequest(fs.readTextSync(targetPath));
      if (request === null || request.sessionId === sessionId) {
        VpnStartRequestStore.removeIfExists(targetPath);
      }
    } catch (_error) {
    }
  }

  private static removeIfExists(path: string): void {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  }

  private static removeIfExistsSafely(path: string): void {
    try {
      VpnStartRequestStore.removeIfExists(path);
    } catch (_error) {
    }
  }

  private static path(context: common.Context, fileName: string): string {
    return `${context.filesDir}/${fileName}`;
  }
}
