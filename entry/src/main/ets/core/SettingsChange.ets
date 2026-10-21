import { AppSettings } from './Profile';

export const RUNTIME_SETTINGS_RESTART_PENDING_KEY: string = 'pendingRuntimeSettingsRestart';

export interface RuntimeSettingsRestartDecision {
  shouldRestart: boolean;
  keepPending: boolean;
}

export function decideRuntimeSettingsRestart(pending: boolean, running: boolean, busy: boolean): RuntimeSettingsRestartDecision {
  if (!pending) {
    return {
      shouldRestart: false,
      keepPending: false
    };
  }
  if (busy) {
    return {
      shouldRestart: false,
      keepPending: true
    };
  }
  if (!running) {
    return {
      shouldRestart: false,
      keepPending: false
    };
  }
  return {
    shouldRestart: true,
    keepPending: false
  };
}

/**
 * 只比较会进入核心配置、监听端口或系统 VPN 的字段。主题、语言、列表布局、扫码/删除确认、
 * 首页观测和可信网络自动化都能即时生效，不应仅因保存这些偏好而拆掉健康隧道。
 */
export function shouldRestartRuntimeForSettingsChange(previous: AppSettings, next: AppSettings): boolean {
  return runtimeSettingsSignature(previous) !== runtimeSettingsSignature(next);
}

function runtimeSettingsSignature(settings: AppSettings): string {
  return JSON.stringify({
    speedEnabled: settings.speedEnabled,
    sniffingEnabled: settings.sniffingEnabled,
    routeOnlyEnabled: settings.routeOnlyEnabled,
    perAppProxyEnabled: settings.perAppProxyEnabled,
    perAppProxyList: settings.perAppProxyList,
    perAppProxyBypass: settings.perAppProxyBypass,
    localDnsEnabled: settings.localDnsEnabled,
    fakeDnsEnabled: settings.fakeDnsEnabled,
    appendHttpProxy: settings.appendHttpProxy,
    localSocksEnabled: settings.localSocksEnabled,
    localSocksPort: settings.localSocksPort,
    localSocksDynamicPort: settings.localSocksDynamicPort,
    localSocksUdpEnabled: settings.localSocksUdpEnabled,
    localSocksUsername: settings.localSocksUsername,
    localSocksPassword: settings.localSocksPassword,
    useHevTun: settings.useHevTun,
    hevTunLogLevel: settings.hevTunLogLevel,
    hevTunRwTimeout: settings.hevTunRwTimeout,
    muxEnabled: settings.muxEnabled,
    muxConcurrency: settings.muxConcurrency,
    muxXudpConcurrency: settings.muxXudpConcurrency,
    muxXudpQuic: settings.muxXudpQuic,
    fragmentEnabled: settings.fragmentEnabled,
    fragmentPackets: settings.fragmentPackets,
    fragmentLength: settings.fragmentLength,
    fragmentInterval: settings.fragmentInterval,
    ipv6Enabled: settings.ipv6Enabled,
    preferIpv6: settings.preferIpv6,
    proxySharingEnabled: settings.proxySharingEnabled,
    allowInsecure: settings.allowInsecure,
    vpnInterfaceAddressIndex: settings.vpnInterfaceAddressIndex,
    vpnBypassLan: settings.vpnBypassLan,
    vpnMtu: settings.vpnMtu,
    vpnDns: settings.vpnDns,
    remoteDns: settings.remoteDns,
    domesticDns: settings.domesticDns,
    dnsHosts: settings.dnsHosts,
    delayTestUrl: settings.delayTestUrl,
    logLevel: settings.logLevel,
    outboundDomainResolveMethod: settings.outboundDomainResolveMethod,
    mode: settings.mode,
    trafficMode: settings.trafficMode,
    routingDomainStrategy: settings.routingDomainStrategy,
    routingRules: settings.routingRules
  });
}

export function markRuntimeSettingsRestartNeeded(): void {
  AppStorage.setOrCreate(RUNTIME_SETTINGS_RESTART_PENDING_KEY, true);
}

export function consumeRuntimeSettingsRestartDecision(running: boolean, busy: boolean): RuntimeSettingsRestartDecision {
  const pending = AppStorage.get<boolean>(RUNTIME_SETTINGS_RESTART_PENDING_KEY) ?? false;
  const decision = decideRuntimeSettingsRestart(pending, running, busy);
  AppStorage.setOrCreate(RUNTIME_SETTINGS_RESTART_PENDING_KEY, decision.keepPending);
  return decision;
}
