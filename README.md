<div align="center">

<img src="design/app-icon/startIcon.png" alt="Hey" width="160" height="160" />

# Hey

**A native network tunnel and protocol debugging client for HarmonyOS NEXT. Bring your own server.**

<p>
  <img src="https://img.shields.io/badge/platform-HarmonyOS%20NEXT-0A0A0A" alt="platform" />
  <img src="https://img.shields.io/badge/target-6.0.1%20(21)-1E88E5" alt="target SDK 6.0.1(21)" />
  <img src="https://img.shields.io/badge/core-Xray%20%2B%20sing--box-6E56CF" alt="Xray and sing-box cores" />
  <img src="https://img.shields.io/badge/version-1.3.5-E85D04" alt="version 1.3.5" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-3DA639" alt="license GPL-3.0" /></a>
</p>

English · [简体中文](README.zh-CN.md)

</div>

---

Hey is a HarmonyOS NEXT app written in ArkTS. The codebase uses the Stage
model, a VPN Extension Ability, a form-based control card, WorkScheduler,
ScanKit QR scanning, launcher shortcuts, `hey://` deep links, system share
import, and a native N-API bridge for the packaged transport cores.

The main runtime is Xray. sing-box is also packaged and can be selected in
settings, but its app integration is intentionally narrower today.

## Design Principle

> **Ship no intended use. Let the user work it out.**

Every change is measured against one question: *is this a decision the app makes
for the user, or a decision the user makes themselves?* Supporting a protocol,
parsing a config format, or exposing a transport parameter is the user's
decision, and those are kept and made to work well. Preset routing rules,
server/configuration sources, automatic selection, and region-based hardcoding
are the app's decision, and those are not implemented. The data-files page has
one narrow exception: an explicit user action can check the maintained default
Geo release and verify both core files against its published SHA-256 sums.

Concretely, the repository ships no server address, no config source, no rule
set, and no region or country preset. Geo files are downloaded only after the
user taps the check action; they are not bundled or updated on a schedule. The
factory default for the delay-test URL is empty. Remote DNS uses an IP-form DoH
endpoint routed through the proxy to avoid falling back to the physical-network
resolver; it can be replaced in advanced settings. Other DNS fields are empty. Exit-IP
checks use an HTTPS endpoint that returns only the public address, run only
after the user starts a proxy, and can be disabled or replaced in advanced
settings. Deep links,
shared text, and scanned codes always show what they contain and wait for an
explicit confirmation before anything is added or fetched.

[`CONTRIBUTING.md`](CONTRIBUTING.md) carries the full list of things that will
never be implemented, and `./scripts/compliance_scan.sh` enforces the wording
part of it.

## Current State

The Xray path is the production path in this repository. It supports VPN mode
and proxy-only mode, generates runtime Xray config from the selected profile,
starts/stops the HarmonyOS VPN Extension, and routes VPN traffic through the
packaged `libheytun2socks.so` adapter. Proxy-only mode does not create a TUN;
it exposes a configurable local SOCKS port plus the loopback HTTP proxy on
port `18081` by default, which is also used for exit-IP verification. Listening
outside loopback still requires the explicit proxy-sharing setting.

The current VPN data path for both cores is:

```text
HarmonyOS VPN TUN fd
  -> libheytun2socks.so (gvisor, default) or libhevsocks5tun.so (hev)
  -> 127.0.0.1:18082 (local SOCKS/mixed inbound)
  -> Xray or sing-box outbound
```

This is why the app does not hand the TUN fd directly to Xray or sing-box. The
OpenHarmony Go fork and TLSDESC build route are documented in
[`docs/harmonyos-go-tls-wall.md`](docs/harmonyos-go-tls-wall.md), the native
build notes are in [`docs/building-native-cores.md`](docs/building-native-cores.md),
and the IPv6 route handling that keeps `::/0` inside the TUN is described in
[`docs/ipv6-leak-prevention.md`](docs/ipv6-leak-prevention.md).

The sing-box path currently supports VPN mode with one converted outbound.
The converter accepts VLESS, VMess, Trojan, Shadowsocks, AnyTLS, and TUIC, with
basic tcp/ws/grpc/http/httpupgrade transport mapping and none/tls/reality
security mapping. It does not yet support full configs, proxy chains, policy
groups, proxy-only mode, Hysteria2, WireGuard, SOCKS, HTTP, or sing-box-native
traffic stats.

## Implemented In Code

- HarmonyOS entry points: `EntryAbility`, `HeyVpnAbility`, `ControlCardAbility`,
  `SubscriptionUpdateWorkAbility`, launcher shortcuts, `hey://` routes, and
  `text/plain` system share import.
- Pages for server list, node detail/edit, import, JSON import, advanced
  outbound, subscriptions, subscription detail/edit, routing, settings,
  language, per-app tunnel, network scenario, data files, logs, scanner,
  backup, export, and about.
  The normal add flow exposes only single-node protocols and custom JSON;
  proxy-chain/policy-group creation is hidden while existing configurations
  remain compatible.
- Node and subscription handling: multiple subscription groups, selected group
  and node state, custom User-Agent, filters, pre/post profile fields, manual
  refresh, due refresh, WorkScheduler background refresh, search/sort/cleanup,
  and real delay testing through the native bridge.
- Imports: subscription URLs, v2rayN plain/base64 text, Xray outbound/full JSON,
  Clash-style YAML proxy entries, WireGuard config files, QR codes, system share
  text, and share links for `vless://`, `vmess://`, `trojan://`, `ss://`,
  `socks://`, `socks4://`, `socks5://`, `http://`, `https://`,
  `wireguard://`, `hysteria2://`, `hy2://`, `anytls://`, and `tuic://`.
  External entry points — `hey://` deep links, system share, and QR scan —
  display the full target and require an explicit confirmation; none of them
  add a source or issue a request on their own. Confirming a subscription URL
  from any of these entry points saves only the source; downloading remains a
  separate, explicit action on the Subscriptions page. Imported nodes are
  deduplicated and do not replace the active selection while a connection is
  running.
- Exports: node share links for the protocols implemented by
  `formatOutboundJsonToShareLink`, QR generation on export/detail flows, routing
  rule JSON, and full local backup JSON.
- Xray runtime config: VPN SOCKS inbound for `tun2socks`, optional local
  SOCKS/HTTP proxy, proxy/direct/block outbounds, DNS settings, sniffing,
  mux, fragmentation/finalmask, Hysteria2 runtime shape, WireGuard IPv6
  handling, proxy chains, policy groups, metrics, and routing rules.
- Routing: traffic modes, domain strategy, user-authored rule sets, locked
  rules, process/port/network/protocol matchers, and rule import/export. The
  app ships no built-in region or country rule sets — every rule is written by
  the user.
- Per-app tunnel: allow/bypass mode plus a stored package-name list. HarmonyOS
  NEXT does not expose a general installed-app enumeration path to third-party
  apps, so the page lists a handful of common local apps as typing shortcuts
  and lets you enter any package name by hand. Nothing is ever selected for
  you, and the list is neither derived from nor tied to any destination.
- Network continuity and scenario automation: the VPN Extension records only
  actual underlying bearer changes and keeps the TUN/core running so new Xray
  connections can follow the system's new default network. An optional,
  user-authored list of trusted Wi-Fi SSIDs plus a cellular toggle can request
  automatic disconnect only; it never auto-connects. The app never classifies
  a network on its own — the list is entirely yours.
- VPN continuity state: the VPN Extension writes a credential-free health
  heartbeat in the shared app sandbox. If the UI process is recreated while the
  extension is still healthy, it adopts that existing session without starting
  a new connection. The extension also tears down its own residual VPN after
  two consecutive unhealthy core/TUN samples, without reconnecting. A stale or
  unhealthy session is left for manual reconnect; the app never reconnects
  after a manual disconnect.
- Data files and diagnostics: one-tap, user-initiated `geoip.dat` and
  `geosite.dat` checks from the maintained default release, published SHA-256
  verification, safe replacement/rollback, advanced user-supplied URLs with
  companion checksum files, and local file import. Runtime logs, core logs,
  optional speed display, persistent traffic totals, and an exit-IP check shown
  on the connection page (the built-in HTTPS endpoint reports the address only).
  English/Chinese plus additional language resources are included.
- Backup/restore: profile, subscription groups, settings, routing rules,
  per-app list, and custom asset URLs are exported as local JSON. Runtime
  traffic totals and control-card state are intentionally not migrated.

## Known Limits

- End-to-end VPN behavior still needs real-device coverage across more
  HarmonyOS NEXT devices and system versions. Some emulator/system images lack
  the VPN authorization component.
- Background timers, lock-screen continuity, UI-process recreation, and
  Wi-Fi/cellular handover still require target-device acceptance testing. The
  heartbeat improves truthful recovery but does not bypass HarmonyOS process or
  power-management limits.
- sing-box is a preview runtime in the app: it is packaged and selectable, but
  the app only starts it for VPN mode with a single supported outbound.

## Project Layout

```text
AppScope/                         App metadata, version, icon, label
entry/src/main/ets/               ArkTS UI, stores, services, routing, VPN code
entry/src/main/cpp/               N-API bridge and native library packaging
entry/src/main/cpp/prebuilt/      Packaged arm64-v8a .so files
libsingbox/                       Go wrapper for the sing-box c-shared library
scripts/                          App build/install/log scripts and native builds
docs/                             Native build and HarmonyOS notes
```

## Build And Install

**This repository ships source code only.** No prebuilt package is provided or
distributed, and the app has no self-update, package-download, or install path.
The user-initiated Geo data update is limited to Xray data files and never
downloads application packages. Build the app yourself with your own signing
key using the instructions below.


`build-profile.json5` is a local DevEco Studio file and is ignored by Git because
it may contain personal signing material. Before opening a fresh checkout, copy
`build-profile.example.json5` to `build-profile.json5`, then configure debug or
release signing in DevEco Studio on your own machine. Keep certificate paths, key
passwords, and other signing material local.

The app is configured for HarmonyOS target SDK `6.0.1(21)` and compatible SDK
`5.1.1(19)`. The project smoke-test script wraps `hvigorw` and `hdc`.

Build the signed HAP:

```bash
./scripts/device_vpn_smoke_test.sh build
```

If DevEco Studio is not in the default macOS location, pass the SDK/tool paths:

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
HVIGOR=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
./scripts/device_vpn_smoke_test.sh build
```

The expected output is:

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

Run the unit tests:

```bash
node "$HVIGORW" --mode module -p module=entry@default -p isLocalTest=true test --no-daemon
```

Before building, verify that the sparse checkout contains all packaged native
cores and that their AArch64 bridge symbols/TLSDESC ABI match the N-API bridge:

```bash
./scripts/verify_prebuilt_native.sh
```

If `prebuilt/arm64-v8a` is absent in a sparse checkout, restore it with
`git sparse-checkout add entry/src/main/cpp/prebuilt`.

Run the wording check before sending a patch:

```bash
./scripts/compliance_scan.sh
```

Useful device commands:

```bash
./scripts/device_vpn_smoke_test.sh targets
./scripts/device_vpn_smoke_test.sh doctor
./scripts/device_vpn_smoke_test.sh install
./scripts/device_vpn_smoke_test.sh logs
```

The target-device test matrix and evidence fields are in
[`docs/device-acceptance.md`](docs/device-acceptance.md). Items in that document
remain **not verified** until they are completed on the actual signed device.

## Native Libraries

`libheyvpn.so` is built from `entry/src/main/cpp/napi_init.cpp`. CMake then
copies the packaged Go shared libraries into the HAP native library directory:

| Library | Current role | Build status |
| --- | --- | --- |
| `libxray.so` | Main Xray runtime (libXray `v26.7.28`); exports a single `CGoInvoke` dispatch entry (plus `CGoFree`) for start/stop and ping. | Scripted by `scripts/build_libxray_ohos.sh`. |
| `libsingbox.so` | Optional sing-box runtime; exports start/stop/version/probe entry points. | Scripted by `scripts/build_libsingbox_ohos.sh`. |
| `libheytun2socks.so` | Default gvisor data-plane engine; relays the HarmonyOS VPN TUN fd into the core's local inbound. | Packaged and used; built by `scripts/build_tun2socks_ohos.sh`. |
| `libhevsocks5tun.so` | Alternative hev data-plane engine for the same relay, selectable in settings. | Packaged and used; built by `scripts/build_hev_ohos.sh`. |

The three Go libraries are built with an OpenHarmony-port Go toolchain (go1.26.5)
with `GOOS=openharmony`; `libhevsocks5tun.so` is plain C and cross-compiles with the
DevEco OHOS clang, so it needs no Go toolchain. Keep the Go toolchain outside the
repository; `hvigor clean` removes the repository `build/` directory.

## License

Copyright (C) 2026 popsiclelmlm

Hey is released under the [GNU General Public License v3.0](LICENSE). You
may use, modify, and redistribute it, including commercially, as long as
derivative works stay under GPL-3.0 and the corresponding source is made
available.

The project packages Xray-core (MPL-2.0), builds on libXray (MIT), packages
sing-box (GPL-3.0-or-later), and uses two TUN adapters: one based on
xjasonlyu/tun2socks (MIT) and one on heiher/hev-socks5-tunnel (MIT). These
components keep their own licenses; see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
