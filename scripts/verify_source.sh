#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

required_project_files=(
  AppScope/app.json5
  AppScope/resources/base/media/layered_image.json
  entry/build-profile.json5
  entry/hvigorfile.ts
  entry/oh-package.json5
  entry/src/main/module.json5
  entry/src/main/resources/base/media/startIcon.png
  entry/src/main/resources/base/media/ic_qr_code.svg
  entry/src/main/resources/base/profile/main_pages.json
  entry/src/main/resources/base/profile/form_config.json
)
for required_file in "${required_project_files[@]}"; do
  if [[ ! -s "${required_file}" ]]; then
    printf 'missing required project file: %s\n' "${required_file}" >&2
    printf 'If this is a sparse checkout, run: git sparse-checkout add AppScope entry\n' >&2
    exit 1
  fi
done

# A sparse clone can look clean while build-critical tracked files are absent from disk.
# Reject skipped AppScope/entry paths when verification runs inside a Git checkout;
# source archives still get the explicit file checks above.
inside_git_checkout=false
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  inside_git_checkout=true
  skipped_project_files="$(git ls-files -t AppScope entry | awk '$1 == "S" { print $2 }')"
  if [[ -n "${skipped_project_files}" ]]; then
    printf 'build-critical files are excluded by sparse checkout:\n%s\n' "${skipped_project_files}" >&2
    printf 'Run: git sparse-checkout add AppScope entry\n' >&2
    exit 1
  fi
fi
printf 'project skeleton verification passed\n'

if [[ "${inside_git_checkout}" == true ]]; then
  git diff --check
else
  printf 'Git diff verification skipped outside a checkout\n'
fi
./scripts/compliance_scan.sh
./scripts/verify_prebuilt_native.sh
bash -n scripts/*.sh

# All ArkTS HTTP call sites are security-sensitive because Hey excludes itself from the
# VPN to avoid a routing loop. Keep the small reviewed allowlist explicit: Geo and
# subscription downloads select the current runtime proxy fail-closed, while exit-IP
# verification always requires a valid loopback proxy port. A new caller must be audited
# before it is added here; in particular, delay tests must never fall back to direct HTTP.
expected_http_request_files="$(printf '%s\n' \
  entry/src/main/ets/features/assets/AssetsController.ets \
  entry/src/main/ets/services/RemoteIpInfo.ets \
  entry/src/main/ets/services/SubscriptionManager.ets)"
actual_http_request_files="$(
  find entry/src/main/ets -type f -name '*.ets' \
    -exec grep -lE 'http[.]createHttp[[:space:]]*[(]' {} + 2>/dev/null | sort || true
)"
if [[ "${actual_http_request_files}" != "${expected_http_request_files}" ]]; then
  printf 'unexpected ArkTS HTTP request call sites:\n' >&2
  printf 'expected:\n%s\n' "${expected_http_request_files}" >&2
  printf 'actual:\n%s\n' "${actual_http_request_files}" >&2
  exit 1
fi
printf 'ArkTS HTTP request allowlist verification passed\n'

# These legacy resources described removed automatic-connect/fastest-node features.
# Their return would contradict the single-node, user-controlled runtime model even if
# no current page referenced them, so keep their identifiers out of the translation map.
if grep -qE "log[.]netAutomation(Connect|NoNode)|subscription[.]edit[.]autoSelectFastest" \
  entry/src/main/ets/core/I18n.ets; then
  printf 'removed automatic-connect translation keys were reintroduced\n' >&2
  exit 1
fi
printf 'manual connection policy translation verification passed\n'

# External deep links and shared text can contain subscription tokens, UUIDs and
# passwords. Confirmation dialogs must use a derived redacted summary, never interpolate
# the raw payload into a screenshot-visible message.
if grep -Fq '${intent.payload}' entry/src/main/ets/pages/Index.ets ||
  grep -Fq '${payload}' entry/src/main/ets/pages/Index.ets ||
  grep -qE 'message:[[:space:]]*(intent[.]payload|payload)' entry/src/main/ets/pages/Index.ets; then
  printf 'raw external import payload was exposed in an Index dialog message\n' >&2
  exit 1
fi
printf 'external import confirmation redaction verification passed\n'

# libXray conversion failures are shown by scanner, link import, and system-share
# paths. The native message may echo the original share link, so sanitize it once
# at the shared service boundary before any caller can render or log it.
if ! grep -Fq 'redactDiagnosticText(converted.message)' \
  entry/src/main/ets/services/NativeShareConverter.ets ||
  ! grep -Fq 'message: redactDiagnosticText(`Native share conversion failed:' \
  entry/src/main/ets/services/NativeShareConverter.ets; then
  printf 'native share conversion errors are not consistently redacted\n' >&2
  exit 1
fi
printf 'native share conversion error redaction verification passed\n'

if ! command -v node >/dev/null 2>&1; then
  printf 'node is required for the translation-key consistency check.\n' >&2
  exit 1
fi

node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/cpp/napi_init.cpp', 'utf8');

function functionBody(name) {
  const start = source.indexOf(`napi_value ${name}(`);
  if (start < 0) throw new Error(`${name} not found`);
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index++) {
    if (source[index] === '{') depth++;
    if (source[index] === '}') depth--;
    if (depth === 0) return source.slice(bodyStart, index + 1);
  }
  throw new Error(`${name} body is incomplete`);
}

for (const name of ['StopXray', 'SingboxStop']) {
  const body = functionBody(name);
  if (!body.includes('ClearCoreOwnedTunState()') || body.includes('g_tunRunning.store(false)')) {
    throw new Error(`${name} must preserve a separately owned tun2socks data plane`);
  }
}
if (!source.includes('if (g_tunEngine.load() == TUN_ENGINE_NONE)')) {
  throw new Error('legacy core-owned TUN cleanup guard is missing');
}
NODE
printf 'core/TUN lifecycle separation verification passed\n'

node <<'NODE'
const fs = require('fs');

const catalog = fs.readFileSync('entry/src/main/ets/features/settings/SettingsCatalog.ets', 'utf8');
const options = fs.readFileSync('entry/src/main/ets/features/settings/SettingsOptions.ets', 'utf8');
const controller = fs.readFileSync('entry/src/main/ets/services/ConnectionController.ets', 'utf8');
const config = fs.readFileSync('entry/src/main/ets/core/XrayConfig.ets', 'utf8');
const coreSelection = fs.readFileSync('entry/src/main/ets/core/CoreSelection.ets', 'utf8');

if (!catalog.includes("{ key: 'mode', titleKey: 'settings.mode', type: 'option' }")) {
  throw new Error('runtime mode selector is missing from settings');
}
if (!options.includes('{ value: APP_MODE_VPN,') ||
  !options.includes('{ value: APP_MODE_PROXY_ONLY,')) {
  throw new Error('runtime mode selector must offer both VPN/TUN and local proxy modes');
}
if (!catalog.includes("{ key: 'coreType', titleKey: 'settings.coreType', type: 'option', descKey: 'settings.coreType.detail', vpnOnly: true }")) {
  throw new Error('VPN-only preview core selector must stay hidden in local proxy mode');
}
if (!coreSelection.includes('normalizeAppRuntimeMode(runtimeMode) === APP_MODE_PROXY_ONLY') ||
  !coreSelection.includes('return CORE_TYPE_XRAY;') ||
  !controller.includes('this.effectiveCoreType = resolveRuntimeCoreType(')) {
  throw new Error('local proxy standard nodes must stay on the main Xray core');
}

const xrayStartMarker = '  async start(context: common.Context, profile: ProxyProfile, settings?: AppSettings)';
const xrayStart = controller.indexOf(xrayStartMarker);
const singboxStart = controller.indexOf('\n  // sing-box 内核启动路径', xrayStart);
if (xrayStart < 0 || singboxStart < 0) {
  throw new Error('ConnectionController Xray start method could not be inspected');
}
const startBody = controller.slice(xrayStart, singboxStart);
const proxyBranch = startBody.indexOf('if (this.runtimeMode === APP_MODE_PROXY_ONLY) {');
const proxyStart = startBody.indexOf('await this.startProxyOnly(context);', proxyBranch);
const proxyReturn = startBody.indexOf('return this.getSnapshot();', proxyStart);
const vpnStart = startBody.indexOf('vpnExtension.startVpnExtensionAbility(', proxyBranch);
if (proxyBranch < 0 || proxyStart < 0 || proxyReturn < 0 || vpnStart < 0 ||
  !(proxyBranch < proxyStart && proxyStart < proxyReturn && proxyReturn < vpnStart)) {
  throw new Error('local proxy startup must return before the VPN Extension/TUN startup path');
}

const proxyMethodStart = controller.indexOf('  private async startProxyOnly(');
const proxyMethodEnd = controller.indexOf('\n  private ', proxyMethodStart + 1);
if (proxyMethodStart < 0 || proxyMethodEnd < 0) {
  throw new Error('startProxyOnly method could not be inspected');
}
const proxyMethod = controller.slice(proxyMethodStart, proxyMethodEnd);
if (proxyMethod.includes('vpnExtension.') || proxyMethod.includes('createVpnWant(')) {
  throw new Error('local proxy startup must not create or control a system VPN');
}

if (!config.includes('if (vpnMode) {\n    inbounds.push(tunInbound);') ||
  !config.includes('settings.localSocksEnabled || proxyOnlyMode')) {
  throw new Error('Xray runtime config no longer keeps TUN and local proxy inbounds mode-scoped');
}
NODE
printf 'optional TUN/runtime mode separation verification passed\n'

node <<'NODE'
const fs = require('fs');

const runtime = fs.readFileSync('entry/src/main/ets/features/runtime/RuntimeController.ets', 'utf8');
const networkScene = fs.readFileSync('entry/src/main/ets/services/NetworkSceneManager.ets', 'utf8');
if (!runtime.includes('private egressCheckGeneration: number = 0;') ||
  !runtime.includes('this.egressCheckGeneration++') ||
  !runtime.includes('isCurrentEgressCheck(')) {
  throw new Error('egress checks must reject stale session/generation results');
}
const invalidateAt = networkScene.indexOf('SHARED_RUNTIME_CONTROLLER.invalidateCurrentEgressIp();');
const recoverAt = networkScene.indexOf('await SHARED_RUNTIME_CONTROLLER.recoverProxyOnlyAfterNetworkChange(', invalidateAt);
const recheckAt = networkScene.indexOf('await SHARED_RUNTIME_CONTROLLER.recheckCurrentEgressIp(', invalidateAt);
if (invalidateAt < 0 || recoverAt < 0 || recheckAt < 0 ||
  !(invalidateAt < recoverAt && recoverAt < recheckAt)) {
  throw new Error('network handover must invalidate stale egress checks before recovery and recheck');
}
NODE
printf 'egress handover generation verification passed\n'

node <<'NODE'
const fs = require('fs');

const app = JSON.parse(fs.readFileSync('AppScope/app.json5', 'utf8'));
const bundleName = app?.app?.bundleName;
if (typeof bundleName !== 'string' || bundleName.length === 0) {
  throw new Error('AppScope bundleName is missing');
}

function declaredString(file, constantName) {
  const source = fs.readFileSync(file, 'utf8');
  const pattern = new RegExp(`(?:export\\s+)?const\\s+${constantName}\\s*:\\s*string\\s*=\\s*'([^']+)'`);
  const match = source.match(pattern);
  if (match === null) throw new Error(`${file}: ${constantName} was not found`);
  return match[1];
}

const runtimeDeclarations = [
  ['entry/src/main/ets/vpn/VpnConstants.ets', 'BUNDLE_NAME'],
  ['entry/src/main/ets/services/SpeedNotificationManager.ets', 'APP_BUNDLE_NAME'],
  ['entry/src/main/ets/core/SubscriptionSchedulerPlan.ets', 'SUBSCRIPTION_AUTO_UPDATE_WORK_BUNDLE_NAME'],
  ['entry/src/main/ets/pages/PerApp.ets', 'SELF_BUNDLE_NAME']
];
for (const [file, constantName] of runtimeDeclarations) {
  const declared = declaredString(file, constantName);
  if (declared !== bundleName) {
    throw new Error(`${file}: ${constantName}=${declared} does not match AppScope bundleName=${bundleName}`);
  }
}

const shortcuts = JSON.parse(fs.readFileSync('entry/src/main/resources/base/profile/shortcuts_config.json', 'utf8'));
const shortcutItems = shortcuts?.shortcuts;
if (!Array.isArray(shortcutItems) || shortcutItems.length === 0) {
  throw new Error('shortcut declarations are missing');
}
for (const shortcut of shortcutItems) {
  if (!Array.isArray(shortcut?.wants) || shortcut.wants.length === 0) {
    throw new Error('shortcut want declarations are missing');
  }
  for (const want of shortcut.wants) {
    if (want?.bundleName !== bundleName) {
      throw new Error('shortcut bundleName does not match AppScope bundleName');
    }
  }
}

const vpnConstants = fs.readFileSync('entry/src/main/ets/vpn/VpnConstants.ets', 'utf8');
if (!vpnConstants.includes('blockedApps = [selfBundle];') ||
  !vpnConstants.includes('const selectedApps = appList.filter(app => app !== selfBundle);')) {
  throw new Error('VPN config no longer guarantees self-bundle exclusion from the TUN');
}
NODE
printf 'bundle identity/self-VPN exclusion verification passed\n'

node <<'NODE'
const fs = require('fs');
const path = require('path');

function etsFiles(dir) {
  const result = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) result.push(...etsFiles(fullPath));
    else if (entry.isFile() && entry.name.endsWith('.ets')) result.push(fullPath);
  }
  return result;
}

const unsafe = [];
for (const file of etsFiles('entry/src/main/ets')) {
  const source = fs.readFileSync(file, 'utf8');
  const callPattern = /(?:console|hilog)[.](?:error|warn|info|debug|log)[(][\s\S]{0,1000}?[)][;]/g;
  for (const match of source.matchAll(callPattern)) {
    const call = match[0];
    if (call.includes('JSON.stringify(') && !call.includes('redactDiagnosticText(')) {
      const line = source.slice(0, match.index).split('\n').length;
      unsafe.push(`${file}:${line}`);
    }
  }
}
if (unsafe.length > 0) {
  throw new Error(`raw JSON error was written to console/hilog: ${unsafe.join(', ')}`);
}
NODE
printf 'ArkTS console/hilog error redaction verification passed\n'

node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/core/I18n.ets', 'utf8');

function translationMapKeys(name) {
  const marker = `const ${name}: Record<string, string> = {`;
  const start = source.indexOf(marker);
  const end = source.indexOf('\n};', start);
  if (start < 0 || end < 0) {
    throw new Error(`translation map not found: ${name}`);
  }
  return [...source.slice(start, end).matchAll(/^\s*'([^']+)'\s*:/gm)].map((match) => match[1]);
}

const listStart = source.indexOf('export const TRANSLATION_KEYS');
const listEnd = source.indexOf('];', listStart);
if (listStart < 0 || listEnd < 0) {
  throw new Error('TRANSLATION_KEYS not found');
}
const expected = [...source.slice(listStart, listEnd).matchAll(/'([^']+)'/g)].map((match) => match[1]);
const maps = [
  ['ZH_TRANSLATIONS', translationMapKeys('ZH_TRANSLATIONS')],
  ['EN_TRANSLATIONS', translationMapKeys('EN_TRANSLATIONS')]
];

for (const [name, keys] of [['TRANSLATION_KEYS', expected], ...maps]) {
  if (new Set(keys).size !== keys.length) {
    throw new Error(`${name} contains duplicate keys`);
  }
}
for (const [name, keys] of maps) {
  const missing = expected.filter((key) => !keys.includes(key));
  const extra = keys.filter((key) => !expected.includes(key));
  if (missing.length > 0 || extra.length > 0) {
    throw new Error(`${name} mismatch: missing=${missing.join(',')} extra=${extra.join(',')}`);
  }
}
console.log(`translation key consistency passed: ${expected.length} keys`);

function resourceStringKeys(file) {
  const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(parsed.string)) {
    throw new Error(`${file} does not contain a string resource array`);
  }
  const keys = parsed.string.map((entry) => entry.name);
  if (new Set(keys).size !== keys.length) {
    throw new Error(`${file} contains duplicate string resources`);
  }
  for (const entry of parsed.string) {
    if (typeof entry.name !== 'string' || entry.name.length === 0 ||
      typeof entry.value !== 'string' || entry.value.length === 0) {
      throw new Error(`${file} contains an invalid string resource`);
    }
  }
  return keys;
}

function verifyResourceCatalog(files) {
  const baseline = resourceStringKeys(files[0]);
  for (const file of files.slice(1)) {
    const keys = resourceStringKeys(file);
    const missing = baseline.filter((key) => !keys.includes(key));
    const extra = keys.filter((key) => !baseline.includes(key));
    if (missing.length > 0 || extra.length > 0) {
      throw new Error(`${file} resource mismatch: missing=${missing.join(',')} extra=${extra.join(',')}`);
    }
  }
  return baseline.length;
}

const moduleResourceCount = verifyResourceCatalog([
  'entry/src/main/resources/base/element/string.json',
  'entry/src/main/resources/en_US/element/string.json',
  'entry/src/main/resources/zh_CN/element/string.json'
]);
const appResourceCount = verifyResourceCatalog([
  'AppScope/resources/base/element/string.json',
  'AppScope/resources/en_US/element/string.json',
  'AppScope/resources/zh_CN/element/string.json'
]);
console.log(`system string resource consistency passed: module=${moduleResourceCount}, app=${appResourceCount}`);
NODE

printf 'source verification passed\n'
