// 提供经代理访问的默认远程解析器。使用 IP 形式避免 DoH 主机名自举时先调用系统 DNS；
// Xray 内置 DNS 产生的 HTTPS 查询再由 dns tag 路由到代理出站。
export const DNS_PROXY: string = 'https://1.1.1.1/dns-query';
export const DNS_DIRECT: string = '223.5.5.5';
// 仅作为 VPN 接口的虚拟 DNS 目的地址，UDP/TCP 53 会在核心配置中被劫持到 dns-out；
// 不是公共 DNS 服务商。createDefaultVpnConfig 会按用户选择的 TUN 网段传入对应 router。
export const DNS_VPN: string = '10.10.14.2';

const IPV4_REGEX: RegExp =
  /^([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])$/;
const IPV6_REGEX: RegExp =
  /^(((?:[0-9A-Fa-f]{1,4}))?((?::[0-9A-Fa-f]{1,4}))*::((?:[0-9A-Fa-f]{1,4}))?((?::[0-9A-Fa-f]{1,4}))*|((?:[0-9A-Fa-f]{1,4}))((?::[0-9A-Fa-f]{1,4})){7})$/;

export function isPureIpAddress(value: string): boolean {
  const address = value.trim();
  if (address.length === 0) {
    return false;
  }
  return IPV4_REGEX.test(address) || IPV6_REGEX.test(stripIpAddressBrackets(address));
}

export function isCoreDnsAddress(value: string): boolean {
  const address = value.trim();
  if (address === 'localhost') {
    return true;
  }
  const lower = address.toLowerCase();
  const schemes: Array<string> = [
    'https://',
    'https+local://',
    'h2c://',
    'tcp://',
    'tcp+local://',
    'quic://',
    'quic+local://'
  ];
  for (let index = 0; index < schemes.length; index++) {
    const scheme = schemes[index];
    if (lower.startsWith(scheme)) {
      return hasCoreDnsTarget(address.substring(scheme.length));
    }
  }
  return false;
}

// Xray 的 local DNS 模式和 localhost 不进入路由系统，会直接使用本机网络。
// 可用于用户明确配置的直连域名，但不得混入“远程 DNS”后造成物理出口泄漏。
export function isLocalCoreDnsAddress(value: string): boolean {
  const lower = value.trim().toLowerCase();
  return lower === 'localhost' || lower.startsWith('https+local://') ||
    lower.startsWith('tcp+local://') || lower.startsWith('quic+local://');
}

// 只返回用户填写的 DNS 地址。未填写时返回空列表——不回落到任何内置服务商，
// 由调用方决定省略该组 server（核心随即使用系统 DNS）。
export function normalizeDnsServers(
  value: string | undefined,
  fallback: string,
  allowCoreDns: boolean = true,
  allowLocalCoreDns: boolean = true
): Array<string> {
  const source = value === undefined ? fallback : value;
  return filterDnsServers(source, allowCoreDns, allowLocalCoreDns);
}

export function normalizeRemoteDnsValue(value: string | undefined, fallback: string = DNS_PROXY): string {
  const trimmed = value?.trim() ?? '';
  const normalized = normalizeDnsServers(
    trimmed.length > 0 ? trimmed : undefined, fallback, true, false);
  return normalized.length > 0 ? normalized.join(',') : fallback;
}

export function normalizeOptionalDnsValue(
  value: string | undefined,
  allowCoreDns: boolean,
  allowLocalCoreDns: boolean = true
): string {
  const trimmed = value?.trim() ?? '';
  if (trimmed.length === 0) {
    return '';
  }
  return normalizeDnsServers(trimmed, '', allowCoreDns, allowLocalCoreDns).join(',');
}

export function normalizeVpnDnsServers(value?: string, fallback: string = DNS_VPN): Array<string> {
  if (value === undefined || value.trim().length === 0) {
    return [stripIpAddressBrackets(fallback.trim())];
  }
  const filtered = filterDnsServers(value, false, false);
  const result = new Array<string>();
  for (let index = 0; index < filtered.length; index++) {
    // 方括号只属于 URL authority 语法；VpnConfig.dnsAddresses 接收的是裸网络地址。
    const address = stripIpAddressBrackets(filtered[index]);
    if (result.indexOf(address) < 0) {
      result.push(address);
    }
  }
  return result.length > 0 ? result : [stripIpAddressBrackets(fallback.trim())];
}

function filterDnsServers(value: string, allowCoreDns: boolean, allowLocalCoreDns: boolean): Array<string> {
  const result = new Array<string>();
  const parts = value.split(',');
  for (let index = 0; index < parts.length; index++) {
    const address = parts[index].trim();
    if (address.length === 0 || result.indexOf(address) >= 0) {
      continue;
    }
    const coreDnsAllowed = allowCoreDns &&
      (isDnsIpWithPort(address) || (isCoreDnsAddress(address) &&
        (allowLocalCoreDns || !isLocalCoreDnsAddress(address))));
    if (isPureIpAddress(address) || coreDnsAllowed) {
      result.push(address);
    }
  }
  return result;
}

function isDnsIpWithPort(value: string): boolean {
  const address = value.trim();
  if (address.startsWith('[')) {
    const close = address.indexOf(']');
    if (close <= 1 || close + 2 >= address.length || address.charAt(close + 1) !== ':') {
      return false;
    }
    return isPureIpAddress(address.substring(0, close + 1)) && isValidPort(address.substring(close + 2));
  }
  const colon = address.lastIndexOf(':');
  if (colon <= 0 || address.indexOf(':') !== colon) {
    return false;
  }
  return IPV4_REGEX.test(address.substring(0, colon)) && isValidPort(address.substring(colon + 1));
}

function isValidPort(value: string): boolean {
  if (!/^\d{1,5}$/.test(value)) {
    return false;
  }
  const port = Number(value);
  return port > 0 && port <= 65535;
}

function hasCoreDnsTarget(value: string): boolean {
  if (value.length === 0 || /\s/.test(value)) {
    return false;
  }
  const slash = value.indexOf('/');
  const authority = slash < 0 ? value : value.substring(0, slash);
  return authority.length > 0 && authority !== ':' && !authority.startsWith(':');
}

function stripIpAddressBrackets(value: string): string {
  if (value.startsWith('[') && value.endsWith(']')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
