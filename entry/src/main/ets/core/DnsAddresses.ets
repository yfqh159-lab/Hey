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
  return address.startsWith('https') || address.startsWith('tcp') || address.startsWith('quic') || address === 'localhost';
}

// 只返回用户填写的 DNS 地址。未填写时返回空列表——不回落到任何内置服务商，
// 由调用方决定省略该组 server（核心随即使用系统 DNS）。
export function normalizeDnsServers(value: string | undefined, fallback: string, allowCoreDns: boolean = true): Array<string> {
  const source = value === undefined ? fallback : value;
  return filterDnsServers(source, allowCoreDns);
}

export function normalizeVpnDnsServers(value?: string, fallback: string = DNS_VPN): Array<string> {
  if (value === undefined || value.trim().length === 0) {
    return [stripIpAddressBrackets(fallback.trim())];
  }
  const filtered = filterDnsServers(value, false);
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

function filterDnsServers(value: string, allowCoreDns: boolean): Array<string> {
  const result = new Array<string>();
  const parts = value.split(',');
  for (let index = 0; index < parts.length; index++) {
    const address = parts[index].trim();
    if (address.length === 0 || result.indexOf(address) >= 0) {
      continue;
    }
    if (isPureIpAddress(address) || (allowCoreDns && isCoreDnsAddress(address))) {
      result.push(address);
    }
  }
  return result;
}

function stripIpAddressBrackets(value: string): string {
  if (value.startsWith('[') && value.endsWith(']')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
