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
  return probeRuntimeTcpHealth(port, timeoutMs);
}

/** Probe a loopback runtime listener without treating it as internet reachability. */
export async function probeRuntimeTcpHealth(
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

/**
 * 等待核心的 SOCKS 数据入口真正开始监听。原生 start 返回只代表启动调用成功，
 * 不能据此把 VPN/TUN 标记为可用。等待有明确上限，失败由调用方回滚整个会话。
 */
export async function waitForRuntimeSocksHealth(
  port: number,
  timeoutMs: number = 5000,
  retryIntervalMs: number = 100
): Promise<RuntimeHealthProbeResult> {
  if (!isRuntimeHealthPort(port) || timeoutMs <= 0 || retryIntervalMs <= 0) {
    return { ok: false, status: 'invalid-endpoint' };
  }
  const deadline = Date.now() + timeoutMs;
  do {
    const remaining = Math.max(1, deadline - Date.now());
    const probe = await probeRuntimeSocksHealth(port, Math.min(500, remaining));
    if (probe.ok) {
      return probe;
    }
    const sleepMs = Math.min(retryIntervalMs, deadline - Date.now());
    if (sleepMs > 0) {
      await delay(sleepMs);
    }
  } while (Date.now() < deadline);
  return { ok: false, status: 'startup-timeout' };
}

export function isRuntimeHealthPort(port: number): boolean {
  return Math.floor(port) === port && port >= 1 && port <= 65535;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, milliseconds);
  });
}
