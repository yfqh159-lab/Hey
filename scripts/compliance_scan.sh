#!/usr/bin/env bash
# 词表扫描：确保应用不内置地区策略、未经批准的第三方规则源、服务商引导或用途宣称。
#
# 设计原则：不主观提供任何用途，允许用户自行摸索。
# 因此本脚本查的是"应用替用户做的决定"，不是用户可以自己配的技术能力——
# 支持解析某种配置格式、支持某个协议参数，都不在查处范围内。
#
# 用法：./scripts/compliance_scan.sh        命中任意词即以退出码 1 失败。
#
# 排除说明：
#   - LICENSE 是 GPL-3.0 法定原文（含 freedom / circumvention 等词），逐字随附是许可证义务，改一个字即违约。
#   - THIRD-PARTY-NOTICES.md 里的上游项目名出现在法定归属语境，删名同样违约。
#   - 本脚本自身含词表，自我排除。
#   - GeoAssets.ets 中工作区明确批准的 Loyalsoldier 发布 API/资产字段是唯一默认源例外。
#   - 测试目录只扫"真实服务商痕迹"，但允许上述可信 Geo 发布源的固定测试夹具。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SELF="scripts/compliance_scan.sh"
COMMON_EXCLUDES=(--exclude-dir=build --exclude-dir=oh_modules --exclude-dir=.test
                 --exclude-dir=.cxx --exclude='*.hap' --exclude='*.so')

# ---- 主代码与物料：完整词表 ----
MAIN_TARGETS=(entry/src/main scripts README.md README.zh-CN.md AppScope oh-package.json5)

# 内置地区规则集与地区分流标签
P='geoip:(cn|ir|ru)\b|geosite:(cn|gfw|greatfire)\b|geosite:category-(ir|ru)\b|geoip-only-cn-private'
# 服务商专有响应头（订阅流量额度 / 到期时间）——永久红线
P="$P"'|subscription-userinfo|profile-update-interval|profile-web-page-url'
# 内置第三方规则源与对标客户端仓库
P="$P"'|Loyalsoldier|runetfreedom|Chocolate4U|2dust/|androidpackagenamelist|v2rayng'
# 冒充第三方客户端的 User-Agent（注意：解析 Clash.Meta 格式是保留能力，只查 UA 形式）
P="$P"'|clash\.meta Hey|v2rayNG/[0-9]|User-Agent.{0,40}clash'
# 出口地理归属解析
P="$P"'|country_code|countryCode'
# 侧载与分发：应用内更新检查 / Release 下载引导（仓库只提供源码）
P="$P"'|browser_download_url|releases/latest|api\.github\.com/repos/[^/]+/[^/]+/releases'
# 用途宣称（中英）
P="$P"'|翻墙|科学上网|机场|梯子|被墙|访问外网|自由上网|突破封锁|大陆白名单|大陆黑名单'
P="$P"'|bypass censorship|great firewall|unblock the internet|circumvent censorship'

# ---- 测试目录：只查真实服务商痕迹 ----
TEST_TARGETS=(entry/src/test entry/src/ohosTest)
PT='naiun|grandmacdn|znnfxzui|zbbfxzui|Loyalsoldier|runetfreedom|Chocolate4U|androidpackagenamelist'
PT="$PT"'|subscription-userinfo|机场|翻墙|科学上网'

fail=0

echo "compliance scan (main): ${MAIN_TARGETS[*]}"
HITS="$(grep -rniE "$P" "${MAIN_TARGETS[@]}" "${COMMON_EXCLUDES[@]}" 2>/dev/null |
  grep -v "^$SELF:" |
  grep -vE '^entry/src/main/ets/core/GeoAssets\.ets:[0-9]+:.*(Loyalsoldier/v2ray-rules-dat|browser_download_url)' || true)"
if [ -n "$HITS" ]; then
  echo
  echo "COMPLIANCE CHECK FAILED (main, excluding the approved Geo source) —"
  echo "$HITS"
  fail=1
fi

echo "compliance scan (test): ${TEST_TARGETS[*]}"
HITS_T="$(grep -rniE "$PT" "${TEST_TARGETS[@]}" "${COMMON_EXCLUDES[@]}" 2>/dev/null |
  grep -vE '^entry/src/test/LocalUnit\.test\.ets:[0-9]+:.*Loyalsoldier/v2ray-rules-dat' || true)"
if [ -n "$HITS_T" ]; then
  echo
  echo "COMPLIANCE CHECK FAILED (test) —"
  echo "$HITS_T"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "参见 CONTRIBUTING.md 的「永不实现」清单。"
  exit 1
fi

echo "clean — 未发现内置地区策略、未经批准的第三方规则源或用途宣称。"
