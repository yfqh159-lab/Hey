<div align="center">

<img src="design/app-icon/startIcon.png" alt="Hey" width="160" height="160" />

# Hey

**面向 HarmonyOS NEXT 的原生网络隧道与协议调试客户端。服务器由你自己提供。**

<p>
  <img src="https://img.shields.io/badge/platform-HarmonyOS%20NEXT-0A0A0A" alt="platform" />
  <img src="https://img.shields.io/badge/target-6.0.1%20(21)-1E88E5" alt="target SDK 6.0.1(21)" />
  <img src="https://img.shields.io/badge/core-Xray%20%2B%20sing--box-6E56CF" alt="Xray and sing-box cores" />
  <img src="https://img.shields.io/badge/version-1.3.5-E85D04" alt="version 1.3.5" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-3DA639" alt="license GPL-3.0" /></a>
</p>

[English](README.md) · 简体中文

</div>

---

Hey 是一个用 ArkTS 写的 HarmonyOS NEXT 应用。当前代码接入了 Stage 模型、
VPN Extension Ability、服务卡片、WorkScheduler、ScanKit 扫码、桌面快捷方式、
`hey://` 深链、系统分享导入，以及一层负责加载原生传输内核的 N-API 桥。

项目的主运行路径是 Xray。sing-box 也已经随包打入，并且可以在设置里切换，但它在应用里的
能力范围目前比 Xray 窄，属于预览路径。

## 设计原则

> **不主观提供任何用途，允许用户自行摸索。**

每一处改动都对照同一个问题：*这是应用替用户做的决定，还是用户自己做的决定？*
支持一种协议、解析一种配置格式、暴露一个传输参数，都属于用户自己做的决定，
保留并且要让它好用；预设路由规则、服务器/配置源、自动选择、按地区分流的硬编码逻辑，
都属于应用替用户做的决定，不实现。数据文件页只有一个窄范围例外：用户明确点击后，
应用可检查维护中的默认 Geo 发布版本，并用发布方提供的 SHA-256 同时校验两个核心文件。

落到代码上：仓库不内置任何服务器地址、配置源地址、规则集，也没有任何以国家或地区
命名的预设。Geo 文件不会随包提供或定时更新，只有用户点击“检查 Geo 更新”才会下载。
延迟测试地址默认留空；远程 DNS 默认使用经代理访问的 IP 形式 DoH，避免回落物理网络的系统
解析器，并可在高级设置替换；其他 DNS 字段留空。出口 IP 检测使用仅返回公网地址的 HTTPS
默认端点，只在用户主动连接代理后请求；高级设置可关闭或替换。深链、系统分享、扫码和剪贴板
这类外部入口一律先展示协议、数量或掩码端点等脱敏摘要，等用户明确确认后才添加；完整节点链接、
UUID、密码和订阅 Token 默认不显示，也不会因预览发起请求。

不会实现的完整清单见 [`CONTRIBUTING.md`](CONTRIBUTING.md)，
其中的措辞部分由 `./scripts/compliance_scan.sh` 做机器校验。

## 当前状态

Xray 路径是这个仓库里的主路径。它支持 VPN 模式和仅代理模式，可以从当前节点/配置生成运行时
Xray 配置，启动和停止 HarmonyOS VPN Extension，并通过随包的 `libheytun2socks.so` 转发
VPN 流量。仅代理模式不会创建 TUN，而是提供可配置的本地 SOCKS 端口及用户可见的 HTTP
`18081` 端口；Hey 自身的 Geo、订阅和出口 IP 请求使用独立、无认证且仅回环监听的
内部 HTTP `18084`，不会被用户代理鉴权或局域网共享影响。只有用户显式开启代理共享时，
用户可见的 SOCKS/HTTP 端口才监听回环以外地址。

全新安装默认使用 VPN/TUN 模式，并且不会同时额外开启用户可见的 `18080/18081` 代理入口；
选择“本地代理模式”后才会固定提供 SOCKS/HTTP。旧版本中用户已经明确开启的附加本地入口会保留。
本地代理模式不会改写 HarmonyOS 的全局代理设置，也不会自动接管未配置代理的其他应用。

当前两个内核共用的 VPN 数据面是：

```text
HarmonyOS VPN TUN fd
  -> libheytun2socks.so（gvisor，默认）或 libhevsocks5tun.so（hev）
  -> 127.0.0.1:18082（本地 SOCKS/mixed 入站）
  -> Xray 或 sing-box outbound
```

也就是说，应用现在不会把 TUN fd 直接交给 Xray 或 sing-box。为什么要这样做、OpenHarmony Go
fork 和 TLSDESC 构建路线怎么来的，见
[`docs/harmonyos-go-tls-wall.md`](docs/harmonyos-go-tls-wall.md)；原生库构建说明见
[`docs/building-native-cores.md`](docs/building-native-cores.md)；
让 `::/0` 真正进 TUN 的 IPv6 路由写法见
[`docs/ipv6-leak-prevention.md`](docs/ipv6-leak-prevention.md)。

sing-box 路径目前支持 VPN 模式下的单个转换后 outbound。转换器覆盖 VLESS、VMess、Trojan、
Shadowsocks、AnyTLS、TUIC 和 Hysteria2，并处理基础的 tcp/ws/grpc/http/httpupgrade 传输以及
none/tls/reality 安全层。它还不支持完整配置、代理链、策略组、仅代理模式、WireGuard、
SOCKS、HTTP，或 sing-box 自身的细粒度流量统计。

## 代码里已经实现的能力

- HarmonyOS 入口：`EntryAbility`、`HeyVpnAbility`、`ControlCardAbility`、
  `SubscriptionUpdateWorkAbility`、桌面快捷方式、`hey://` 路由和 `text/plain` 系统分享导入。
- 页面：服务器列表、节点详情/编辑、导入、JSON 导入、高级出站、订阅、订阅详情/编辑、路由、
  设置、语言、分应用隧道、网络场景、数据文件、日志、扫码、备份、导出和关于。
  日常添加页只展示链接/扫码导入与单节点协议表单；完整 JSON、代理链和策略组的新建入口已隐藏，
  底层仍兼容既有配置。
- 节点与订阅：多订阅分组、当前分组和节点状态、自定义 User-Agent、过滤、前置/后置配置字段、
  手动刷新、到期刷新、WorkScheduler 后台刷新、搜索/排序/清理，以及通过原生桥做真实延迟测试。
- 导入：订阅 URL、v2rayN 明文/BASE64 文本、Xray outbound/full JSON、Clash 风格 YAML 节点、
  WireGuard 配置文件、二维码、系统分享文本，以及 `vless://`、`vmess://`、`trojan://`、
  `ss://`、`socks://`、`socks4://`、`socks5://`、`http://`、`https://`、`wireguard://`、
  `hysteria2://`、`hy2://`、`anytls://`、`tuic://` 分享链接。
  `hey://` 深链、系统分享、扫码和剪贴板会先展示协议、数量或掩码端点等脱敏摘要并等待用户确认，
  不会展示完整凭据、自行添加配置源或发起请求。确认这些入口收到的订阅 URL 时只保存来源，
  下载仍需用户前往订阅页另行手动触发。外部入口导入节点时会去重，已有连接运行中不会
  因导入而悄悄切换当前节点。
- 导出：`formatOutboundJsonToShareLink` 已实现协议的节点分享链接、节点详情/导出页二维码、
  路由规则 JSON，以及本地完整备份 JSON。
- Xray 运行时配置：给 `tun2socks` 用的 VPN SOCKS 入站、可选本地 SOCKS/HTTP 代理、
  proxy/direct/block 出站、DNS、嗅探、mux、fragment/finalmask、Hysteria2 运行时形态、
  WireGuard IPv6 处理、代理链、策略组、metrics 和路由规则。
- 路由：流量模式、域名策略、用户自行编写的规则集、锁定规则、
  process/port/network/protocol 匹配，以及规则导入导出。应用不内置任何地区或国家规则集，
  全部规则由用户自行编写。
- 分应用隧道：支持隧道/直出模式和持久化包名列表。HarmonyOS NEXT 不向三方应用开放
  已安装应用的全局枚举接口，所以页面提供了少量常用本地应用作为输入快捷方式，
  同时支持手动填写任意包名。应用不会替你勾选任何一项，这份快捷列表也与目的地无关。
- 网络连续性与场景自动化：应用在自身生命周期内观察底层承载变化并重新验证出口；VPN
  Extension 保持 TUN/核心运行，让 Xray 新建连接跟随系统新的默认网络。用户自己列出的可信
  Wi-Fi SSID 与蜂窝开关可选择触发自动断开，但绝不自动连接；关闭自动化仍只观察、不连断，
  应用不会自行判定网络性质，名单完全由用户决定。
- VPN 连续性状态：VPN Extension 会在共享应用沙箱写入不含节点凭据的健康心跳。若主界面进程
  被回收而扩展仍健康，新进程只接管现有会话，不会另起连接；扩展连续两次检测到核心或 TUN
  不健康时会自行拆除残留 VPN、等待用户手动重连，用户主动断开后绝不自动连回。
- 数据文件与诊断：用户手动点击即可检查默认发布版本、校验并安全替换 `geoip.dat` 与
  `geosite.dat`，失败会回滚；高级入口支持带同名 `.sha256sum` 的自定义地址，也可导入本地文件。
  TUN 运行时这些应用自身请求通过仅回环的内部 HTTP 入口进入当前节点，不要求开启用户可见
  HTTP 代理。同时提供运行日志、Core 日志、可选速度显示、持久累计流量，以及在连接页显示的
  出口 IP 检测（内置 HTTPS 端点只回报地址本身），并包含中英文和更多语言资源。
- 备份恢复：本地 JSON 覆盖 profile、订阅分组、设置、路由规则、分应用列表和自定义资源 URL。
  运行流量累计和服务卡片状态属于设备本地状态，代码里刻意不迁移。

## 已知限制

- VPN 闭环仍需要更多 HarmonyOS NEXT 真机和系统版本验证。部分模拟器或系统镜像没有 VPN 授权组件。
- 后台计时器、锁屏连续性、主界面进程重建、Wi-Fi/蜂窝切换仍需在目标真机验收。健康心跳用于
  改善状态真实性和恢复控制权，不会绕过 HarmonyOS 的进程与省电限制。
- sing-box 是预览运行路径：它已经随包、可选择、可启动，但应用层只在 VPN 模式下用它跑一个已支持的
  outbound。

## 项目结构

```text
AppScope/                         应用元数据、版本、图标和名称
entry/src/main/ets/               ArkTS UI、存储、服务、路由和 VPN 代码
entry/src/main/cpp/               N-API 桥和原生库打包
entry/src/main/cpp/prebuilt/      随包的 arm64-v8a .so 文件
libsingbox/                       sing-box c-shared 库的 Go wrapper
scripts/                          应用构建/安装/日志脚本和原生库构建脚本
docs/                             原生构建与 HarmonyOS 相关说明
```

## 构建与安装

**本仓库只提供源代码。** 不提供也不分发任何预编译安装包，应用内没有自身更新、安装包下载或
安装入口。用户主动触发的 Geo 更新只处理 Xray 数据文件，绝不会下载应用安装包。请按下面的说明
自行构建，并用你自己的签名安装。


`build-profile.json5` 是 DevEco Studio 的本地配置文件，方便个人调试，因此不会提交到仓库。
首次打开新拉取的工程前，请先把 `build-profile.example.json5` 复制为 `build-profile.json5`，然后在
DevEco Studio 里配置本机的调试或发布签名。证书路径、密钥密码等签名内容只保留在本地。

当前构建配置里的 target SDK 是 `6.0.1(21)`，compatible SDK 是 `5.1.1(19)`。
项目里的烟测脚本封装了 `hvigorw` 和 `hdc`。

Linux 构建机不必安装图形界面 IDE，可以登录华为开发者联盟的
[Command Line Tools 下载中心](https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos)，
下载与 **DevEco Studio 6.0.1 Release / HarmonyOS SDK 6.0.1(21)** 配套的 Linux 工具包，并按
[官方命令行工具说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-get)
核对发布方校验值后解压。不要使用公开归档里的 2.x/3.x 旧工具构建本项目，也不要从非官方镜像
取得 SDK。下载页面需要开发者账号时应由用户正常登录，构建脚本不会绕过认证或代存账号凭据。

解压后至少把 `command-line-tools/bin` 加入本次终端的 `PATH`；若工具不在标准位置，再显式设置
`DEVECO_SDK_HOME`、`HVIGOR` 和 `HDC`。先在下载页/工具包元数据核对 API 21 版本，再运行
`doctor` 确认脚本识别到了对应 SDK 和工具路径；不要把 OpenHarmony 社区 SDK 或历史版本混入。

构建签名 HAP：

```bash
./scripts/device_vpn_smoke_test.sh build
```

脚本优先使用 `PATH` 中的 `hvigorw` / `hdc`，macOS 上也会探测 DevEco Studio 默认安装目录。
其他安装位置可显式传入 SDK、hvigor 和 hdc 路径：

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
HVIGOR=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc \
./scripts/device_vpn_smoke_test.sh build
```

Windows 已安装 DevEco Studio 时不需要额外 MCP 才能运行构建。PowerShell 可直接调用 DevEco 自带
工具；若从 WSL 协作，建议把用于编译的工作树放在 Windows 本地卷，避免 `ohpm` 在 UNC/WSL 路径
创建依赖链接时阻塞。以下路径按实际安装目录调整：

```powershell
$DevEcoHome = 'D:\Program Files\DevEco Studio'
$env:DEVECO_SDK_HOME = "$DevEcoHome\sdk"
$env:JAVA_HOME = "$DevEcoHome\jbr"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
& "$DevEcoHome\tools\ohpm\bin\ohpm.bat" install --all
& "$DevEcoHome\tools\hvigor\bin\hvigorw.bat" `
  --mode module -p module=entry@default -p isLocalTest=true test --no-daemon --stacktrace
```

仓库也提供 Windows 烟测入口；它会额外检查 Hypium 汇总，不能只凭 Hvigor 的
`BUILD SUCCESSFUL` 把断言失败误报为通过：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\device_vpn_smoke_test.ps1 doctor
powershell -ExecutionPolicy Bypass -File .\scripts\device_vpn_smoke_test.ps1 test
powershell -ExecutionPolicy Bypass -File .\scripts\device_vpn_smoke_test.ps1 build
powershell -ExecutionPolicy Bypass -File .\scripts\device_vpn_smoke_test.ps1 targets
```

`test` 默认 120 秒后终止本轮 Hvigor 进程树，防止 Ark 本地预览运行时崩溃后命令永久挂住；低性能
机器可传 `-TestTimeoutSeconds 300`。超时或缺少新的 Hypium 汇总都按失败处理。

完整安装包仍应在 DevEco Studio 中配置用户自己的签名后构建；不要把本地证书、密码或
`build-profile.json5` 提交到仓库。

Linux 命令行工具的路径示例（以实际解压结构为准）：

```bash
export PATH=/绝对路径/command-line-tools/bin:$PATH
DEVECO_SDK_HOME=/绝对路径/command-line-tools/sdk \
HVIGOR=/绝对路径/command-line-tools/bin/hvigorw \
HDC=/绝对路径/command-line-tools/sdk/default/openharmony/toolchains/hdc \
./scripts/device_vpn_smoke_test.sh doctor
```

先运行 `./scripts/device_vpn_smoke_test.sh doctor` 可一次查看 Node.js、unzip、hvigor、SDK、本地签名配置、
签名 HAP、hdc 设备及系统 VPN 授权组件；缺少多项时会全部列出并以非零状态结束，而不是只报告
第一个缺失工具。预检不仅检查 `build-profile.json5` 是否存在，也会拒绝原样复制示例后仍为空的
`signingConfigs`；不会输出证书路径、密码或其他签名内容。

构建产物默认位于：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

跑单元测试：

```bash
./scripts/device_vpn_smoke_test.sh test
```

在没有 Harmony SDK 时，也可以使用标准 Go 1.23.4 或更高版本检查 sing-box wrapper 的代表性
配置和 tun2socks 适配器包：

```bash
./scripts/device_vpn_smoke_test.sh go-test
```

该命令以只读模块模式运行，不会重建或覆盖随包 `.so`。它只验证平台无关 Go 代码，不能替代
OpenHarmony cgo/TLSDESC 交叉编译或真机 TUN 测试。Go 不在 `PATH` 时可传入
`GO_BIN=/绝对路径/go`。

`build` 和 `test` 会先运行 `verify_source.sh` 的完整源码门禁（包括工程骨架、合规、原生产物、
网络调用点、运行模式隔离、VPN 自包排除和翻译资源）；`build` 随后还会确认签名 HAP 内确实包含
`libheyvpn.so`、Xray、sing-box 和两套 TUN 适配器。若本机签名配置生成了不同路径的
产物，脚本会显示预期路径；此时可用 `HAP=/绝对路径/文件.hap` 指定实际文件。

构建前先确认稀疏检出中包含全部随包原生核心，并检查 AArch64 桥接符号及 TLSDESC ABI
是否与 N-API 桥一致：

```bash
./scripts/verify_prebuilt_native.sh
```

若稀疏检出缺少应用清单、资源或 `prebuilt/arm64-v8a`，运行
`git sparse-checkout add AppScope entry` 恢复完整的可构建应用目录。`verify_source.sh`
会拒绝“Git 状态看似干净、但构建必需文件仍被 sparse checkout 跳过”的检出，避免到
Hvigor 构建阶段才发现缺件。

提交前跑一遍措辞校验：

```bash
./scripts/compliance_scan.sh
```

一次运行所有不依赖 Harmony SDK 或真机的源码检查：

```bash
./scripts/verify_source.sh
```

常用真机命令：

```bash
./scripts/device_vpn_smoke_test.sh targets
./scripts/device_vpn_smoke_test.sh doctor
./scripts/device_vpn_smoke_test.sh install
./scripts/device_vpn_smoke_test.sh logs
```

目标真机的测试矩阵与证据记录字段见
[`docs/device-acceptance.md`](docs/device-acceptance.md)。只有在实际签名设备上完成后，里面的项目
才能标记为“已验证”；当前不得把静态检查或构建结果当作真机通过。
按阶段归纳的改动记录和当前验证边界见
[`docs/implementation-record.md`](docs/implementation-record.md)。

## 原生库

`libheyvpn.so` 由 `entry/src/main/cpp/napi_init.cpp` 构建。CMake 会把随包的 Go 共享库拷进
HAP 原生库目录：

| 库 | 当前作用 | 构建状态 |
| --- | --- | --- |
| `libxray.so` | 主 Xray 运行时（libXray `v26.7.28`），只导出单一分发入口 `CGoInvoke`（外加 `CGoFree`），用于启动、停止和测速。 | `scripts/build_libxray_ohos.sh` 已脚本化。 |
| `libsingbox.so` | 可选 sing-box 运行时，导出启动、停止、版本和探针入口。 | `scripts/build_libsingbox_ohos.sh` 已脚本化。 |
| `libheytun2socks.so` | 默认的 gvisor 数据面引擎，把 HarmonyOS VPN TUN fd 转发到内核本地入站。 | 已随包并使用，由 `scripts/build_tun2socks_ohos.sh` 构建。 |
| `libhevsocks5tun.so` | 同一条转发链路的另一套 hev 数据面引擎，可在设置里切换。 | 已随包并使用，由 `scripts/build_hev_ohos.sh` 构建。 |

三个 Go 库都用带 OpenHarmony 端口的 Go 工具链（go1.26.5）+ `GOOS=openharmony` 编译；
`libhevsocks5tun.so` 是纯 C，用 DevEco 自带的 OHOS clang 交叉编译，不需要 Go 工具链。
Go 工具链建议放在仓库外面；
`hvigor clean` 会删除仓库内的 `build/` 目录。

## 许可协议

版权所有 (C) 2026 popsiclelmlm

Hey 基于 [GNU 通用公共许可证 v3.0（GPL-3.0）](LICENSE) 开源。你可以自由使用、修改和再分发
（包括商用），但衍生作品须同样以 GPL-3.0 开源，并向接收者提供对应源码。

项目打包了 Xray-core（MPL-2.0），基于 libXray（MIT）构建，同时打包 sing-box
（GPL-3.0-or-later），并使用两套 TUN 适配层：基于 xjasonlyu/tun2socks（MIT）
和 heiher/hev-socks5-tunnel（MIT）。这些组件保留各自的协议，详见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。
