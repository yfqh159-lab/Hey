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

if ! command -v node >/dev/null 2>&1; then
  printf 'node is required for the translation-key consistency check.\n' >&2
  exit 1
fi

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
NODE

printf 'source verification passed\n'
