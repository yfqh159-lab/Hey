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

function flagPath(context: common.Context): string {
  return `${context.filesDir}/net_scene_stopped_at`;
}

function writeFlag(context: common.Context, value: number): void {
  try {
    const file = fs.openSync(flagPath(context), fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, value.toString());
    fs.closeSync(file);
  } catch (error) {
    // ignore
  }
}

export class NetSceneStopFlag {
  /** 扩展进程自动断开时调用：标记「本次启动后发生过自动断开」。 */
  static async markStopped(context: common.Context, at: number): Promise<void> {
    writeFlag(context, at);
  }

  /** VPN 启动成功时调用：清除标志（此后若再置位即代表本次启动后的自动断开）。 */
  static async clear(context: common.Context): Promise<void> {
    writeFlag(context, 0);
  }

  /** 主进程前台读取：本次启动后是否发生过后台自动断开。 */
  static async wasStopped(context: common.Context, sessionStartedAt: number = 0): Promise<boolean> {
    try {
      const path = flagPath(context);
      if (!fs.accessSync(path)) {
        return false;
      }
      const raw = fs.readTextSync(path);
      const num = Number(raw.trim());
      return wasNetSceneStoppedAfter(num, sessionStartedAt);
    } catch (error) {
      return false;
    }
  }
}

export function wasNetSceneStoppedAfter(stoppedAt: number, sessionStartedAt: number): boolean {
  return !Number.isNaN(stoppedAt) && stoppedAt > 0 &&
    !Number.isNaN(sessionStartedAt) && stoppedAt > Math.max(0, sessionStartedAt);
}
