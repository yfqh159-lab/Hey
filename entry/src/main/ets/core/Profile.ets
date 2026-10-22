export const DEFAULT_PROFILE_ID: string = 'default-profile';

export type ResolvedAppLanguage = 'en' | 'zh-rCN' | 'zh-rTW' | 'vi' | 'ru' | 'fa' | 'ar' | 'bn' | 'bqi-rIR';
export type AppLanguage = 'auto' | ResolvedAppLanguage;
export const APP_LANGUAGE_AUTO: AppLanguage = 'auto';
export const APP_LANGUAGE_EN: ResolvedAppLanguage = 'en';
export const APP_LANGUAGE_ZH_CN: ResolvedAppLanguage = 'zh-rCN';
export const APP_LANGUAGE_ZH_TW: ResolvedAppLanguage = 'zh-rTW';
export const LANGUAGE_OPTIONS: AppLanguage[] = [
  APP_LANGUAGE_AUTO,
  APP_LANGUAGE_EN,
  APP_LANGUAGE_ZH_CN,
  APP_LANGUAGE_ZH_TW,
  'vi',
  'ru',
  'fa',
  'ar',
  'bn',
  'bqi-rIR'
];

export type XrayConfigType = 'outbound' | 'full' | 'proxy-chain' | 'policy-group';

export interface ProxyProfile {
  id: string;
  name: string;
  outboundJson: string;
  configType?: XrayConfigType;
  updatedAt: number;
}

export interface ProxyNode {
  id: string;
  name: string;
  protocol: string;
  outboundJson: string;
  configType?: XrayConfigType;
  sourceUrl: string;
  rawLink: string;
  updatedAt: number;
  delayMs: number;
  delayTestAt: number;
  delayStatus: string;
}

export interface SubscriptionGroup {
  id: string;
  name: string;
  url: string;
  enabled: boolean;
  selectedNodeId: string;
  nodes: Array<ProxyNode>;
  updatedAt: number;
  userAgent?: string;
  filter?: string;
  prevProfile?: string;
  nextProfile?: string;
  allowInsecureUrl?: boolean;
  autoUpdate?: boolean;
  updateIntervalMinutes?: number;
}

export interface SubscriptionProfile {
  url: string;
  selectedNodeId: string;
  nodes: Array<ProxyNode>;
  updatedAt: number;
  selectedGroupId: string;
  groups: Array<SubscriptionGroup>;
}

export interface ValidationResult {
  valid: boolean;
  message: string;
  protocol: string;
  normalizedJson: string;
  configType?: XrayConfigType;
}

export interface GeneratedXrayConfig {
  configJson: string;
  socksHost?: string;
  socksPort?: number;
  httpProxyHost?: string;
  httpProxyPort?: number;
  metricsServer?: string;
  runtimeHealthPort?: number;
  vpnDataPlaneCompatible?: boolean;
}

export interface RoutingRule {
  id: string;
  remarks: string;
  domain: string[];
  ip: string[];
  process: string[];
  outboundTag: string;
  port: string;
  network: string;
  protocol: string[];
  enabled: boolean;
  locked: boolean;
}

export interface VpnInterfaceAddressConfig {
  displayName: string;
  ipv4Client: string;
  ipv4Router: string;
  ipv6Client: string;
  ipv6Router: string;
}

// TUN 的 IPv6 客户端地址必须用「全局单播 scope」的段(这里用 RFC 3849 文档段 2001:db8::/32,
// 不会在公网路由、不撞真实主机)。若用 ULA(fc00::/7),按 RFC 6724 源地址选择,访问全局 v6
// 目标(2000::/3)时系统会优先挑物理网卡的全局源地址 → v6 绕过 TUN 从物理口直出 → 泄漏(测速
// 显示本地运营商)。改成全局段后,源地址 label 与目标匹配,全局 v6 才会真正走 TUN。
export const VPN_INTERFACE_ADDRESS_CONFIGS: Array<VpnInterfaceAddressConfig> = [
  { displayName: '10.10.14.x', ipv4Client: '10.10.14.1', ipv4Router: '10.10.14.2', ipv6Client: '2001:db8::10:10:14:1', ipv6Router: '2001:db8::10:10:14:2' },
  { displayName: '10.1.0.x', ipv4Client: '10.1.0.1', ipv4Router: '10.1.0.2', ipv6Client: '2001:db8::10:1:0:1', ipv6Router: '2001:db8::10:1:0:2' },
  { displayName: '10.0.0.x', ipv4Client: '10.0.0.1', ipv4Router: '10.0.0.2', ipv6Client: '2001:db8::10:0:0:1', ipv6Router: '2001:db8::10:0:0:2' },
  { displayName: '172.31.0.x', ipv4Client: '172.31.0.1', ipv4Router: '172.31.0.2', ipv6Client: '2001:db8::172:31:0:1', ipv6Router: '2001:db8::172:31:0:2' },
  { displayName: '172.20.0.x', ipv4Client: '172.20.0.1', ipv4Router: '172.20.0.2', ipv6Client: '2001:db8::172:20:0:1', ipv6Router: '2001:db8::172:20:0:2' },
  { displayName: '172.16.0.x', ipv4Client: '172.16.0.1', ipv4Router: '172.16.0.2', ipv6Client: '2001:db8::172:16:0:1', ipv6Router: '2001:db8::172:16:0:2' },
  { displayName: '192.168.100.x', ipv4Client: '192.168.100.1', ipv4Router: '192.168.100.2', ipv6Client: '2001:db8::192:168:100:1', ipv6Router: '2001:db8::192:168:100:2' }
];

export const DEFAULT_VPN_INTERFACE_ADDRESS_INDEX: number = 0;
// 延迟探测端点默认留空，测速退化为到服务器的 TCP 握手时延。出口地址仅在代理已经
// 运行后通过本地回环 HTTP 代理查询；默认服务只返回公网 IP，不请求地理归属信息。
export const DEFAULT_DELAY_TEST_URL: string = '';
// sing-box 独有的 UDP/QUIC 协议无法由临时 Xray 出站验证；该状态表示“不可测”，
// 不是节点失败，批量清理不得据此删除节点。
export const DELAY_STATUS_UDP_ONLY: string = 'udp-only';
export const DELAY_STATUS_CORE_UNAVAILABLE: string = 'core-unavailable';
export const DELAY_STATUS_UNAVAILABLE: string = 'probe-unavailable';

export function isNeutralDelayStatus(status: string): boolean {
  return status === DELAY_STATUS_UDP_ONLY || status === DELAY_STATUS_CORE_UNAVAILABLE ||
    status === DELAY_STATUS_UNAVAILABLE;
}
export const DEFAULT_IP_API_URL: string = 'https://api.ipify.org?format=json';
export const VPN_BYPASS_LAN_FOLLOW_CONFIG: string = '0';
export const VPN_BYPASS_LAN_BYPASS: string = '1';
export const VPN_BYPASS_LAN_PROXY: string = '2';
export const DEFAULT_VPN_BYPASS_LAN: string = VPN_BYPASS_LAN_BYPASS;
export const DEFAULT_VPN_MTU: number = 1500;
export const MIN_VPN_MTU: number = 1280;
// 上限 1500 与 gvisor tun2socks 原生侧的硬性校验（napi_init.cpp 要求 mtu ≤ 1500）对齐。
// 此前为 9000，用户设 >1500 时 gvisor 引擎会因非法 MTU 拒绝启动、VPN 连上却不过流量。
export const MAX_VPN_MTU: number = 1500;
export const DEFAULT_REAL_PING_CONCURRENCY: number = 16;
export const MIN_REAL_PING_CONCURRENCY: number = 1;
export const MAX_REAL_PING_CONCURRENCY: number = 128;
// 首页「当前连接」自动测速间隔（分钟）。0=不自动测速，仅连接时测一次；1–30=每隔 N 分钟复测。
export const DEFAULT_HOME_DELAY_TEST_INTERVAL: number = 0;
export const MIN_HOME_DELAY_TEST_INTERVAL: number = 0;
export const MAX_HOME_DELAY_TEST_INTERVAL: number = 30;
export type AppUiModeNight = '0' | '1' | '2';
export const UI_MODE_NIGHT_SYSTEM: AppUiModeNight = '0';
export const UI_MODE_NIGHT_LIGHT: AppUiModeNight = '1';
export const UI_MODE_NIGHT_DARK: AppUiModeNight = '2';
export type AppRuntimeMode = 'VPN' | 'Proxy only';
export type HevTunLogLevel = 'error' | 'warn' | 'info' | 'debug';
export const APP_MODE_VPN: AppRuntimeMode = 'VPN';
export const APP_MODE_PROXY_ONLY: AppRuntimeMode = 'Proxy only';

export const HEV_TUN_LOG_LEVEL_ERROR: HevTunLogLevel = 'error';
export const HEV_TUN_LOG_LEVEL_WARN: HevTunLogLevel = 'warn';
export const HEV_TUN_LOG_LEVEL_INFO: HevTunLogLevel = 'info';
export const HEV_TUN_LOG_LEVEL_DEBUG: HevTunLogLevel = 'debug';
export const DEFAULT_HEV_TUN_LOG_LEVEL: HevTunLogLevel = HEV_TUN_LOG_LEVEL_WARN;
export const DEFAULT_HEV_TUN_RW_TIMEOUT: string = '300,60';
export const HEV_TUN_LOG_LEVEL_OPTIONS: Array<HevTunLogLevel> = [
  HEV_TUN_LOG_LEVEL_ERROR,
  HEV_TUN_LOG_LEVEL_WARN,
  HEV_TUN_LOG_LEVEL_INFO,
  HEV_TUN_LOG_LEVEL_DEBUG
];
export type OutboundDomainResolveMethod = '0' | '1' | '2';
export const OUTBOUND_DOMAIN_RESOLVE_NONE: OutboundDomainResolveMethod = '0';
export const OUTBOUND_DOMAIN_RESOLVE_DNS_HOSTS: OutboundDomainResolveMethod = '1';
export const OUTBOUND_DOMAIN_RESOLVE_REPLACE: OutboundDomainResolveMethod = '2';
export const ROUTING_DOMAIN_STRATEGY_AS_IS: string = 'AsIs';
export const ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH: string = 'IPIfNonMatch';
export const ROUTING_DOMAIN_STRATEGY_IP_ON_DEMAND: string = 'IPOnDemand';

export function normalizeVpnInterfaceAddressIndex(value: number | undefined, fallback: number = DEFAULT_VPN_INTERFACE_ADDRESS_INDEX): number {
  const safeFallback = fallback >= 0 && fallback < VPN_INTERFACE_ADDRESS_CONFIGS.length ? fallback : DEFAULT_VPN_INTERFACE_ADDRESS_INDEX;
  if (value === undefined || Number.isNaN(value)) {
    return safeFallback;
  }
  const index = Math.floor(value);
  if (index < 0 || index >= VPN_INTERFACE_ADDRESS_CONFIGS.length) {
    return safeFallback;
  }
  return index;
}

export function resolveVpnInterfaceAddressConfig(index?: number): VpnInterfaceAddressConfig {
  return VPN_INTERFACE_ADDRESS_CONFIGS[normalizeVpnInterfaceAddressIndex(index)];
}

export function normalizeVpnBypassLanMode(value: string | undefined, fallback: string = DEFAULT_VPN_BYPASS_LAN): string {
  if (value === VPN_BYPASS_LAN_FOLLOW_CONFIG || value === VPN_BYPASS_LAN_BYPASS || value === VPN_BYPASS_LAN_PROXY) {
    return value;
  }
  return fallback === VPN_BYPASS_LAN_FOLLOW_CONFIG || fallback === VPN_BYPASS_LAN_PROXY ? fallback : DEFAULT_VPN_BYPASS_LAN;
}


export function normalizeVpnMtuValue(value: number | undefined, fallback: number = DEFAULT_VPN_MTU): number {
  if (value === undefined || Number.isNaN(value)) {
    return fallback;
  }
  const mtu = Math.floor(value);
  if (mtu < MIN_VPN_MTU) {
    return MIN_VPN_MTU;
  }
  if (mtu > MAX_VPN_MTU) {
    return MAX_VPN_MTU;
  }
  return mtu;
}

export function normalizeRealPingConcurrency(value: number | undefined, fallback: number = DEFAULT_REAL_PING_CONCURRENCY): number {
  const safeFallback = normalizeRealPingConcurrencyFallback(fallback);
  if (value === undefined || Number.isNaN(value)) {
    return safeFallback;
  }
  const concurrency = Math.floor(value);
  if (concurrency < MIN_REAL_PING_CONCURRENCY) {
    return MIN_REAL_PING_CONCURRENCY;
  }
  if (concurrency > MAX_REAL_PING_CONCURRENCY) {
    return MAX_REAL_PING_CONCURRENCY;
  }
  return concurrency;
}

export function normalizeHomeDelayTestInterval(value: number | undefined, fallback: number = DEFAULT_HOME_DELAY_TEST_INTERVAL): number {
  const safeFallback = normalizeHomeDelayTestIntervalFallback(fallback);
  if (value === undefined || Number.isNaN(value)) {
    return safeFallback;
  }
  const minutes = Math.floor(value);
  if (minutes < MIN_HOME_DELAY_TEST_INTERVAL) {
    return MIN_HOME_DELAY_TEST_INTERVAL;
  }
  if (minutes > MAX_HOME_DELAY_TEST_INTERVAL) {
    return MAX_HOME_DELAY_TEST_INTERVAL;
  }
  return minutes;
}

export function resolveDelayTestUrl(value: string | undefined, fallback: string = DEFAULT_DELAY_TEST_URL): string {
  const url = (value ?? '').trim();
  return url.length > 0 ? url : fallback;
}

export function normalizeUiModeNight(value: string | undefined, fallback: AppUiModeNight = UI_MODE_NIGHT_SYSTEM): AppUiModeNight {
  if (value === UI_MODE_NIGHT_LIGHT || value === UI_MODE_NIGHT_DARK || value === UI_MODE_NIGHT_SYSTEM) {
    return value;
  }
  return fallback === UI_MODE_NIGHT_LIGHT || fallback === UI_MODE_NIGHT_DARK ? fallback : UI_MODE_NIGHT_SYSTEM;
}

export function normalizeAppRuntimeMode(value: string | undefined, fallback: AppRuntimeMode = APP_MODE_VPN): AppRuntimeMode {
  if (value === APP_MODE_VPN || value === APP_MODE_PROXY_ONLY) {
    return value;
  }
  return fallback === APP_MODE_PROXY_ONLY ? APP_MODE_PROXY_ONLY : APP_MODE_VPN;
}

export function normalizeHevTunLogLevel(
  value: string | undefined,
  fallback: HevTunLogLevel = DEFAULT_HEV_TUN_LOG_LEVEL
): HevTunLogLevel {
  switch (value) {
    case HEV_TUN_LOG_LEVEL_ERROR:
    case HEV_TUN_LOG_LEVEL_WARN:
    case HEV_TUN_LOG_LEVEL_INFO:
    case HEV_TUN_LOG_LEVEL_DEBUG:
      return value;
    default:
      return fallback;
  }
}

export function normalizeHevTunRwTimeout(
  value: string | undefined,
  fallback: string = DEFAULT_HEV_TUN_RW_TIMEOUT
): string {
  const text = (value ?? '').trim();
  if (text.length === 0) {
    return fallback;
  }
  const parts = text.split(',');
  if (parts.length !== 2) {
    return fallback;
  }
  const tcpTimeout = Number(parts[0].trim());
  const udpTimeout = Number(parts[1].trim());
  if (!Number.isInteger(tcpTimeout) || !Number.isInteger(udpTimeout) || tcpTimeout <= 0 || udpTimeout <= 0) {
    return fallback;
  }
  return `${tcpTimeout},${udpTimeout}`;
}

export function normalizeOutboundDomainResolveMethod(
  value: string | undefined,
  fallback: OutboundDomainResolveMethod = OUTBOUND_DOMAIN_RESOLVE_DNS_HOSTS
): OutboundDomainResolveMethod {
  if (value === OUTBOUND_DOMAIN_RESOLVE_NONE || value === OUTBOUND_DOMAIN_RESOLVE_DNS_HOSTS || value === OUTBOUND_DOMAIN_RESOLVE_REPLACE) {
    return value;
  }
  return fallback;
}

export function normalizeRoutingDomainStrategy(value: string | undefined, fallback: string = ROUTING_DOMAIN_STRATEGY_AS_IS): string {
  if (value === ROUTING_DOMAIN_STRATEGY_AS_IS || value === ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH ||
    value === ROUTING_DOMAIN_STRATEGY_IP_ON_DEMAND) {
    return value;
  }
  if (fallback === ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH || fallback === ROUTING_DOMAIN_STRATEGY_IP_ON_DEMAND) {
    return fallback;
  }
  return ROUTING_DOMAIN_STRATEGY_AS_IS;
}

export function isVpnRuntimeMode(value: string | undefined): boolean {
  return normalizeAppRuntimeMode(value) === APP_MODE_VPN;
}

export function isProxyOnlyRuntimeMode(value: string | undefined): boolean {
  return normalizeAppRuntimeMode(value) === APP_MODE_PROXY_ONLY;
}

function normalizeRealPingConcurrencyFallback(value: number): number {
  if (Number.isNaN(value)) {
    return DEFAULT_REAL_PING_CONCURRENCY;
  }
  const concurrency = Math.floor(value);
  if (concurrency < MIN_REAL_PING_CONCURRENCY || concurrency > MAX_REAL_PING_CONCURRENCY) {
    return DEFAULT_REAL_PING_CONCURRENCY;
  }
  return concurrency;
}

function normalizeHomeDelayTestIntervalFallback(value: number): number {
  if (Number.isNaN(value)) {
    return DEFAULT_HOME_DELAY_TEST_INTERVAL;
  }
  const minutes = Math.floor(value);
  if (minutes < MIN_HOME_DELAY_TEST_INTERVAL || minutes > MAX_HOME_DELAY_TEST_INTERVAL) {
    return DEFAULT_HOME_DELAY_TEST_INTERVAL;
  }
  return minutes;
}

export interface AppSettings {
  language: AppLanguage;
  uiModeNight: AppUiModeNight;
  speedEnabled: boolean;
  confirmRemove: boolean;
  startScanImmediate: boolean;
  startOnBoot: boolean;
  groupAllDisplay: boolean;
  doubleColumnDisplay: boolean;
  sniffingEnabled: boolean;
  routeOnlyEnabled: boolean;
  perAppProxyEnabled: boolean;
  perAppProxyList: string[];
  perAppProxyBypass: boolean;
  localDnsEnabled: boolean;
  fakeDnsEnabled: boolean;
  appendHttpProxy: boolean;
  localSocksEnabled: boolean;
  localSocksPort: number;
  localSocksDynamicPort: boolean;
  localSocksUdpEnabled: boolean;
  localSocksUsername: string;
  localSocksPassword: string;
  useHevTun: boolean;
  hevTunLogLevel: HevTunLogLevel;
  hevTunRwTimeout: string;
  muxEnabled: boolean;
  muxConcurrency: number;
  muxXudpConcurrency: number;
  muxXudpQuic: string;
  fragmentEnabled: boolean;
  fragmentPackets: string;
  fragmentLength: string;
  fragmentInterval: string;
  ipv6Enabled: boolean;
  preferIpv6: boolean;
  proxySharingEnabled: boolean;
  allowInsecure: boolean;
  localDnsPort: number;
  vpnInterfaceAddressIndex: number;
  vpnBypassLan: string;
  vpnMtu: number;
  vpnDns: string;
  remoteDns: string;
  domesticDns: string;
  dnsHosts: string;
  delayTestUrl: string;
  ipApiUrl: string;
  realPingConcurrency: number;
  homeDelayTestInterval: number;
  logLevel: string;
  outboundDomainResolveMethod: OutboundDomainResolveMethod;
  mode: AppRuntimeMode;
  trafficMode: string;
  routingDomainStrategy: string;
  routingRules: Array<RoutingRule>;
  autoSortAfterTest: boolean;
  autoRemoveInvalidAfterTest: boolean;
  // 网络场景自动化（按 WiFi SSID / 蜂窝自动连断 VPN）
  netAutomationEnabled: boolean;                  // 总开关（接入可信网络时自动断开 VPN）
  netAutomationTrustedSsids: string[];            // 可信 WiFi SSID 列表
  netAutomationCellularTrusted: boolean;          // 蜂窝是否可信
}

export interface RuntimeStats {
  uploadBytes: number;
  downloadBytes: number;
  xrayRunning: boolean;
  tunRunning: boolean;
  lastMessage: string;
}

export enum ConnectionStatus {
  IDLE = 'idle',
  STARTING = 'starting',
  RUNNING = 'running',
  STOPPING = 'stopping',
  ERROR = 'error'
}
