import { AppLanguage, ConnectionStatus } from '../core/Profile';
import { formatTranslation, translate } from '../core/I18n';
import { buildUnsupportedShareLinkMessage } from '../core/ShareLinkParser';
import { formatBytes, formatClockTime } from './Formatters';

export function formatOne(language: AppLanguage, key: string, name: string, value: string): string {
  const names = new Array<string>();
  const values = new Array<string>();
  names.push(name);
  values.push(value);
  return formatTranslation(language, key, names, values);
}

export function formatTwo(language: AppLanguage, key: string, name1: string, value1: string, name2: string, value2: string): string {
  const names = new Array<string>();
  const values = new Array<string>();
  names.push(name1);
  values.push(value1);
  names.push(name2);
  values.push(value2);
  return formatTranslation(language, key, names, values);
}

export function localizedConnectionStatus(language: AppLanguage, status: ConnectionStatus): string {
  switch (status) {
    case ConnectionStatus.STARTING:
      return translate(language, 'status.starting');
    case ConnectionStatus.RUNNING:
      return translate(language, 'status.running');
    case ConnectionStatus.STOPPING:
      return translate(language, 'status.stopping');
    case ConnectionStatus.ERROR:
      return translate(language, 'status.error');
    default:
      return translate(language, 'status.idle');
  }
}

export function localizedProfileSavedText(language: AppLanguage, updatedAt: number): string {
  if (updatedAt <= 0) {
    return translate(language, 'profile.notSaved');
  }
  return formatOne(language, 'profile.savedAt', 'time', formatClockTime(updatedAt));
}

export function localizedSubscriptionStatusText(language: AppLanguage, updatedAt: number): string {
  if (updatedAt <= 0) {
    return translate(language, 'subscription.none');
  }
  return formatOne(language, 'subscription.updatedAt', 'time', formatClockTime(updatedAt));
}

// 把 VPN 运行心跳（速度显示开启时 2 秒、关闭时 5 秒一条）渲染成友好文案，
// 顺带带上它携带的有用数据：上/下行累计流量与 Xray/TUN 运行状态。
export function localizeDiagnosticHeartbeat(
  language: AppLanguage,
  uploadBytes: number,
  downloadBytes: number,
  xrayRunning: boolean,
  tunRunning: boolean,
  coreLabel: string = 'Xray'
): string {
  const names = new Array<string>();
  const values = new Array<string>();
  names.push('up');
  values.push(formatBytes(uploadBytes));
  names.push('down');
  values.push(formatBytes(downloadBytes));
  // {core} 是当前运行内核名（Xray / sing-box），{xray} 仍是运行状态勾。
  names.push('core');
  values.push(coreLabel);
  names.push('xray');
  values.push(xrayRunning ? '✓' : '✗');
  names.push('tun');
  values.push(tunRunning ? '✓' : '✗');
  return formatTranslation(language, 'log.heartbeat', names, values);
}

export function localizeCoreMessage(language: AppLanguage, message: string): string {
  if (message.length === 0) {
    return '';
  }
  if (message === 'Native bridge not queried yet.' ||
    message === translate('zh-rCN', 'runtime.nativeBridgeNotQueried') ||
    message === translate('en', 'runtime.nativeBridgeNotQueried')) {
    return translate(language, 'runtime.nativeBridgeNotQueried');
  }
  if (message === 'VPN extension owns the native bridge. Xray is handling the TUN inbound directly.' ||
    message === translate('zh-rCN', 'runtime.vpnOwnsBridge') ||
    message === translate('en', 'runtime.vpnOwnsBridge')) {
    return translate(language, 'runtime.vpnOwnsBridge');
  }
  if (message === 'Xray is running in proxy-only mode.' ||
    message === translate('zh-rCN', 'runtime.proxyOnlyRunning') ||
    message === translate('en', 'runtime.proxyOnlyRunning')) {
    return translate(language, 'runtime.proxyOnlyRunning');
  }
  if (message === '请先粘贴 Xray outbound JSON。') {
    return translate(language, 'core.emptyOutbound');
  }
  if (message === 'outbound 缺少 protocol 字段。') {
    return translate(language, 'core.missingProtocol');
  }
  if (message === 'outbound 缺少 settings 字段。') {
    return translate(language, 'core.missingSettings');
  }
  if (message === '请先粘贴 Xray 完整配置 JSON。') {
    return translate(language, 'core.emptyFullConfig');
  }
  if (message === '完整配置缺少 inbounds 数组。') {
    return translate(language, 'core.missingFullConfigInbounds');
  }
  if (message === '完整配置缺少 outbounds 数组。') {
    return translate(language, 'core.missingFullConfigOutbounds');
  }
  if (message === '完整 Xray 配置校验通过。') {
    return translate(language, 'core.validFullConfig');
  }
  if (message === 'sing-box 预览暂不转换自定义分流规则；请选择全局/直连模式，或使用 Xray 支持的节点。') {
    return translate(language, 'core.singboxCustomRoutingUnsupported');
  }
  if (message === '请先粘贴代理链 JSON。') {
    return translate(language, 'core.emptyProxyChainConfig');
  }
  if (message === '代理链配置缺少 outbounds 数组。') {
    return translate(language, 'core.missingProxyChainOutbounds');
  }
  if (message === '代理链至少需要两个 outbound。') {
    return translate(language, 'core.insufficientProxyChainOutbounds');
  }
  if (message === '代理链至少需要两个普通 outbound 节点。') {
    return translate(language, 'core.insufficientProxyChainBuildableNodes');
  }
  if (message === '代理链配置校验通过。') {
    return translate(language, 'core.validProxyChainConfig');
  }
  if (message === '请先粘贴策略组 JSON。') {
    return translate(language, 'core.emptyPolicyGroupConfig');
  }
  if (message === '策略组配置缺少 outbounds 数组。') {
    return translate(language, 'core.missingPolicyGroupOutbounds');
  }
  if (message === '策略组至少需要一个 outbound。') {
    return translate(language, 'core.emptyPolicyGroupOutbounds');
  }
  if (message === '策略组至少需要一个普通 outbound 节点。') {
    return translate(language, 'core.emptyPolicyGroupBuildableNodes');
  }
  if (message === '策略组配置校验通过。') {
    return translate(language, 'core.validPolicyGroupConfig');
  }
  if (message === buildUnsupportedShareLinkMessage()) {
    return translate(language, 'core.unsupportedShareLink');
  }
  if (message === 'VLESS 链接缺少用户 ID。') {
    return translate(language, 'core.vlessMissingId');
  }
  if (message === 'VMess 链接缺少服务器、端口或用户 ID。') {
    return translate(language, 'core.vmessMissingServer');
  }
  if (message === 'VMess 链接缺少用户 ID。') {
    return translate(language, 'core.vmessMissingId');
  }
  if (message === 'Trojan 链接缺少密码。') {
    return translate(language, 'core.trojanMissingPassword');
  }
  if (message === 'Shadowsocks 链接缺少加密方法或密码。') {
    return translate(language, 'core.ssMissingMethod');
  }
  if (message === 'Shadowsocks legacy 链接格式不正确。') {
    return translate(language, 'core.ssLegacyInvalid');
  }
  if (message === 'WireGuard 链接缺少私钥。') {
    return translate(language, 'core.wgMissingPrivateKey');
  }
  if (message === 'WireGuard 链接缺少 publickey。') {
    return translate(language, 'core.wgMissingPublicKey');
  }
  if (message === 'WireGuard 配置缺少 endpoint。') {
    return translate(language, 'core.wgMissingEndpoint');
  }
  if (message === 'WireGuard 配置文件导入成功。') {
    return translate(language, 'core.wgConfigImported');
  }
  if (message === 'Hysteria2 链接缺少认证密码。') {
    return translate(language, 'core.hy2MissingPassword');
  }
  if (message === '订阅链接必须是 http:// 或 https://。') {
    return translate(language, 'subscription.urlMustHttp');
  }
  if (message === '订阅链接缺少有效的主机名或端口。') {
    return translate(language, 'subscription.invalidUrl');
  }
  if (message === 'HTTP 订阅链接不安全，请开启允许不安全订阅链接后重试。') {
    return translate(language, 'subscription.insecureUrlBlocked');
  }
  if (message === '订阅内容里没有识别到支持的节点。') {
    return translate(language, 'subscription.noSupportedNodes');
  }
  if (message === '订阅返回的是网页内容而不是节点数据，请检查订阅链接是否为面板下发的订阅地址。') {
    return translate(language, 'subscription.htmlResponse');
  }
  if (message === '启动 VPN 超时：系统 VPN 授权服务没有响应。若 hilog 中出现 com.huawei.hmos.vpndialog bundle not exist，说明当前系统镜像缺少 VPN 授权组件，请改用真机测试。') {
    return translate(language, 'vpn.startTimeout');
  }
  if (message === '启动 VPN 未确认完成：VPN 扩展没有回写启动完成状态。') {
    return translate(language, 'vpn.startNotConfirmed');
  }
  if (message === '停止 VPN 超时：VPN 扩展没有响应停止命令。') {
    return translate(language, 'vpn.stopCommandTimeout');
  }
  if (message === '停止 VPN 未确认完成：VPN 扩展尚未回写清理完成状态。') {
    return translate(language, 'vpn.stopNotConfirmed');
  }
  if (message === '仅代理模式缺少运行配置。') {
    return translate(language, 'proxy.missingRuntimeConfig');
  }
  if (message === '本地代理配置缺少可从 127.0.0.1 探测的 SOCKS 入站。') {
    return translate(language, 'proxy.missingSocksInbound');
  }
  if (message === '不支持编辑此协议节点。') {
    return translate(language, 'manualEdit.unsupportedProtocol');
  }
  if (message === '节点配置缺少 settings。') {
    return translate(language, 'manualEdit.missingSettings');
  }

  if (message.startsWith('暂不支持 tuic') || message.startsWith('暂不支持 TUIC')) {
    return translate(language, 'core.tuicNeedsSingbox');
  }

  const unsupportedPrefix = '暂不支持 ';
  const unsupportedEnd = '，当前支持 VLESS、VMess、Trojan、Shadowsocks、SOCKS、HTTP、WireGuard 和 Hysteria2。';
  if (message.startsWith(unsupportedPrefix) && message.endsWith(unsupportedEnd)) {
    const protocol = message.substring(unsupportedPrefix.length, message.length - unsupportedEnd.length);
    return formatOne(language, 'core.unsupportedProtocol', 'protocol', protocol);
  }

  const validSuffix = ' outbound 校验通过。';
  if (message.endsWith(validSuffix)) {
    const protocol = message.substring(0, message.length - validSuffix.length);
    return formatOne(language, 'core.validOutbound', 'protocol', protocol);
  }

  const advancedOutboundNodePrefix = '第 ';
  const advancedOutboundNodeSuffix = ' 个节点不是可用的普通 outbound，不能加入高级节点。';
  if (message.startsWith(advancedOutboundNodePrefix) && message.endsWith(advancedOutboundNodeSuffix)) {
    const index = message.substring(advancedOutboundNodePrefix.length, message.length - advancedOutboundNodeSuffix.length);
    return formatOne(language, 'core.invalidAdvancedOutboundNode', 'index', index);
  }

  const proxyChainHopPrefix = '代理链第 ';
  const proxyChainHopMiddle = ' 跳无效：';
  const proxyChainHopMiddleIndex = message.indexOf(proxyChainHopMiddle);
  if (message.startsWith(proxyChainHopPrefix) && proxyChainHopMiddleIndex > proxyChainHopPrefix.length) {
    const index = message.substring(proxyChainHopPrefix.length, proxyChainHopMiddleIndex);
    const error = message.substring(proxyChainHopMiddleIndex + proxyChainHopMiddle.length);
    return formatTwo(language, 'core.invalidProxyChainHop', 'index', index, 'error', localizeCoreMessage(language, error));
  }

  const policyGroupMemberPrefix = '策略组第 ';
  const policyGroupMemberMiddle = ' 个成员无效：';
  const policyGroupMemberMiddleIndex = message.indexOf(policyGroupMemberMiddle);
  if (message.startsWith(policyGroupMemberPrefix) && policyGroupMemberMiddleIndex > policyGroupMemberPrefix.length) {
    const index = message.substring(policyGroupMemberPrefix.length, policyGroupMemberMiddleIndex);
    const error = message.substring(policyGroupMemberMiddleIndex + policyGroupMemberMiddle.length);
    return formatTwo(language, 'core.invalidPolicyGroupMember', 'index', index, 'error', localizeCoreMessage(language, error));
  }

  const shareSuffix = ' 分享链接导入成功。';
  if (message.endsWith(shareSuffix)) {
    const protocol = message.substring(0, message.length - shareSuffix.length);
    return formatOne(language, 'core.shareImported', 'protocol', protocol);
  }

  const updatePrefix = '订阅更新完成，共 ';
  const updateSuffix = ' 个可用节点。';
  if (message.startsWith(updatePrefix) && message.endsWith(updateSuffix)) {
    const count = message.substring(updatePrefix.length, message.length - updateSuffix.length);
    return formatOne(language, 'subscription.updateComplete', 'count', count);
  }

  const updateSkippedMiddle = ' 个可用节点，跳过 ';
  const updateSkippedSuffix = ' 条不支持的记录。';
  const updateSkippedMiddleIndex = message.indexOf(updateSkippedMiddle);
  if (message.startsWith(updatePrefix) && updateSkippedMiddleIndex > updatePrefix.length && message.endsWith(updateSkippedSuffix)) {
    const count = message.substring(updatePrefix.length, updateSkippedMiddleIndex);
    const skipped = message.substring(updateSkippedMiddleIndex + updateSkippedMiddle.length, message.length - updateSkippedSuffix.length);
    return formatTwo(language, 'subscription.updateCompleteSkipped', 'count', count, 'skipped', skipped);
  }

  return localizePrefixMessage(language, message, 'JSON 解析失败：', 'core.jsonParseFailed') ??
    localizePrefixMessage(language, message, '分享链接解析失败：', 'core.shareParseFailed') ??
    localizePrefixMessage(language, message, '节点配置解析失败：', 'manualEdit.parseFailed') ??
    localizePrefixMessage(language, message, '高级节点配置解析失败：', 'advancedOutbound.parseFailed') ??
    localizeCoreErrorPrefixMessage(language, message, '启动 VPN 失败：', 'vpn.startFailed') ??
    localizeCoreErrorPrefixMessage(language, message, '停止 VPN 失败：', 'vpn.stopFailed') ??
    localizeCoreErrorPrefixMessage(language, message, '启动仅代理模式失败：', 'proxy.startFailed') ??
    localizeCoreErrorPrefixMessage(language, message, '停止仅代理模式失败：', 'proxy.stopFailed') ??
    message;
}

function localizePrefixMessage(language: AppLanguage, message: string, prefix: string, key: string): string | null {
  if (!message.startsWith(prefix)) {
    return null;
  }
  return formatOne(language, key, 'error', message.substring(prefix.length));
}

function localizeCoreErrorPrefixMessage(language: AppLanguage, message: string, prefix: string, key: string): string | null {
  if (!message.startsWith(prefix)) {
    return null;
  }
  const error = message.substring(prefix.length);
  return formatOne(language, key, 'error', localizeCoreMessage(language, error));
}
