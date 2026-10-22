#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_BIN="${GO_BIN:-go}"
SINGBOX_TAGS="with_gvisor with_utls with_clash_api with_quic"

tool_available() {
  local tool="$1"
  if [[ "${tool}" == */* ]]; then
    [[ -x "${tool}" ]]
  else
    command -v "${tool}" >/dev/null 2>&1
  fi
}

if ! tool_available "${GO_BIN}"; then
  printf 'Go toolchain not found or not executable: %s\n' "${GO_BIN}" >&2
  printf 'Install standard Go 1.23.4 or newer, or set GO_BIN to its executable path.\n' >&2
  exit 1
fi

printf 'Go component test toolchain: '
"${GO_BIN}" version

# These checks validate platform-independent wrapper/config behavior only. They
# deliberately keep module files read-only and never overwrite packaged OHOS
# libraries. GOOS=openharmony/cgo/TLSDESC still require the documented OHOS Go
# fork plus the DevEco native SDK.
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOFLAGS="${GOFLAGS:+${GOFLAGS} }-mod=readonly"

printf '\nValidating representative sing-box configurations...\n'
(
  cd "${ROOT_DIR}/libsingbox"
  "${GO_BIN}" test \
    -tags "${SINGBOX_TAGS}" \
    -run TestGeneratedConfigs \
    -v \
    ./...
)

printf '\nCompiling and testing the tun2socks adapter package...\n'
(
  cd "${ROOT_DIR}/entry/src/main/cpp/tun2socks_adapter"
  "${GO_BIN}" test ./...
)

printf '\nGo component tests passed. This is not an OpenHarmony cross-build or device test.\n'
