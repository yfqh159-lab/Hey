import { socket } from '@kit.NetworkKit';

export interface RuntimeHealthProbeResult {
  ok: boolean;
  status: string;
}

/**
 * 连接核心真正使用的回环 SOCKS 入口，确认监听器仍存活。
 * 这只是本地数据面存活探针，不把 TCP 建连成功当作外网或 VPS 可用的证明。
 */
export async function probeRuntimeSocksHealth(
  port: number,
  timeoutMs: number = 1500
): Promise<RuntimeHealthProbeResult> {
  if (!isRuntimeHealthPort(port)) {
    return { ok: false, status: 'invalid-endpoint' };
  }
  const tcp = socket.constructTCPSocketInstance();
  try {
    await tcp.connect({
      address: {
        address: '127.0.0.1',
        port
      },
      timeout: timeoutMs
    });
    return { ok: true, status: 'ok' };
  } catch (_error) {
    return { ok: false, status: 'tcp-failed' };
  } finally {
    try {
      await tcp.close();
    } catch (_) {
    }
  }
}

export function isRuntimeHealthPort(port: number): boolean {
  return Math.floor(port) === port && port >= 1 && port <= 65535;
}
