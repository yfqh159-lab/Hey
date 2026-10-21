import { AppSettings, isProxyOnlyRuntimeMode, isVpnRuntimeMode } from './Profile';

export function shouldExposeLocalHttpProxy(settings: AppSettings | undefined): boolean {
  if (settings === undefined) {
    return false;
  }
  return shouldExposeLocalHttpProxyState(settings.mode, settings.appendHttpProxy, settings.localSocksEnabled);
}

export function shouldExposeLocalHttpProxyState(mode: string | undefined, appendHttpProxy: boolean, localSocksEnabled: boolean): boolean {
  // 本地代理模式本身承诺 SOCKS + HTTP 两个显式代理入口；它不创建系统 VPN/TUN。
  // VPN 模式则维持原来的双开关约束，避免用户未授权时额外监听 HTTP 端口。
  return isProxyOnlyRuntimeMode(mode) || (isVpnRuntimeMode(mode) && appendHttpProxy && localSocksEnabled);
}

export function shouldUseDynamicLocalSocksPort(settings: AppSettings | undefined): boolean {
  return settings !== undefined && (settings.localSocksEnabled || isProxyOnlyRuntimeMode(settings.mode)) && settings.localSocksDynamicPort;
}

export function selectRuntimeLocalSocksPort(settings: AppSettings, freePorts: Array<number>, reservedPorts: Array<number> = []): number {
  if (!shouldUseDynamicLocalSocksPort(settings)) {
    return settings.localSocksPort;
  }
  for (let index = 0; index < freePorts.length; index++) {
    const port = freePorts[index];
    if (isValidPort(port) && reservedPorts.indexOf(port) < 0) {
      return port;
    }
  }
  return settings.localSocksPort;
}

export function withRuntimeLocalSocksPort(settings: AppSettings, port: number): AppSettings {
  const runtimeSettings = JSON.parse(JSON.stringify(settings)) as AppSettings;
  runtimeSettings.localSocksPort = isValidPort(port) ? port : settings.localSocksPort;
  return runtimeSettings;
}

function isValidPort(port: number): boolean {
  return typeof port === 'number' && Math.floor(port) === port && port >= 1 && port <= 65535;
}
