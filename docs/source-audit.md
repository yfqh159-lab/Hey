# Hey 静态源码审计结论

> 审计日期：2026-10-22
> 审计分支：`codex/p0-vpn-mainline`
> 远端基线：fork `origin/main` 为 `65bdea3`，上游 `upstream/main` 为 `3371128`
> 实现审计点：`02de88d`
> v2rayNG 只读参考版本：`118cf5b`
> 范围声明：本文件只记录仓库、源码和当前环境可运行的静态检查结论，不把它们写成编译、模拟器或真机结果。

## 结论

本轮要求的静态审计已经闭环：对 VPN/Xray 主链、可选 TUN、本地代理、导入、Geo、后台恢复、跨进程状态、外部输入、持久化、控制卡、原生桥接和隐私日志进行了逐项检查；已确认且能由源码闭环的问题均已修复并提交。目前没有继续依靠静态推理就能确认的阻断性缺口，也没有发现需要替换 Xray、重写客户端或引入代理链的理由。

产品模式保持为两种明确选择：

- **TUN/VPN 模式**：创建系统 VPN，数据面为 `TUN -> tun2socks/HEV -> 回环 SOCKS -> Xray`，用于接管系统应用流量。
- **本地代理模式**：只提供本机 SOCKS/HTTP 入口，不创建 TUN；只有显式配置该代理的应用才会使用它。

这里的 TUN 是用户可选择的运行模式，不是所有连接都必开的选项；TUN 模式内部必须存在的 tun2socks/HEV 转发也不是“多跳代理链”。

静态闭环不等于产品验收通过。ArkTS/Native 编译、VPN 授权、真实转发、DNS/IPv6、防回环、后台锁屏、Wi-Fi/蜂窝切换和 ChatGPT 等应用流量必须进入 DevEco、模拟器及真机阶段验证。

## 审计范围与结论

| 范围 | 静态结论 | 主要证据 |
| --- | --- | --- |
| 仓库与远端 | 已刷新 fork 和上游；当前分支分别领先 504、506 个提交，缺失提交数均为 0。工作在独立分支进行，未推送、未改写历史 | `git fetch --prune`、`git rev-list --left-right --count` |
| 参考客户端 | v2rayNG 已完整拉取到 `reference/v2rayNG`；仅对照交互和运行模式，没有复制 Android UI、图标或代码 | 本地参考提交 `118cf5b` |
| Xray/VPN 主链 | Xray 仍是主内核；VPN 启动要求核心 SOCKS、TUN 引擎和 Extension 同会话健康，停止要求核心、TUN 与系统 VPN 均清理完成 | `ConnectionController.ets`、`HeyVpnAbility.ets`、`VpnRuntimeStateStore.ets` |
| TUN 可选性 | TUN/VPN 和本地代理互斥且可选；本地代理不创建 VPN，TUN 使用独立内部回环入口，不依赖用户可见代理开关 | `SettingsController.ets`、`XrayConfig.ets`、`ConnectionController.ets` |
| 原生 TUN 生命周期 | HEV 启动增加稳定窗口，立即退出会报告失败；gVisor/HEV 超时未退出不再伪报停止成功，pending 栅栏阻止重叠实例 | `entry/src/main/cpp/xray_napi.cpp` |
| 停止与状态真值 | 会话 ID、持久取消记录、心跳和清理结果共同约束 UI/卡片状态；手动停止后不自动重连，清理未完成不写入虚假 idle/cleanup complete | VPN 状态、停止标志及运行控制器相关 store/controller |
| 路由、DNS、IPv6 | 全局、规则、直连模式隔离；TUN DNS 由核心接管；关闭 IPv6 时有对应阻断；完整配置会检查可用回环 SOCKS 能力 | `XrayConfig.ets`、`SingboxConfig.ets`、`VpnConstants.ets` |
| 后台与换网 | Extension 独立维护健康和承载检测；换网在同一会话内有界重载核心，连续异常会清理但不会替用户自动建立新连接 | `HeyVpnAbility.ets`、`NetworkSceneManager.ets`、`NetworkProbe.ets` |
| 节点导入 | 相机、相册、剪贴板、分享和手动输入均先解析/脱敏预览，经确认后保存；无效、重复、取消、权限错误和混合批量内容有边界处理。API 12+ 剪贴板读取统一由系统 `PasteButton` 的单次用户授权触发，不申请宽泛 `READ_PASTEBOARD` 权限 | `Scanner.ets`、`QrScan.ets`、`ShareLinkParser.ets`、订阅存储 |
| 外部输入 | Deep Link、Want、控制卡参数、分享文本、订阅响应、配置文本和诊断内容均设置长度/数量上限；超限数据不会整块进入 AppStorage 或持久层 | Ability、Want、导入与共享控制代码；对应 LocalUnit 用例 |
| 节点/订阅存储 | 原始记录和字段均有限额；非空但全损坏的主数据不能掩盖有效备份；批量解析和规范化工作量有界 | `SubscriptionStore.ets`、数据库与调度索引 |
| 跨进程状态 | VPN 状态、停止标志、流量、控制卡状态均限制原始大小并验证结构；损坏主记录可回退备份，损坏临时工件不会永久阻塞后续写入 | `VpnRuntimeStateStore.ets`、`NetSceneStopStore.ets` 等 |
| 控制卡 | formId 和节点 ID 有边界；持久化动作 URI 只允许固定 `hey://start/stop/toggle/scan`，不能把任意 URI 变成可执行卡片动作 | FormExtension/控制卡服务及状态存储 |
| 后台订阅任务 | WorkScheduler 回调进程内单飞；重复投递不会在一个永久 pending 任务上无限叠加；旧 groupId 输入受限 | 后台订阅 worker 与调度存储 |
| Geo 更新 | 内置可信 HTTPS 来源，无需普通用户输入 URL；双文件下载经版本/大小/protobuf/SHA-256 校验和事务替换，失败回滚且保留旧文件；核心加载前恢复中断事务 | `GeoAssets.ets`、`AssetsController.ets`、`GeoCoreReadiness.ets` |
| 出口与延迟 | 运行态和外网验证分离；出口只接受有界 HTTPS 响应和公网 IP，失败清除旧结果但不会因单个检测站暂时不可达拆毁健康隧道 | 网络探针、Runtime controller/panel |
| 日志与隐私 | URL 凭据、UUID、密码、Token、私钥、主机/IP 等在 UI/诊断持久化前脱敏；日志数量和单条长度有界 | `DiagnosticRedaction.ets`、`DiagnosticLog.ets` |
| 原生二进制 | 四个随包 `.so` 有固定 SHA-256 清单；脚本验证精确文件集、AArch64、所需桥接符号和 OpenHarmony TLSDESC | `prebuilt/arm64-v8a/SHA256SUMS`、`verify_prebuilt_native.sh` |
| 权限、敏感信息、许可 | 未发现私人节点、凭据、签名材料或额外越权保活；直接使用的第三方组件和构建来源有记录，未移植 v2rayNG 代码 | manifests、合规扫描、`THIRD-PARTY-NOTICES.md` |

## 本轮静态修复提交

- `1bc230b`：相对 HTTP 重定向链解析。
- `b6bdd5c`：外部配置输入加固。
- `9cdc60e`：外部输入及诊断持久化限额。
- `9693efe`：拒绝结构损坏且会掩盖备份的数据。
- `e1ae871`：订阅与配置处理工作量限额。
- `4683061`：VPN 取消历史限额。
- `85e230a`：持久化及交互输入边界。
- `d11080c`：剩余存储、Want、控制卡、后台任务、TUN 生命周期及原生校验缺口。
- `02de88d`：将六处剪贴板读取入口迁移到系统 `PasteButton` 临时授权，并删除始终返回成功的伪权限辅助函数；路由规则仍在读取后等待用户确认才写入。

这些提交之前的主链、扫码、运行模式、Geo 事务和状态修复仍保留在同一分支；上述列表只标识本次最后一轮安全审计的收口提交。

## 静态分析无法证明的剩余风险

### 1. Network Kit 自动重定向边界

当前系统 HTTP API 可能在异步响应头回调前自动联系下一跳。应用会逐跳检查可见的 `Location`，拒绝 HTTP 降级、越出可信域和超限链，也不会安装未通过内容校验的数据；但仅靠现有 ArkTS API 不能证明非法下一跳从未被连接。必须用受控服务器和抓包执行 `V138`、`G29`、`G35`。若目标系统确实泄露 URL 凭据或提前联系不允许的目标，应改为可关闭自动跳转、逐跳验证的最小 native HTTPS 下载器，或进一步收紧带凭据 URL 能力。

### 2. 同步 N-API/CGo 调用无法由 ArkTS 超时强制中断

ArkTS 的截止时间能结束上层等待，但不能强制终止已经卡死在同步 native/CGo 调用中的线程。源码已防止已知的重叠启动和虚假停止成功；是否存在特定系统/内核版本永久不返回，只能通过设备故障注入确认。在没有运行证据前，不贸然把核心控制重写成异步 worker，以免扩大 VPN 主链回归面。

### 3. 后台连续性受系统调度约束

实现只使用官方 VPN Extension、WorkScheduler、通知和生命周期能力，不使用越权保活。锁屏时长、进程回收、系统重建和兼容环境应用是否进入 VPN，无法从源码保证。

### 4. 数据面 ready 不等于目标网络可用

`RUNNING` 只能表示 VPN/TUN/本地核心入口达到实现定义的健康条件。VPS 出口、DNS、IPv6、TLS、目标服务地区限制及 ChatGPT/其他 AI 应用的兼容层网络仍需分别留证，不能由按钮状态推导。

### 5. 发布前的许可证归档

直接依赖的许可和来源已有记录，但正式公开分发前仍应基于最终四个原生产物生成并复核完整的 Go/C 传递依赖许可归档。这不是当前源码运行阻断项，但属于发布门槛。

## 已执行检查

- `git diff --check`：实现提交前通过；文档提交前再次执行。
- `bash scripts/verify_source.sh`：通过；翻译键 1153、模块字符串 23、AppScope 字符串 1。
- `bash scripts/verify_prebuilt_native.sh`：通过；四个 AArch64 库的文件集、SHA-256、桥接符号及 TLSDESC 检查通过。
- 标准 Linux Go 1.27.3 临时工具链：`libsingbox` 在产物同组 build tags 下的 7 类代表配置全部通过真实 `libbox.NewService`；`tun2socks_adapter` 包编译通过（当前无独立 Go 测试用例）。两者均使用 `GOFLAGS=-mod=readonly`，没有改写依赖文件。
- 所有 `scripts/*.sh` 执行 `bash -n`：通过。
- `bash scripts/compliance_scan.sh`：通过；未发现私人节点、签名材料、地区策略或未批准用途。
- `bash scripts/device_vpn_smoke_test.sh doctor`：按预期未通过；Node.js、unzip 可用，但缺少 `hvigorw`、Harmony SDK、项目级签名 `build-profile.json5`、已签名 HAP 和 `hdc`。

因此本轮**没有运行** ArkTS LocalUnit、OpenHarmony Native/HAP 编译、模拟器或真机测试，也不声称这些项目通过。标准 Linux Go 测试不能替代 OHOS cgo/TLSDESC 交叉编译；尤其是 `xray_napi.cpp` 的新改动尚未经过目标 Harmony 工具链编译。

## 下一阶段入口

静态审计到此停止扩张。具备 DevEco/Harmony SDK 后，先运行源码门禁、LocalUnit 和完整 HAP 构建，处理编译/API 差异；再用模拟器检查页面、导入和存储恢复；最后严格按 [`device-acceptance.md`](device-acceptance.md) 在真机验证 VPN/TUN、DNS/IPv6、防回环、锁屏后台、承载切换、原生阻塞故障、出口以及 AI 应用流量。所有未执行项继续标为未执行，不能用静态检查替代。

## 后续 DevEco 编译复核（2026-10-22）

静态审计完成后，已从 WSL 直接调用同机 Windows DevEco Studio 6.0.1/API 21 的 Hvigor、ohpm、JBR
和 SDK，在 Windows 本地卷上的独立验证工作树执行真实编译：

- ArkTS LocalUnit 已完成一次全量执行：`243` 个用例，`failure 0`、`error 0`、`pass 243`。
- 完整应用的 ArkTS、CMake、Ninja、资源编译及无签名 HAP 打包通过；生成的约 86 MB HAP 经
  `unzip -t` 校验无损，且含 `libheyvpn.so`、`libxray.so`、`libsingbox.so`、
  `libheytun2socks.so`、`libhevsocks5tun.so` 五个 arm64 库。
- 编译实际发现并修复了 API 21 ArkTS 严格类型、页面编译和测试夹具错误；Hvigor 的 LocalUnit
  任务即使有断言失败也可能返回成功，因此烟测脚本现会额外检查 Hypium 汇总。
- 后续完整编译发现 API 12+ 剪贴板读取权限提示；六处用户粘贴入口改用系统 `PasteButton` 后，
  完整应用再次通过 ArkTS/CMake/Ninja/HAP 构建。编译器仍会按 `getData()` 的静态权限标注给出提示，
  运行时授权由成功的安全组件点击提供，清单不申请可持续读取剪贴板的敏感权限。
- Windows 默认 8 GB Node 堆上限曾触发错误 1455；项目将 Hvigor 上限收敛到 2 GB 后完成测试。
  后续预览运行时重跑分别停在 `modules.abc`、普通 panda file 与 `arkTheme` panda file 加载，均未
  产生新的 Hypium 汇总；这是 DevEco 本地预览运行时的不稳定项，不覆盖前述 243/243 成功证据，
  也不能算当前提交的单测通过。

本次只生成无签名 HAP，没有写入或提交用户签名。`hdc list targets` 返回 `[Empty]`，所以安装、
VPN 授权、模拟器页面和真机网络矩阵仍全部是未验证，不能由编译结果替代。
