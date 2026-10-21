import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DEFAULT_LANGUAGE, normalizeLanguage } from '../core/I18n';
import {
  AppLanguage,
  AppSettings,
  APP_MODE_VPN,
  DEFAULT_DELAY_TEST_URL,
  DEFAULT_HEV_TUN_LOG_LEVEL,
  DEFAULT_HEV_TUN_RW_TIMEOUT,
  DEFAULT_IP_API_URL,
  DEFAULT_VPN_BYPASS_LAN,
  DEFAULT_VPN_INTERFACE_ADDRESS_INDEX,
  DEFAULT_VPN_MTU,
  OUTBOUND_DOMAIN_RESOLVE_DNS_HOSTS,
  normalizeAppRuntimeMode,
  normalizeHevTunLogLevel,
  normalizeHevTunRwTimeout,
  normalizeHomeDelayTestInterval,
  normalizeOutboundDomainResolveMethod,
  normalizeRealPingConcurrency,
  normalizeRoutingDomainStrategy,
  normalizeUiModeNight,
  normalizeVpnBypassLanMode,
  normalizeVpnInterfaceAddressIndex,
  normalizeVpnMtuValue,
  RoutingRule
} from '../core/Profile';
import { DEFAULT_CORE_LOG_LEVEL, DEFAULT_MUX_XUDP_QUIC, normalizeCoreLogLevel, normalizeMuxXudpQuic } from '../core/ProtocolOptions';
import { DNS_PROXY } from '../core/DnsAddresses';
import { isReservedAppRuntimePort } from '../core/XrayConfig';

const PREFERENCES_NAME: string = 'hey_vpn_settings';
const SETTINGS_KEY: string = 'app_settings';
const SETTINGS_BACKUP_KEY: string = 'app_settings_backup';

export const DEFAULT_APP_SETTINGS: AppSettings = {
  language: DEFAULT_LANGUAGE,
  uiModeNight: '0',
  speedEnabled: false,
  confirmRemove: false,
  startScanImmediate: false,
  startOnBoot: false,
  groupAllDisplay: false,
  doubleColumnDisplay: false,
  sniffingEnabled: true,
  routeOnlyEnabled: false,
  perAppProxyEnabled: false,
  perAppProxyList: [],
  perAppProxyBypass: false,
  // 默认在 VPN 模式劫持 DNS（tun-in 的 53 端口 → 内置 dns-out），与 sing-box 路径一致。
  // 关掉时浏览器的 UDP/53 会被原样转发给节点，节点不放行 UDP 时解析失败（issue #6）。
  localDnsEnabled: true,
  fakeDnsEnabled: false,
  // 默认只监听 127.0.0.1，供出口 IP 检测与 Geo 下载复用；只有用户另行开启共享时才监听 LAN。
  appendHttpProxy: true,
  localSocksEnabled: true,
  localSocksPort: 18080,
  localSocksDynamicPort: false,
  localSocksUdpEnabled: true,
  localSocksUsername: '',
  localSocksPassword: '',
  useHevTun: false,
  hevTunLogLevel: DEFAULT_HEV_TUN_LOG_LEVEL,
  hevTunRwTimeout: DEFAULT_HEV_TUN_RW_TIMEOUT,
  muxEnabled: false,
  muxConcurrency: 8,
  muxXudpConcurrency: 8,
  muxXudpQuic: DEFAULT_MUX_XUDP_QUIC,
  fragmentEnabled: false,
  fragmentPackets: '',
  fragmentLength: '',
  fragmentInterval: '',
  ipv6Enabled: false,
  preferIpv6: false,
  proxySharingEnabled: false,
  allowInsecure: false,
  localDnsPort: 18053,
  vpnInterfaceAddressIndex: DEFAULT_VPN_INTERFACE_ADDRESS_INDEX,
  vpnBypassLan: DEFAULT_VPN_BYPASS_LAN,
  vpnMtu: DEFAULT_VPN_MTU,
  vpnDns: '',
  // 远程 DNS 走 DoH（HTTPS/TCP）而非明文 UDP：内置 DNS 的上游查询经节点转发时，很多节点
  // 不放行 UDP、只有 TCP 通（测速用 TCP 所以显示节点可用）。DoH 绕开该限制（issue #6）。
  remoteDns: DNS_PROXY,
  domesticDns: '',
  dnsHosts: '',
  delayTestUrl: DEFAULT_DELAY_TEST_URL,
  ipApiUrl: DEFAULT_IP_API_URL,
  realPingConcurrency: 16,
  homeDelayTestInterval: 0,
  logLevel: DEFAULT_CORE_LOG_LEVEL,
  outboundDomainResolveMethod: OUTBOUND_DOMAIN_RESOLVE_DNS_HOSTS,
  mode: APP_MODE_VPN,
  trafficMode: 'rules',
  routingDomainStrategy: 'AsIs',
  routingRules: [],
  autoSortAfterTest: false,
  autoRemoveInvalidAfterTest: false,
  netAutomationEnabled: false,
  netAutomationTrustedSsids: [],
  netAutomationCellularTrusted: false
};

export interface StoredSettingsSelection {
  settings: AppSettings | null;
  source: string;
}

export class SettingsStore {
  // Preferences exposes independent asynchronous operations. Keep reads and writes in one
  // process-wide queue so a page cannot load an old full-settings snapshot while another
  // page is still saving and later write that stale snapshot back over newer values.
  private static operationTail: Promise<void> = Promise.resolve();

  static load(context: common.Context): Promise<AppSettings> {
    return SettingsStore.enqueueOperation((): Promise<AppSettings> => SettingsStore.loadNow(context));
  }

  private static async loadNow(context: common.Context): Promise<AppSettings> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const primaryRaw = (await store.get(SETTINGS_KEY, '')).toString();
    const backupRaw = (await store.get(SETTINGS_BACKUP_KEY, '')).toString();
    const selection = SettingsStore.selectStoredSettings(primaryRaw, backupRaw);
    if (selection.settings !== null && selection.source !== 'backup') {
      return selection.settings;
    }
    if (selection.settings !== null) {
      try {
        await store.put(SETTINGS_KEY, JSON.stringify(selection.settings));
        await store.flush();
      } catch (_error) {
        // keep recovered in-memory value
      }
      return selection.settings;
    }
    throw new Error('Stored application settings are unreadable; defaults were not applied over existing data.');
  }

  static selectStoredSettings(primaryRaw: string, backupRaw: string): StoredSettingsSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { settings: SettingsStore.copy(DEFAULT_APP_SETTINGS), source: 'empty' };
    }
    const primary = SettingsStore.parseStoredSettings(primaryRaw);
    if (primary !== null) {
      return { settings: primary, source: 'primary' };
    }
    const backup = SettingsStore.parseStoredSettings(backupRaw);
    if (backup !== null) {
      return { settings: backup, source: 'backup' };
    }
    return { settings: null, source: 'invalid' };
  }

  static save(context: common.Context, settings: AppSettings): Promise<AppSettings> {
    const normalized = SettingsStore.normalize(settings);
    return SettingsStore.enqueueOperation((): Promise<AppSettings> => SettingsStore.saveNow(context, normalized));
  }

  private static async saveNow(context: common.Context, normalized: AppSettings): Promise<AppSettings> {
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const nextRaw = JSON.stringify(normalized);
    const currentRaw = (await store.get(SETTINGS_KEY, '')).toString();
    if (SettingsStore.parseStoredSettings(currentRaw) !== null) {
      await store.put(SETTINGS_BACKUP_KEY, currentRaw);
    } else {
      const backupRaw = (await store.get(SETTINGS_BACKUP_KEY, '')).toString();
      if (SettingsStore.parseStoredSettings(backupRaw) === null) {
        await store.put(SETTINGS_BACKUP_KEY, nextRaw);
      }
    }
    await store.put(SETTINGS_KEY, nextRaw);
    await store.flush();
    return normalized;
  }

  static saveLanguage(context: common.Context, language: AppLanguage): Promise<AppSettings> {
    return SettingsStore.enqueueOperation(async (): Promise<AppSettings> => {
      const settings = await SettingsStore.loadNow(context);
      settings.language = language;
      return SettingsStore.saveNow(context, SettingsStore.normalize(settings));
    });
  }

  private static enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = SettingsStore.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    SettingsStore.operationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static parseStoredSettings(raw: string): AppSettings | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as AppSettings;
      if (parsed === null || typeof parsed !== 'object') {
        return null;
      }
      const record = parsed as Record<string, Object>;
      if (record['language'] === undefined && record['mode'] === undefined &&
        record['speedEnabled'] === undefined && record['confirmRemove'] === undefined &&
        record['remoteDns'] === undefined && record['vpnDns'] === undefined) {
        return null;
      }
      return SettingsStore.normalize(parsed);
    } catch (_error) {
      return null;
    }
  }

  private static normalize(raw: AppSettings): AppSettings {
    const base = SettingsStore.copy(DEFAULT_APP_SETTINGS);
    const useHevTun = SettingsStore.boolValue(raw.useHevTun, base.useHevTun);
    // Hev 只是 VPN/TUN 数据面的可选适配器，固定转发到内部 VPN_DATA_SOCKS_PORT；
    // 它不依赖、也不应擅自开启用户可见的本地 SOCKS 监听。
    const localSocksEnabled = SettingsStore.boolValue(raw.localSocksEnabled, base.localSocksEnabled);
    const localDnsEnabled = SettingsStore.boolValue(raw.localDnsEnabled, base.localDnsEnabled);
    let localSocksPort = SettingsStore.runtimePortValue(raw.localSocksPort, base.localSocksPort);
    let localDnsPort = SettingsStore.runtimePortValue(raw.localDnsPort, base.localDnsPort);
    if (localDnsPort === localSocksPort) {
      if (base.localDnsPort !== localSocksPort) {
        localDnsPort = base.localDnsPort;
      } else {
        localSocksPort = base.localSocksPort;
      }
    }
    return {
      language: normalizeLanguage(raw.language),
      uiModeNight: normalizeUiModeNight(raw.uiModeNight, base.uiModeNight),
      speedEnabled: SettingsStore.boolValue(raw.speedEnabled, base.speedEnabled),
      confirmRemove: SettingsStore.boolValue(raw.confirmRemove, base.confirmRemove),
      startScanImmediate: SettingsStore.boolValue(raw.startScanImmediate, base.startScanImmediate),
      startOnBoot: SettingsStore.boolValue(raw.startOnBoot, base.startOnBoot),
      groupAllDisplay: SettingsStore.boolValue(raw.groupAllDisplay, base.groupAllDisplay),
      doubleColumnDisplay: SettingsStore.boolValue(raw.doubleColumnDisplay, base.doubleColumnDisplay),
      sniffingEnabled: SettingsStore.boolValue(raw.sniffingEnabled, base.sniffingEnabled),
      routeOnlyEnabled: SettingsStore.boolValue(raw.routeOnlyEnabled, base.routeOnlyEnabled),
      perAppProxyEnabled: SettingsStore.boolValue(raw.perAppProxyEnabled, base.perAppProxyEnabled),
      perAppProxyList: SettingsStore.arrayValue(raw.perAppProxyList, base.perAppProxyList),
      perAppProxyBypass: SettingsStore.boolValue(raw.perAppProxyBypass, base.perAppProxyBypass),
      localDnsEnabled,
      fakeDnsEnabled: SettingsStore.boolValue(raw.fakeDnsEnabled, base.fakeDnsEnabled) && localDnsEnabled,
      appendHttpProxy: SettingsStore.boolValue(raw.appendHttpProxy, base.appendHttpProxy) && localSocksEnabled,
      localSocksEnabled,
      localSocksPort,
      localSocksDynamicPort: SettingsStore.boolValue(raw.localSocksDynamicPort, base.localSocksDynamicPort),
      localSocksUdpEnabled: SettingsStore.boolValue(raw.localSocksUdpEnabled, base.localSocksUdpEnabled),
      localSocksUsername: SettingsStore.stringValue(raw.localSocksUsername, base.localSocksUsername),
      localSocksPassword: SettingsStore.stringValue(raw.localSocksPassword, base.localSocksPassword),
      useHevTun,
      hevTunLogLevel: normalizeHevTunLogLevel(SettingsStore.stringValue(raw.hevTunLogLevel, base.hevTunLogLevel), base.hevTunLogLevel),
      hevTunRwTimeout: normalizeHevTunRwTimeout(SettingsStore.stringValue(raw.hevTunRwTimeout, base.hevTunRwTimeout), base.hevTunRwTimeout),
      muxEnabled: SettingsStore.boolValue(raw.muxEnabled, base.muxEnabled),
      muxConcurrency: SettingsStore.numberValue(raw.muxConcurrency, base.muxConcurrency),
      muxXudpConcurrency: SettingsStore.numberValue(raw.muxXudpConcurrency, base.muxXudpConcurrency),
      muxXudpQuic: normalizeMuxXudpQuic(SettingsStore.stringValue(raw.muxXudpQuic, base.muxXudpQuic), base.muxXudpQuic),
      fragmentEnabled: SettingsStore.boolValue(raw.fragmentEnabled, base.fragmentEnabled),
      fragmentPackets: SettingsStore.stringValue(raw.fragmentPackets, base.fragmentPackets),
      fragmentLength: SettingsStore.stringValue(raw.fragmentLength, base.fragmentLength),
      fragmentInterval: SettingsStore.stringValue(raw.fragmentInterval, base.fragmentInterval),
      ipv6Enabled: SettingsStore.boolValue(raw.ipv6Enabled, base.ipv6Enabled),
      preferIpv6: SettingsStore.boolValue(raw.preferIpv6, base.preferIpv6),
      proxySharingEnabled: SettingsStore.boolValue(raw.proxySharingEnabled, base.proxySharingEnabled) && localSocksEnabled,
      allowInsecure: SettingsStore.boolValue(raw.allowInsecure, base.allowInsecure),
      localDnsPort,
      vpnInterfaceAddressIndex: normalizeVpnInterfaceAddressIndex(raw.vpnInterfaceAddressIndex, base.vpnInterfaceAddressIndex),
      vpnBypassLan: normalizeVpnBypassLanMode(raw.vpnBypassLan, base.vpnBypassLan),
      vpnMtu: normalizeVpnMtuValue(raw.vpnMtu, base.vpnMtu),
      vpnDns: SettingsStore.stringValue(raw.vpnDns, base.vpnDns),
      remoteDns: SettingsStore.stringValue(raw.remoteDns, base.remoteDns),
      domesticDns: SettingsStore.stringValue(raw.domesticDns, base.domesticDns),
      dnsHosts: SettingsStore.stringValue(raw.dnsHosts, base.dnsHosts),
      delayTestUrl: SettingsStore.stringValue(raw.delayTestUrl, base.delayTestUrl),
      ipApiUrl: SettingsStore.stringValue(raw.ipApiUrl, base.ipApiUrl),
      realPingConcurrency: normalizeRealPingConcurrency(raw.realPingConcurrency, base.realPingConcurrency),
      homeDelayTestInterval: normalizeHomeDelayTestInterval(raw.homeDelayTestInterval, base.homeDelayTestInterval),
      logLevel: normalizeCoreLogLevel(SettingsStore.stringValue(raw.logLevel, base.logLevel), base.logLevel),
      outboundDomainResolveMethod: normalizeOutboundDomainResolveMethod(raw.outboundDomainResolveMethod, base.outboundDomainResolveMethod),
      mode: normalizeAppRuntimeMode(raw.mode, base.mode),
      trafficMode: SettingsStore.trafficModeValue(raw.trafficMode, base.trafficMode),
      routingDomainStrategy: normalizeRoutingDomainStrategy(raw.routingDomainStrategy, base.routingDomainStrategy),
      routingRules: SettingsStore.routingRulesValue(raw.routingRules),
      autoSortAfterTest: SettingsStore.boolValue(raw.autoSortAfterTest, base.autoSortAfterTest),
      autoRemoveInvalidAfterTest: SettingsStore.boolValue(raw.autoRemoveInvalidAfterTest, base.autoRemoveInvalidAfterTest),
      netAutomationEnabled: SettingsStore.boolValue(raw.netAutomationEnabled, base.netAutomationEnabled),
      netAutomationTrustedSsids: SettingsStore.arrayValue(raw.netAutomationTrustedSsids, base.netAutomationTrustedSsids),
      netAutomationCellularTrusted: SettingsStore.boolValue(raw.netAutomationCellularTrusted, base.netAutomationCellularTrusted)
    };
  }

  private static copy(settings: AppSettings): AppSettings {
    return JSON.parse(JSON.stringify(settings)) as AppSettings;
  }

  private static boolValue(value: boolean | undefined, fallback: boolean): boolean {
    return value === undefined ? fallback : value;
  }

  private static stringValue(value: string | undefined, fallback: string): string {
    return value === undefined ? fallback : value;
  }

  private static numberValue(value: number | undefined, fallback: number): number {
    if (value === undefined || Number.isNaN(value)) {
      return fallback;
    }
    return Math.floor(value);
  }

  private static portValue(value: number | undefined, fallback: number): number {
    const port = SettingsStore.numberValue(value, fallback);
    if (port < 1 || port > 65535) {
      return fallback;
    }
    return port;
  }

  private static runtimePortValue(value: number | undefined, fallback: number): number {
    const port = SettingsStore.portValue(value, fallback);
    return isReservedAppRuntimePort(port) ? fallback : port;
  }

  private static trafficModeValue(value: string | undefined, fallback: string): string {
    if (value === 'global' || value === 'rules' || value === 'direct') {
      return value;
    }
    return fallback;
  }

  private static arrayValue(value: string[] | undefined, fallback: string[]): string[] {
    // save() may wait behind another Preferences operation. Never retain a page-owned
    // array reference in that queued snapshot, otherwise later UI edits mutate the value
    // that has not been written yet and break call-order persistence guarantees.
    return Array.isArray(value) ? value.slice() : fallback.slice();
  }

  private static routingRulesValue(value: Array<RoutingRule> | undefined): Array<RoutingRule> {
    if (!Array.isArray(value)) {
      return [];
    }
    const rules = new Array<RoutingRule>();
    for (let index = 0; index < value.length; index++) {
      const item = value[index];
      const rule: RoutingRule = {
        id: SettingsStore.nonEmptyString(item.id, `routing-rule-${index + 1}`),
        remarks: SettingsStore.stringValue(item.remarks, '').trim(),
        domain: SettingsStore.cleanStringArray(item.domain),
        ip: SettingsStore.cleanStringArray(item.ip),
        process: SettingsStore.cleanStringArray(item.process),
        outboundTag: SettingsStore.outboundTagValue(item.outboundTag),
        port: SettingsStore.stringValue(item.port, '').trim(),
        network: SettingsStore.networkValue(item.network),
        protocol: SettingsStore.cleanStringArray(item.protocol),
        enabled: SettingsStore.boolValue(item.enabled, true),
        locked: SettingsStore.boolValue(item.locked, false)
      };
      if (rule.remarks.length > 0 || SettingsStore.hasRoutingMatcher(rule)) {
        rules.push(rule);
      }
    }
    return rules;
  }

  private static cleanStringArray(value: string[] | undefined): string[] {
    if (!Array.isArray(value)) {
      return [];
    }
    const result = new Array<string>();
    for (let index = 0; index < value.length; index++) {
      const item = value[index].trim();
      if (item.length > 0 && result.indexOf(item) < 0) {
        result.push(item);
      }
    }
    return result;
  }

  private static nonEmptyString(value: string | undefined, fallback: string): string {
    const normalized = SettingsStore.stringValue(value, '').trim();
    return normalized.length > 0 ? normalized : fallback;
  }

  private static outboundTagValue(value: string | undefined): string {
    const normalized = SettingsStore.stringValue(value, 'proxy').trim();
    if (normalized === 'direct' || normalized === 'block' || normalized === 'proxy' ||
      normalized === 'proxy-chain' || normalized === 'policy-group') {
      return normalized;
    }
    return 'proxy';
  }

  private static networkValue(value: string | undefined): string {
    const normalized = SettingsStore.stringValue(value, '').trim().toLowerCase();
    if (normalized === 'tcp' || normalized === 'udp' || normalized === 'tcp,udp' || normalized === 'udp,tcp') {
      return normalized === 'udp,tcp' ? 'tcp,udp' : normalized;
    }
    return '';
  }

  private static hasRoutingMatcher(rule: RoutingRule): boolean {
    return rule.domain.length > 0 || rule.ip.length > 0 || rule.process.length > 0 ||
      rule.port.length > 0 || rule.protocol.length > 0 || rule.network.length > 0;
  }
}
