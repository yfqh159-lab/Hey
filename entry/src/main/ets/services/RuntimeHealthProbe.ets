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
  if (!isRuntimeHealthPort(port) || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return { ok: false, status: 'invalid-endpoint' };
  }
  const tcp = socket.constructTCPSocketInstance();
  try {
    // Some device builds have been observed to leave NetworkKit promises pending
    // beyond the option timeout. Keep an outer deadline so the Extension health
    // loop cannot permanently retain healthProbeInFlight and stop heartbeats.
    await withProbeTimeout(
      tcp.connect({
        address: {
          address: '127.0.0.1',
          port
        },
        timeout: timeoutMs
      }),
      timeoutMs
    );
    return { ok: true, status: 'ok' };
  } catch (_error) {
    return { ok: false, status: 'tcp-failed' };
  } finally {
    try {
      // close() is cleanup, not a reason to wedge startup or runtime polling.
      await withProbeTimeout(tcp.close(), Math.min(500, timeoutMs));
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
  return new Promise<RuntimeHealthProbeResult>((resolve) => {
    let settled = false;
    let cancelled = false;
    let timerId: number = -1;
    const finish = (result: RuntimeHealthProbeResult): void => {
      if (settled) {
        return;
      }
      settled = true;
      cancelled = true;
      if (timerId >= 0) {
        clearTimeout(timerId);
      }
      resolve(result);
    };
    // setTimeout is not derived from wall-clock timestamps. If it wins while one bounded TCP
    // probe is pending, cancelled prevents that late probe from scheduling another attempt.
    timerId = setTimeout(() => {
      finish({ ok: false, status: 'startup-timeout' });
    }, timeoutMs);
    const poll = async (): Promise<void> => {
      while (!cancelled) {
        const probe = await probeRuntimeSocksHealth(port, Math.min(500, timeoutMs));
        if (cancelled) {
          return;
        }
        if (probe.ok) {
          finish(probe);
          return;
        }
        await delay(retryIntervalMs);
      }
    };
    poll().catch((_error: Object): void => {
      finish({ ok: false, status: 'startup-timeout' });
    });
  });
}

export function isRuntimeHealthPort(port: number): boolean {
  return Math.floor(port) === port && port >= 1 && port <= 65535;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, milliseconds);
  });
}

function withProbeTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timerId = setTimeout(() => {
      reject(new Error('runtime health probe timed out'));
    }, timeoutMs);
    promise.then((value: T) => {
      clearTimeout(timerId);
      resolve(value);
    }, (error: Object) => {
      clearTimeout(timerId);
      reject(error);
    });
  });
}
