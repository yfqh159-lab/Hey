import { socket } from '@kit.NetworkKit';
import { taskpool } from '@kit.ArkTS';
import { XrayConfigType } from '../core/Profile';
import { DEFAULT_SOCKS_HOST, DELAY_TEST_SOCKS_PORT, buildDelayTestConfig } from '../core/XrayConfig';
import { NativePingResult, nativeXrayAssetReadiness, pingNativeOutbound } from '../native/HeyNative';
import { isSingboxOnlyProtocol } from '../core/CoreSelection';

export interface DelayTestResult {
  ok: boolean;
  delayMs: number;
  status: string;
}

// hysteria2 / tuic 等基于 QUIC/UDP 的 sing-box 独有协议：Xray 核心无对应 outbound，
// 无法建临时实例做真实 ping；服务器端口通常只监听 UDP，快速 TCP 探测多半失败。
// 这类"无法用快速探测测出延迟"的情况用此中性状态标记，UI 据此显示中性文案而非红色"失败"
// （节点本身可正常使用，只是延迟测不出来）。
export const DELAY_STATUS_UDP_ONLY: string = 'udp-only';

interface DelayProbeServer {
  address?: string;
  port?: number;
}

interface DelayProbeSettings {
  servers?: Array<DelayProbeServer>;
  vnext?: Array<DelayProbeServer>;
}

interface DelayProbeOutbound {
  protocol?: string;
  settings?: DelayProbeSettings;
}

interface DelayTcpTarget {
  address: string;
  port: number;
}

function isCoreUnavailable(message: string): boolean {
  const lower = message.toLowerCase();
  return lower.indexOf('unavailable') >= 0 || lower.indexOf('failed to load') >= 0 || lower.indexOf('symbol missing') >= 0;
}

export function nativeDelayFailureStatus(message: string): string {
  if (message === 'invalid-config') {
    return 'invalid-config';
  }
  if (isCoreUnavailable(message)) {
    return 'core-unavailable';
  }
  const lower = message.toLowerCase();
  if (lower.indexOf('timeout') >= 0 || lower.indexOf('deadline exceeded') >= 0) {
    return 'timeout';
  }
  // Native/core errors can contain a private node endpoint or the complete probe URL.
  // Only return stable categories to UI/log callers.
  return 'ping-failed';
}

// 在 TaskPool worker 线程上执行 native 延迟测试。pingNativeOutbound 是同步 cgo
// （建临时 Xray + ping），放到 worker 跑避免阻塞 UI 线程。cgo 在 worker 线程上由
// OHOS Go fork 的 TLSDESC 保证安全。必须是顶层 @Concurrent 函数（无闭包捕获）。
// socksPort 由调用方分配：并发测速时每个"槽"用固定且互不相同的端口，槽内顺序处理，
// 因此并发的 ping 不会撞端口，也无需 getNativeFreePorts（旧 .so 未导出该符号）。
@Concurrent
function runNativeDelayTest(outboundJson: string, datDir: string, url: string, timeoutSeconds: number, configType: string, socksPort: number): NativePingResult {
  const effectiveType: XrayConfigType | undefined = configType.length > 0 ? (configType as XrayConfigType) : undefined;
  let configJson = '';
  try {
    configJson = buildDelayTestConfig(outboundJson, socksPort, effectiveType).configJson;
  } catch (error) {
    return { ok: false, delayMs: -1, message: 'invalid-config' };
  }
  const proxy = `socks5://${DEFAULT_SOCKS_HOST}:${socksPort}`;
  return pingNativeOutbound(configJson, datDir, url, timeoutSeconds, proxy);
}

export class DelayTester {
  static async measureTcp(address: string, port: number, timeoutMs: number = 8000): Promise<DelayTestResult> {
    const target = address.trim();
    if (target.length === 0 || port <= 0 || port > 65535) {
      return {
        ok: false,
        delayMs: -1,
        status: 'invalid-endpoint'
      };
    }

    const startedAt = Date.now();
    const tcp = socket.constructTCPSocketInstance();
    try {
      await tcp.connect({
        address: {
          address: target,
          port
        },
        timeout: timeoutMs
      });
      return {
        ok: true,
        delayMs: Math.max(0, Date.now() - startedAt),
        status: 'tcp'
      };
    } catch (_error) {
      return {
        ok: false,
        delayMs: -1,
        // 系统 socket 错误可能包含节点地址；对 UI/日志只返回稳定错误码。
        status: 'tcp-failed'
      };
    } finally {
      try {
        await tcp.close();
      } catch (_) {
      }
    }
  }

  // socksPort：本次测速用的本地 socks 端口。并发测速时由调用方给每个并发槽分配一个
  // 固定且互不相同的端口（见 Index 的流式测速池），避免并发 ping 撞端口/撞配置文件。
  // 单点测速不传则用默认端口。
  private static singboxOnlyTcpTarget(outboundJson: string): DelayTcpTarget | null {
    let parsed: DelayProbeOutbound;
    try {
      parsed = JSON.parse(outboundJson) as DelayProbeOutbound;
    } catch (_error) {
      return null;
    }
    if (!isSingboxOnlyProtocol(parsed.protocol)) {
      return null;
    }
    const settings = parsed.settings;
    if (settings === undefined || settings.servers === undefined || settings.servers.length === 0) {
      return null;
    }
    const first = settings.servers[0];
    const address = first.address ?? '';
    const port = first.port ?? 0;
    if (address.length === 0 || port <= 0) {
      return null;
    }
    return { address, port };
  }

  // 未配置探测地址时用的通用目标提取：取 outbound 的第一台服务器（vnext 或 servers）。
  private static outboundTcpTarget(outboundJson: string): DelayTcpTarget | null {
    let parsed: DelayProbeOutbound;
    try {
      parsed = JSON.parse(outboundJson) as DelayProbeOutbound;
    } catch (_error) {
      return null;
    }
    const settings = parsed.settings;
    if (settings === undefined) {
      return null;
    }
    const hosts = settings.vnext !== undefined && settings.vnext.length > 0 ? settings.vnext : settings.servers;
    if (hosts === undefined || hosts.length === 0) {
      return null;
    }
    const first = hosts[0];
    const address = first.address ?? '';
    const port = first.port ?? 0;
    if (address.length === 0 || port <= 0) {
      return null;
    }
    return { address, port };
  }

  static async measureNodeOutbound(outboundJson: string, datDir: string, url: string, timeoutMs: number = 8000, configType?: XrayConfigType, socksPort: number = DELAY_TEST_SOCKS_PORT): Promise<DelayTestResult> {
    // 用户未填探测地址时，测到服务器的 TCP 握手时延，不向任何第三方端点发请求。
    if (url.trim().length === 0) {
      const target = DelayTester.outboundTcpTarget(outboundJson);
      if (target === null) {
        return { ok: false, delayMs: -1, status: 'no-test-url' };
      }
      return DelayTester.measureTcp(target.address, target.port, timeoutMs);
    }
    // anytls / tuic / hysteria2 等 sing-box 独有协议 Xray 核心没有对应 outbound，
    // native 测速（建临时 Xray + ping）必然失败。先尝试到节点服务器的 TCP 握手：
    // 少数把伪装站点开在同端口的服务器能借此测出 RTT；但 hysteria2/tuic 走 QUIC/UDP，
    // 端口通常只监听 UDP，TCP 握手会失败。此时不误报为"失败"（节点实际能用），
    // 而是返回中性状态 DELAY_STATUS_UDP_ONLY，由 UI 显示中性文案。
    const singboxTarget = DelayTester.singboxOnlyTcpTarget(outboundJson);
    if (singboxTarget !== null) {
      const tcpResult = await DelayTester.measureTcp(singboxTarget.address, singboxTarget.port, timeoutMs);
      if (tcpResult.ok) {
        return tcpResult;
      }
      return { ok: false, delayMs: -1, status: DELAY_STATUS_UDP_ONLY };
    }
    // EntryAbility 必须先完成中断 Geo 事务恢复并设置 XRAY_LOCATION_ASSET。失败时
    // 不把临时核心投递到 worker，否则可能让 Go runtime 读取半套或错误目录的数据。
    if (!nativeXrayAssetReadiness().ready) {
      return { ok: false, delayMs: -1, status: 'core-unavailable' };
    }
    const timeoutSeconds = Math.max(1, Math.floor(timeoutMs / 1000));
    let result: NativePingResult;
    try {
      // native cgo（建临时 Xray + ping）放到 TaskPool worker 线程跑，避免阻塞 UI。
      result = await taskpool.execute(
        runNativeDelayTest, outboundJson, datDir, url, timeoutSeconds, configType ?? '', socksPort
      ) as NativePingResult;
    } catch (_error) {
      return {
        ok: false,
        delayMs: -1,
        status: 'native-probe-failed'
      };
    }

    if (result.ok && result.delayMs >= 0) {
      return {
        ok: true,
        delayMs: result.delayMs,
        status: 'ok'
      };
    }
    return {
      ok: false,
      delayMs: -1,
      // Never replace a failed node-through-core probe with a direct HTTP result. That would
      // present physical-network latency as node latency and could hide an unavailable core.
      status: nativeDelayFailureStatus(result.message)
    };
  }
}
