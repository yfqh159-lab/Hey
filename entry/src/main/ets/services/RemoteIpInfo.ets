import { http } from '@kit.NetworkKit';
import { APP_HTTP_USER_AGENT } from '../core/HttpDefaults';
import { LOCAL_HTTP_PROXY_HOST } from '../core/XrayConfig';

interface RemoteIpPayload {
  ip?: string;
  clientIp?: string;
  ip_addr?: string;
  query?: string;
}

export interface RemoteIpInfoResult {
  ok: boolean;
  summary: string;
  status: string;
}

export async function fetchRemoteIpInfo(ipApiUrl: string, proxyPort: number, timeoutMs: number = 5000): Promise<RemoteIpInfoResult> {
  const target = normalizeIpApiUrl(ipApiUrl);
  if (target.length === 0) {
    return failedRemoteIpInfo('invalid-url');
  }
  if (!shouldUseHttpProxy(proxyPort)) {
    return failedRemoteIpInfo('proxy-unavailable');
  }

  const request = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      readTimeout: timeoutMs,
      connectTimeout: timeoutMs,
      usingCache: false,
      header: {
        'User-Agent': APP_HTTP_USER_AGENT,
        'Accept': 'application/json, text/plain, */*',
        'Cache-Control': 'no-cache'
      },
      usingProxy: {
        host: LOCAL_HTTP_PROXY_HOST,
        port: proxyPort,
        exclusionList: []
      }
    };
    const response = await request.request(target, options);
    const responseCode = Number(response.responseCode);
    if (responseCode < 200 || responseCode >= 300) {
      return failedRemoteIpInfo(`HTTP ${response.responseCode}`);
    }
    return parseRemoteIpInfoContent(responseBodyText(response.result));
  } catch (_error) {
    // 系统异常文本可能回显自定义 URL（其中可能含私密查询参数），日志只保留稳定错误码。
    return failedRemoteIpInfo('request-failed');
  } finally {
    request.destroy();
  }
}

export function parseRemoteIpInfoContent(content: string): RemoteIpInfoResult {
  if (content.length > 4096) {
    return failedRemoteIpInfo('response-too-large');
  }
  try {
    const payload = JSON.parse(content) as RemoteIpPayload;
    const ip = firstNonEmpty([
      payload.ip,
      payload.clientIp,
      payload.ip_addr,
      payload.query
    ]);
    // 只回报出口 IP，不解析也不展示地理归属。
    if (!looksLikePublicIpLiteral(ip)) {
      return failedRemoteIpInfo(ip.length === 0 ? 'missing-ip' : 'invalid-ip');
    }
    return { ok: true, summary: ip, status: 'ok' };
  } catch (error) {
    return failedRemoteIpInfo(`parse-failed: ${JSON.stringify(error)}`);
  }
}

function looksLikePublicIpLiteral(value: string): boolean {
  if (value.length < 2 || value.length > 64 || !/^[0-9a-fA-F:.]+$/.test(value)) {
    return false;
  }
  if (value.indexOf(':') >= 0) {
    return isPublicIpv6Literal(value);
  }
  const octets = parseIpv4Octets(value);
  return octets !== null && isPublicIpv4Octets(octets);
}

function parseIpv4Octets(value: string): Array<number> | null {
  const parts = value.split('.');
  if (parts.length !== 4) {
    return null;
  }
  const octets = new Array<number>();
  for (let index = 0; index < parts.length; index++) {
    const part = parts[index];
    if (part.length === 0 || part.length > 3 || !/^\d+$/.test(part)) {
      return null;
    }
    const numberValue = Number(part);
    if (numberValue < 0 || numberValue > 255) {
      return null;
    }
    octets.push(numberValue);
  }
  return octets;
}

function isPublicIpv4Octets(octets: Array<number>): boolean {
  const first = octets[0];
  const second = octets[1];
  const third = octets[2];
  if (first === 0 || first === 10 || first === 127 || first >= 224) {
    return false;
  }
  if (first === 100 && second >= 64 && second <= 127) {
    return false; // shared carrier-grade NAT space
  }
  if (first === 169 && second === 254) {
    return false;
  }
  if (first === 172 && second >= 16 && second <= 31) {
    return false;
  }
  if (first === 192 && (second === 168 ||
    (second === 0 && (third === 0 || third === 2)) ||
    (second === 88 && third === 99))) {
    return false;
  }
  if (first === 198 && (second === 18 || second === 19 || second === 51 && third === 100)) {
    return false;
  }
  if (first === 203 && second === 0 && third === 113) {
    return false;
  }
  return true;
}

function isPublicIpv6Literal(value: string): boolean {
  const units = parseIpv6Units(value);
  if (units === null) {
    return false;
  }
  // IPv4-mapped/compatible text forms inherit the embedded IPv4 scope.
  const embeddedIpv4 = value.substring(value.lastIndexOf(':') + 1);
  const isIpv4Compatible = units[0] === 0 && units[1] === 0 && units[2] === 0 &&
    units[3] === 0 && units[4] === 0 && (units[5] === 0 || units[5] === 0xffff);
  if (embeddedIpv4.indexOf('.') >= 0 && isIpv4Compatible) {
    const octets = parseIpv4Octets(embeddedIpv4);
    return octets !== null && isPublicIpv4Octets(octets);
  }
  // Public exit addresses should be globally routable unicast. Exclude ULA,
  // link-local, multicast, unspecified/loopback and documentation space by
  // accepting the currently allocated 2000::/3 global range minus 2001:db8::/32.
  if ((units[0] & 0xe000) !== 0x2000) {
    return false;
  }
  return !(units[0] === 0x2001 && units[1] === 0x0db8);
}

function parseIpv6Units(value: string): Array<number> | null {
  const compressionIndex = value.indexOf('::');
  const hasCompression = compressionIndex >= 0;
  let segments = new Array<string>();
  let leftSegmentCount = 0;
  if (hasCompression) {
    const leftText = value.substring(0, compressionIndex);
    const rightText = value.substring(compressionIndex + 2);
    const left = leftText.length === 0 ? [] : leftText.split(':');
    const right = rightText.length === 0 ? [] : rightText.split(':');
    // `:::` 或第二个压缩标记会在任一侧留下空段。
    if (left.some((segment: string): boolean => segment.length === 0) ||
      right.some((segment: string): boolean => segment.length === 0)) {
      return null;
    }
    segments = left.concat(right);
    leftSegmentCount = left.length;
  } else {
    segments = value.split(':');
    if (segments.some((segment: string): boolean => segment.length === 0)) {
      return null;
    }
    leftSegmentCount = segments.length;
  }

  const parsed = new Array<number>();
  let leftUnits = 0;
  for (let index = 0; index < segments.length; index++) {
    const segment = segments[index];
    if (segment.indexOf('.') >= 0) {
      // IPv4 映射形式只允许把最后 32 位写成点分十进制。
      const octets = parseIpv4Octets(segment);
      if (index !== segments.length - 1 || !value.endsWith(segment) || octets === null) {
        return null;
      }
      parsed.push((octets[0] << 8) | octets[1]);
      parsed.push((octets[2] << 8) | octets[3]);
    } else {
      if (!/^[0-9a-fA-F]{1,4}$/.test(segment)) {
        return null;
      }
      parsed.push(Number.parseInt(segment, 16));
    }
    if (index < leftSegmentCount) {
      leftUnits = parsed.length;
    }
  }
  // `::` 必须实际压缩至少一个 16-bit 单元；无压缩时恰好需要八个单元。
  if (!hasCompression) {
    return parsed.length === 8 ? parsed : null;
  }
  const missingUnits = 8 - parsed.length;
  if (missingUnits <= 0) {
    return null;
  }
  const expanded = parsed.slice(0, leftUnits);
  for (let index = 0; index < missingUnits; index++) {
    expanded.push(0);
  }
  return expanded.concat(parsed.slice(leftUnits));
}

// 未填写地址时返回空串，调用方据此跳过请求；高级设置仍允许替换或关闭默认服务。
export function normalizeIpApiUrl(ipApiUrl: string): string {
  const target = ipApiUrl.trim();
  if (target.startsWith('http://') || target.startsWith('https://')) {
    return target;
  }
  return '';
}

function responseBodyText(result: Object | string | ArrayBuffer): string {
  if (typeof result === 'string') {
    return result;
  }
  const text = JSON.stringify(result);
  return text === undefined ? '' : text;
}

function shouldUseHttpProxy(proxyPort: number): boolean {
  return proxyPort > 0 && Math.floor(proxyPort) === proxyPort && proxyPort <= 65535;
}

function firstNonEmpty(values: Array<string | undefined>): string {
  for (let index = 0; index < values.length; index++) {
    const value = values[index];
    if (value !== undefined && value.trim().length > 0) {
      return value.trim();
    }
  }
  return '';
}

function failedRemoteIpInfo(status: string): RemoteIpInfoResult {
  return {
    ok: false,
    summary: '',
    status
  };
}
