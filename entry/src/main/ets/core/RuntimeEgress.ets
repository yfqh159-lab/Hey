import { ConnectionStatus } from './Profile';

/**
 * 出口检测结果只能写回发起它的同一运行会话和同一检测代际。
 * 承载切换会推进代际，使旧 Wi-Fi/蜂窝请求即使迟到完成也不能覆盖新出口状态。
 */
export function isCurrentEgressCheck(
  status: ConnectionStatus,
  currentStartedAt: number,
  requestStartedAt: number,
  currentGeneration: number,
  requestGeneration: number
): boolean {
  return status === ConnectionStatus.RUNNING && currentStartedAt > 0 &&
    currentStartedAt === requestStartedAt && currentGeneration === requestGeneration;
}
