#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_MAC_DEVECO_HOME="/Applications/DevEco-Studio.app/Contents"
if [[ -z "${DEVECO_SDK_HOME:-}" && -d "${DEFAULT_MAC_DEVECO_HOME}/sdk" ]]; then
  DEVECO_SDK_HOME="${DEFAULT_MAC_DEVECO_HOME}/sdk"
else
  DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-}"
fi
if [[ -z "${HVIGOR:-}" ]]; then
  if command -v hvigorw >/dev/null 2>&1; then
    HVIGOR="hvigorw"
  elif [[ -x "${DEFAULT_MAC_DEVECO_HOME}/tools/hvigor/bin/hvigorw" ]]; then
    HVIGOR="${DEFAULT_MAC_DEVECO_HOME}/tools/hvigor/bin/hvigorw"
  else
    HVIGOR="hvigorw"
  fi
fi
if [[ -z "${HDC:-}" ]]; then
  if command -v hdc >/dev/null 2>&1; then
    HDC="hdc"
  elif [[ -n "${DEVECO_SDK_HOME}" && -x "${DEVECO_SDK_HOME}/default/openharmony/toolchains/hdc" ]]; then
    HDC="${DEVECO_SDK_HOME}/default/openharmony/toolchains/hdc"
  else
    HDC="hdc"
  fi
fi
HAP="${HAP:-${ROOT_DIR}/entry/build/default/outputs/default/entry-default-signed.hap}"
BUILD_PROFILE="${BUILD_PROFILE:-${ROOT_DIR}/build-profile.json5}"

usage() {
  printf 'Usage: %s {build|test|go-test|install|logs|targets|doctor}\n' "$0"
}

require_hvigor() {
  if ! tool_available "${HVIGOR}"; then
    printf 'hvigorw not found or not executable: %s\n' "${HVIGOR}" >&2
    printf 'Set HVIGOR to the executable path when DevEco Studio is not on PATH.\n' >&2
    exit 1
  fi
}

tool_available() {
  local tool="$1"
  if [[ "${tool}" == */* ]]; then
    [[ -x "${tool}" ]]
  else
    command -v "${tool}" >/dev/null 2>&1
  fi
}

signing_profile_configured() {
  local profile="$1"
  node - "${profile}" <<'NODE'
const fs = require('fs');

let source;
try {
  source = fs.readFileSync(process.argv[2], 'utf8');
} catch (_) {
  process.exit(2);
}

const key = /["']signingConfigs["']\s*:\s*\[/g.exec(source);
if (!key) {
  process.exit(2);
}

let index = key.index + key[0].length;
while (index < source.length) {
  const char = source[index];
  const next = source[index + 1];
  if (/\s/.test(char)) {
    index += 1;
    continue;
  }
  if (char === '/' && next === '/') {
    index = source.indexOf('\n', index + 2);
    if (index < 0) {
      process.exit(2);
    }
    continue;
  }
  if (char === '/' && next === '*') {
    index = source.indexOf('*/', index + 2);
    if (index < 0) {
      process.exit(2);
    }
    index += 2;
    continue;
  }
  process.exit(char === ']' ? 1 : 0);
}
process.exit(2);
NODE
}

require_signing_profile() {
  if [[ ! -f "${BUILD_PROFILE}" ]]; then
    printf 'build-profile.json5 not found: %s\n' "${BUILD_PROFILE}" >&2
    printf 'Copy build-profile.example.json5 and configure local signing.\n' >&2
    exit 1
  fi
  local status=0
  signing_profile_configured "${BUILD_PROFILE}" || status=$?
  if [[ "${status}" -eq 0 ]]; then
    return
  fi
  if [[ "${status}" -eq 1 ]]; then
    printf 'Signing is not configured in: %s\n' "${BUILD_PROFILE}" >&2
  else
    printf 'Could not verify signingConfigs in: %s\n' "${BUILD_PROFILE}" >&2
  fi
  printf 'Configure a non-empty local signingConfigs entry in DevEco Studio.\n' >&2
  exit 1
}

run_hvigor() {
  if [[ -n "${DEVECO_SDK_HOME}" ]]; then
    DEVECO_SDK_HOME="${DEVECO_SDK_HOME}" "${HVIGOR}" "$@"
  else
    "${HVIGOR}" "$@"
  fi
}

verify_hap_native_libs() {
  if [[ ! -f "${HAP}" ]]; then
    printf 'Signed HAP not found after build: %s\n' "${HAP}" >&2
    printf 'Configure your local signing profile, or override HAP with the actual signed output path.\n' >&2
    exit 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    printf 'unzip is required to verify packaged native libraries.\n' >&2
    exit 1
  fi
  local archive_list
  archive_list="$(unzip -Z1 "${HAP}")"
  local library
  for library in libheyvpn.so libxray.so libsingbox.so libheytun2socks.so libhevsocks5tun.so; do
    if ! grep -qE "(^|/)libs/arm64-v8a/${library}$" <<<"${archive_list}"; then
      printf 'Packaged native library missing from HAP: %s\n' "${library}" >&2
      exit 1
    fi
  done
  printf 'Packaged native libraries verified in: %s\n' "${HAP}"
}

require_hdc() {
  if ! tool_available "${HDC}"; then
    printf 'hdc not found or not executable: %s\n' "${HDC}" >&2
    printf 'Set HDC to the executable path when the SDK toolchain is not on PATH.\n' >&2
    exit 1
  fi
}

case "${1:-}" in
  build)
    require_hvigor
    require_signing_profile
    "${ROOT_DIR}/scripts/verify_source.sh"
    run_hvigor clean --no-daemon --stacktrace
    run_hvigor --mode module \
      -p product=default -p module=entry@default -p buildMode=debug \
      assembleHap --no-daemon --stacktrace
    verify_hap_native_libs
    ;;
  test)
    require_hvigor
    "${ROOT_DIR}/scripts/verify_source.sh"
    run_hvigor --mode module \
      -p module=entry@default -p isLocalTest=true test --no-daemon --stacktrace
    test_result_log="${ROOT_DIR}/entry/.test/default/intermediates/test/coverage_data/coverage.log"
    if [[ ! -f "${test_result_log}" ]]; then
      printf 'LocalUnit result log was not generated: %s\n' "${test_result_log}" >&2
      exit 1
    fi
    test_summary="$(grep -E '\[Hypium\]total cases:[0-9]+;failure [0-9]+,error [0-9]+,pass [0-9]+;' \
      "${test_result_log}" | tail -n 1 || true)"
    if [[ -z "${test_summary}" || "${test_summary}" != *';failure 0,error 0,'* ]]; then
      printf 'LocalUnit assertions did not all pass: %s\n' "${test_summary:-summary missing}" >&2
      exit 1
    fi
    printf 'LocalUnit assertions passed: %s\n' "${test_summary#*\[Hypium\]}"
    ;;
  go-test)
    "${ROOT_DIR}/scripts/test_go_components.sh"
    ;;
  install)
    require_hdc
    verify_hap_native_libs
    "${HDC}" install -r "${HAP}"
    ;;
  logs)
    require_hdc
    "${HDC}" shell hilog | awk '/HeyVpn|HeyVpnAbility|HeyNative|NetworkVpnManager|NETMANAGER_EXT|vpndialog|connectAbility/ { print; fflush(); }'
    ;;
  targets)
    require_hdc
    "${HDC}" list targets
    ;;
  doctor)
    doctor_failed=0
    for required_tool in node unzip; do
      if command -v "${required_tool}" >/dev/null 2>&1; then
        printf 'OK: %s: %s\n' "${required_tool}" "$(command -v "${required_tool}")"
      else
        printf 'MISSING: %s is required by source or packaged-HAP verification.\n' "${required_tool}"
        doctor_failed=1
      fi
    done
    if tool_available "${HVIGOR}"; then
      printf 'OK: hvigorw: %s\n' "${HVIGOR}"
    else
      printf 'MISSING: hvigorw (%s). Set HVIGOR or add it to PATH.\n' "${HVIGOR}"
      doctor_failed=1
    fi
    if [[ -n "${DEVECO_SDK_HOME}" && -d "${DEVECO_SDK_HOME}" ]]; then
      printf 'OK: DevEco SDK: %s\n' "${DEVECO_SDK_HOME}"
    elif [[ -n "${DEVECO_SDK_HOME}" ]]; then
      printf 'MISSING: DEVECO_SDK_HOME does not exist: %s\n' "${DEVECO_SDK_HOME}"
      doctor_failed=1
    else
      printf 'INFO: DEVECO_SDK_HOME is unset; hvigorw must resolve the SDK itself.\n'
    fi
    if [[ ! -f "${BUILD_PROFILE}" ]]; then
      printf 'MISSING: build-profile.json5. Copy build-profile.example.json5 and configure local signing.\n'
      doctor_failed=1
    elif signing_profile_configured "${BUILD_PROFILE}"; then
      printf 'OK: local build profile has a non-empty signing configuration.\n'
    else
      signing_status=$?
      if [[ "${signing_status}" -eq 1 ]]; then
        printf 'MISSING: build-profile.json5 exists but signingConfigs is empty. Configure local signing.\n'
      else
        printf 'MISSING: build-profile.json5 exists but signingConfigs could not be verified.\n'
      fi
      doctor_failed=1
    fi
    if [[ -f "${HAP}" ]]; then
      printf 'OK: signed HAP: %s\n' "${HAP}"
    else
      printf 'INFO: signed HAP not found yet: %s\n' "${HAP}"
    fi
    if tool_available "${HDC}"; then
      printf '\nTargets:\n'
      targets_ok=1
      targets_output="$("${HDC}" list targets 2>&1)" || targets_ok=0
      printf '%s\n' "${targets_output}"
      if [[ "${targets_ok}" -ne 1 ]]; then
        printf 'MISSING: hdc could not enumerate targets.\n'
        doctor_failed=1
      elif [[ -z "${targets_output//[[:space:]]/}" ]] || grep -qiE '^\[?empty\]?$' <<<"${targets_output}"; then
        printf 'MISSING: no connected hdc target.\n'
        doctor_failed=1
      else
        printf '\nSystem:\n'
        "${HDC}" shell 'param get const.product.model; param get const.product.software.version; param get const.ohos.apiversion'
        printf '\nVPN dialog package:\n'
        vpn_dialog_dump="$("${HDC}" shell 'bm dump -n com.huawei.hmos.vpndialog 2>&1' || true)"
        if grep -qiE 'failed|not exist|no bundle|no valid extension' <<<"${vpn_dialog_dump}"; then
          printf 'MISSING: com.huawei.hmos.vpndialog is not installed. VPN authorization cannot complete on this target.\n'
          printf '%s\n' "${vpn_dialog_dump}"
          doctor_failed=1
        else
          printf 'OK: com.huawei.hmos.vpndialog is installed.\n'
        fi
      fi
    else
      printf 'MISSING: hdc (%s). Set HDC or add it to PATH.\n' "${HDC}"
      doctor_failed=1
    fi
    exit "${doctor_failed}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
