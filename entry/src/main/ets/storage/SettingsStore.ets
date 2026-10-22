import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DEFAULT_LANGUAGE, normalizeLanguage } from '../core/I18n';
import {
  AppLanguage,
  AppSettings,
  APP_MODE_PROXY_ONLY,
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
import { DNS_PROXY, normalizeOptionalDnsValue, normalizeRemoteDnsValue } from '../core/DnsAddresses';
import { normalizeHttpsUrl } from '../core/HttpDefaults';
import { isReservedAppRuntimePort } from '../core/XrayConfig';
import { MAX_PER_APP_PACKAGE_COUNT, normalizePerAppPackageList } from '../core/PerAppProxy';
import {
  MAX_ROUTING_MATCHER_COUNT,
  MAX_ROUTING_RULE_COUNT,
  MAX_ROUTING_VALUE_CHARS
} from '../core/RoutingRules';

const PREFERENCES_NAME: string = 'hey_vpn_settings';
const SETTINGS_KEY: string = 'app_settings';
const SETTINGS_BACKUP_KEY: string = 'app_settings_backup';
export const MAX_SETTINGS_JSON_CHARS: number = 2 * 1024 * 1024;

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
  // TUN 模式已有独立的内部 18082/18083 数据面，不默认再开放用户可见代理端口。
  // 切换到本地代理模式时运行配置仍会无条件创建 SOCKS/HTTP；旧持久设置继续按原值读取。
  appendHttpProxy: false,
  localSocksEnabled: false,
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
    if (nextRaw.length > MAX_SETTINGS_JSON_CHARS) {
      throw new Error('Application settings exceed the 2 MB storage limit.');
    }
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
    if (raw.length === 0 || raw.length > MAX_SETTINGS_JSON_CHARS) {
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
    const runtimeMode = normalizeAppRuntimeMode(SettingsStore.stringValue(raw.mode, base.mode), base.mode);
    // Hev 只是 VPN/TUN 数据面的可选适配器，转发到本次生成或完整配置的 SOCKS 入口；
    // 它不依赖、也不应擅自开启用户可见的本地 SOCKS 监听。
    const localSocksEnabled = SettingsStore.boolValue(raw.localSocksEnabled, base.localSocksEnabled);
    const localProxyAvailable = localSocksEnabled || runtimeMode === APP_MODE_PROXY_ONLY;
    // VPN/TUN 的系统 DNS 指向 TUN 内虚拟 router，53 端口接管是数据面必需项，不能关闭。
    // 字段继续保留并归一为 true，以兼容旧备份和上游设置结构。
    const localDnsEnabled = true;
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
      language: normalizeLanguage(SettingsStore.stringValue(raw.language, base.language)),
      uiModeNight: normalizeUiModeNight(SettingsStore.stringValue(raw.uiModeNight, base.uiModeNight), base.uiModeNight),
      speedEnabled: SettingsStore.boolValue(raw.speedEnabled, base.speedEnabled),
      confirmRemove: SettingsStore.boolValue(raw.confirmRemove, base.confirmRemove),
      startScanImmediate: SettingsStore.boolValue(raw.startScanImmediate, base.startScanImmediate),
      startOnBoot: SettingsStore.boolValue(raw.startOnBoot, base.startOnBoot),
      groupAllDisplay: SettingsStore.boolValue(raw.groupAllDisplay, base.groupAllDisplay),
      doubleColumnDisplay: SettingsStore.boolValue(raw.doubleColumnDisplay, base.doubleColumnDisplay),
      sniffingEnabled: SettingsStore.boolValue(raw.sniffingEnabled, base.sniffingEnabled),
      routeOnlyEnabled: SettingsStore.boolValue(raw.routeOnlyEnabled, base.routeOnlyEnabled),
      perAppProxyEnabled: SettingsStore.boolValue(raw.perAppProxyEnabled, base.perAppProxyEnabled),
      perAppProxyList: normalizePerAppPackageList(
        SettingsStore.arrayValue(raw.perAppProxyList, base.perAppProxyList)),
      perAppProxyBypass: SettingsStore.boolValue(raw.perAppProxyBypass, base.perAppProxyBypass),
      localDnsEnabled,
      fakeDnsEnabled: SettingsStore.boolValue(raw.fakeDnsEnabled, base.fakeDnsEnabled),
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
      proxySharingEnabled: SettingsStore.boolValue(raw.proxySharingEnabled, base.proxySharingEnabled) && localProxyAvailable,
      allowInsecure: SettingsStore.boolValue(raw.allowInsecure, base.allowInsecure),
      localDnsPort,
      vpnInterfaceAddressIndex: normalizeVpnInterfaceAddressIndex(SettingsStore.numberValue(raw.vpnInterfaceAddressIndex, base.vpnInterfaceAddressIndex), base.vpnInterfaceAddressIndex),
      vpnBypassLan: normalizeVpnBypassLanMode(SettingsStore.stringValue(raw.vpnBypassLan, base.vpnBypassLan), base.vpnBypassLan),
      vpnMtu: normalizeVpnMtuValue(SettingsStore.numberValue(raw.vpnMtu, base.vpnMtu), base.vpnMtu),
      vpnDns: normalizeOptionalDnsValue(SettingsStore.stringValue(raw.vpnDns, base.vpnDns), false),
      remoteDns: normalizeRemoteDnsValue(SettingsStore.stringValue(raw.remoteDns, base.remoteDns)),
      domesticDns: normalizeOptionalDnsValue(SettingsStore.stringValue(raw.domesticDns, base.domesticDns), true),
      dnsHosts: SettingsStore.stringValue(raw.dnsHosts, base.dnsHosts),
      delayTestUrl: SettingsStore.stringValue(raw.delayTestUrl, base.delayTestUrl),
      ipApiUrl: normalizeHttpsUrl(SettingsStore.stringValue(raw.ipApiUrl, base.ipApiUrl)),
      realPingConcurrency: normalizeRealPingConcurrency(SettingsStore.numberValue(raw.realPingConcurrency, base.realPingConcurrency), base.realPingConcurrency),
      homeDelayTestInterval: normalizeHomeDelayTestInterval(SettingsStore.numberValue(raw.homeDelayTestInterval, base.homeDelayTestInterval), base.homeDelayTestInterval),
      logLevel: normalizeCoreLogLevel(SettingsStore.stringValue(raw.logLevel, base.logLevel), base.logLevel),
      outboundDomainResolveMethod: normalizeOutboundDomainResolveMethod(SettingsStore.stringValue(raw.outboundDomainResolveMethod, base.outboundDomainResolveMethod), base.outboundDomainResolveMethod),
      mode: runtimeMode,
      trafficMode: SettingsStore.trafficModeValue(raw.trafficMode, base.trafficMode),
      routingDomainStrategy: normalizeRoutingDomainStrategy(SettingsStore.stringValue(raw.routingDomainStrategy, base.routingDomainStrategy), base.routingDomainStrategy),
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

  private static boolValue(value: Object | undefined | null, fallback: boolean): boolean {
    return typeof value === 'boolean' ? value as boolean : fallback;
  }

  private static stringValue(value: Object | undefined | null, fallback: string): string {
    return typeof value === 'string' ? value as string : fallback;
  }

  private static numberValue(value: Object | undefined | null, fallback: number): number {
    if (typeof value !== 'number' || !Number.isFinite(value as number)) {
      return fallback;
    }
    return Math.floor(value as number);
  }

  private static portValue(value: Object | undefined | null, fallback: number): number {
    const port = SettingsStore.numberValue(value, fallback);
    if (port < 1 || port > 65535) {
      return fallback;
    }
    return port;
  }

  private static runtimePortValue(value: Object | undefined | null, fallback: number): number {
    const port = SettingsStore.portValue(value, fallback);
    return isReservedAppRuntimePort(port) ? fallback : port;
  }

  private static trafficModeValue(value: Object | undefined | null, fallback: string): string {
    if (value === 'global' || value === 'rules' || value === 'direct') {
      return value;
    }
    return fallback;
  }

  private static arrayValue(value: Object | undefined | null, fallback: string[]): string[] {
    // save() may wait behind another Preferences operation. Never retain a page-owned
    // array reference in that queued snapshot, otherwise later UI edits mutate the value
    // that has not been written yet and break call-order persistence guarantees.
    if (!Array.isArray(value)) {
      return fallback.slice();
    }
    const result = new Array<string>();
    for (let index = 0; index < value.length && result.length < MAX_PER_APP_PACKAGE_COUNT; index++) {
      if (typeof value[index] === 'string') {
        const item = value[index] as string;
        if (item.length <= MAX_ROUTING_VALUE_CHARS) {
          result.push(item);
        }
      }
    }
    return result;
  }

  private static routingRulesValue(value: Object | undefined | null): Array<RoutingRule> {
    if (!Array.isArray(value)) {
      return [];
    }
    const rules = new Array<RoutingRule>();
    for (let index = 0; index < value.length && rules.length < MAX_ROUTING_RULE_COUNT; index++) {
      const candidate = value[index] as Object;
      if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
        continue;
      }
      const item = candidate as RoutingRule;
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

  private static cleanStringArray(value: Object | undefined | null): string[] {
    if (!Array.isArray(value)) {
      return [];
    }
    const result = new Array<string>();
    for (let index = 0; index < value.length && result.length < MAX_ROUTING_MATCHER_COUNT; index++) {
      if (typeof value[index] !== 'string') {
        continue;
      }
      const item = (value[index] as string).trim().substring(0, MAX_ROUTING_VALUE_CHARS);
      if (item.length > 0 && result.indexOf(item) < 0) {
        result.push(item);
      }
    }
    return result;
  }

  private static nonEmptyString(value: Object | undefined | null, fallback: string): string {
    const normalized = SettingsStore.stringValue(value, '').trim();
    return normalized.length > 0 ? normalized : fallback;
  }

  private static outboundTagValue(value: Object | undefined | null): string {
    const normalized = SettingsStore.stringValue(value, 'proxy').trim();
    if (normalized === 'direct' || normalized === 'block' || normalized === 'proxy' ||
      normalized === 'proxy-chain' || normalized === 'policy-group') {
      return normalized;
    }
    return 'proxy';
  }

  private static networkValue(value: Object | undefined | null): string {
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
