# Hey 源码审计结论

> 审计日期：2026-10-22  
> 审计分支：`codex/p0-vpn-mainline`  
> 审计基线：`65bdea3`，审计时 HEAD 为 `10b3aa6`  
> 说明：本文件只记录源码、仓库和可在当前环境运行的静态检查结论，不把它们写成构建、模拟器或真机结果。

## 结论

本轮要求的源码审计已完成。目标功能均已有可继续验证的实现路径，没有发现需要推翻现有架构或替换 Xray 主内核的问题。当前默认仍是单节点、单跳；TUN/VPN 与本地代理是两个可选运行模式，本地代理不会创建 TUN，也不会自动接管未配置代理的应用。

本轮审计期间已把确认的问题拆成小提交修复，包括 VPN 会话身份与持久状态、真实 SOCKS 健康端口、完整配置的 TUN 入站能力、扫码/分享批量预览校验，以及全局/规则/直连模式隔离。审计结束时工作树没有未提交源码改动。

仍不能从源码得出的结论是：VPN 授权、真实 TUN 转发、DNS/IPv6 防泄漏、锁屏与后台连续性、Wi-Fi/蜂窝切换、ChatGPT/其他应用流量，以及设备上 Network Kit 的重定向行为。这些项目必须按 [`device-acceptance.md`](device-acceptance.md) 在目标设备留证。

## 审计范围与结果

| 范围 | 结论 | 主要证据 |
| --- | --- | --- |
| 仓库与上游 | 当前 HEAD 包含 fork `origin/main` 和 `upstream/main` 的全部提交；分别领先 496 和 498 个提交，没有待合入的远端提交 | 分别刷新两个 remote 后执行 `git rev-list --left-right --count` |
| 参考客户端 | v2rayNG 已位于工作区 `reference/v2rayNG`，审计版本 `118cf5b`（2.3.12）；本轮仅参考交互和运行模式，没有复制 Android UI 或代码 | 本地只读对照；Hey 保持 ArkUI/ArkTS 实现 |
| Xray/VPN 主链 | Xray 仍是主内核；系统 VPN 数据面为 `TUN -> tun2socks/HEV -> 已验证的回环 SOCKS -> Xray`。启动必须等核心 SOCKS 入口和 Extension 同会话健康状态；停止必须确认核心、TUN 适配器和系统 VPN 清理 | `ConnectionController.ets`、`HeyVpnAbility.ets`、`VpnRuntimeStateStore.ets`、`VpnStartCancellationStore.ets` |
| 可选 TUN | TUN/VPN 与本地代理独立选择。本地代理只启动 Xray SOCKS/HTTP，不创建 VPN/TUN；TUN 模式不依赖用户可见的本地代理开关 | `SettingsController.ets`、`XrayConfig.ets`、`ConnectionController.ets` |
| 路由与 DNS | 全局模式忽略用户分流并最终代理，直连模式忽略用户分流并最终直连，规则模式才应用自定义规则；TUN DNS 始终由核心接管，关闭 IPv6 时有阻断规则 | `XrayConfig.ets`、`SingboxConfig.ets`、`VpnConstants.ets` |
| 节点导入 | 相机、相册、剪贴板和手动输入均先解析并显示脱敏预览，确认后才保存；无效、重复、取消、权限错误、批量部分无效和页面退出后的迟到结果均有处理 | `Scanner.ets`、`QrScan.ets`、`ShareLinkParser.ets`、`SubscriptionManager.ets`、`SubscriptionStore.ets` |
| 首页与状态 | 首页为节点列表，可选节点并使用统一启停动作；运行状态以同一共享控制器为准，后台 VPN 必须由持久会话和实际 SOCKS 探针接管，不能只凭旧 UI 状态恢复 | `Index.ets`、`RuntimeController.ets`、`RuntimePanel.ets` |
| Geo 更新 | 内置可信发布源，无需普通用户输入 URL；两个核心文件分别校验声明大小、protobuf 外形和 SHA-256 后成组安装。事务状态、提交标记、备份、回滚及冷启动恢复均在核心初始化前执行 | `GeoAssets.ets`、`AssetsController.ets`、`EntryAbility.ets`、`GeoCoreReadiness.ets` |
| 后台与切网 | VPN Extension 独立写健康心跳并轮询底层承载；真实承载变化时重载当前核心但保留 VPN/TUN。连续异常会清理且不重连；手动停止写入持久取消栅栏 | `HeyVpnAbility.ets`、`NetworkSceneManager.ets`、`NetworkProbe.ets` |
| 存储与并发 | 设置、节点/订阅档案、当前 Profile、VPN 状态和控制卡状态都有串行或事务化写入；关键异步操作有代际隔离和外层截止时间 | `storage/`、`SubscriptionsController.ets`、`RuntimeController.ets` |
| 日志与隐私 | 应用日志入内存前、诊断日志写盘前统一脱敏 URL、UUID、密码/Token/私钥、主机和 IP；外部导入原文不进入可截图预览或日志 | `DiagnosticRedaction.ets`、`DiagnosticLog.ets` |
| 原生件与许可 | 四个随包 `.so` 均为 AArch64；Xray、sing-box 和 Go tun2socks 含 OpenHarmony TLS/TLSDESC 证据，桥接符号符合脚本约束；第三方许可和构建来源已记录 | `verify_prebuilt_native.sh`、`THIRD-PARTY-NOTICES.md`、`building-native-cores.md` |

## 审计发现但不能在当前环境闭环的边界

### 1. Network Kit 自动重定向

当前 OpenHarmony NetStack 的 ArkTS HTTP 实现会设置 libcurl `CURLOPT_FOLLOWLOCATION=1`，而公开的 `HttpRequestOptions` 没有关闭自动重定向的选项。应用能通过 `headersReceive` 在响应完成后拒绝 HTTP 降级、跨出白名单或超限的跳转，但不能证明在拒绝前从未连接过该目标。

NetStack 源码没有启用 `CURLOPT_UNRESTRICTED_AUTH`，按 libcurl 默认规则，显式 `Authorization` 不应发送到不同主机；这仍需在目标系统版本用受控服务器日志或抓包确认。URL 路径/查询中的 Token 若被服务端放入降级 `Location`，则可能在应用事后拒绝前已经被请求。默认 Geo 安装仍受可信 URL、发布声明和 SHA-256 保护，不会把未校验内容装入核心，但“未先联系非法跳转目标”不能由现有 ArkTS API 保证。

发布前有两条可选闭环路径：在 native 层提供禁用自动跳转、逐跳校验后再请求的最小 HTTPS 下载器；或明确收紧带凭据的自定义 URL 能力。不能仅把现有事后校验描述为同步阻断。

### 2. “数据面运行”与“外网已验证”是两个状态

当前 `RUNNING` 表示系统 VPN、TUN 适配器和本地核心 SOCKS 数据入口已经就绪。出口 IP HTTPS 检查随后异步执行，失败会清空出口并记录错误，但不会自动拆掉可能只是暂时断网的健康隧道；完整 Xray 配置和用户关闭出口端点时也不会执行该检查。

因此设备验收必须同时记录“隧道运行”和“HTTPS/出口验证通过”，不能把连接按钮变色当作 VPS 或 ChatGPT 已可用。若后续产品文案仍使用单一“已连接”，应改成能区分“隧道已启动、正在验证、已验证、验证失败”的显示，而不是伪造成功或因单个检测站不可达自动断开。

### 3. 后台连续性受系统约束

源码只使用官方 VPN Extension、WorkScheduler、通知和生命周期回调，没有越权保活。Extension 自身可在 UI 退出后维持和清理数据面，但系统是否保留它、锁屏多久后调度定时器、以及兼容环境应用是否进入 VPN，只能由目标机型和系统版本验证。

### 4. 当前环境缺少构建和设备条件

`device_vpn_smoke_test.sh doctor` 已确认 Node.js 和 unzip 可用，但缺少 `hvigorw`、Harmony SDK、`build-profile.json5` 签名配置、签名 HAP 和 `hdc`。因此本轮没有运行 ArkTS LocalUnit、HAP 构建、模拟器或真机测试。

## 已执行检查

- `bash scripts/verify_source.sh`：通过；包含项目骨架、HTTP 调用白名单、运行模式隔离、VPN 会话/清理、Geo 事务、扫码确认、日志脱敏、翻译一致性等门禁。
- `bash scripts/verify_prebuilt_native.sh`：通过；四个 AArch64 原生库、桥接符号及 Go OpenHarmony TLS/TLSDESC 核验通过。
- `bash scripts/compliance_scan.sh`：通过；未发现内置私人节点、地区策略、未经批准的规则源或用途宣称。
- `bash scripts/device_vpn_smoke_test.sh doctor`：按预期失败，并完整列出当前环境缺少的构建、签名和设备依赖。
- `git diff --check`：应在每次审计修复提交前执行；本审计文档提交前再次执行。

## 下一阶段入口

源码审计结束后，不再继续用静态推理代替运行证据。下一步先补齐 DevEco/Harmony SDK 与签名配置，依次执行源码门禁、LocalUnit、HAP 构建和模拟器 UI/导入检查；随后用真机完成 `device-acceptance.md` 中的 VPN/TUN、DNS/IPv6、锁屏后台、承载切换、出口及 AI 应用验收。
