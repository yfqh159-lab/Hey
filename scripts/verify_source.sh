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
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  skipped_project_files="$(git ls-files -t AppScope entry | awk '$1 == "S" { print $2 }')"
  if [[ -n "${skipped_project_files}" ]]; then
    printf 'build-critical files are excluded by sparse checkout:\n%s\n' "${skipped_project_files}" >&2
    printf 'Run: git sparse-checkout add AppScope entry\n' >&2
    exit 1
  fi
fi
printf 'project skeleton verification passed\n'

git diff --check
./scripts/compliance_scan.sh
./scripts/verify_prebuilt_native.sh
bash -n scripts/*.sh

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
