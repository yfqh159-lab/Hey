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
    if (!looksLikeIpLiteral(ip)) {
      return failedRemoteIpInfo(ip.length === 0 ? 'missing-ip' : 'invalid-ip');
    }
    return { ok: true, summary: ip, status: 'ok' };
  } catch (error) {
    return failedRemoteIpInfo(`parse-failed: ${JSON.stringify(error)}`);
  }
}

function looksLikeIpLiteral(value: string): boolean {
  if (value.length < 2 || value.length > 64 || !/^[0-9a-fA-F:.]+$/.test(value)) {
    return false;
  }
  if (value.indexOf(':') >= 0) {
    return isValidIpv6Literal(value);
  }
  return isValidIpv4Literal(value);
}

function isValidIpv4Literal(value: string): boolean {
  const parts = value.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let index = 0; index < parts.length; index++) {
    const part = parts[index];
    if (part.length === 0 || part.length > 3 || !/^\d+$/.test(part)) {
      return false;
    }
    const numberValue = Number(part);
    if (numberValue < 0 || numberValue > 255) {
      return false;
    }
  }
  return true;
}

function isValidIpv6Literal(value: string): boolean {
  const compressionIndex = value.indexOf('::');
  const hasCompression = compressionIndex >= 0;
  let segments = new Array<string>();
  if (hasCompression) {
    const leftText = value.substring(0, compressionIndex);
    const rightText = value.substring(compressionIndex + 2);
    const left = leftText.length === 0 ? [] : leftText.split(':');
    const right = rightText.length === 0 ? [] : rightText.split(':');
    // `:::` 或第二个压缩标记会在任一侧留下空段。
    if (left.some((segment: string): boolean => segment.length === 0) ||
      right.some((segment: string): boolean => segment.length === 0)) {
      return false;
    }
    segments = left.concat(right);
  } else {
    segments = value.split(':');
    if (segments.some((segment: string): boolean => segment.length === 0)) {
      return false;
    }
  }

  let units = 0;
  for (let index = 0; index < segments.length; index++) {
    const segment = segments[index];
    if (segment.indexOf('.') >= 0) {
      // IPv4 映射形式只允许把最后 32 位写成点分十进制。
      if (index !== segments.length - 1 || !value.endsWith(segment) || !isValidIpv4Literal(segment)) {
        return false;
      }
      units += 2;
      continue;
    }
    if (!/^[0-9a-fA-F]{1,4}$/.test(segment)) {
      return false;
    }
    units++;
  }
  // `::` 必须实际压缩至少一个 16-bit 单元；无压缩时恰好需要八个单元。
  return hasCompression ? units < 8 : units === 8;
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
