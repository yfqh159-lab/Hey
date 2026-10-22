export interface NativeResult {
  ok: boolean;
  message: string;
}

export interface NativePingResult {
  ok: boolean;
  delayMs: number;
  message: string;
}

export interface RuntimeStats {
  uploadBytes: number;
  downloadBytes: number;
  xrayRunning: boolean;
  tunRunning: boolean;
  lastMessage: string;
}

export const validateConfig: (configJson: string) => NativeResult;
export const prepareXrayAssets: (workDir: string) => NativeResult;
export const setTunFd: (tunFd: number) => NativeResult;
export const startXray: (configJson: string, workDir: string) => NativeResult;
export const stopXray: () => NativeResult;
export const getStats: () => RuntimeStats;
// tun2socks 适配器（libheytun2socks.so）：TUN fd 流量 -> 本地 SOCKS 入站。
export const startTun2Socks: (tunFd: number, socksHost: string, socksPort: number, mtu: number) => NativeResult;
export const startHevTun: (tunFd: number, configYaml: string) => NativeResult;
export const stopTun2Socks: () => NativeResult;
export const pingOutbound: (configJson: string, datDir: string, url: string, timeoutSeconds: number, proxy: string) => NativePingResult;
export const queryStats: (server: string) => NativeResult;
export const testXrayConfig: (configJson: string, workDir: string) => NativeResult;
export const xrayVersion: () => NativeResult;
export const countGeoData: (datDir: string, name: string, geoType: string) => NativeResult;
export const readGeoFiles: (configJson: string) => NativeResult;
export const getFreePorts: (count: number) => NativeResult;
export const convertShareLinksToXrayJson: (text: string) => NativeResult;
export const convertXrayJsonToShareLinks: (configJson: string) => NativeResult;
// sing-box second core (optional). singboxProbe is UI-thread safe (dlopen only);
// singboxVersion/SetTunFd/Start/Stop must be called from the VPN native thread.
export const singboxProbe: () => NativeResult;
export const singboxVersion: () => NativeResult;
export const singboxSetTunFd: (tunFd: number) => NativeResult;
export const singboxStart: (configJson: string, workDir: string) => NativeResult;
export const singboxStop: () => NativeResult;
