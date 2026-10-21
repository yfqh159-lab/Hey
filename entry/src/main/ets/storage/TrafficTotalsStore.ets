import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// 持久化的流量累计。lifetime* 是跨重连/重启累加的历史总量；lastSession* 是上次记录到的
// 「本会话累计字节」，用来算两次采样之间的增量、并检测重连导致的计数归零（会话计数跳回
// 更小值即视为新会话）。四个值一起持久化，保证 app 重启后仍能正确续算增量。
export interface TrafficTotals {
  lifetimeUpload: number;
  lifetimeDownload: number;
  lastSessionUpload: number;
  lastSessionDownload: number;
}

export const EMPTY_TRAFFIC_TOTALS: TrafficTotals = {
  lifetimeUpload: 0,
  lifetimeDownload: 0,
  lastSessionUpload: 0,
  lastSessionDownload: 0
};

const PREFERENCES_NAME: string = 'hey_vpn_traffic';
const TOTALS_KEY: string = 'traffic_totals';

function sanitize(value: number): number {
  // Number.isFinite 不做隐式转换：非 number / NaN / Infinity 一律判 false，落到 0。
  if (!Number.isFinite(value) || value < 0) {
    return 0;
  }
  return Math.floor(value);
}

function normalize(raw: TrafficTotals): TrafficTotals {
  return {
    lifetimeUpload: sanitize(raw.lifetimeUpload),
    lifetimeDownload: sanitize(raw.lifetimeDownload),
    lastSessionUpload: sanitize(raw.lastSessionUpload),
    lastSessionDownload: sanitize(raw.lastSessionDownload)
  };
}

export class TrafficTotalsStore {
  private static operationTail: Promise<void> = Promise.resolve();

  static load(context: common.Context): Promise<TrafficTotals> {
    return TrafficTotalsStore.enqueueOperation(async (): Promise<TrafficTotals> => {
      try {
        const store = await preferences.getPreferences(context, PREFERENCES_NAME);
        const raw = (await store.get(TOTALS_KEY, '')).toString();
        if (raw.length === 0) {
          return normalize(EMPTY_TRAFFIC_TOTALS);
        }
        return normalize(JSON.parse(raw) as TrafficTotals);
      } catch (error) {
        return normalize(EMPTY_TRAFFIC_TOTALS);
      }
    });
  }

  static save(context: common.Context, totals: TrafficTotals): Promise<void> {
    const totalsSnapshot = normalize(totals);
    return TrafficTotalsStore.enqueueOperation(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      await store.put(TOTALS_KEY, JSON.stringify(totalsSnapshot));
      await store.flush();
    });
  }

  private static enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = TrafficTotalsStore.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    TrafficTotalsStore.operationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }
}
