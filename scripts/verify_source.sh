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
const loadAt = page.indexOf('  private async loadGeoMetadata(): Promise<void>');
const loadEnd = page.indexOf('\n  private applyGeoMetadata(', loadAt);
const load = page.slice(loadAt, loadEnd);
if (loadAt < 0 || loadEnd < 0 ||
  !load.includes('await ASSETS_CONTROLLER.isBuiltinGeoMetadataCurrent(context, metadata)') ||
  !load.includes('await AssetStore.clearGeoUpdateMetadata(context);') ||
  !load.includes("this.geoUpdateSummary = this.t('assets.geo.defaultSource');")) {
  throw new Error('Assets page can display stale Geo verification metadata');
}
const updateAt = page.indexOf('  private async checkGeoUpdate(): Promise<void>');
const updateEnd = page.indexOf('\n  private deleteAsset(', updateAt);
const update = page.slice(updateAt, updateEnd);
if (updateAt < 0 || updateEnd < 0 || !update.includes('if (result.metadataSaved)') ||
  !update.includes('await this.clearGeoMetadata();') || !update.includes('this.applyGeoMetadata({')) {
  throw new Error('a metadata write failure can reload and display an obsolete Geo version');
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
const disappearAt = scanner.indexOf('  aboutToDisappear(): void');
const buildAt = scanner.indexOf('\n  build()', disappearAt);
const disappear = scanner.slice(disappearAt, buildAt);
if (!disappear.includes("this.pendingSensitiveImport = '';" ) ||
  !disappear.includes('this.hasPendingSensitiveImport = false;')) {
  throw new Error('scanner keeps external credentials in the page instance after leaving');
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
const requestedModeAssignment = startBody.indexOf('this.runtimeMode = requestedMode;');
const firstCoreSelectionAwait = startBody.indexOf('await CoreSelectionStore.load(context)');
if (requestedModeAssignment < 0 || firstCoreSelectionAwait < 0 ||
  requestedModeAssignment > firstCoreSelectionAwait) {
  throw new Error('connection mode must be fixed before the first cancellable startup await');
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
const refreshAt = consumer.indexOf('await this.refreshRuntime();');
const startupAt = consumer.indexOf('await this.handlePendingAutoStartupLaunch();');
if (consumerAt < 0 || consumerEnd < 0 || refreshAt < 0 || startupAt < refreshAt) {
  throw new Error('warm AUTO_STARTUP is not serialized after authoritative runtime recovery');
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
if (!index.includes('if (this.isBusy() && !canCancelStartingConnection(this.status))') ||
  !index.includes('if (canCancelStartingConnection(this.status)) {\n          this.stopConnection();') ||
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
const vpn = fs.readFileSync('entry/src/main/ets/vpn/HeyVpnAbility.ets', 'utf8');
if (!connection.includes('vpnSessionId: string;') ||
  !connection.includes('vpnSessionId: this.vpnSessionId')) {
  throw new Error('runtime snapshots no longer expose the owning VPN session for diagnostic matching');
}
if (!health.includes('expectedSessionId: string') || !health.includes('eventDetails: string | undefined') ||
  !health.includes('eventDetails.startsWith(`${marker};`)')) {
  throw new Error('VPN diagnostic errors are not matched to the exact active session');
}
const applyAt = runtime.indexOf('  private async applyDiagnosticError(');
const apply = runtime.slice(applyAt);
const refreshAt = runtime.indexOf('  async refresh(context: common.Context, language: AppLanguage)');
const reconcileCallAt = runtime.indexOf('await this.reconcilePersistedVpnState(context, language);', refreshAt);
const diagnosticPrecheckAt = runtime.indexOf('await this.applyPendingVpnDiagnosticError(context, language);', refreshAt);
if (applyAt < 0 || refreshAt < 0 || diagnosticPrecheckAt < refreshAt || reconcileCallAt < diagnosticPrecheckAt ||
  !apply.includes('for (let index = 0; index < events.length; index++)') ||
  !apply.includes('connection.vpnSessionId') || !apply.includes('candidate.details')) {
  throw new Error('cleanup info/state can hide a fatal current-session VPN diagnostic');
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
const createAwait = vpn.indexOf('await creatingConnection.create(vpnConfig);', createAt);
const reclaimAt = vpn.indexOf('if (this.stopRequested && this.vpnConnection === null)', createAwait);
const startGuard = vpn.indexOf("this.ensureStartAllowed('VPN interface creation', sessionGeneration);", createAwait);
if (createAt < 0 || createAwait < createAt || reclaimAt < createAwait || startGuard < reclaimAt ||
  !vpn.slice(reclaimAt, startGuard).includes('this.vpnConnection = creatingConnection;') ||
  !vpn.slice(reclaimAt, startGuard).includes('this.cleanupAgainRequested = true;')) {
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
