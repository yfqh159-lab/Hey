import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ControlCardFormData, buildControlCardFormData, normalizeControlCardFormData } from '../core/ControlCard';

const PREFERENCES_NAME: string = 'hey_control_card';
const FORM_IDS_KEY: string = 'form_ids';
const FORM_IDS_BACKUP_KEY: string = 'form_ids_backup';
const STATE_KEY: string = 'state';
const STATE_BACKUP_KEY: string = 'state_backup';

export interface StoredControlCardStateSelection {
  state: ControlCardFormData | null;
  source: string;
}

export interface StoredFormIdsSelection {
  ids: Array<string> | null;
  source: string;
}

export class ControlCardStore {
  private static operationTail: Promise<void> = Promise.resolve();
  private static formMutationTail: Promise<void> = Promise.resolve();

  static loadFormIds(context: common.Context): Promise<Array<string>> {
    return ControlCardStore.enqueueOperation(async (): Promise<Array<string>> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const primaryRaw = (await store.get(FORM_IDS_KEY, '')).toString();
      const backupRaw = (await store.get(FORM_IDS_BACKUP_KEY, '')).toString();
      const selection = ControlCardStore.selectStoredFormIds(primaryRaw, backupRaw);
      if (selection.ids !== null && selection.source !== 'backup') {
        return selection.ids;
      }
      if (selection.ids !== null) {
        try {
          await store.put(FORM_IDS_KEY, JSON.stringify(selection.ids));
          await store.flush();
        } catch (_error) {
          // keep recovered in-memory value
        }
        return selection.ids;
      }
      throw new Error('Stored control card identifiers are unreadable.');
    });
  }

  static addFormId(context: common.Context, formId: string): Promise<Array<string>> {
    return ControlCardStore.enqueueFormMutation(async (): Promise<Array<string>> => {
      if (formId.length === 0) {
        return ControlCardStore.loadFormIds(context);
      }
      const ids = await ControlCardStore.loadFormIds(context);
      if (ids.indexOf(formId) < 0) {
        ids.push(formId);
        await ControlCardStore.saveFormIds(context, ids);
      }
      return ids;
    });
  }

  static removeFormId(context: common.Context, formId: string): Promise<Array<string>> {
    return ControlCardStore.enqueueFormMutation(async (): Promise<Array<string>> => {
      const ids = await ControlCardStore.loadFormIds(context);
      const next = ids.filter((id: string) => id !== formId);
      if (next.length !== ids.length) {
        await ControlCardStore.saveFormIds(context, next);
      }
      return next;
    });
  }

  static loadState(context: common.Context): Promise<ControlCardFormData> {
    return ControlCardStore.enqueueOperation(async (): Promise<ControlCardFormData> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const primaryRaw = (await store.get(STATE_KEY, '')).toString();
      const backupRaw = (await store.get(STATE_BACKUP_KEY, '')).toString();
      const selection = ControlCardStore.selectStoredState(primaryRaw, backupRaw);
      if (selection.state !== null && selection.source !== 'backup') {
        return selection.state;
      }
      if (selection.state !== null) {
        try {
          await store.put(STATE_KEY, JSON.stringify(selection.state));
          await store.flush();
        } catch (_error) {
          // keep recovered in-memory value
        }
        return selection.state;
      }
      throw new Error('Stored control card runtime state is unreadable.');
    });
  }

  static selectStoredState(primaryRaw: string, backupRaw: string): StoredControlCardStateSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { state: buildControlCardFormData(), source: 'empty' };
    }
    const primary = ControlCardStore.parseState(primaryRaw);
    if (primary !== null) {
      return { state: primary, source: 'primary' };
    }
    const backup = ControlCardStore.parseState(backupRaw);
    if (backup !== null) {
      return { state: backup, source: 'backup' };
    }
    return { state: null, source: 'invalid' };
  }

  static selectStoredFormIds(primaryRaw: string, backupRaw: string): StoredFormIdsSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { ids: [], source: 'empty' };
    }
    const primary = ControlCardStore.parseIds(primaryRaw);
    if (primary !== null) {
      return { ids: primary, source: 'primary' };
    }
    const backup = ControlCardStore.parseIds(backupRaw);
    if (backup !== null) {
      return { ids: backup, source: 'backup' };
    }
    return { ids: null, source: 'invalid' };
  }

  static saveState(context: common.Context, state: ControlCardFormData): Promise<ControlCardFormData> {
    const normalized = normalizeControlCardFormData(state);
    return ControlCardStore.enqueueOperation(async (): Promise<ControlCardFormData> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const nextRaw = JSON.stringify(normalized);
      const currentRaw = (await store.get(STATE_KEY, '')).toString();
      const current = ControlCardStore.parseState(currentRaw);
      if (current !== null && !ControlCardStore.sameRuntimeRoutingState(current, normalized)) {
        await store.put(STATE_BACKUP_KEY, currentRaw);
      } else if (current === null) {
        const backupRaw = (await store.get(STATE_BACKUP_KEY, '')).toString();
        if (ControlCardStore.parseState(backupRaw) === null) {
          await store.put(STATE_BACKUP_KEY, nextRaw);
        }
      }
      await store.put(STATE_KEY, nextRaw);
      await store.flush();
      return normalized;
    });
  }

  private static saveFormIds(context: common.Context, ids: Array<string>): Promise<void> {
    const idsSnapshot = ControlCardStore.uniqueIds(ids);
    return ControlCardStore.enqueueOperation(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const nextRaw = JSON.stringify(idsSnapshot);
      const currentRaw = (await store.get(FORM_IDS_KEY, '')).toString();
      if (ControlCardStore.parseIds(currentRaw) !== null) {
        await store.put(FORM_IDS_BACKUP_KEY, currentRaw);
      } else {
        const backupRaw = (await store.get(FORM_IDS_BACKUP_KEY, '')).toString();
        if (ControlCardStore.parseIds(backupRaw) === null) {
          await store.put(FORM_IDS_BACKUP_KEY, nextRaw);
        }
      }
      await store.put(FORM_IDS_KEY, nextRaw);
      await store.flush();
    });
  }

  private static enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = ControlCardStore.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    ControlCardStore.operationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static enqueueFormMutation<T>(operation: () => Promise<T>): Promise<T> {
    const task = ControlCardStore.formMutationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    ControlCardStore.formMutationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static parseState(raw: string): ControlCardFormData | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as ControlCardFormData;
      if (parsed === null || typeof parsed !== 'object') {
        return null;
      }
      const record = parsed as Record<string, Object>;
      if (record['primaryActionUri'] === undefined && record['runtimeStatus'] === undefined &&
        record['runtimeMode'] === undefined) {
        return null;
      }
      return normalizeControlCardFormData(parsed);
    } catch (_error) {
      return null;
    }
  }

  private static parseIds(raw: string): Array<string> | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as Array<Object>;
      if (!Array.isArray(parsed)) {
        return null;
      }
      const ids = new Array<string>();
      for (let index = 0; index < parsed.length; index++) {
        if (typeof parsed[index] === 'string') {
          ids.push(parsed[index] as string);
        }
      }
      return ControlCardStore.uniqueIds(ids);
    } catch (_error) {
      return null;
    }
  }

  private static sameRuntimeRoutingState(left: ControlCardFormData, right: ControlCardFormData): boolean {
    return left.runtimeStatus === right.runtimeStatus && left.runtimeMode === right.runtimeMode &&
      left.vpnBacked === right.vpnBacked && left.cleanupRequired === right.cleanupRequired &&
      left.primaryActionUri === right.primaryActionUri;
  }

  private static uniqueIds(ids: Array<string>): Array<string> {
    const result = new Array<string>();
    for (let index = 0; index < ids.length; index++) {
      const id = ids[index];
      if (id.length > 0 && result.indexOf(id) < 0) {
        result.push(id);
      }
    }
    return result;
  }
}
