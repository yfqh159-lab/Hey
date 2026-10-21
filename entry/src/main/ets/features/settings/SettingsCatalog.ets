import { AppRoute } from '../../shell/AppRoute';
import { APP_MODE_VPN, AppRuntimeMode, isProxyOnlyRuntimeMode } from '../../core/Profile';

/**
 * 设置页目录（单页长滚动 · 数据驱动）。
 *
 * 纯数据：不含 UI / 资源引用（图标在页面层按 group.id 用字面量 $r 映射），
 * 因此 filterSettings 可被纯单测覆盖。每个 item.key 对应 Settings 页既有的
 * @State 字段与处理器（toggleSetting / show*Menu / updateSettingInput），
 * 目录只负责「展示哪些项、什么类型、依赖谁、怎么搜」。
 */

export type SettingItemType = 'toggle' | 'option' | 'input' | 'nav';
export type SettingInputKind = 'text' | 'number' | 'password';

export interface SettingItem {
  key: string;            // 与现有处理器 action 一致，亦作搜索别名（'localSocks' 命中 'socks'）
  titleKey: string;       // i18n
  type: SettingItemType;
  descKey?: string;       // 可选副标题（i18n）
  dependsOn?: string;     // 依赖的开关 key；为假时整项隐藏
  vpnOnly?: boolean;      // 仅系统 VPN/TUN 模式有意义；本地代理模式隐藏
  danger?: boolean;       // 危险项，标题红色
  inputKind?: SettingInputKind;  // type==='input' 时（默认 text）
  route?: string;         // type==='nav' 时的目标路由
}

export interface SettingGroup {
  id: string;             // 'ui' | 'core' | 'vpn' | 'transport' | 'advanced' | 'testing'
  titleKey: string;       // i18n
  color: string;          // 分组色块图标背景（hex，明暗通用）
  items: SettingItem[];
}

export const SETTINGS_CATALOG: SettingGroup[] = [
  {
    id: 'ui',
    titleKey: 'settings.cat.ui',
    color: '#5B6CF0',
    items: [
      { key: 'language', titleKey: 'settings.language.title', type: 'option' },
      { key: 'uiModeNight', titleKey: 'settings.uiModeNight', type: 'option' },
      { key: 'speedEnabled', titleKey: 'settings.speedEnabled', type: 'toggle' },
      { key: 'confirmRemove', titleKey: 'settings.confirmRemove', type: 'toggle' },
      { key: 'startScanImmediate', titleKey: 'settings.startScanImmediate', type: 'toggle' },
      { key: 'startOnBoot', titleKey: 'settings.startOnBoot', type: 'toggle', descKey: 'settings.startOnBoot.detail' },
      { key: 'groupAllDisplay', titleKey: 'settings.groupAllDisplay', type: 'toggle' },
      { key: 'doubleColumnDisplay', titleKey: 'settings.doubleColumnDisplay', type: 'toggle' }
    ]
  },
  {
    id: 'core',
    titleKey: 'settings.cat.core',
    color: '#F97910',
    items: [
      { key: 'mode', titleKey: 'settings.mode', type: 'option' },
      { key: 'coreType', titleKey: 'settings.coreType', type: 'option', descKey: 'settings.coreType.detail', vpnOnly: true },
      { key: 'sniffing', titleKey: 'settings.sniffing', type: 'toggle', descKey: 'settings.sniffing.detail' },
      { key: 'routeOnly', titleKey: 'settings.routeOnly', type: 'toggle' },
      { key: 'allowInsecure', titleKey: 'settings.allowInsecure', type: 'toggle', danger: true, descKey: 'settings.allowInsecure.detail' }
    ]
  },
  {
    id: 'vpn',
    titleKey: 'settings.cat.vpn',
    color: '#16A34A',
    items: [
      { key: 'perApp', titleKey: 'settings.perAppProxy', type: 'nav', route: AppRoute.PER_APP, vpnOnly: true },
      { key: 'localDns', titleKey: 'settings.localDns', type: 'toggle', descKey: 'settings.localDns.detail', vpnOnly: true },
      { key: 'fakeDns', titleKey: 'settings.fakeDns', type: 'toggle', dependsOn: 'localDns', descKey: 'settings.fakeDns.detail', vpnOnly: true },
      { key: 'localDnsPort', titleKey: 'settings.localDnsPort', type: 'input', inputKind: 'number', vpnOnly: true },
      { key: 'proxySharing', titleKey: 'settings.proxySharing', type: 'toggle' },
      { key: 'appendHttpProxy', titleKey: 'settings.appendHttpProxy', type: 'toggle', vpnOnly: true },
      { key: 'localSocks', titleKey: 'settings.localSocks', type: 'toggle', vpnOnly: true },
      { key: 'localSocksPort', titleKey: 'settings.localSocksPort', type: 'input', inputKind: 'number', dependsOn: 'localSocks' },
      { key: 'localSocksDynamicPort', titleKey: 'settings.localSocksDynamicPort', type: 'toggle', dependsOn: 'localSocks' },
      { key: 'localSocksUdp', titleKey: 'settings.localSocksUdp', type: 'toggle', dependsOn: 'localSocks' },
      { key: 'localSocksUsername', titleKey: 'settings.localSocksUsername', type: 'input', dependsOn: 'localSocks' },
      { key: 'localSocksPassword', titleKey: 'settings.localSocksPassword', type: 'input', inputKind: 'password', dependsOn: 'localSocks' },
      { key: 'useHevTun', titleKey: 'settings.useHevTun', type: 'toggle', descKey: 'settings.useHevTun.detail', vpnOnly: true },
      { key: 'hevTunLogLevel', titleKey: 'settings.hevTunLogLevel', type: 'option', dependsOn: 'useHevTun', vpnOnly: true },
      { key: 'hevTunRwTimeout', titleKey: 'settings.hevTunRwTimeout', type: 'input', inputKind: 'number', dependsOn: 'useHevTun', vpnOnly: true },
      { key: 'ipv6Enabled', titleKey: 'settings.ipv6Enabled', type: 'toggle' },
      { key: 'preferIpv6', titleKey: 'settings.preferIpv6', type: 'toggle' },
      { key: 'vpnBypassLan', titleKey: 'settings.vpnBypassLan', type: 'option', vpnOnly: true },
      { key: 'vpnInterfaceAddress', titleKey: 'settings.vpnInterfaceAddress', type: 'option', vpnOnly: true },
      { key: 'vpnDns', titleKey: 'settings.vpnDns', type: 'input', vpnOnly: true },
      { key: 'vpnMtu', titleKey: 'settings.vpnMtu', type: 'input', inputKind: 'number', vpnOnly: true }
    ]
  },
  {
    id: 'netAutomation',
    titleKey: 'settings.cat.netAutomation',
    color: '#0EA5E9',
    items: [
      { key: 'netAutomationEnabled', titleKey: 'settings.netAutomation', type: 'toggle', descKey: 'settings.netAutomation.detail', vpnOnly: true },
      { key: 'netAutomationTrusted', titleKey: 'settings.netAutomationTrusted', type: 'nav', route: AppRoute.NETWORK_SCENARIO, dependsOn: 'netAutomationEnabled', descKey: 'settings.netAutomationTrusted.detail', vpnOnly: true }
    ]
  },
  {
    id: 'transport',
    titleKey: 'settings.cat.transport',
    color: '#8B5CF6',
    items: [
      { key: 'mux', titleKey: 'settings.mux', type: 'toggle' },
      { key: 'muxConcurrency', titleKey: 'settings.muxConcurrency', type: 'input', inputKind: 'number', dependsOn: 'mux' },
      { key: 'muxXudpConcurrency', titleKey: 'settings.muxXudpConcurrency', type: 'input', inputKind: 'number', dependsOn: 'mux' },
      { key: 'muxXudpQuic', titleKey: 'settings.muxXudpQuic', type: 'option', dependsOn: 'mux' },
      { key: 'fragment', titleKey: 'settings.fragment', type: 'toggle' },
      { key: 'fragmentPackets', titleKey: 'settings.fragmentPackets', type: 'option', dependsOn: 'fragment' },
      { key: 'fragmentLength', titleKey: 'settings.fragmentLength', type: 'input', dependsOn: 'fragment' },
      { key: 'fragmentInterval', titleKey: 'settings.fragmentInterval', type: 'input', dependsOn: 'fragment' }
    ]
  },
  {
    id: 'advanced',
    titleKey: 'settings.cat.advanced',
    color: '#64748B',
    items: [
      { key: 'remoteDns', titleKey: 'settings.remoteDns', type: 'input', descKey: 'settings.remoteDns.detail' },
      { key: 'domesticDns', titleKey: 'settings.domesticDns', type: 'input' },
      { key: 'dnsHosts', titleKey: 'settings.dnsHosts', type: 'input' },
      { key: 'outboundDomainResolveMethod', titleKey: 'settings.outboundDomainResolveMethod', type: 'option' },
      { key: 'delayTestUrl', titleKey: 'settings.delayTestUrl', type: 'input' },
      { key: 'ipApiUrl', titleKey: 'settings.ipApiUrl', type: 'input' },
      { key: 'logLevel', titleKey: 'settings.logLevel', type: 'option' },
      { key: 'backup', titleKey: 'settings.backup.title', type: 'nav', descKey: 'settings.backup.detail', route: AppRoute.BACKUP }
    ]
  },
  {
    id: 'testing',
    titleKey: 'settings.cat.testing',
    color: '#0EA5E9',
    items: [
      { key: 'realPingConcurrency', titleKey: 'settings.realPingConcurrency', type: 'input', inputKind: 'number' },
      { key: 'homeDelayTestInterval', titleKey: 'settings.homeDelayTestInterval', type: 'input', inputKind: 'number', descKey: 'settings.homeDelayTestInterval.detail' },
      { key: 'autoSortAfterTest', titleKey: 'settings.autoSortAfterTest', type: 'toggle' },
      { key: 'autoRemoveAfterTest', titleKey: 'settings.autoRemoveAfterTest', type: 'toggle' }
    ]
  }
];

/**
 * 依赖过滤 + 搜索过滤。纯函数（不依赖 UI/资源），可单测。
 * - 依赖未满足（dependsOn 关）的项隐藏。
 * - 本地代理模式隐藏仅对系统 VPN/TUN 生效的项。
 * - query 非空时，命中 = 本地化标题 / 描述 / 组标题 / item.key（英文别名）包含 query。
 * - 仅返回仍有可见项的分组。
 */
export function filterSettings(
  catalog: SettingGroup[],
  isEnabled: (key: string) => boolean,
  query: string,
  text: (key: string) => string,
  runtimeMode: AppRuntimeMode = APP_MODE_VPN
): SettingGroup[] {
  const q = query.trim().toLowerCase();
  const out: SettingGroup[] = [];
  for (const group of catalog) {
    const items: SettingItem[] = [];
    for (const item of group.items) {
      if (item.vpnOnly === true && isProxyOnlyRuntimeMode(runtimeMode)) {
        continue;
      }
      if (item.dependsOn !== undefined && !isEnabled(item.dependsOn)) {
        continue;
      }
      if (q.length > 0) {
        const title = text(item.titleKey).toLowerCase();
        const desc = item.descKey !== undefined ? text(item.descKey).toLowerCase() : '';
        const groupTitle = text(group.titleKey).toLowerCase();
        const key = item.key.toLowerCase();
        const hit = title.includes(q) || desc.includes(q) || groupTitle.includes(q) || key.includes(q);
        if (!hit) {
          continue;
        }
      }
      items.push(item);
    }
    if (items.length > 0) {
      out.push({ id: group.id, titleKey: group.titleKey, color: group.color, items: items });
    }
  }
  return out;
}
