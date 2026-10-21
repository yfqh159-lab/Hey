#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
HVIGOR="${HVIGOR:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"
HDC="${HDC:-${DEVECO_SDK_HOME}/default/openharmony/toolchains/hdc}"
HAP="${HAP:-${ROOT_DIR}/entry/build/default/outputs/default/entry-default-signed.hap}"

usage() {
  printf 'Usage: %s {build|test|install|logs|targets|doctor}\n' "$0"
}

require_hvigor() {
  if [[ "${HVIGOR}" == */* ]]; then
    if [[ ! -x "${HVIGOR}" ]]; then
      printf 'hvigorw not found or not executable: %s\n' "${HVIGOR}" >&2
      exit 1
    fi
  elif ! command -v "${HVIGOR}" >/dev/null 2>&1; then
    printf 'hvigorw not found on PATH: %s\n' "${HVIGOR}" >&2
    exit 1
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
  if [[ ! -x "${HDC}" ]]; then
    printf 'hdc not found: %s\n' "${HDC}" >&2
    exit 1
  fi
}

case "${1:-}" in
  build)
    require_hvigor
    "${ROOT_DIR}/scripts/verify_prebuilt_native.sh"
    DEVECO_SDK_HOME="${DEVECO_SDK_HOME}" "${HVIGOR}" clean --no-daemon --stacktrace
    DEVECO_SDK_HOME="${DEVECO_SDK_HOME}" "${HVIGOR}" assembleApp --no-daemon --stacktrace
    verify_hap_native_libs
    ;;
  test)
    require_hvigor
    DEVECO_SDK_HOME="${DEVECO_SDK_HOME}" "${HVIGOR}" --mode module \
      -p module=entry@default -p isLocalTest=true test --no-daemon --stacktrace
    ;;
  install)
    require_hdc
    if [[ ! -f "${HAP}" ]]; then
      printf 'HAP not found, run build first: %s\n' "${HAP}" >&2
      exit 1
    fi
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
    require_hdc
    printf 'Targets:\n'
    "${HDC}" list targets
    printf '\nSystem:\n'
    "${HDC}" shell 'param get const.product.model; param get const.product.software.version; param get const.ohos.apiversion'
    printf '\nVPN dialog package:\n'
    vpn_dialog_dump="$("${HDC}" shell 'bm dump -n com.huawei.hmos.vpndialog 2>&1' || true)"
    if grep -qiE 'failed|not exist|no bundle|no valid extension' <<<"${vpn_dialog_dump}"; then
      printf 'MISSING: com.huawei.hmos.vpndialog is not installed. VPN authorization cannot complete on this target.\n'
      printf '%s\n' "${vpn_dialog_dump}"
    else
      printf 'OK: com.huawei.hmos.vpndialog is installed.\n'
    fi
    ;;
  *)
    usage
    exit 1
    ;;
esac
