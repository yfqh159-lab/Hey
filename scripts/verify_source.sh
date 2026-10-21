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

# Exit-IP verification is user-visible proof of the active egress. It must require a
# valid loopback proxy and an authenticated HTTPS endpoint; neither an unavailable proxy
# nor a custom plaintext endpoint may fall back to the physical network or claim success.
node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/services/RemoteIpInfo.ets', 'utf8');
const defaults = fs.readFileSync('entry/src/main/ets/core/HttpDefaults.ets', 'utf8');
const settings = fs.readFileSync('entry/src/main/ets/features/settings/SettingsController.ets', 'utf8');
const settingsStore = fs.readFileSync('entry/src/main/ets/storage/SettingsStore.ets', 'utf8');
const fetchAt = source.indexOf('export async function fetchRemoteIpInfo(');
const fetchEnd = source.indexOf('\nexport function parseRemoteIpInfoContent(', fetchAt);
const fetchBody = source.slice(fetchAt, fetchEnd);
const normalizeAt = source.indexOf('export function normalizeIpApiUrl(');
const normalizeEnd = source.indexOf('\nfunction responseBodyText(', normalizeAt);
const normalizeBody = source.slice(normalizeAt, normalizeEnd);
if (fetchAt < 0 || fetchEnd < 0 ||
  !fetchBody.includes("return failedRemoteIpInfo('proxy-unavailable');") ||
  !fetchBody.includes('usingProxy: {') ||
  !fetchBody.includes('host: LOCAL_HTTP_PROXY_HOST') ||
  !fetchBody.includes('port: proxyPort')) {
  throw new Error('exit-IP check can bypass its required loopback runtime proxy');
}
if (normalizeAt < 0 || normalizeEnd < 0 ||
  !normalizeBody.includes('return normalizeHttpsUrl(ipApiUrl);') ||
  !defaults.includes('export function normalizeHttpsUrl(value: string): string') ||
  !defaults.includes("const prefix = 'https://';") ||
  !defaults.includes("authority.includes('@')") ||
  settings.includes('ipApiUrl: draft.ipApiUrl.trim()') ||
  !settings.includes('ipApiUrl: normalizeHttpsUrl(draft.ipApiUrl)') ||
  !settingsStore.includes(
    'ipApiUrl: normalizeHttpsUrl(SettingsStore.stringValue(raw.ipApiUrl, base.ipApiUrl))')) {
  throw new Error('exit-IP verification accepts an unauthenticated plaintext endpoint');
}
NODE
printf 'HTTPS-only proxied exit-IP verification passed\n'

# The remote resolver is part of the anti-leak boundary. Xray's localhost and
# *+local DNS modes intentionally bypass routing, so they are valid only for an
# explicitly direct resolver and must be filtered from the remote resolver list.
node <<'NODE'
const fs = require('fs');
const addresses = fs.readFileSync('entry/src/main/ets/core/DnsAddresses.ets', 'utf8');
const xray = fs.readFileSync('entry/src/main/ets/core/XrayConfig.ets', 'utf8');
const settings = fs.readFileSync('entry/src/main/ets/features/settings/SettingsController.ets', 'utf8');
const settingsStore = fs.readFileSync('entry/src/main/ets/storage/SettingsStore.ets', 'utf8');
if (!addresses.includes('export function isLocalCoreDnsAddress(value: string): boolean') ||
  !addresses.includes("lower === 'localhost'") ||
  !addresses.includes("lower.startsWith('https+local://')") ||
  !addresses.includes("lower.startsWith('tcp+local://')") ||
  !addresses.includes("lower.startsWith('quic+local://')") ||
  !addresses.includes('allowLocalCoreDns: boolean = true') ||
  !addresses.includes('allowLocalCoreDns || !isLocalCoreDnsAddress(address)') ||
  !addresses.includes('export function normalizeRemoteDnsValue(')) {
  throw new Error('DNS normalization does not distinguish routed and physical-network local modes');
}
if (!xray.includes('DNS_PROXY, true, false);')) {
  throw new Error('remote DNS can bypass Xray routing through localhost or a +local mode');
}
if (!settings.includes('private remoteDnsValue(value: string): string') ||
  !settings.includes('return normalizeRemoteDnsValue(value);') ||
  !settings.includes('remoteDns,')) {
  throw new Error('settings can display a remote DNS value that runtime silently ignores');
}
if (!settingsStore.includes(
  'remoteDns: normalizeRemoteDnsValue(SettingsStore.stringValue(raw.remoteDns, base.remoteDns))')) {
  throw new Error('persisted or imported local-mode remote DNS survives settings normalization');
}
for (const [field, allowCore] of [['vpnDns', 'false'], ['domesticDns', 'true']]) {
  if (!settings.includes(`${field}: normalizeOptionalDnsValue(draft.${field}, ${allowCore})`) ||
    !settingsStore.includes(
      `${field}: normalizeOptionalDnsValue(SettingsStore.stringValue(raw.${field}, base.${field}), ${allowCore})`)) {
    throw new Error(`${field} can display values that runtime silently ignores`);
  }
}
NODE
printf 'remote DNS local-mode leak guard passed\n'

node <<'NODE'
const fs = require('fs');
const health = fs.readFileSync('entry/src/main/ets/core/RuntimeHealth.ets', 'utf8');
const runtime = fs.readFileSync('entry/src/main/ets/features/runtime/RuntimeController.ets', 'utf8');
const routedDownloads = [
  'entry/src/main/ets/features/assets/AssetsController.ets',
  'entry/src/main/ets/pages/SubscriptionDetail.ets',
  'entry/src/main/ets/pages/Subscriptions.ets'
];
if (!health.includes('export function runtimeMayOwnNetwork(status: ConnectionStatus, cleanupRequired: boolean)') ||
  !health.includes('status === ConnectionStatus.ERROR && cleanupRequired') ||
  !runtime.includes('return runtimeMayOwnNetwork(this.status, this.controller.requiresCleanup());')) {
  throw new Error('runtime network ownership does not distinguish ordinary errors from incomplete cleanup');
}
for (const file of routedDownloads) {
  const source = fs.readFileSync(file, 'utf8');
  if (!source.includes('SHARED_RUNTIME_CONTROLLER.mayOwnNetwork()') ||
    source.includes('runtime.status !== ConnectionStatus.IDLE')) {
    throw new Error(`${file}: downloads do not use cleanup-aware runtime proxy routing`);
  }
}
NODE
printf 'cleanup-aware download routing verification passed\n'

node <<'NODE'
const fs = require('fs');
const controller = fs.readFileSync('entry/src/main/ets/features/assets/AssetsController.ets', 'utf8');
const page = fs.readFileSync('entry/src/main/ets/pages/Assets.ets', 'utf8');
const assetStore = fs.readFileSync('entry/src/main/ets/storage/AssetStore.ets', 'utf8');
const verifyAt = controller.indexOf('  async isBuiltinGeoMetadataCurrent(');
const verifyEnd = controller.indexOf('\n  // 检查可信默认发布源', verifyAt);
const verify = controller.slice(verifyAt, verifyEnd);
if (verifyAt < 0 || verifyEnd < 0 ||
  !verify.includes('GEO_METADATA_INVALID_FILE') ||
  !verify.includes('metadata.assets.length !== BUILTIN_GEO_DATA_FILE_NAMES.length') ||
  !verify.includes('isPlausibleGeoData(data, matched.size)') ||
  !verify.includes('await this.sha256(data) !== matched.sha256')) {
  throw new Error('stored Geo version/hash metadata is not verified against both installed files');
}
const loadAt = page.indexOf('  private async loadGeoMetadata(pageGeneration: number): Promise<boolean>');
const loadEnd = page.indexOf('\n  private applyGeoMetadata(', loadAt);
const load = page.slice(loadAt, loadEnd);
if (loadAt < 0 || loadEnd < 0 ||
  !load.includes('await ASSETS_CONTROLLER.isBuiltinGeoMetadataCurrent(context, metadata)') ||
  !load.includes('await AssetStore.clearGeoUpdateMetadata(context);') ||
  !load.includes("this.geoUpdateSummary = this.t('assets.geo.defaultSource');") ||
  !load.includes('return false;') || !load.includes('return true;')) {
  throw new Error('Assets page can display stale Geo verification metadata');
}
const updateAt = page.indexOf('  private async checkGeoUpdate(): Promise<void>');
const updateEnd = page.indexOf('\n  private deleteAsset(', updateAt);
const update = page.slice(updateAt, updateEnd);
if (updateAt < 0 || updateEnd < 0 || !update.includes('if (result.metadataSaved)') ||
  !update.includes('await this.clearGeoMetadata(pageGeneration);') || !update.includes('this.applyVerifiedGeoResult(result);')) {
  throw new Error('a metadata write failure can reload and display an obsolete Geo version');
}
if (!update.includes('let metadataConfirmed = result.metadataSaved;') ||
  !update.includes('metadataConfirmed = false;') ||
  !update.includes('if (!await this.loadGeoMetadata(pageGeneration)) {') ||
  !update.includes('this.applyVerifiedGeoResult(result);') ||
  !update.includes('resolveGeoUpdateNotice(\n        result.changed,\n        SHARED_RUNTIME_CONTROLLER.isRunning(),\n        metadataConfirmed') ||
  update.includes('SHARED_RUNTIME_CONTROLLER.isRunning(),\n        result.metadataSaved')) {
  throw new Error('a Geo metadata display failure can overwrite or misreport the verified file result');
}
const applyVerifiedAt = page.indexOf('  private applyVerifiedGeoResult(');
const applyVerifiedEnd = page.indexOf('\n  private applyGeoMetadata(', applyVerifiedAt);
const applyVerified = page.slice(applyVerifiedAt, applyVerifiedEnd);
if (applyVerifiedAt < 0 || applyVerifiedEnd < 0 ||
  !applyVerified.includes('this.applyGeoMetadata({') ||
  !applyVerified.includes('version: result.version') ||
  !applyVerified.includes('assets: result.assets')) {
  throw new Error('verified Geo controller results are not preserved when metadata display reload fails');
}
const customDownloadAt = page.indexOf('  private async downloadCustomAsset(');
const customDeleteEnd = page.indexOf('\n  // ===================== 状态读取', customDownloadAt);
const customMutations = page.slice(customDownloadAt, customDeleteEnd);
if (customDownloadAt < 0 || customDeleteEnd < 0 ||
  !customMutations.includes('() => this.notifyGeoReloadRequiredIfRunning(),') ||
  !customMutations.includes('localFileChanged = true;') ||
  customMutations.split('this.notifyGeoReloadRequiredIfRunning();').length - 1 < 4 ||
  !customMutations.includes('if (fileExisted && !this.assetFileExists(targetPath)) {')) {
  throw new Error('custom Geo file changes can remain invisible to an already running core');
}
const customNameInputAt = page.indexOf("TextInput({ text: this.editName, placeholder: 'e.g. custom_geo' })");
const customNameInputEnd = page.indexOf("Text(this.t('assets.urlAddress'))", customNameInputAt);
const customNameInput = page.slice(customNameInputAt, customNameInputEnd);
const saveCustomAt = page.indexOf('  private async saveCustomAsset(): Promise<void>');
const deleteCustomPageAt = page.indexOf('  private async deleteCustomAsset(', saveCustomAt);
const saveCustom = page.slice(saveCustomAt, deleteCustomPageAt);
if (customNameInputAt < 0 || customNameInputEnd < 0 || saveCustomAt < 0 || deleteCustomPageAt < 0 ||
  !customNameInput.includes('.enabled(this.editId.length === 0)') ||
  !saveCustom.includes('if (this.customAssets[index].id === this.editId)') ||
  !saveCustom.includes('trimmedName = existingName;')) {
  throw new Error('editing a custom Geo source can rename its record without migrating the .dat file');
}
const deleteCustomAt = controller.indexOf('  async deleteCustomAsset(');
const deleteCustomEnd = controller.indexOf('\n  private removeStandaloneAssetFiles(', deleteCustomAt);
const deleteCustom = controller.slice(deleteCustomAt, deleteCustomEnd);
const persistDeleteAt = deleteCustom.indexOf('await AssetStore.save(context, updated);');
const removeCustomFileAt = deleteCustom.indexOf('this.removeStandaloneAssetFiles(path);');
if (deleteCustomAt < 0 || deleteCustomEnd < 0 || persistDeleteAt < 0 ||
  removeCustomFileAt < persistDeleteAt ||
  !deleteCustom.includes('await AssetStore.save(context, customAssets);') ||
  !deleteCustom.includes('if (rollbackSucceeded) {') ||
  !deleteCustom.includes('Geo file deletion failed and source rollback was not confirmed')) {
  throw new Error('custom Geo deletion can remove the file before its source record is durably updated');
}
const updateCatchAt = update.indexOf('    } catch (error) {');
const updateCatch = update.slice(updateCatchAt);
if (updateCatchAt < 0 || !updateCatch.includes('const message = redactDiagnosticText(') ||
  !updateCatch.includes('try {\n        await this.loadGeoMetadata(pageGeneration);\n      } catch (metadataError) {') ||
  !updateCatch.includes("const localized = this.f1('assets.geo.checkFailed', 'error', message);") ||
  !updateCatch.includes('SHARED_RUNTIME_CONTROLLER.appendLog(localized);')) {
  throw new Error('a secondary Geo metadata load failure can mask the original update error');
}
const appearAt = page.indexOf('  aboutToAppear(): void');
const buildAt = page.indexOf('\n  build()', appearAt);
const lifecycle = page.slice(appearAt, buildAt);
const checkGenerationCount =
  (update.match(/this[.]isCurrentPage[(]pageGeneration[)]/g) ?? []).length;
if (!page.includes('private pageActive: boolean = false;') ||
  !page.includes('private pageGeneration: number = 0;') ||
  !lifecycle.includes('this.pageActive = true;') ||
  !lifecycle.includes('this.pageActive = false;') ||
  !lifecycle.includes('this.pageGeneration++;') ||
  !update.includes('const pageGeneration = this.pageGeneration;') ||
  checkGenerationCount < 6 ||
  !update.includes('this.logDetachedGeoResult(result);') ||
  !update.includes('await this.loadState(this.pageGeneration);') ||
  !load.includes('this.isCurrentPage(pageGeneration)')) {
  throw new Error('Geo update or metadata load can update a disposed page or lose refresh after returning');
}
if (!controller.includes('await AssetStore.saveGeoUpdateMetadata(context, updateMetadata);') ||
  !controller.includes('this.removeFileStrictIfExists(`${context.filesDir}/${GEO_METADATA_INVALID_FILE}`);') ||
  !controller.includes('this.writeFileData(`${context.filesDir}/${GEO_METADATA_INVALID_FILE}`')) {
  throw new Error('Geo metadata failures are not durably invalidated across equal-content releases');
}
for (const name of ['load', 'save', 'loadGeoUpdateMetadata', 'saveGeoUpdateMetadata', 'clearGeoUpdateMetadata']) {
  const methodAt = assetStore.indexOf(`  static ${name}(`);
  const nextMethodAt = assetStore.indexOf('\n  static ', methodAt + 1);
  const body = assetStore.slice(methodAt, nextMethodAt < 0 ? assetStore.length : nextMethodAt);
  if (methodAt < 0 || !body.includes('return AssetStore.enqueueOperation(')) {
    throw new Error(`${name} bypasses serialized Geo metadata storage`);
  }
}
if (!assetStore.includes('private static operationTail: Promise<void> = Promise.resolve();') ||
  !assetStore.includes('AssetStore.operationTail = task.then(') ||
  !assetStore.includes('const assetsSnapshot = AssetStore.normalizeCustomAssets(assets);') ||
  !assetStore.includes('const metadataSnapshot = AssetStore.copyGeoUpdateMetadata(metadata);')) {
  throw new Error('Geo/custom asset storage queue or input snapshots are missing');
}
NODE
printf 'installed Geo metadata verification passed\n'

geo_controller="entry/src/main/ets/features/assets/AssetsController.ets"
if ! grep -q 'maxLimit: MAX_GEO_TEXT_BYTES' "${geo_controller}" ||
  ! grep -q 'maxLimit: MAX_GEO_HTTP_DATA_BYTES' "${geo_controller}" ||
  ! grep -q "response.result.byteLength > MAX_GEO_HTTP_DATA_BYTES" "${geo_controller}" ||
  ! grep -q "response.result.byteLength > MAX_GEO_TEXT_BYTES" "${geo_controller}"; then
  throw_error='Geo HTTP responses are not bounded before and after materialization'
  echo "${throw_error}" >&2
  exit 1
fi
printf 'bounded Geo HTTP response verification passed\n'

geo_page="entry/src/main/ets/pages/Assets.ets"
geo_urls="entry/src/main/ets/core/AssetUrls.ets"
if ! grep -q 'const normalizedUrl = normalizeGeoAssetDownloadUrl(url)' "${geo_controller}" ||
  ! grep -q 'const checksumUrl = buildGeoChecksumUrl(normalizedUrl)' "${geo_controller}" ||
  ! grep -q 'normalizeGeoAssetDownloadUrl(this.geoUrlInput)' "${geo_page}" ||
  ! grep -q 'normalizeGeoAssetDownloadUrl(trimmedUrl)' "${geo_page}" ||
  ! grep -q 'normalizeGeoAssetDownloadUrl(value)' "${geo_urls}" ||
  grep -q "startsWith('http://')" "${geo_page}" ||
  grep -q "startsWith('http://')" "${geo_controller}"; then
  echo 'Geo remote sources are not consistently restricted to normalized HTTPS URLs' >&2
  exit 1
fi
printf 'HTTPS-only Geo source verification passed\n'

# These legacy resources described removed automatic-connect/fastest-node features.
# Their return would contradict the single-node, user-controlled runtime model even if
# no current page referenced them, so keep their identifiers out of the translation map.
if grep -qE "log[.]netAutomation(Connect|NoNode)|subscription[.]edit[.]autoSelectFastest" \
  entry/src/main/ets/core/I18n.ets; then
  printf 'removed automatic-connect translation keys were reintroduced\n' >&2
  exit 1
fi
printf 'manual connection policy translation verification passed\n'

# Trusted-network edits only change the auto-disconnect decision. They must be
# re-evaluated immediately without scheduling a core/TUN restart.
network_scenario_source='entry/src/main/ets/pages/NetworkScenario.ets'
if grep -Fq 'markRuntimeSettingsRestartNeeded' "${network_scenario_source}" ||
  ! grep -Fq 'NETWORK_SCENE_MANAGER.refreshNow(true);' "${network_scenario_source}" ||
  ! grep -Fq '@State private settingsLoaded: boolean = false;' "${network_scenario_source}" ||
  ! grep -Fq 'private settingsLoadGeneration: number = 0;' "${network_scenario_source}" ||
  ! grep -Fq '.enabled(this.settingsLoaded)' "${network_scenario_source}" ||
  ! grep -Fq 'loadGeneration !== this.settingsLoadGeneration' "${network_scenario_source}" ||
  ! grep -Fq 'private settingsSaveInFlight: boolean = false;' "${network_scenario_source}" ||
  ! grep -Fq 'while (this.settingsSavePending)' "${network_scenario_source}" ||
  ! grep -Fq 'draft.netAutomationTrustedSsids = this.trustedSsids.slice();' "${network_scenario_source}"; then
  printf 'trusted-network settings can still restart the active data plane\n' >&2
  exit 1
fi
printf 'trusted-network no-restart verification passed\n'

# General settings are persisted from many immediate UI callbacks. Keep those writes
# single-flight and reject stale normalized snapshots so rapid edits cannot be reverted.
settings_page_source='entry/src/main/ets/pages/Settings.ets'
if ! grep -Fq 'private settingsSaveInFlight: boolean = false;' "${settings_page_source}" ||
  ! grep -Fq '@State private settingsLoaded: boolean = false;' "${settings_page_source}" ||
  ! grep -Fq 'private settingsLoadGeneration: number = 0;' "${settings_page_source}" ||
  ! grep -Fq 'if (!this.settingsLoaded)' "${settings_page_source}" ||
  ! grep -Fq 'this.settingsLoaded = true;' "${settings_page_source}" ||
  ! grep -Fq 'loadGeneration !== this.settingsLoadGeneration' "${settings_page_source}" ||
  ! grep -Fq 'private settingsEditGeneration: number = 0;' "${settings_page_source}" ||
  ! grep -Fq 'while (this.settingsSavePending)' "${settings_page_source}" ||
  ! grep -Fq 'generation === this.settingsEditGeneration && !this.settingsSavePending' "${settings_page_source}" ||
  ! grep -Fq 'shouldRestartRuntimeForSettingsChange(baseline, finalSaved)' "${settings_page_source}" ||
  ! grep -Fq 'shouldRestartRuntimeForSettingsChange(previous, latestSaved)' "${settings_page_source}"; then
  printf 'general settings writes are not serialized against stale UI rollback\n' >&2
  exit 1
fi
printf 'general settings save serialization verification passed\n'

if ! grep -Fq "@StorageLink(RUNTIME_SETTINGS_RESTART_PENDING_KEY) @Watch('onPendingRuntimeSettingsRestartChanged')" \
  "entry/src/main/ets/pages/Index.ets" || \
  ! grep -Fq "if (!this.pageVisible || !this.pendingRuntimeSettingsRestartSignal)" \
  "entry/src/main/ets/pages/Index.ets" || \
  ! grep -Fq "if (!await this.recoverForegroundAuthority())" "entry/src/main/ets/pages/Index.ets" || \
  ! grep -Fq "await this.handlePendingRuntimeSettingsRestart();" "entry/src/main/ets/pages/Index.ets" || \
  ! grep -Fq "this.pendingRuntimeSettingsRestartSignal && !this.isBusy()" \
  "entry/src/main/ets/pages/Index.ets"; then
  throw_error "late settings-save restart signals must be consumed from authoritative visible-home state"
fi
printf 'late settings restart handoff verification passed\n'

# Settings pages persist complete AppSettings snapshots. Serialize every store read and
# write globally so one page cannot load stale data during another page's save and later
# overwrite unrelated settings. Language changes must keep their read-modify-write inside
# the same queue operation rather than recursively enqueueing and deadlocking.
settings_store_source='entry/src/main/ets/storage/SettingsStore.ets'
if ! grep -Fq 'private static operationTail: Promise<void> = Promise.resolve();' "${settings_store_source}" ||
  ! grep -Fq 'return SettingsStore.enqueueOperation((): Promise<AppSettings> => SettingsStore.loadNow(context));' "${settings_store_source}" ||
  ! grep -Fq 'return SettingsStore.enqueueOperation((): Promise<AppSettings> => SettingsStore.saveNow(context, normalized));' "${settings_store_source}" ||
  ! grep -Fq 'return SettingsStore.enqueueOperation(async (): Promise<AppSettings> => {' "${settings_store_source}" ||
  ! grep -Fq 'const settings = await SettingsStore.loadNow(context);' "${settings_store_source}" ||
  ! grep -Fq 'return SettingsStore.saveNow(context, SettingsStore.normalize(settings));' "${settings_store_source}" ||
  ! grep -Fq 'private static enqueueOperation<T>(operation: () => Promise<T>): Promise<T>' "${settings_store_source}" ||
  ! grep -Fq 'SettingsStore.operationTail = task.then(' "${settings_store_source}" ||
  ! grep -Fq 'return Array.isArray(value) ? value.slice() : fallback.slice();' "${settings_store_source}"; then
  printf 'settings store operations are not serialized against cross-page stale snapshots\n' >&2
  exit 1
fi
printf 'settings store global operation serialization verification passed\n'

# External deep links and shared text can contain subscription tokens, UUIDs and
# passwords. Confirmation dialogs must use a derived redacted summary, never interpolate
# the raw payload into a screenshot-visible message.
if grep -Fq '${intent.payload}' entry/src/main/ets/pages/Index.ets ||
  grep -Fq '${payload}' entry/src/main/ets/pages/Index.ets ||
  grep -qE 'message:[[:space:]]*(intent[.]payload|payload)' entry/src/main/ets/pages/Index.ets ||
  grep -Fq 'this.lastError = validation.message;' entry/src/main/ets/pages/Index.ets ||
  ! grep -Fq "'name', redactDiagnosticText(nodeName)" entry/src/main/ets/pages/Index.ets ||
  ! grep -Fq 'lastValidationError = redactDiagnosticText(imported.message);' entry/src/main/ets/pages/Index.ets; then
  printf 'external import payload or derived diagnostics were exposed by Index\n' >&2
  exit 1
fi
printf 'external import confirmation redaction verification passed\n'

# Camera, photo, and clipboard results are often complete share links containing UUIDs,
# passwords, or subscription tokens. Keep the raw value only in page memory for the
# explicit confirmation action; the screenshot-visible TextArea and preview receive no
# unredacted external payload.
scanner_source='entry/src/main/ets/pages/Scanner.ets'
if ! grep -Fq "private pendingSensitiveImport: string = '';" "${scanner_source}" ||
  ! grep -Fq 'this.setSensitiveImportValue(value);' "${scanner_source}" ||
  ! grep -Fq 'this.setSensitiveImportValue(text);' "${scanner_source}" ||
  ! grep -Fq "'scanner.previewEndpoint', 'endpoint', redactDiagnosticText(endpointText)" "${scanner_source}" ||
  grep -Fq 'this.importBuffer = value.trim();' "${scanner_source}" ||
  grep -Fq 'this.importBuffer = text.trim();' "${scanner_source}" ||
  grep -Fq 'this.lastError = state.subscriptionMessage;' "${scanner_source}"; then
  printf 'scanner external payload privacy guard failed\n' >&2
  exit 1
fi
printf 'scanner external payload privacy verification passed\n'

# Import handlers also guard themselves rather than relying only on a reactively disabled
# button. Two tap events can be delivered before the next render; without a synchronous
# guard both handlers can pass duplicate checks and write the same node twice. Raw scan,
# photo and clipboard content must also be released when the scanner page leaves.
node <<'NODE'
const fs = require('fs');
for (const [file, marker] of [
  ['entry/src/main/ets/pages/Scanner.ets', '  private async importResult(): Promise<void>'],
  ['entry/src/main/ets/pages/Import.ets', '  private async importLink(): Promise<void>']
]) {
  const source = fs.readFileSync(file, 'utf8');
  const at = source.indexOf(marker);
  if (at < 0 || !source.slice(at, at + 140).includes('if (this.isBusy) {')) {
    throw new Error(`${file} import handler can be entered twice before UI disable is rendered`);
  }
}
const scanner = fs.readFileSync('entry/src/main/ets/pages/Scanner.ets', 'utf8');
const manualImport = fs.readFileSync('entry/src/main/ets/pages/Import.ets', 'utf8');
const disappearAt = scanner.indexOf('  aboutToDisappear(): void');
const buildAt = scanner.indexOf('\n  build()', disappearAt);
const disappear = scanner.slice(disappearAt, buildAt);
if (!disappear.includes("this.pendingSensitiveImport = '';" ) ||
  !disappear.includes('this.hasPendingSensitiveImport = false;')) {
  throw new Error('scanner keeps external credentials in the page instance after leaving');
}
if (!scanner.includes('private pageActive: boolean = false;') ||
  !scanner.includes('private pageGeneration: number = 0;') ||
  !disappear.includes('this.pageActive = false;') ||
  !disappear.includes('this.pageGeneration++;') ||
  !scanner.includes('private isCurrentPage(pageGeneration: number): boolean')) {
  throw new Error('scanner async results can repopulate sensitive content after the page leaves');
}
const pasteAt = scanner.indexOf('  private async pasteFromClipboard(): Promise<void>');
const pasteEnd = scanner.indexOf('\n  private isCurrentPage(', pasteAt);
const paste = scanner.slice(pasteAt, pasteEnd);
if (pasteAt < 0 || pasteEnd < 0 || !paste.includes('if (this.isBusy) {') ||
  !paste.includes('this.isBusy = true;') || !paste.includes('this.isCurrentPage(pageGeneration)') ||
  !paste.includes('this.isBusy = false;')) {
  throw new Error('scanner clipboard reads are not single-flight or page-generation safe');
}
const importAt = scanner.indexOf('  private async importResult(): Promise<void>');
const importEnd = scanner.indexOf('\n  private updateImportPreview(', importAt);
const importBody = scanner.slice(importAt, importEnd);
const importGenerationChecks =
  (importBody.match(/this[.]isCurrentPage[(]pageGeneration[)]/g) ?? []).length;
if (importAt < 0 || importEnd < 0 ||
  !importBody.includes('const pageGeneration = this.pageGeneration;') ||
  importGenerationChecks < 7 ||
  !importBody.includes('if (this.isCurrentPage(pageGeneration)) {\n        this.isBusy = false;')) {
  throw new Error('scanner confirmed import can navigate or update a disposed page from a late continuation');
}
const manualDisappearAt = manualImport.indexOf('  aboutToDisappear(): void');
const manualBuildAt = manualImport.indexOf('\n  build()', manualDisappearAt);
const manualLoadAt = manualImport.indexOf('  private async loadState(pageGeneration: number)');
const manualImportAt = manualImport.indexOf('  private async importLink(): Promise<void>');
const manualImportEnd = manualImport.indexOf('\n  private isCurrentPage(', manualImportAt);
const manualImportBody = manualImport.slice(manualImportAt, manualImportEnd);
const manualGenerationChecks =
  (manualImportBody.match(/this[.]isCurrentPage[(]pageGeneration[)]/g) ?? []).length;
if (!manualImport.includes('private pageActive: boolean = false;') ||
  !manualImport.includes('private pageGeneration: number = 0;') ||
  manualDisappearAt < 0 || manualBuildAt < 0 ||
  !manualImport.slice(manualDisappearAt, manualBuildAt).includes('this.pageGeneration++;') ||
  manualLoadAt < 0 ||
  !manualImport.slice(manualLoadAt, manualImportAt).includes('this.isCurrentPage(pageGeneration)') ||
  manualImportAt < 0 || manualImportEnd < 0 ||
  !manualImportBody.includes('const pageGeneration = this.pageGeneration;') ||
  manualGenerationChecks < 5 ||
  !manualImportBody.includes('if (this.isCurrentPage(pageGeneration)) {\n        this.isBusy = false;')) {
  throw new Error('manual link page can apply late loads, navigation, or import UI after disposal');
}
for (const [method, next, minimumChecks] of [
  ['  private async loadState(', '\n  private tryStartImmediateScan(', 2],
  ['  private async startCameraScan(', '\n  private async selectPhotoQr(', 4],
  ['  private async selectPhotoQr(', '\n  private firstScanValue(', 3]
]) {
  const methodAt = scanner.indexOf(method);
  const methodEnd = scanner.indexOf(next, methodAt);
  const body = scanner.slice(methodAt, methodEnd);
  const checks = (body.match(/this[.]isCurrentPage[(]pageGeneration[)]/g) ?? []).length;
  if (methodAt < 0 || methodEnd < 0 || checks < minimumChecks) {
    throw new Error(`${method.trim()} does not reject late results after scanner page disposal`);
  }
}
NODE
printf 'import re-entry and scanner disposal verification passed\n'

# Node/subscription persistence is a full-profile read/modify/write store. Every mutating
# public method must enter the same queue before its first read, and all external node-add
# paths must combine duplicate detection with insertion in that transaction.
node <<'NODE'
const fs = require('fs');
const store = fs.readFileSync('entry/src/main/ets/storage/SubscriptionStore.ets', 'utf8');
const profileStore = fs.readFileSync('entry/src/main/ets/storage/ProfileStore.ets', 'utf8');
const mutations = [
  'saveUrl', 'saveNodes', 'saveNodeDelay', 'saveNodeDelays', 'saveActiveGroupNodes',
  'saveGroups', 'restoreProfile', 'removeNode', 'removeInvalidNodes',
  'dedupeActiveGroupNodes', 'clearActiveGroupNodes', 'selectNode', 'selectGroup',
  'toggleGroup', 'removeGroup', 'moveGroup', 'addGroup', 'updateGroup',
  'addManualNode', 'addManualNodeIfUnique', 'updateManualNode'
];
for (const name of mutations) {
  const methodAt = store.indexOf(`  static ${name}(`);
  const nextMethodAt = store.indexOf('\n  static ', methodAt + 1);
  const body = store.slice(methodAt, nextMethodAt < 0 ? store.length : nextMethodAt);
  const queuedAt = body.indexOf('return SubscriptionStore.enqueueMutation(');
  const loadAt = body.indexOf('SubscriptionStore.load(context)');
  const saveAt = body.indexOf('SubscriptionStore.save(context');
  const firstStorageAt = loadAt < 0 ? saveAt : (saveAt < 0 ? loadAt : Math.min(loadAt, saveAt));
  if (methodAt < 0 || queuedAt < 0 || (firstStorageAt >= 0 && queuedAt > firstStorageAt)) {
    throw new Error(`${name} is outside the subscription mutation queue`);
  }
}
if (!store.includes('private static mutationTail: Promise<void> = Promise.resolve();') ||
  !store.includes('SubscriptionStore.mutationTail = task.then(') ||
  !store.includes('SubscriptionStore.findDuplicateNodeInProfile(profile, outboundJson, configType)')) {
  throw new Error('subscription mutation queue or atomic duplicate check is missing');
}
const loadAt = store.indexOf('  static load(context: common.Context)');
const selectionAt = store.indexOf('  static selectStoredProfile(', loadAt);
const loadBody = store.slice(loadAt, selectionAt);
const saveAt = store.indexOf('  private static save(context: common.Context');
const parseAt = store.indexOf('  private static parseStoredProfile(', saveAt);
const saveBody = store.slice(saveAt, parseAt);
if (!store.includes('private static storageTail: Promise<void> = Promise.resolve();') ||
  !store.includes('SubscriptionStore.storageTail = task.then(') ||
  !loadBody.includes('return SubscriptionStore.enqueueStorage(') ||
  !saveBody.includes('return SubscriptionStore.enqueueStorage(')) {
  throw new Error('subscription reads, backup recovery and saves do not share the storage queue');
}
for (const marker of [
  'const nodesSnapshot = SubscriptionStore.normalizeNodes(nodes);',
  'const updatesSnapshot = new Array<NodeDelayUpdate>();',
  'const groupsSnapshot = SubscriptionStore.normalizeGroups(groups);',
  'const profileSnapshot = SubscriptionStore.normalize(profile);'
]) {
  const snapshotAt = store.indexOf(marker);
  const followingQueueAt = store.indexOf('return SubscriptionStore.enqueueMutation(', snapshotAt);
  if (snapshotAt < 0 || followingQueueAt < snapshotAt) {
    throw new Error(`queued subscription input is not snapshotted: ${marker}`);
  }
}
if (store.split('const nodesSnapshot = SubscriptionStore.normalizeNodes(nodes);').length - 1 !== 2) {
  throw new Error('node array snapshots do not cover both queued replacement paths');
}
const profileLoadAt = profileStore.indexOf('  static load(context: common.Context)');
const profileSelectAt = profileStore.indexOf('  static selectStoredProfile(', profileLoadAt);
const profileSaveAt = profileStore.indexOf('  static save(context: common.Context', profileSelectAt);
const profileQueueAt = profileStore.indexOf('  private static enqueueOperation', profileSaveAt);
if (!profileStore.includes('private static operationTail: Promise<void> = Promise.resolve();') ||
  !profileStore.includes('ProfileStore.operationTail = task.then(') ||
  !profileStore.slice(profileLoadAt, profileSelectAt).includes('return ProfileStore.enqueueOperation(') ||
  !profileStore.slice(profileSaveAt, profileQueueAt).includes('return ProfileStore.enqueueOperation(')) {
  throw new Error('selected profile recovery and saves do not share a failure-safe operation queue');
}
for (const file of [
  'entry/src/main/ets/pages/Scanner.ets',
  'entry/src/main/ets/pages/Import.ets',
  'entry/src/main/ets/pages/Index.ets',
  'entry/src/main/ets/pages/JsonImport.ets',
  'entry/src/main/ets/pages/NodeEdit.ets'
]) {
  const source = fs.readFileSync(file, 'utf8');
  if (!source.includes('SubscriptionStore.addManualNodeIfUnique(')) {
    throw new Error(`${file} bypasses atomic node deduplication`);
  }
}
NODE
printf 'subscription mutation transaction verification passed\n'

# Control-card runtime state and registered form IDs share one Preferences file. Physical
# recovery/saves must be ordered, while add/remove keep their full read-modify-write transaction
# in a second queue so concurrent form lifecycle callbacks cannot lose an identifier.
node <<'NODE'
const fs = require('fs');
const store = fs.readFileSync('entry/src/main/ets/storage/ControlCardStore.ets', 'utf8');
for (const name of ['loadFormIds', 'loadState', 'saveState']) {
  const methodAt = store.indexOf(`  static ${name}(`);
  const nextMethodAt = store.indexOf('\n  static ', methodAt + 1);
  const body = store.slice(methodAt, nextMethodAt < 0 ? store.length : nextMethodAt);
  if (methodAt < 0 || !body.includes('return ControlCardStore.enqueueOperation(')) {
    throw new Error(`${name} bypasses serialized control-card storage`);
  }
}
for (const name of ['addFormId', 'removeFormId']) {
  const methodAt = store.indexOf(`  static ${name}(`);
  const nextMethodAt = store.indexOf('\n  static ', methodAt + 1);
  const body = store.slice(methodAt, nextMethodAt < 0 ? store.length : nextMethodAt);
  if (methodAt < 0 || !body.includes('return ControlCardStore.enqueueFormMutation(')) {
    throw new Error(`${name} is outside the form-ID mutation queue`);
  }
}
const saveIdsAt = store.indexOf('  private static saveFormIds(');
const operationAt = store.indexOf('  private static enqueueOperation', saveIdsAt);
if (!store.slice(saveIdsAt, operationAt).includes('return ControlCardStore.enqueueOperation(') ||
  !store.includes('private static operationTail: Promise<void> = Promise.resolve();') ||
  !store.includes('private static formMutationTail: Promise<void> = Promise.resolve();') ||
  !store.includes('ControlCardStore.operationTail = task.then(') ||
  !store.includes('ControlCardStore.formMutationTail = task.then(') ||
  !store.includes('const idsSnapshot = ControlCardStore.uniqueIds(ids);')) {
  throw new Error('control-card operation queues or form-ID input snapshot are missing');
}
NODE
printf 'control-card storage transaction verification passed\n'

# Foreground settings changes and a WorkScheduler callback can both reconcile subscription
# jobs. Serialize the complete stop/start/index-write operation and avoid recursive queue entry
# when sync discovers that every group is disabled.
node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/services/SubscriptionBackgroundScheduler.ets', 'utf8');
const syncAt = source.indexOf('  static sync(context: common.Context)');
const syncNowAt = source.indexOf('  private static async syncNow(', syncAt);
const cancelAt = source.indexOf('  static cancel(', syncNowAt);
const cancelNowAt = source.indexOf('  private static async cancelNow(', cancelAt);
const enqueueAt = source.indexOf('  private static enqueueScheduleOperation', cancelNowAt);
if (syncAt < 0 || syncNowAt < 0 || cancelAt < 0 || cancelNowAt < 0 || enqueueAt < 0 ||
  !source.slice(syncAt, syncNowAt).includes('SubscriptionBackgroundScheduler.enqueueScheduleOperation(') ||
  !source.slice(syncNowAt, cancelAt).includes('return SubscriptionBackgroundScheduler.cancelNow(') ||
  source.slice(syncNowAt, cancelAt).includes('return SubscriptionBackgroundScheduler.cancel(') ||
  !source.slice(cancelAt, cancelNowAt).includes('const workIdsSnapshot = knownWorkIds.slice();') ||
  !source.slice(cancelAt, cancelNowAt).includes('SubscriptionBackgroundScheduler.enqueueScheduleOperation(') ||
  !source.includes('private static scheduleTail: Promise<void> = Promise.resolve();') ||
  !source.includes('SubscriptionBackgroundScheduler.scheduleTail = task.then(')) {
  throw new Error('subscription schedule reconciliation is not serialized safely');
}
NODE
printf 'subscription schedule serialization verification passed\n'

# Foreground edits, manual refreshes and WorkScheduler refreshes share one controller singleton.
# Preserve intent order across the whole network-fetch/store/schedule operation so an old fetch
# cannot finish after a newer edit and restore the old URL, nodes or active group.
node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/features/subscriptions/SubscriptionsController.ets', 'utf8');
for (const name of [
  'saveGroup', 'update', 'addGroup', 'updateGroup', 'updateAll', 'updateDue',
  'updateDueGroup', 'selectGroup', 'toggleGroup', 'removeGroup', 'moveGroup'
]) {
  const methodAt = source.indexOf(`  ${name}(`);
  const implementationAt = source.indexOf(`\n  private async ${name}Now(`, methodAt);
  const wrapper = source.slice(methodAt, implementationAt < 0 ? source.length : implementationAt);
  if (methodAt < 0 || implementationAt < 0 || !wrapper.includes('this.enqueueOperation(')) {
    throw new Error(`${name} bypasses serialized subscription controller operations`);
  }
}
if (!source.includes('private operationTail: Promise<void> = Promise.resolve();') ||
  !source.includes('this.operationTail = task.then(') ||
  !source.includes('const groupId = group.id;') ||
  !source.includes('const groupName = group.name;') ||
  !source.includes('const wasEnabled = group.enabled;')) {
  throw new Error('subscription controller operation queue or queued group snapshots are missing');
}
NODE
printf 'subscription controller operation ordering verification passed\n'

# A node object passed by a page can become stale while a subscription refresh replaces that
# group. Only persist the node that the serialized store transaction confirms is still selected;
# on mismatch rebuild UI state from the authoritative subscription instead of the stale object.
node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/features/nodes/NodesController.ets', 'utf8');
const selectAt = source.indexOf('  async selectNode(');
const removeAt = source.indexOf('\n  async removeNode(', selectAt);
const body = source.slice(selectAt, removeAt);
if (selectAt < 0 || removeAt < 0 ||
  !body.includes('this.findNodeInGroups(subscription.groups, subscription.selectedNodeId)') ||
  !body.includes('selected === null || selected.id !== node.id') ||
  !body.includes('ProfileStore.save(context, selected.outboundJson, configType)') ||
  body.includes('ProfileStore.save(context, node.outboundJson, configType)') ||
  !body.includes('return this.stateFromSubscription(')) {
  throw new Error('node selection can persist or display a stale page node after subscription replacement');
}
NODE
printf 'authoritative node selection verification passed\n'

# UDP/QUIC-only sing-box nodes cannot be verified by the temporary Xray probe. Keep that result
# neutral everywhere: show the dedicated text/color and never delete the node as a failed test.
node <<'NODE'
const fs = require('fs');
const profile = fs.readFileSync('entry/src/main/ets/core/Profile.ets', 'utf8');
const operations = fs.readFileSync('entry/src/main/ets/features/nodes/NodeOperations.ets', 'utf8');
const visuals = fs.readFileSync('entry/src/main/ets/features/subscriptions/SubscriptionVisuals.ets', 'utf8');
const detail = fs.readFileSync('entry/src/main/ets/pages/SubscriptionDetail.ets', 'utf8');
const tests = fs.readFileSync('entry/src/test/LocalUnit.test.ets', 'utf8');
if (!profile.includes("export const DELAY_STATUS_UDP_ONLY: string = 'udp-only';") ||
  !operations.includes("status !== DELAY_STATUS_UDP_ONLY") ||
  !visuals.includes("node.delayStatus === DELAY_STATUS_UDP_ONLY") ||
  !visuals.includes("return 'pending';") ||
  !detail.includes("return this.t('node.delay.udpOnly');") ||
  !tests.includes('expect(neutral.removedCount).assertEqual(0);')) {
  throw new Error('UDP-only delay results are treated as failures or can be batch-deleted');
}
NODE
printf 'neutral UDP-only delay status verification passed\n'

# Throttled and forced traffic-total saves are fire-and-forget and may overlap. Preserve call
# order, snapshot each sample before queueing, and let write failures reach the existing caller log.
node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/storage/TrafficTotalsStore.ets', 'utf8');
const loadAt = source.indexOf('  static load(context: common.Context)');
const saveAt = source.indexOf('  static save(context: common.Context', loadAt);
const enqueueAt = source.indexOf('  private static enqueueOperation', saveAt);
const saveBody = source.slice(saveAt, enqueueAt);
if (loadAt < 0 || saveAt < 0 || enqueueAt < 0 ||
  !source.slice(loadAt, saveAt).includes('return TrafficTotalsStore.enqueueOperation(') ||
  !saveBody.includes('const totalsSnapshot = normalize(totals);') ||
  !saveBody.includes('return TrafficTotalsStore.enqueueOperation(') ||
  saveBody.includes('catch (') ||
  !source.includes('private static operationTail: Promise<void> = Promise.resolve();') ||
  !source.includes('TrafficTotalsStore.operationTail = task.then(')) {
  throw new Error('traffic-total writes are not ordered or still hide persistence failures');
}
NODE
printf 'traffic-total storage ordering verification passed\n'

# Manual link entry is a separate daily add path from camera/photo scanning. It must
# parse into a redacted summary on the first action and require a second action for the
# exact unchanged input before any node-store write.
node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/pages/Import.ets', 'utf8');
const previewAt = source.indexOf('  private previewLink(): void');
const previewEnd = source.indexOf('\n  private showSingleNodePreview(', previewAt);
const importAt = source.indexOf('  private async importLink(): Promise<void>');
const importEnd = source.indexOf('\n  private previewLink(): void', importAt);
const clickAt = source.indexOf('if (this.linkPreviewValid && this.previewedImportValue === this.importBuffer.trim())');
if (!source.includes("private previewedImportValue: string = '';") || previewAt < 0 || previewEnd < 0 ||
  importAt < 0 || importEnd < 0 || clickAt < 0 ||
  !source.slice(clickAt, previewAt).includes('this.previewLink();') ||
  !source.slice(importAt, importEnd).includes('this.previewedImportValue !== value') ||
  !source.slice(previewAt, previewEnd).includes('this.previewedImportValue = value;') ||
  source.slice(previewAt, previewEnd).includes('addManualNodeIfUnique(') ||
  !source.includes("'scanner.previewEndpoint', 'endpoint', redactDiagnosticText(endpointText)")) {
  throw new Error('manual link import can save before an unchanged redacted preview is confirmed');
}
const importBody = source.slice(importAt, importEnd);
const navigation = /this[.]getUIContext[(][)][.]getRouter[(][)][.]back[(][)];/g;
let match;
let successCount = 0;
while ((match = navigation.exec(importBody)) !== null) {
  successCount++;
  const prefix = importBody.slice(Math.max(0, match.index - 100), match.index);
  if (!prefix.includes('this.clearManualImportValue();')) {
    throw new Error('manual link input retained credentials while navigating after success');
  }
}
if (successCount !== 2) {
  throw new Error(`Expected 2 successful manual link navigation paths, found ${successCount}`);
}
NODE
printf 'manual link preview confirmation verification passed\n'

# Keep the everyday node-add surface deliberately small. Existing full-config,
# proxy-chain, and policy-group records remain editable from NodeDetail for
# compatibility, but the normal Add page must not offer creation routes for
# them. The node-list header must retain the one-tap scanner entry requested by
# the product scope, including the explicit immediate-scan intent.
node <<'NODE'
const fs = require('fs');
const importSource = fs.readFileSync('entry/src/main/ets/pages/Import.ets', 'utf8');
const indexSource = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const detailSource = fs.readFileSync('entry/src/main/ets/pages/NodeDetail.ets', 'utf8');

const importBuildAt = importSource.indexOf('  build() {');
const importBuildEnd = importSource.indexOf('\n  @Builder\n  private RowDivider()', importBuildAt);
if (importBuildAt < 0 || importBuildEnd < 0) {
  throw new Error('Import page build surface could not be inspected');
}
const importBuild = importSource.slice(importBuildAt, importBuildEnd);
if (!importBuild.includes('this.LinkImportSection()') ||
  !importBuild.includes('this.ManualGridSection()') ||
  importBuild.includes('this.AdvancedConfigSection()') ||
  importBuild.includes('this.JsonImportSection()') ||
  importBuild.includes('AppRoute.ADVANCED_OUTBOUND') ||
  importBuild.includes('AppRoute.JSON_IMPORT')) {
  throw new Error('daily Add page exposes advanced/full-config creation or lost its single-node paths');
}

const nodesHeaderAt = indexSource.indexOf('  private NodesHeader()');
const nodesHeaderEnd = indexSource.indexOf('\n  @Builder\n  private NodesMenu()', nodesHeaderAt);
const scannerAt = indexSource.indexOf('  private openScannerImmediately(): void');
const scannerEnd = indexSource.indexOf('\n  private ', scannerAt + 1);
if (nodesHeaderAt < 0 || nodesHeaderEnd < 0 || scannerAt < 0 || scannerEnd < 0) {
  throw new Error('home scanner entry could not be inspected');
}
const nodesHeader = indexSource.slice(nodesHeaderAt, nodesHeaderEnd);
const scanner = indexSource.slice(scannerAt, scannerEnd);
if (!nodesHeader.includes("$r('app.media.ic_qr_code')") ||
  !nodesHeader.includes('this.openScannerImmediately();') ||
  !scanner.includes('url: AppRoute.SCANNER') ||
  !scanner.includes('startImmediately: true')) {
  throw new Error('node-list header no longer provides one-tap immediate QR scanning');
}

if (!detailSource.includes("configType === 'proxy-chain' || configType === 'policy-group'") ||
  !detailSource.includes('url: AppRoute.ADVANCED_OUTBOUND') ||
  !detailSource.includes('url: AppRoute.JSON_IMPORT')) {
  throw new Error('hiding advanced creation broke compatibility editing for existing nodes');
}

const tabsAt = indexSource.indexOf('  build() {');
const tabsEnd = indexSource.indexOf('\n  @Builder\n  private TabBarItem(', tabsAt);
const nodesAt = indexSource.indexOf('  private NodesTab()');
const nodesEnd = indexSource.indexOf('\n  @Builder\n  private NodeListConnectionBar()', nodesAt);
const barAt = nodesEnd;
const barEnd = indexSource.indexOf('\n  @Builder\n  private NodesHeader()', barAt);
const ringAt = indexSource.indexOf('  private ConnectRing()');
const ringEnd = indexSource.indexOf('\n  // 「当前连接」', ringAt);
if (tabsAt < 0 || tabsEnd < 0 || nodesAt < 0 || nodesEnd < 0 ||
  barAt < 0 || barEnd < 0 || ringAt < 0 || ringEnd < 0) {
  throw new Error('home node-list/connection surface could not be inspected');
}
const tabs = indexSource.slice(tabsAt, tabsEnd);
const firstNodes = tabs.indexOf('this.NodesTab()');
const laterConnect = tabs.indexOf('this.ConnectTab()');
const nodes = indexSource.slice(nodesAt, nodesEnd);
const bar = indexSource.slice(barAt, barEnd);
const ring = indexSource.slice(ringAt, ringEnd);
const connectAt = indexSource.indexOf('  private ConnectTab()');
const connectEnd = indexSource.indexOf('\n  @Builder\n  private ConnectRing()', connectAt);
const connect = indexSource.slice(connectAt, connectEnd);
if (firstNodes < 0 || laterConnect < 0 || firstNodes > laterConnect ||
  !indexSource.includes('@State private initialStateLoading: boolean = false;') ||
  !indexSource.includes('@State private initialStateReady: boolean = false;') ||
  !indexSource.includes('@State private initialStateFailed: boolean = false;') ||
  !nodes.includes('if (this.initialStateFailed) {') ||
  !nodes.includes('this.InitialRecoveryFailedState()') ||
  !nodes.includes('if (!this.initialStateReady) {') ||
  !nodes.includes('this.InitialLoadingState()') ||
  !nodes.includes('this.NodeListConnectionBar()') ||
  !nodes.includes('this.HomeErrorBanner()') ||
  connectAt < 0 || connectEnd < 0 || !connect.includes('this.HomeErrorBanner()') ||
  !bar.includes('this.statusLabel()') ||
  !bar.includes('this.findSelectedNodeName()') ||
  !bar.includes('.enabled(this.initialStateReady &&') ||
  !bar.includes('this.handleConnectionButton();') ||
  !ring.includes('this.handleConnectionButton();') ||
  !ring.includes('.enabled(this.initialStateReady &&') ||
  !indexSource.includes('private handleConnectionButton(): void') ||
  !indexSource.includes("Text(this.t('home.loading'))") ||
  !indexSource.includes("Button(this.t('action.retry'))") ||
  !indexSource.includes('private HomeErrorBanner()')) {
  throw new Error('home must open on the node list with one shared connection action');
}

const initialLoadAt = indexSource.indexOf('  private async loadInitialState(): Promise<void>');
const initializeAt = indexSource.indexOf('  private async initializePageState(): Promise<void>', initialLoadAt);
const retryAt = indexSource.indexOf('  private retryInitialState(): void', initializeAt);
const totalsAt = indexSource.indexOf('  private async loadTrafficTotals(): Promise<void>', retryAt);
const settingsAt = indexSource.indexOf('  private async loadSettings(strict: boolean = false)');
const nodesLoadAt = indexSource.indexOf('  private async loadNodes(strict: boolean = false)');
const runtimeRefreshAt = indexSource.indexOf('  private async refreshRuntime(strict: boolean = false)');
const runtimeRefreshPerformAt = indexSource.indexOf('  private async performRuntimeRefresh(strict: boolean)');
if (initialLoadAt < 0 || initializeAt < 0 || retryAt < 0 || totalsAt < 0 ||
  settingsAt < 0 || nodesLoadAt < 0 || runtimeRefreshAt < 0 || runtimeRefreshPerformAt < 0) {
  throw new Error('strict initial state recovery could not be inspected');
}
const initialLoad = indexSource.slice(initialLoadAt, initializeAt);
const initialize = indexSource.slice(initializeAt, retryAt);
const retry = indexSource.slice(retryAt, totalsAt);
if (!initialLoad.includes('await this.loadSettings(true);') ||
  !initialLoad.includes('await this.loadNodes(true);') ||
  !initialLoad.includes('await this.refreshRuntime(true);') ||
  !initialize.includes('this.initialStateReady = true;') ||
  !initialize.includes('this.initialStateFailed = true;') ||
  !initialize.includes('if (this.initialStateReady && this.hasPendingExternalIntent())') ||
  initialize.includes('this.initialStateReady = true;\n      // Watch') ||
  !retry.includes('this.initialStateFailed = false;') ||
  !retry.includes('this.initializePageState();')) {
  throw new Error('failed initial reads can still enable controls or consume pending actions');
}
for (const start of [settingsAt, nodesLoadAt, runtimeRefreshPerformAt]) {
  const nextMethod = indexSource.indexOf('\n  private ', start + 1);
  const body = indexSource.slice(start, nextMethod);
  if (!body.includes('if (strict) {') || !body.includes('throw new Error(this.lastError);')) {
    throw new Error('a critical initial read still hides its failure');
  }
}
const runtimeRefreshEnd = indexSource.indexOf('\n  private async performRuntimeRefresh(', runtimeRefreshAt);
const runtimeRefresh = indexSource.slice(runtimeRefreshAt, runtimeRefreshEnd);
if (!indexSource.includes('private runtimeRefreshBusy: boolean = false;') ||
  !indexSource.includes('private runtimeRefreshTail: Promise<void> = Promise.resolve();') ||
  runtimeRefreshEnd < 0 ||
  !runtimeRefresh.includes('if (!strict && this.runtimeRefreshBusy) {') ||
  !runtimeRefresh.includes('const previous = this.runtimeRefreshTail;') ||
  !runtimeRefresh.includes('this.performRuntimeRefresh(strict)') ||
  !runtimeRefresh.includes('this.runtimeRefreshTail = settled;') ||
  !runtimeRefresh.includes('if (this.runtimeRefreshTail === settled) {')) {
  throw new Error('periodic and authoritative runtime refreshes can overlap or reorder');
}
const runtimeRefreshPerformEnd = indexSource.indexOf('\n  // 首页「当前连接」', runtimeRefreshPerformAt);
const runtimeRefreshPerform = indexSource.slice(runtimeRefreshPerformAt, runtimeRefreshPerformEnd);
if (runtimeRefreshPerformEnd < 0 ||
  !runtimeRefreshPerform.includes('SHARED_RUNTIME_CONTROLLER.refresh(context, this.language, strict)')) {
  throw new Error('strict page recovery does not request a fresh shared runtime read');
}
NODE
printf 'simplified add surface verification passed\n'

acceptance_duplicate_ids="$(sed -n 's/^| \([A-Z][0-9][0-9]*\) |.*/\1/p' docs/device-acceptance.md | sort | uniq -d)"
if [ -n "${acceptance_duplicate_ids}" ]; then
  printf 'duplicate device acceptance ids: %s\n' "${acceptance_duplicate_ids}" >&2
  exit 1
fi
printf 'device acceptance id uniqueness passed\n'

# User-facing documentation must not promise that camera/share/clipboard payloads are
# shown in full. That would contradict the screenshot-safe confirmation UI and can make
# reviewers treat a credential disclosure as intended behavior.
if grep -Fq '都会先完整展示目标内容' README.zh-CN.md ||
  grep -Fq 'display the full target' README.md ||
  ! grep -Fq 'UUID、密码和订阅 Token 默认不显示' README.zh-CN.md ||
  ! grep -Fq 'Full share links, UUIDs, passwords, and' README.md; then
  printf 'external import privacy documentation is inconsistent\n' >&2
  exit 1
fi
printf 'external import privacy documentation verification passed\n'

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
const source = fs.readFileSync('entry/src/main/ets/pages/Scanner.ets', 'utf8');
const start = source.indexOf('  private async importResult(): Promise<void> {');
const end = source.indexOf('\n  private updateImportPreview(', start);
if (start < 0 || end < 0) throw new Error('Scanner importResult method could not be inspected');
const body = source.slice(start, end);
const navigation = /router[.](?:back[(][)]|pushUrl[(][{] url: AppRoute[.]SUBSCRIPTIONS [}][)]);/g;
let match;
let count = 0;
while ((match = navigation.exec(body)) !== null) {
  count++;
  const prefix = body.slice(Math.max(0, match.index - 120), match.index);
  if (!prefix.includes('this.clearImportValue();')) {
    throw new Error('Scanner retained sensitive import text while navigating after success');
  }
}
if (count !== 5) throw new Error(`Expected 5 successful Scanner navigation paths, found ${count}`);
NODE
printf 'scanner successful import cleanup verification passed\n'

node <<'NODE'
const fs = require('fs');
const source = fs.readFileSync('entry/src/main/ets/utils/QrScan.ets', 'utf8');
const permissionAt = source.indexOf('export async function requestCameraPermission(');
const scanAt = source.indexOf('\nexport async function scanQrCode(', permissionAt);
const permission = source.slice(permissionAt, scanAt);
if (permissionAt < 0 || scanAt < 0 ||
  !permission.includes('await atManager.requestPermissionsFromUser(') || permission.includes('catch (')) {
  throw new Error('camera permission service failures can still be misreported as user denial');
}
NODE
printf 'scanner camera permission error classification passed\n'

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
const settingsPage = fs.readFileSync('entry/src/main/ets/pages/Settings.ets', 'utf8');

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
const coreLoadAt = coreSelection.indexOf('  static load(context: common.Context)');
const coreSaveAt = coreSelection.indexOf('  static save(context: common.Context', coreLoadAt);
const coreQueueAt = coreSelection.indexOf('  private static enqueueOperation', coreSaveAt);
if (coreLoadAt < 0 || coreSaveAt < 0 || coreQueueAt < 0 ||
  !coreSelection.slice(coreLoadAt, coreSaveAt).includes('return CoreSelectionStore.enqueueOperation(') ||
  !coreSelection.slice(coreSaveAt, coreQueueAt).includes('return CoreSelectionStore.enqueueOperation(') ||
  coreSelection.slice(coreLoadAt, coreQueueAt).includes('catch (') ||
  !coreSelection.includes('private static operationTail: Promise<void> = Promise.resolve();') ||
  !coreSelection.includes('CoreSelectionStore.operationTail = task.then(')) {
  throw new Error('core selection storage is unordered or hides persistence failures');
}
if (!settingsPage.includes('private coreSaveGeneration: number = 0;') ||
  !settingsPage.includes('const previousCoreType = this.settingCoreType;') ||
  !settingsPage.includes('const saveGeneration = ++this.coreSaveGeneration;') ||
  !settingsPage.includes('if (saveGeneration === this.coreSaveGeneration) {') ||
  !settingsPage.includes('this.settingCoreType = previousCoreType;')) {
  throw new Error('core selector UI does not isolate stale saves or roll back the latest failed choice');
}

const xrayStartMarker = '  async start(context: common.Context, profile: ProxyProfile, settings?: AppSettings)';
const xrayStart = controller.indexOf(xrayStartMarker);
const singboxStart = controller.indexOf('\n  // sing-box 内核启动路径', xrayStart);
if (xrayStart < 0 || singboxStart < 0) {
  throw new Error('ConnectionController Xray start method could not be inspected');
}
const startBody = controller.slice(xrayStart, singboxStart);
const requestedModeAssignment = startBody.indexOf('this.runtimeMode = requestedMode;');
const firstCoreSelectionAwait = startBody.indexOf('await CoreSelectionStore.load(context)');
if (requestedModeAssignment < 0 || firstCoreSelectionAwait < 0 ||
  requestedModeAssignment > firstCoreSelectionAwait) {
  throw new Error('connection mode must be fixed before the first cancellable startup await');
}
const coreLoadCatch = startBody.indexOf('return this.failStartPreparation(startGeneration, error as Object);', firstCoreSelectionAwait);
const postCoreGenerationCheck = startBody.indexOf('if (!this.isCurrentStart(startGeneration))', firstCoreSelectionAwait);
if (!startBody.includes('let coreType: CoreType;') || coreLoadCatch < firstCoreSelectionAwait ||
  postCoreGenerationCheck < coreLoadCatch) {
  throw new Error('core selection read failures can leave connection startup stuck');
}
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

const stopMethodStart = controller.indexOf('  async stop(context: common.Context): Promise<ConnectionSnapshot>');
const stopMethodEnd = controller.indexOf('\n  // 隧道已被 VPN 扩展在后台自动断开', stopMethodStart);
const stopMethod = controller.slice(stopMethodStart, stopMethodEnd);
const stopCatchAt = stopMethod.indexOf('} catch (error) {');
const fallbackVpnStopAt = stopMethod.indexOf('vpnExtension.stopVpnExtensionAbility(createStopVpnWant())', stopCatchAt);
const fallbackVpnGuardAt = stopMethod.lastIndexOf(
  'if (this.runtimeMode === APP_MODE_VPN && !systemStopAttempted)', fallbackVpnStopAt);
if (stopMethodStart < 0 || stopMethodEnd < 0 || stopCatchAt < 0 || fallbackVpnStopAt < stopCatchAt ||
  fallbackVpnGuardAt < stopCatchAt) {
  throw new Error('local proxy stop failures can still fall through to VPN Extension cleanup');
}

const reloadStart = controller.indexOf('  async reloadProxyOnlyAfterNetworkChange(');
const reloadEnd = controller.indexOf('\n  private isCurrentProxyReload(', reloadStart);
const reload = controller.slice(reloadStart, reloadEnd);
const reloadCatch = reload.indexOf('} catch (error) {');
const reloadRollback = reload.indexOf('const stopResult = stopNativeXray();', reloadCatch);
const reloadCleanupLatch = reload.indexOf('this.cleanupRequired = !stopResult.ok;', reloadRollback);
const reloadError = reload.indexOf('this.status = ConnectionStatus.ERROR;', reloadCleanupLatch);
if (reloadStart < 0 || reloadEnd < 0 || reloadCatch < 0 || reloadRollback < reloadCatch ||
  reloadCleanupLatch < reloadRollback || reloadError < reloadCleanupLatch ||
  !reload.includes('本地核心清理失败：${stopResult.message}')) {
  throw new Error('proxy-only handover rollback can hide residual native core resources');
}

if (!config.includes('if (vpnMode) {\n    inbounds.push(tunInbound);') ||
  !config.includes('settings.localSocksEnabled || proxyOnlyMode')) {
  throw new Error('Xray runtime config no longer keeps TUN and local proxy inbounds mode-scoped');
}
NODE
printf 'optional TUN/runtime mode separation verification passed\n'

# The core config, VpnConfig and TUN engine form one launch transaction. The UI process
# must pass the exact normalized settings snapshot used to build the core config; loading
# mutable Preferences later in the Extension could mix IPv6/DNS/app-routing/MTU settings
# from a newer edit into the older core config.
node <<'NODE'
const fs = require('fs');
const constants = fs.readFileSync('entry/src/main/ets/vpn/VpnConstants.ets', 'utf8');
const controller = fs.readFileSync('entry/src/main/ets/services/ConnectionController.ets', 'utf8');
const ability = fs.readFileSync('entry/src/main/ets/vpn/HeyVpnAbility.ets', 'utf8');

if (!constants.includes("export const VPN_SETTINGS_SNAPSHOT_KEY: string = 'settingsSnapshotJson';") ||
  !constants.includes("settingsSnapshotJson: (settingsSnapshot === undefined ? '' : JSON.stringify(settingsSnapshot)) as Object")) {
  throw new Error('VPN start Want does not carry its immutable settings snapshot');
}
if (!controller.includes('handoverConfigJson,\n        runtimeSettings') ||
  !controller.includes('undefined,\n        settings')) {
  throw new Error('Xray and sing-box VPN starts do not pass their launch settings snapshot');
}
const startAt = ability.indexOf('  private async startVpn(');
const resolverAt = ability.indexOf('  private async resolveStartSettings(', startAt);
if (startAt < 0 || resolverAt < 0 ||
  !ability.slice(startAt, resolverAt).includes('const settings = await this.resolveStartSettings(want);') ||
  !ability.slice(resolverAt).includes("const selection = SettingsStore.selectStoredSettings(snapshotJson, '');") ||
  !ability.slice(resolverAt).includes("throw new Error('VPN start settings snapshot is invalid.');")) {
  throw new Error('VPN Extension does not validate and use the launch settings snapshot');
}
NODE
printf 'VPN launch settings snapshot verification passed\n'

node <<'NODE'
const fs = require('fs');
const ability = fs.readFileSync('entry/src/main/ets/entryability/EntryAbility.ets', 'utf8');
const index = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const newWantAt = ability.indexOf('  onNewWant(');
const newWantEnd = ability.indexOf('\n  // Stash a deep-link', newWantAt);
const newWant = ability.slice(newWantAt, newWantEnd);
if (newWantAt < 0 || newWantEnd < 0 || !newWant.includes('this.stashAutoStartupLaunch(launchParam);')) {
  throw new Error('AUTO_STARTUP delivered to an existing UIAbility is not recorded');
}
if (!index.includes("@StorageLink('pendingAutoStartupLaunch') @Watch('onPendingExternalIntentChanged')") ||
  !index.includes('return this.pendingAutoStartupSignal || this.pendingDeepLinkSignal.trim().length > 0')) {
  throw new Error('warm AUTO_STARTUP delivery cannot wake the serialized pending-work consumer');
}
const consumerAt = index.indexOf('  private consumePendingExternalIntentSoon(): void');
const consumerEnd = index.indexOf('\n  private async handlePendingRuntimeSettingsRestart()', consumerAt);
const consumer = index.slice(consumerAt, consumerEnd);
const recoveryAt = consumer.indexOf('if (!await this.recoverForegroundAuthority())');
const startupAt = consumer.indexOf('await this.handlePendingAutoStartupLaunch();');
const authorityAt = consumer.indexOf('private async recoverForegroundAuthority(): Promise<boolean>');
const authorityEnd = consumer.indexOf('\n  private recordForegroundRecoveryError(', authorityAt);
const authority = consumer.slice(authorityAt, authorityEnd);
if (consumerAt < 0 || consumerEnd < 0 || recoveryAt < 0 || startupAt < recoveryAt ||
  authorityAt < 0 || authorityEnd < 0 ||
  !authority.includes('await this.loadSettings(true);') ||
  !authority.includes('await this.loadNodes(true);') ||
  !authority.includes('await this.refreshRuntime(true);') ||
  !consumer.includes('let completed = false;') ||
  !consumer.includes('if (completed && this.hasPendingExternalIntent())')) {
  throw new Error('warm AUTO_STARTUP is not serialized after authoritative runtime recovery');
}
const foregroundAt = index.indexOf('  private async refreshFromStorage(): Promise<void>');
const foregroundEnd = index.indexOf('\n  private onPendingExternalIntentChanged()', foregroundAt);
const foreground = index.slice(foregroundAt, foregroundEnd);
if (foregroundAt < 0 || foregroundEnd < 0 ||
  !foreground.includes('if (!await this.recoverForegroundAuthority())') ||
  foreground.indexOf('await this.handlePendingRuntimeSettingsRestart();') <
    foreground.indexOf('if (!await this.recoverForegroundAuthority())')) {
  throw new Error('foreground resume actions can run after failed authoritative reads');
}
const autoStartAt = index.indexOf('  private async handlePendingAutoStartupLaunch(): Promise<void>');
const autoStartEnd = index.indexOf('\n  // Imports a stashed deep link', autoStartAt);
const autoStart = index.slice(autoStartAt, autoStartEnd);
const controlAt = index.indexOf('  private async handleControlDeepLink(');
const controlEnd = index.indexOf('\n  private async selectControlTargetNode(', controlAt);
const control = index.slice(controlAt, controlEnd);
const stopAt = index.indexOf('  private async stopConnection(): Promise<void>');
const stopEnd = index.indexOf('\n  private async stopConnectionInternal()', stopAt);
const stop = index.slice(stopAt, stopEnd);
if (autoStartAt < 0 || autoStartEnd < 0 || controlAt < 0 || controlEnd < 0 || stopAt < 0 || stopEnd < 0 ||
  !index.includes('private explicitStopGeneration: number = 0;') ||
  !autoStart.includes('const expectedStopGeneration = this.explicitStopGeneration;') ||
  !autoStart.includes("await this.handleControlDeepLink('start', '', expectedStopGeneration);") ||
  control.split('expectedStopGeneration !== this.explicitStopGeneration').length - 1 < 2 ||
  !stop.includes('this.explicitStopGeneration++;') ||
  stop.split("AppStorage.setOrCreate('pendingAutoStartupLaunch', false);").length - 1 < 2) {
  throw new Error('an in-flight AUTO_STARTUP continuation can reconnect after an explicit stop');
}
NODE
printf 'warm AUTO_STARTUP delivery verification passed\n'

node <<'NODE'
const fs = require('fs');
const policy = fs.readFileSync('entry/src/main/ets/core/ConnectionInteraction.ets', 'utf8');
const index = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
if (!policy.includes('status === ConnectionStatus.STARTING') ||
  !policy.includes("action === 'stop' || action === 'toggle'")) {
  throw new Error('connection-start cancellation policy is incomplete');
}
const connectionButtonAt = index.indexOf('  private handleConnectionButton(): void');
const connectionButtonEnd = index.indexOf('\n  private isBusy(): boolean', connectionButtonAt);
const connectionButton = index.slice(connectionButtonAt, connectionButtonEnd);
if (connectionButtonAt < 0 || connectionButtonEnd < 0 ||
  !connectionButton.includes('if (!this.initialStateReady)') ||
  !connectionButton.includes('if (this.isBusy() && !canCancelStartingConnection(this.status))') ||
  !connectionButton.includes('if (canCancelStartingConnection(this.status) || this.shouldStopBeforeStart())') ||
  !connectionButton.includes('this.stopConnection();') ||
  !index.includes('shouldDeferBusyControlAction(action, this.status, this.isBusy())') ||
  !index.includes('shouldOfferConnectionStop(this.status, SHARED_RUNTIME_CONTROLLER.requiresCleanup())')) {
  throw new Error('home or external controls no longer expose safe startup cancellation');
}
const reconnectAt = index.indexOf('  private async reconnectService(): Promise<void>');
const reconnectEnd = index.indexOf('\n  private async exportAllNodesToClipboard()', reconnectAt);
const reconnect = index.slice(reconnectAt, reconnectEnd);
const cleanupGuard = reconnect.indexOf('if (SHARED_RUNTIME_CONTROLLER.requiresCleanup())');
const firstDirectStart = reconnect.indexOf('await this.startConnectionInternal();');
if (reconnectAt < 0 || reconnectEnd < 0 || cleanupGuard < 0 || firstDirectStart < 0 ||
  cleanupGuard > firstDirectStart || !reconnect.slice(cleanupGuard, firstDirectStart).includes('await this.stopConnection();')) {
  throw new Error('service restart can bypass incomplete-cleanup isolation');
}
NODE
printf 'connection startup cancellation verification passed\n'

node <<'NODE'
const fs = require('fs');
const runtime = fs.readFileSync('entry/src/main/ets/features/runtime/RuntimeController.ets', 'utf8');
const startAt = runtime.indexOf('  async start(context: common.Context, profile: ProxyProfile');
const stopAt = runtime.indexOf('\n  async stop(context: common.Context', startAt);
const reconcileAt = runtime.indexOf('\n  // 网络场景在后台', stopAt);
if (startAt < 0 || stopAt < 0 || reconcileAt < 0) {
  throw new Error('RuntimeController start/stop methods could not be inspected');
}
const start = runtime.slice(startAt, stopAt);
const stop = runtime.slice(stopAt, reconcileAt);
const controllerAwait = start.indexOf('await this.controller.start(context, profile, settings);');
const generationGuard = start.indexOf('if (runtimeStartGeneration !== this.runtimeStartGeneration)', controllerAwait);
const applySnapshot = start.indexOf('this.applySnapshot(snapshot, language);', controllerAwait);
if (!runtime.includes('private runtimeStartGeneration: number = 0;') ||
  !start.includes('const runtimeStartGeneration = ++this.runtimeStartGeneration;') ||
  controllerAwait < 0 || generationGuard < controllerAwait || applySnapshot < generationGuard ||
  !stop.includes('this.runtimeStartGeneration++;')) {
  throw new Error('runtime start continuations are not generation-isolated from cancellation');
}
const runningBranch = start.indexOf('if (this.status === ConnectionStatus.RUNNING)', applySnapshot);
const connectivity = start.indexOf('this.scheduleRuntimeConnectivityInfo(', runningBranch);
const errorBranch = start.indexOf('else if (this.status === ConnectionStatus.ERROR)', runningBranch);
if (runningBranch < 0 || connectivity < runningBranch || start.includes('NetSceneStopFlag.clear(context)') ||
  errorBranch < connectivity || start.indexOf('log.vpnStartIncomplete', errorBranch) < errorBranch) {
  throw new Error('cancelled starts may still clear flags, schedule probes, or report a false failure');
}
NODE
printf 'runtime startup continuation isolation verification passed\n'

node <<'NODE'
const fs = require('fs');
const connection = fs.readFileSync('entry/src/main/ets/services/ConnectionController.ets', 'utf8');
const health = fs.readFileSync('entry/src/main/ets/core/RuntimeHealth.ets', 'utf8');
const runtime = fs.readFileSync('entry/src/main/ets/features/runtime/RuntimeController.ets', 'utf8');
const runtimeStateStore = fs.readFileSync('entry/src/main/ets/services/VpnRuntimeStateStore.ets', 'utf8');
const controlCardManager = fs.readFileSync('entry/src/main/ets/services/ControlCardManager.ets', 'utf8');
const subscriptionWorker = fs.readFileSync('entry/src/main/ets/work/SubscriptionUpdateWorkAbility.ets', 'utf8');
const indexPage = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const vpn = fs.readFileSync('entry/src/main/ets/vpn/HeyVpnAbility.ets', 'utf8');
const geoReadiness = fs.readFileSync('entry/src/main/ets/services/GeoCoreReadiness.ets', 'utf8');
if (!connection.includes('vpnSessionId: string;') ||
  !connection.includes('vpnSessionId: this.vpnSessionId')) {
  throw new Error('runtime snapshots no longer expose the owning VPN session for diagnostic matching');
}
const vpnStartAt = vpn.indexOf('  private async startVpn(');
const vpnConnectionCreateAt = vpn.indexOf('vpnExtension.createVpnConnection(this.context)', vpnStartAt);
const geoFenceAt = vpn.indexOf('assertGeoAssetsStableForCore(this.context.filesDir);', vpnStartAt);
if (vpnStartAt < 0 || geoFenceAt < vpnStartAt || vpnConnectionCreateAt < geoFenceAt ||
  !geoReadiness.includes('return !hasPendingGeoReplacementArtifacts(names);')) {
  throw new Error('VPN Extension can load a core while a Geo replacement transaction is incomplete');
}
const vpnReloadAt = vpn.indexOf('  private async reloadCoreAfterNetworkChange(');
const vpnReloadStopAt = vpn.indexOf("this.activeCoreType === 'singbox' ? stopNativeSingbox() : stopNativeXray()", vpnReloadAt);
const vpnReloadGeoAt = vpn.indexOf('if (!areGeoAssetsStableForCore(this.context.filesDir))', vpnReloadAt);
const vpnReloadRetrySignatureAt = vpn.indexOf("this.netSceneSignature = '';", vpnReloadGeoAt);
if (vpnReloadAt < 0 || vpnReloadGeoAt < vpnReloadAt || vpnReloadRetrySignatureAt < vpnReloadGeoAt ||
  vpnReloadStopAt < vpnReloadRetrySignatureAt) {
  throw new Error('VPN handover core reload can race a cross-process Geo replacement or lose its retry');
}
const connectionStartAt = connection.indexOf(
  '  async start(context: common.Context, profile: ProxyProfile, settings?: AppSettings)');
const connectionValidationAt = connection.indexOf(
  'const validation = normalizeConfigInput(', connectionStartAt);
const connectionGeoFenceAt = connection.indexOf(
  'assertGeoAssetsStableForCore(context.filesDir);', connectionStartAt);
if (connectionStartAt < 0 || connectionGeoFenceAt < connectionStartAt ||
  connectionValidationAt < connectionGeoFenceAt) {
  throw new Error('proxy-only startup can reach config/core preparation before the Geo transaction fence');
}
if (!health.includes('expectedSessionId: string') || !health.includes('eventDetails: string | undefined') ||
  !health.includes('eventDetails.startsWith(`${marker};`)')) {
  throw new Error('VPN diagnostic errors are not matched to the exact active session');
}
if (!runtimeStateStore.includes('(!value.active && (value.xrayRunning || value.tunRunning))')) {
  throw new Error('an inactive VPN state can still claim running core/TUN resources');
}
if (!runtimeStateStore.includes('static readWithEvidence(context: common.Context): PersistedVpnRuntimeStateReadResult') ||
  !runtimeStateStore.includes('export function inspectPersistedVpnRuntimeArtifacts(') ||
  !runtimeStateStore.includes('const authoritative = temp.exists ? temp : (primary.exists ? primary : backup);') ||
  !runtimeStateStore.includes('state: selectPersistedVpnRuntimeState(primary.content, backup.content, temp.content)') ||
  !runtimeStateStore.includes('authoritativeArtifactInvalid: authoritative.exists &&') ||
  !runtimeStateStore.includes('private static readArtifactSnapshot(path: string): VpnRuntimeArtifactSnapshot') ||
  !runtimeStateStore.includes('return { exists: true, content: fs.readTextSync(path) };') ||
  !runtimeStateStore.includes('const first = VpnRuntimeStateStore.readArtifactSet(context);') ||
  !runtimeStateStore.includes('const confirmed = VpnRuntimeStateStore.readArtifactSet(context);') ||
  !runtimeStateStore.includes('if (!VpnRuntimeStateStore.sameArtifactSet(first, confirmed))') ||
  !runtimeStateStore.includes('return { state: result.state, authoritativeArtifactInvalid: true };') ||
  !runtimeStateStore.includes('// 无法确认是瞬时访问错误还是损坏，涉及订阅凭据时必须保守处理。')) {
  throw new Error('VPN state and artifact validity are not derived from one authoritative snapshot');
}
const workerVpnBeforeAt = subscriptionWorker.indexOf(
  'const vpnStateBefore = VpnRuntimeStateStore.readWithEvidence(context);');
const workerCardAt = subscriptionWorker.indexOf(
  'const controlCardState = await ControlCardStore.loadState(context);', workerVpnBeforeAt);
const workerVpnAfterAt = subscriptionWorker.indexOf(
  'const vpnStateAfter = VpnRuntimeStateStore.readWithEvidence(context);', workerCardAt);
const workerRouteAt = subscriptionWorker.indexOf(
  'this.vpnMayOwnNetwork(vpnStateBefore) || this.vpnMayOwnNetwork(vpnStateAfter)', workerVpnAfterAt);
if (workerVpnBeforeAt < 0 || workerCardAt < workerVpnBeforeAt || workerVpnAfterAt < workerCardAt ||
  workerRouteAt < workerVpnAfterAt ||
  !subscriptionWorker.includes('read.authoritativeArtifactInvalid || (read.state !== null && read.state.active)')) {
  throw new Error('background subscriptions can miss a VPN transition while loading persisted routing state');
}
if (!controlCardManager.includes('async persistRuntimeState(') ||
  !controlCardManager.includes('return ControlCardStore.saveState(')) {
  throw new Error('control card runtime state cannot be durably fenced before data-plane startup');
}
const pageStartAt = indexPage.indexOf('  private async startConnectionInternal(): Promise<boolean>');
const pageStartEnd = indexPage.indexOf('\n  private showProxySharingStartWarning(', pageStartAt);
const pageStart = indexPage.slice(pageStartAt, pageStartEnd);
const pageStartingAt = pageStart.indexOf('this.status = ConnectionStatus.STARTING;');
const pagePersistAt = pageStart.indexOf('await CONTROL_CARD_MANAGER.persistRuntimeState(', pageStartingAt);
const pageCancelAt = pageStart.indexOf('if (this.status !== ConnectionStatus.STARTING)', pagePersistAt);
const pageControllerStartAt = pageStart.indexOf('await SHARED_RUNTIME_CONTROLLER.start(', pageCancelAt);
if (pageStartAt < 0 || pageStartEnd < 0 || pageStartingAt < 0 || pagePersistAt < pageStartingAt ||
  pageCancelAt < pagePersistAt || pageControllerStartAt < pageCancelAt) {
  throw new Error('UI startup can open the data plane before persisting STARTING or resume after cancellation');
}
const startWaitAt = connection.indexOf('  private async waitForVpnStartEvent(');
const cleanupWaitAt = connection.indexOf('  private async waitForVpnCleanupEvent(', startWaitAt);
const diagnosticFindAt = connection.indexOf('  private async findDiagnosticEvent(', cleanupWaitAt);
const startWait = connection.slice(startWaitAt, cleanupWaitAt);
const cleanupWait = connection.slice(cleanupWaitAt, diagnosticFindAt);
if (startWaitAt < 0 || cleanupWaitAt < 0 || diagnosticFindAt < 0 ||
  startWait.split('VpnRuntimeStateStore.readWithEvidence(context)').length - 1 < 2 ||
  cleanupWait.split('VpnRuntimeStateStore.readWithEvidence(context)').length - 1 < 2 ||
  startWait.split('persistedRead.authoritativeArtifactInvalid').length - 1 < 2 ||
  cleanupWait.split('persistedRead.authoritativeArtifactInvalid').length - 1 < 2 ||
  startWait.includes('VpnRuntimeStateStore.read(context)') ||
  cleanupWait.includes('VpnRuntimeStateStore.read(context)')) {
  throw new Error('VPN start/stop confirmation can trust a fallback state behind an untrusted artifact');
}
const stopMethodAt = connection.indexOf('\n  async stop(context: common.Context');
const reconcileStoppedAt = connection.indexOf('\n  // 隧道已被 VPN 扩展在后台自动断开', stopMethodAt);
const stopMethod = connection.slice(stopMethodAt, reconcileStoppedAt);
const cleanupIncompleteAt = stopMethod.indexOf('if (cleanupEvent.message === VPN_CLEANUP_INCOMPLETE_MESSAGE)');
const cleanupIncompleteThrowAt = stopMethod.indexOf('throw new Error(this.formatDiagnosticEvent(cleanupEvent));', cleanupIncompleteAt);
const idleStopWarningAt = stopMethod.indexOf("hilog.info(LOG_DOMAIN, LOG_TAG, 'idle VPN extension stop did not complete", cleanupIncompleteThrowAt);
const idleStatusAt = stopMethod.indexOf('this.status = ConnectionStatus.IDLE;', idleStopWarningAt);
if (stopMethodAt < 0 || reconcileStoppedAt < 0 || cleanupIncompleteAt < 0 ||
  cleanupIncompleteThrowAt < cleanupIncompleteAt || idleStopWarningAt < cleanupIncompleteThrowAt ||
  idleStatusAt < idleStopWarningAt ||
  !stopMethod.includes('// cleanup finished 已由同一会话的持久状态/诊断确认核心、tun2socks 与 VpnConnection')) {
  throw new Error('an idle VPN Extension stop failure can still override confirmed data-plane cleanup');
}
const cardReconcileAt = controlCardManager.indexOf('  private async loadReconciledState(');
const cardReconcileEnd = controlCardManager.indexOf('\n  private async updateOne(', cardReconcileAt);
const cardReconcile = controlCardManager.slice(cardReconcileAt, cardReconcileEnd);
const cardProbeAt = cardReconcile.indexOf('await probeRuntimeTcpHealth(VPN_DATA_SOCKS_PORT)');
const cardRereadAt = cardReconcile.indexOf('VpnRuntimeStateStore.readWithEvidence(context)', cardProbeAt);
const cardHealthyReturnAt = cardReconcile.indexOf('return state;', cardRereadAt);
if (cardReconcileAt < 0 || cardReconcileEnd < 0 || cardProbeAt < 0 ||
  cardRereadAt < cardProbeAt || cardHealthyReturnAt < cardRereadAt ||
  !cardReconcile.includes('confirmed.sessionId === expectedSessionId') ||
  !cardReconcile.includes('confirmed.startedAt === expectedStartedAt') ||
  !cardReconcile.includes('ConnectionStatus.ERROR') ||
  !cardReconcile.includes("translate(state.language, 'runtime.vpnHealthLost')") ||
  !cardReconcile.includes('APP_MODE_VPN,\n          true') ||
  cardReconcile.includes('ControlCardStore.saveState(\n          context,\n          buildControlCardFormData(\n          state.language,\n          ConnectionStatus.ERROR')) {
  throw new Error('control card can trust a stale VPN heartbeat without a session-bound data-plane probe');
}
if (!cardReconcile.includes('const persistedRead = VpnRuntimeStateStore.readWithEvidence(context);') ||
  !cardReconcile.includes('if (persistedRead.authoritativeArtifactInvalid)') ||
  !cardReconcile.includes('!confirmedRead.authoritativeArtifactInvalid') ||
  !cardReconcile.includes('// 可能已回退到旧 inactive/active 备份') ||
  !cardReconcile.includes('APP_MODE_VPN,\n        true')) {
  throw new Error('control card can present a corrupt VPN state fallback as authoritative');
}
const applyAt = runtime.indexOf('  private async applyDiagnosticError(');
const apply = runtime.slice(applyAt);
const refreshAt = runtime.indexOf('  async refresh(\n    context: common.Context,');
const performRefreshAt = runtime.indexOf('  private async performRefresh(', refreshAt);
const reconcileCallAt = runtime.indexOf('await this.reconcilePersistedVpnState(context, language);', performRefreshAt);
const diagnosticPrecheckAt = runtime.indexOf('await this.applyPendingVpnDiagnosticError(context, language);', performRefreshAt);
if (applyAt < 0 || refreshAt < 0 || performRefreshAt < refreshAt ||
  diagnosticPrecheckAt < performRefreshAt || reconcileCallAt < diagnosticPrecheckAt ||
  !apply.includes('for (let index = 0; index < events.length; index++)') ||
  !apply.includes('connection.vpnSessionId') || !apply.includes('candidate.details')) {
  throw new Error('cleanup info/state can hide a fatal current-session VPN diagnostic');
}
const refreshWrapper = runtime.slice(refreshAt, performRefreshAt);
if (!runtime.includes('private runtimeRefreshBusy: boolean = false;') ||
  !runtime.includes('private runtimeRefreshTail: Promise<void> = Promise.resolve();') ||
  !refreshWrapper.includes('if (!authoritative && this.runtimeRefreshBusy) {') ||
  !refreshWrapper.includes('return this.snapshot();') ||
  !refreshWrapper.includes('this.performRefresh(context, language)') ||
  !refreshWrapper.includes('this.runtimeRefreshTail = settled;') ||
  !refreshWrapper.includes('if (this.runtimeRefreshTail === settled) {')) {
  throw new Error('cross-page runtime refreshes are not single-flight or authoritative reads are not serialized');
}
const persistedReconcileAt = runtime.indexOf('  private async reconcilePersistedVpnState(');
const persistedReconcileEnd = runtime.indexOf('\n  private resetUnhealthyVpnStateConfirmation()', persistedReconcileAt);
const persistedReconcile = runtime.slice(persistedReconcileAt, persistedReconcileEnd);
const recoveredProbeAt = persistedReconcile.indexOf('await probeRuntimeSocksHealth(VPN_DATA_SOCKS_PORT)');
const firstCandidateCheckAt = persistedReconcile.indexOf(
  'this.isCurrentRecoveredVpnCandidate(context, recoveredSessionId, recoveredStartedAt)', recoveredProbeAt);
const stopFlagAt = persistedReconcile.indexOf(
  'await NetSceneStopFlag.wasStopped(context, recoveredStartedAt)', firstCandidateCheckAt);
const secondCandidateCheckAt = persistedReconcile.indexOf(
  'this.isCurrentRecoveredVpnCandidate(context, recoveredSessionId, recoveredStartedAt)', stopFlagAt);
const recoveredApplyAt = persistedReconcile.indexOf(
  'this.controller.reconcileRunning(\n        recoveredStartedAt, persisted.coreType, recoveredSessionId)', stopFlagAt);
if (persistedReconcileAt < 0 || persistedReconcileEnd < 0 ||
  !runtime.includes("import { LOCAL_HTTP_PROXY_PORT, VPN_DATA_SOCKS_PORT, VPN_INTERNAL_HTTP_PROXY_PORT }") ||
  recoveredProbeAt < 0 || firstCandidateCheckAt < recoveredProbeAt ||
  stopFlagAt < firstCandidateCheckAt || secondCandidateCheckAt < stopFlagAt ||
  recoveredApplyAt < secondCandidateCheckAt ||
  !persistedReconcile.includes('await this.cleanupUnhealthyVpn(context, language);') ||
  !runtime.includes('private isCurrentRecoveredVpnCandidate(') ||
  !runtime.includes('current.sessionId === expectedSessionId') ||
  !runtime.includes('current.startedAt === expectedStartedAt')) {
  throw new Error('persisted VPN recovery can trust a stale active file or overwrite a newer session');
}
const invalidArtifactAt = persistedReconcile.indexOf(
  'const stateArtifactsInvalid = persistedRead.authoritativeArtifactInvalid;');
const invalidArtifactBranchAt = persistedReconcile.indexOf('if (stateArtifactsInvalid) {', invalidArtifactAt);
const missingArtifactBranchAt = persistedReconcile.indexOf('if (persisted === null) {', invalidArtifactBranchAt);
const invalidArtifactCleanupAt = persistedReconcile.indexOf(
  'await this.cleanupUnhealthyVpn(context, language);', invalidArtifactBranchAt);
const inactiveFallbackGuardAt = persistedReconcile.indexOf(
  'if (persisted === null || !persisted.active) {', invalidArtifactBranchAt);
if (invalidArtifactAt < 0 || invalidArtifactBranchAt < invalidArtifactAt ||
  missingArtifactBranchAt < invalidArtifactBranchAt || invalidArtifactCleanupAt < invalidArtifactBranchAt ||
  inactiveFallbackGuardAt < invalidArtifactCleanupAt || invalidArtifactBranchAt > missingArtifactBranchAt ||
  !persistedReconcile.slice(invalidArtifactBranchAt, missingArtifactBranchAt)
    .includes('shouldCleanupUnhealthyVpnRuntimeState(')) {
  throw new Error('corrupt VPN state artifacts can bypass the repair window or trust an old backup');
}
if (!persistedReconcile.includes(
  'const suspectedSessionId = persisted?.sessionId ?? this.controller.getSnapshot().vpnSessionId;') ||
  !persistedReconcile.includes('if (persisted === null || !persisted.active) {')) {
  throw new Error('a corrupt VPN state without a parseable backup can be cleaned up before the next heartbeat');
}
if (!persistedReconcile.includes('const persistedRead = VpnRuntimeStateStore.readWithEvidence(context);') ||
  !persistedReconcile.includes('const persisted = persistedRead.state;')) {
  throw new Error('runtime reconciliation can mix VPN state and validity from different filesystem snapshots');
}
if (!vpn.includes("this.emitInfo('VPN runtime state heartbeat write failed; retrying.'") ||
  !vpn.includes("`session=${this.sessionId}; error=${this.errorMessage(error)}`") ||
  !vpn.includes("`session=${this.sessionId}; ${details}`")) {
  throw new Error('recoverable heartbeat failures or fatal VPN diagnostics have incorrect severity/session identity');
}
NODE
printf 'VPN diagnostic session/severity verification passed\n'

node <<'NODE'
const fs = require('fs');
const vpn = fs.readFileSync('entry/src/main/ets/vpn/HeyVpnAbility.ets', 'utf8');
const createAt = vpn.indexOf('const creatingConnection = vpnExtension.createVpnConnection(this.context);');
const observeAt = vpn.indexOf('this.observeVpnCreateCompletion(creatingConnection, createPromise, sessionGeneration);', createAt);
const createAwait = vpn.indexOf('this.tunFd = await withTimeout(', observeAt);
const reclaimAt = vpn.indexOf('if (this.stopRequested && this.vpnConnection === null)', createAwait);
const startGuard = vpn.indexOf("this.ensureStartAllowed('VPN interface creation', sessionGeneration);", createAwait);
const observerMethodAt = vpn.indexOf('  private observeVpnCreateCompletion(');
const observerMethodEnd = vpn.indexOf('\n  private async resolveStartSettings', observerMethodAt);
const observerMethod = vpn.slice(observerMethodAt, observerMethodEnd);
if (createAt < 0 || observeAt < createAt || createAwait < observeAt || reclaimAt < createAwait || startGuard < reclaimAt ||
  !vpn.slice(reclaimAt, startGuard).includes('this.vpnConnection = creatingConnection;') ||
  !vpn.slice(reclaimAt, startGuard).includes('this.cleanupAgainRequested = true;') ||
  observerMethodAt < 0 || observerMethodEnd < observerMethodAt ||
  !observerMethod.includes('this.tunFd = lateTunFd;') ||
  !observerMethod.includes('this.cleanupAgainRequested = true;') ||
  !observerMethod.includes('this.cleanup().catch(')) {
  throw new Error('late VPN create results are not reclaimed after startup cancellation');
}
const cleanupAt = vpn.indexOf('  private async cleanup(): Promise<void>');
const cleanupEnd = vpn.indexOf('\n  private async cancelSpeedNotificationSafely', cleanupAt);
const cleanup = vpn.slice(cleanupAt, cleanupEnd);
const unlockAt = cleanup.indexOf('this.cleaningUp = false;');
const boundaryRetryAt = cleanup.indexOf('if (this.cleanupAgainRequested)', unlockAt);
const credentialClearAt = cleanup.indexOf("this.activeConfigJson = '';", unlockAt);
if (cleanupAt < 0 || cleanupEnd < 0 || unlockAt < 0 || boundaryRetryAt < unlockAt ||
  credentialClearAt < boundaryRetryAt || !cleanup.slice(boundaryRetryAt, credentialClearAt).includes('await this.cleanup();')) {
  throw new Error('VPN cleanup can lose a reentrant request at its loop/finally boundary');
}
NODE
printf 'late VPN create cleanup verification passed\n'

node <<'NODE'
const fs = require('fs');
const vpn = fs.readFileSync('entry/src/main/ets/vpn/HeyVpnAbility.ets', 'utf8');
const onRequestAt = vpn.indexOf('  onRequest(want: Want, startId: number): void');
const onDestroyAt = vpn.indexOf('\n  onDestroy(): void', onRequestAt);
const onRequest = vpn.slice(onRequestAt, onDestroyAt);
if (!vpn.includes('private pendingStartWant: Want | null = null;') ||
  !vpn.includes('private lastCleanupComplete: boolean = false;') ||
  !vpn.includes('private vpnCreateInFlight: boolean = false;') ||
  !onRequest.includes('if (this.destroying || !this.stopRequested)') ||
  !onRequest.includes('this.pendingStartWant = want;') ||
  !onRequest.includes('this.cleaningUp || this.vpnCreateInFlight || !this.lastCleanupComplete') ||
  !onRequest.includes('this.startPendingSessionIfReady();')) {
  throw new Error('a cleaned but still-live VPN Extension cannot accept an explicit new start request');
}
const beginAt = vpn.indexOf('  private beginSession(want: Want): void');
const requestAt = vpn.indexOf('\n  onRequest(want: Want, startId: number): void', beginAt);
const begin = vpn.slice(beginAt, requestAt);
if (!begin.includes('this.stopRequested = false;') ||
  !begin.includes('this.lastCleanupComplete = false;') ||
  !begin.includes('const sessionGeneration = ++this.sessionGeneration;') ||
  !begin.includes('this.startVpn(want, sessionGeneration).catch(')) {
  throw new Error('reused VPN Extension sessions do not reset cancellation/cleanup state before start');
}
if (!vpn.includes('private ensureStartAllowed(stage: string, sessionGeneration: number)') ||
  !vpn.includes('if (sessionGeneration !== this.sessionGeneration)') ||
  !vpn.includes('if (this.stopRequested)') ||
  !vpn.includes('await NetSceneStopFlag.clear(this.context);') ||
  !vpn.includes("this.ensureStartAllowed('network scene stop flag reset', sessionGeneration);") ||
  !vpn.includes('private async pollNetScene(sessionGeneration: number)') ||
  !vpn.includes('private async recordStats(sessionGeneration: number)') ||
  !vpn.includes('sessionGeneration === this.sessionGeneration && !this.stopRequested && !this.cleaningUp')) {
  throw new Error('old VPN session continuations are not generation-isolated from a reused Extension session');
}
const cleanupAt = vpn.indexOf('  private async cleanup(): Promise<void>');
const cleanupEnd = vpn.indexOf('\n  private async cancelSpeedNotificationSafely', cleanupAt);
const cleanup = vpn.slice(cleanupAt, cleanupEnd);
if (!cleanup.includes('&& !this.vpnCreateInFlight;') ||
  !cleanup.includes('createPending=${this.vpnCreateInFlight}')) {
  throw new Error('VPN cleanup may attest completion while system TUN creation is still pending');
}
const pendingStartAt = vpn.indexOf('  private startPendingSessionIfReady(): void');
const pendingStartEnd = vpn.indexOf('\n  private async cancelSpeedNotificationSafely', pendingStartAt);
const pendingStart = vpn.slice(pendingStartAt, pendingStartEnd);
if (pendingStartAt < 0 || pendingStartEnd < 0 ||
  !pendingStart.includes('this.vpnCreateInFlight') || !pendingStart.includes('!this.lastCleanupComplete') ||
  !pendingStart.includes('this.pendingStartWant = null;') ||
  !pendingStart.includes('this.beginSession(want);')) {
  throw new Error('pending VPN starts are not gated on confirmed cleanup or consumed exactly once');
}
NODE
printf 'reused VPN Extension start verification passed\n'

node <<'NODE'
const fs = require('fs');

const runtime = fs.readFileSync('entry/src/main/ets/features/runtime/RuntimeController.ets', 'utf8');
const networkScene = fs.readFileSync('entry/src/main/ets/services/NetworkSceneManager.ets', 'utf8');
const entryAbility = fs.readFileSync('entry/src/main/ets/entryability/EntryAbility.ets', 'utf8');
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
if (!networkScene.includes('const MAX_REGISTER_RETRIES: number = 3;') ||
  !networkScene.includes('private handleRegisterFailure(') ||
  !networkScene.includes('private scheduleRegisterRetry(') ||
  !networkScene.includes('this.registerRetryCount >= MAX_REGISTER_RETRIES') ||
  !networkScene.includes('private owner: Object | null = null;') ||
  !networkScene.includes('if (owner !== undefined && this.owner !== owner)') ||
  !entryAbility.includes('NETWORK_SCENE_MANAGER.ensureStarted(this.context, this);') ||
  !entryAbility.includes('NETWORK_SCENE_MANAGER.stop(this);')) {
  throw new Error('network listener registration is not bounded-retry and UIAbility-owner safe');
}
NODE
printf 'egress handover and listener lifecycle verification passed\n'

vpn_ability="entry/src/main/ets/vpn/HeyVpnAbility.ets"
net_scene_manager="entry/src/main/ets/services/NetworkSceneManager.ets"
if ! grep -q 'NET_SCENE_POLL_STEP_TIMEOUT_MS' "${vpn_ability}" ||
  ! grep -q 'withTimeout(.*' "${vpn_ability}" ||
  ! grep -q 'Underlying network poll timed out' "${vpn_ability}" ||
  ! grep -q 'EVALUATION_STEP_TIMEOUT_MS' "${net_scene_manager}" ||
  ! grep -q 'Network evaluation settings load timed out' "${net_scene_manager}" ||
  ! grep -q 'Network evaluation probe timed out' "${net_scene_manager}"; then
  echo 'network observation promises are not bounded for retry' >&2
  exit 1
fi
printf 'bounded network observation verification passed\n'

node <<'NODE'
const fs = require('fs');
const probe = fs.readFileSync('entry/src/main/ets/services/RuntimeHealthProbe.ets', 'utf8');
const tcpAt = probe.indexOf('export async function probeRuntimeTcpHealth(');
const waitAt = probe.indexOf('\nexport async function waitForRuntimeSocksHealth(', tcpAt);
const tcp = probe.slice(tcpAt, waitAt);
if (tcpAt < 0 || waitAt < 0 ||
  !tcp.includes('await withProbeTimeout(') ||
  !tcp.includes('tcp.connect({') ||
  !tcp.includes('await withProbeTimeout(tcp.close(), Math.min(500, timeoutMs));') ||
  !probe.includes('function withProbeTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T>')) {
  throw new Error('runtime SOCKS health connect/close promises are not bounded');
}
NODE
printf 'bounded runtime health probe verification passed\n'

vpn_ability_file="entry/src/main/ets/vpn/HeyVpnAbility.ets"
if ! grep -q "const VPN_DESTROY_TIMEOUT_MS: number = 8000;" "$vpn_ability_file" || \
  ! grep -q "VPN connection destroy timed out\." "$vpn_ability_file" || \
  ! grep -A4 "connection\.destroy()" "$vpn_ability_file" | grep -q "VPN_DESTROY_TIMEOUT_MS"; then
  throw_error "VPN connection destroy must be bounded and remain distinguishable from successful cleanup"
fi
printf 'bounded VPN destroy verification passed\n'

if ! grep -q "const VPN_CREATE_TIMEOUT_MS: number = 8000;" "$vpn_ability_file" || \
  ! grep -q "observeVpnCreateCompletion(creatingConnection, createPromise, sessionGeneration);" "$vpn_ability_file" || \
  ! grep -A5 "this.tunFd = await withTimeout(" "$vpn_ability_file" | grep -q "VPN_CREATE_TIMEOUT_MS" || \
  ! grep -q "this.tunFd = lateTunFd;" "$vpn_ability_file"; then
  throw_error "VPN interface creation must be bounded while retaining late-result cleanup"
fi
printf 'bounded VPN create verification passed\n'

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

const moduleConfig = JSON.parse(fs.readFileSync('entry/src/main/module.json5', 'utf8'))?.module;
if (moduleConfig === undefined) {
  throw new Error('entry module declaration is missing');
}
const requestedPermissions = Array.isArray(moduleConfig.requestPermissions)
  ? moduleConfig.requestPermissions : [];
const permission = (name) => requestedPermissions.find((item) => item?.name === name);
if (permission('ohos.permission.INTERNET') === undefined) {
  throw new Error('entry module must request INTERNET for proxy and update traffic');
}
const networkPermission = permission('ohos.permission.GET_NETWORK_INFO');
const networkAbilities = networkPermission?.usedScene?.abilities;
if (!Array.isArray(networkAbilities) || !networkAbilities.includes('EntryAbility') ||
  !networkAbilities.includes('HeyVpnAbility')) {
  throw new Error('GET_NETWORK_INFO must cover both the UI and VPN network observers');
}

const extensions = Array.isArray(moduleConfig.extensionAbilities)
  ? moduleConfig.extensionAbilities : [];
const vpnExtension = extensions.find((item) => item?.name === 'HeyVpnAbility');
if (vpnExtension?.type !== 'vpn' || vpnExtension?.srcEntry !== './ets/vpn/HeyVpnAbility.ets' ||
  vpnExtension?.exported !== false) {
  throw new Error('HeyVpnAbility manifest entry must remain a private VPN extension');
}
const schedulerAbility = declaredString(
  'entry/src/main/ets/core/SubscriptionSchedulerPlan.ets',
  'SUBSCRIPTION_AUTO_UPDATE_WORK_ABILITY'
);
const schedulerExtension = extensions.find((item) => item?.name === schedulerAbility);
if (schedulerExtension?.type !== 'workScheduler' ||
  schedulerExtension?.srcEntry !== './ets/work/SubscriptionUpdateWorkAbility.ets' ||
  schedulerExtension?.exported !== false) {
  throw new Error('subscription WorkInfo ability does not match its private manifest extension');
}

const subscriptionGroups = fs.readFileSync('entry/src/main/ets/core/SubscriptionGroups.ets', 'utf8');
const minimumIntervalMatch = subscriptionGroups.match(
  /MIN_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES\s*:\s*number\s*=\s*(\d+)/
);
if (minimumIntervalMatch === null || Number(minimumIntervalMatch[1]) < 20) {
  throw new Error('subscription WorkScheduler repeat interval is below the platform minimum');
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

const diagnosticLog = fs.readFileSync('entry/src/main/ets/services/DiagnosticLog.ets', 'utf8');
for (const operation of ['append', 'clear', 'rotate']) {
  if (!diagnosticLog.includes(`DiagnosticLog.closeFile(file, '${operation}');`)) {
    throw new Error(`diagnostic ${operation} path can leak its file descriptor after an exception`);
  }
}
if (!diagnosticLog.includes('details: redactDiagnosticText(JSON.stringify(error))')) {
  throw new Error('malformed diagnostic parse errors can bypass the log redaction boundary');
}
NODE
printf 'ArkTS console/hilog error redaction verification passed\n'

# A full backup restore spans four independent stores and cannot be a single ArkData
# transaction. Require a durable pre-import recovery file and an in-process rollback that
# independently attempts every store, so a later failure cannot silently leave a mixed
# configuration or report success. Cleanup errors must not hide the original write error.
node <<'NODE'
const fs = require('fs');
const page = fs.readFileSync('entry/src/main/ets/pages/Backup.ets', 'utf8');
const manager = fs.readFileSync('entry/src/main/ets/services/BackupManager.ets', 'utf8');

const applyAt = page.indexOf('  private async applyImport(backup: ConfigBackup): Promise<void>');
const applyEnd = page.indexOf('\n  private summaryValue(', applyAt);
const apply = page.slice(applyAt, applyEnd);
const confirmAt = page.indexOf('  private confirmImport(backup: ConfigBackup): void');
const confirmEnd = page.indexOf('\n  private async applyImport(', confirmAt);
const confirm = page.slice(confirmAt, confirmEnd);
if (applyAt < 0 || applyEnd < 0 ||
  !apply.includes('if (this.busy) {') ||
  !apply.includes('if (SHARED_RUNTIME_CONTROLLER.mayOwnNetwork()) {') ||
  !apply.includes("this.t('backup.import.disconnectFirst')") ||
  !apply.includes('this.writeFilesDirFile(context, PRE_IMPORT_BACKUP_FILE, serializeConfigBackup(current));') ||
  !apply.includes('await BackupManager.applyBackup(context, backup);') ||
  apply.indexOf('this.writeFilesDirFile(') > apply.indexOf('await BackupManager.applyBackup(') ||
  apply.includes('安全副本失败不阻断恢复')) {
  throw new Error('backup import can overwrite stores before a durable safety copy exists');
}
if (confirmAt < 0 || confirmEnd < 0 ||
  !confirm.includes('if (SHARED_RUNTIME_CONTROLLER.mayOwnNetwork()) {') ||
  !confirm.includes("this.t('backup.import.disconnectFirst')")) {
  throw new Error('backup restore confirmation can be opened while a runtime may own the network');
}

const writeAt = page.indexOf('  private writeFilesDirFile(');
const writeEnd = page.indexOf('\n  private readTextFromUri(', writeAt);
const write = page.slice(writeAt, writeEnd);
for (const marker of ["path + '.tmp'", "path + '.bak'", 'fs.fsyncSync(file.fd);',
  'fs.renameSync(path, backupPath);', 'fs.renameSync(tempPath, path);',
  'fs.renameSync(backupPath, path);']) {
  if (writeAt < 0 || writeEnd < 0 || !write.includes(marker)) {
    throw new Error(`pre-import recovery file is not replaced transactionally: ${marker}`);
  }
}

const restoreAt = manager.indexOf('  static async applyBackup(');
const restoreEnd = manager.indexOf('\n  private static async applyBackupParts(', restoreAt);
const restore = manager.slice(restoreAt, restoreEnd);
if (restoreAt < 0 || restoreEnd < 0 ||
  !restore.includes('const previous = await BackupManager.collectBackup(context);') ||
  !restore.includes('await BackupManager.applyBackupParts(context, backup);') ||
  !restore.includes('await BackupManager.rollbackBackupParts(context, previous);')) {
  throw new Error('multi-store backup restore does not snapshot and roll back the previous configuration');
}

const rollbackAt = manager.indexOf('  private static async rollbackBackupParts(');
const rollback = manager.slice(rollbackAt);
for (const marker of ['SubscriptionStore.restoreProfile(', 'ProfileStore.save(',
  'SettingsStore.save(', 'AssetStore.save(']) {
  if (rollbackAt < 0 || !rollback.includes(marker)) {
    throw new Error(`backup rollback does not attempt every store independently: ${marker}`);
  }
}
if ((rollback.match(/catch \(_error\)/g) ?? []).length < 4) {
  throw new Error('backup rollback can abandon remaining stores after the first failure');
}
NODE
printf 'recoverable backup restore verification passed\n'

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
