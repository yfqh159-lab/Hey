import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { workScheduler } from '@kit.BackgroundTasksKit';
import {
  SUBSCRIPTION_AUTO_UPDATE_WORK_ABILITY,
  SUBSCRIPTION_AUTO_UPDATE_WORK_BUNDLE_NAME,
  SUBSCRIPTION_AUTO_UPDATE_WORK_ID,
  SubscriptionAutoUpdateGroupSchedulePlan,
  SubscriptionAutoUpdateSchedulePlan,
  buildSubscriptionAutoUpdateSchedulePlan,
  subscriptionAutoUpdateWorkIdForGroup
} from '../core/SubscriptionSchedulerPlan';
import { SubscriptionGroup } from '../core/Profile';
import { SubscriptionStore } from '../storage/SubscriptionStore';

const PREFERENCES_NAME: string = 'hey_subscription_background_scheduler';
const SCHEDULED_WORKS_KEY: string = 'scheduled_works';
const SCHEDULED_WORKS_BACKUP_KEY: string = 'scheduled_works_backup';

export interface SubscriptionBackgroundScheduleResult {
  ok: boolean;
  scheduled: boolean;
  enabledGroupCount: number;
  repeatCycleTimeMs: number;
  message: string;
}

export interface SubscriptionScheduledWorkRecord {
  groupId: string;
  workId: number;
}

export interface StoredSubscriptionScheduledWorksSelection {
  records: Array<SubscriptionScheduledWorkRecord> | null;
  source: string;
}

export class SubscriptionBackgroundScheduler {
  private static scheduleTail: Promise<void> = Promise.resolve();

  static sync(context: common.Context): Promise<SubscriptionBackgroundScheduleResult> {
    return SubscriptionBackgroundScheduler.enqueueScheduleOperation(
      (): Promise<SubscriptionBackgroundScheduleResult> => SubscriptionBackgroundScheduler.syncNow(context));
  }

  private static async syncNow(context: common.Context): Promise<SubscriptionBackgroundScheduleResult> {
    const profile = await SubscriptionStore.load(context);
    const plan = buildSubscriptionAutoUpdateSchedulePlan(profile.groups);
    if (!plan.enabled) {
      return SubscriptionBackgroundScheduler.cancelNow(
        context,
        'No enabled subscription auto-update groups.',
        SubscriptionBackgroundScheduler.workIdsForGroups(profile.groups)
      );
    }

    const startedWorkIds = new Array<number>();
    try {
      const previous = await SubscriptionBackgroundScheduler.loadScheduledWorks(context);
      SubscriptionBackgroundScheduler.stopExistingWork(previous);
      for (let index = 0; index < plan.groupPlans.length; index++) {
        workScheduler.startWork(SubscriptionBackgroundScheduler.buildWorkInfo(plan.groupPlans[index], plan));
        startedWorkIds.push(plan.groupPlans[index].workId);
      }
      await SubscriptionBackgroundScheduler.saveScheduledWorks(context, plan.groupPlans);
      return {
        ok: true,
        scheduled: true,
        enabledGroupCount: plan.enabledGroupCount,
        repeatCycleTimeMs: plan.repeatCycleTimeMs,
        message: `Subscription background auto-update scheduled for ${plan.enabledGroupCount} group task(s).`
      };
    } catch (error) {
      SubscriptionBackgroundScheduler.stopWorkIds(startedWorkIds);
      return {
        ok: false,
        scheduled: false,
        enabledGroupCount: plan.enabledGroupCount,
        repeatCycleTimeMs: plan.repeatCycleTimeMs,
        message: `Subscription background auto-update schedule failed: ${SubscriptionBackgroundScheduler.stringifyError(error)}`
      };
    }
  }

  static cancel(
    context: common.Context,
    reason: string = 'Subscription background auto-update disabled.',
    knownWorkIds: Array<number> = []
  ): Promise<SubscriptionBackgroundScheduleResult> {
    const workIdsSnapshot = knownWorkIds.slice();
    return SubscriptionBackgroundScheduler.enqueueScheduleOperation(
      (): Promise<SubscriptionBackgroundScheduleResult> =>
        SubscriptionBackgroundScheduler.cancelNow(context, reason, workIdsSnapshot));
  }

  private static async cancelNow(
    context: common.Context,
    reason: string,
    knownWorkIds: Array<number>
  ): Promise<SubscriptionBackgroundScheduleResult> {
    // Even if the persisted task index is damaged, the legacy task and every task
    // derivable from the current subscription database must still be stopped.
    SubscriptionBackgroundScheduler.stopWorkId(SUBSCRIPTION_AUTO_UPDATE_WORK_ID);
    SubscriptionBackgroundScheduler.stopWorkIds(knownWorkIds);
    try {
      const previous = await SubscriptionBackgroundScheduler.loadScheduledWorks(context);
      SubscriptionBackgroundScheduler.stopExistingWork(previous);
      await SubscriptionBackgroundScheduler.saveScheduledWorks(context, []);
    } catch (error) {
      return {
        ok: false,
        scheduled: false,
        enabledGroupCount: 0,
        repeatCycleTimeMs: 0,
        message: `${reason} Task index cleanup failed: ${SubscriptionBackgroundScheduler.stringifyError(error)}`
      };
    }

    return {
      ok: true,
      scheduled: false,
      enabledGroupCount: 0,
      repeatCycleTimeMs: 0,
      message: reason
    };
  }

  private static enqueueScheduleOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = SubscriptionBackgroundScheduler.scheduleTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    SubscriptionBackgroundScheduler.scheduleTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static stopExistingWork(previous: Array<SubscriptionScheduledWorkRecord>): void {
    SubscriptionBackgroundScheduler.stopWorkId(SUBSCRIPTION_AUTO_UPDATE_WORK_ID);
    for (let index = 0; index < previous.length; index++) {
      SubscriptionBackgroundScheduler.stopWorkId(previous[index].workId);
    }
  }

  private static stopWorkIds(workIds: Array<number>): void {
    const stopped = new Array<number>();
    for (let index = 0; index < workIds.length; index++) {
      const workId = workIds[index];
      if (workId > 0 && stopped.indexOf(workId) < 0) {
        SubscriptionBackgroundScheduler.stopWorkId(workId);
        stopped.push(workId);
      }
    }
  }

  private static stopWorkId(workId: number): void {
    try {
      workScheduler.stopWork(SubscriptionBackgroundScheduler.buildCancelWorkInfo(workId), true);
    } catch (error) {
      // WorkScheduler throws when there is no existing work. Registering the new
      // work below is still the source of truth for schedule success.
    }
  }

  private static buildWorkInfo(groupPlan: SubscriptionAutoUpdateGroupSchedulePlan, plan: SubscriptionAutoUpdateSchedulePlan): workScheduler.WorkInfo {
    return {
      workId: groupPlan.workId,
      bundleName: SUBSCRIPTION_AUTO_UPDATE_WORK_BUNDLE_NAME,
      abilityName: SUBSCRIPTION_AUTO_UPDATE_WORK_ABILITY,
      isPersisted: true,
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isRepeat: true,
      repeatCycleTime: groupPlan.repeatCycleTimeMs,
      parameters: {
        source: 'subscription-auto-update',
        groupId: groupPlan.groupId,
        workId: groupPlan.workId,
        enabledGroupCount: plan.enabledGroupCount,
        intervalMinutes: groupPlan.intervalMinutes,
        nextDelayTimeMs: groupPlan.nextDelayTimeMs
      }
    };
  }

  private static buildCancelWorkInfo(workId: number): workScheduler.WorkInfo {
    return {
      workId,
      bundleName: SUBSCRIPTION_AUTO_UPDATE_WORK_BUNDLE_NAME,
      abilityName: SUBSCRIPTION_AUTO_UPDATE_WORK_ABILITY
    };
  }

  private static async loadScheduledWorks(context: common.Context): Promise<Array<SubscriptionScheduledWorkRecord>> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const primaryRaw = (await store.get(SCHEDULED_WORKS_KEY, '')).toString();
    const backupRaw = (await store.get(SCHEDULED_WORKS_BACKUP_KEY, '')).toString();
    const selection = SubscriptionBackgroundScheduler.selectStoredWorks(primaryRaw, backupRaw);
    if (selection.records !== null && selection.source !== 'backup') {
      return selection.records;
    }
    if (selection.records !== null) {
      try {
        await store.put(SCHEDULED_WORKS_KEY, JSON.stringify(selection.records));
        await store.flush();
      } catch (_error) {
        // The recovered in-memory index is enough to stop or replace its tasks.
      }
      return selection.records;
    }
    throw new Error('Stored subscription background task index is unreadable.');
  }

  private static async saveScheduledWorks(context: common.Context, groupPlans: Array<SubscriptionAutoUpdateGroupSchedulePlan>): Promise<void> {
    const records = new Array<SubscriptionScheduledWorkRecord>();
    for (let index = 0; index < groupPlans.length; index++) {
      records.push({
        groupId: groupPlans[index].groupId,
        workId: groupPlans[index].workId
      });
    }
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const nextRaw = JSON.stringify(records);
    const currentRaw = (await store.get(SCHEDULED_WORKS_KEY, '')).toString();
    if (currentRaw === nextRaw) {
      return;
    }
    const current = SubscriptionBackgroundScheduler.parseScheduledWorks(currentRaw);
    if (current !== null) {
      await store.put(SCHEDULED_WORKS_BACKUP_KEY, JSON.stringify(current));
    } else {
      const backupRaw = (await store.get(SCHEDULED_WORKS_BACKUP_KEY, '')).toString();
      if (SubscriptionBackgroundScheduler.parseScheduledWorks(backupRaw) === null) {
        await store.put(SCHEDULED_WORKS_BACKUP_KEY, nextRaw);
      }
    }
    await store.put(SCHEDULED_WORKS_KEY, nextRaw);
    await store.flush();
  }

  static selectStoredWorks(primaryRaw: string, backupRaw: string): StoredSubscriptionScheduledWorksSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { records: [], source: 'empty' };
    }
    const primary = SubscriptionBackgroundScheduler.parseScheduledWorks(primaryRaw);
    if (primary !== null) {
      return { records: primary, source: 'primary' };
    }
    const backup = SubscriptionBackgroundScheduler.parseScheduledWorks(backupRaw);
    if (backup !== null) {
      return { records: backup, source: 'backup' };
    }
    return { records: null, source: 'invalid' };
  }

  private static parseScheduledWorks(raw: string): Array<SubscriptionScheduledWorkRecord> | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as Array<Object>;
      if (!Array.isArray(parsed)) {
        return null;
      }
      const records = new Array<SubscriptionScheduledWorkRecord>();
      for (let index = 0; index < parsed.length; index++) {
        const record = parsed[index] as Record<string, Object>;
        const groupId = record['groupId'];
        const workId = record['workId'];
        if (typeof groupId !== 'string' || groupId.length === 0 || typeof workId !== 'number' ||
          !Number.isFinite(workId) || Math.floor(workId) !== workId || workId <= 0) {
          return null;
        }
        if (!SubscriptionBackgroundScheduler.hasWorkId(records, workId)) {
          records.push({
            groupId,
            workId
          });
        }
      }
      return records;
    } catch (_error) {
      return null;
    }
  }

  private static hasWorkId(records: Array<SubscriptionScheduledWorkRecord>, workId: number): boolean {
    for (let index = 0; index < records.length; index++) {
      if (records[index].workId === workId) {
        return true;
      }
    }
    return false;
  }

  private static workIdsForGroups(groups: Array<SubscriptionGroup>): Array<number> {
    const workIds = new Array<number>();
    for (let index = 0; index < groups.length; index++) {
      const workId = subscriptionAutoUpdateWorkIdForGroup(groups[index].id);
      if (workIds.indexOf(workId) < 0) {
        workIds.push(workId);
      }
    }
    return workIds;
  }

  private static stringifyError(error: Error | Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return JSON.stringify(error);
  }
}
