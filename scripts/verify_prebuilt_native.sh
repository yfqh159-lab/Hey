#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREBUILT_DIR="${ROOT_DIR}/entry/src/main/cpp/prebuilt/arm64-v8a"

if [[ -n "${READELF:-}" ]]; then
  READELF_BIN="${READELF}"
elif command -v llvm-readelf >/dev/null 2>&1; then
  READELF_BIN="$(command -v llvm-readelf)"
elif command -v readelf >/dev/null 2>&1; then
  READELF_BIN="$(command -v readelf)"
else
  echo "error: llvm-readelf/readelf not found (set READELF explicitly)" >&2
  exit 1
fi

fail() {
  echo "error: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -s "${file}" ]] || fail "missing or empty native library: ${file}"
  grep -Eq 'Machine:[[:space:]]+AArch64' < <("${READELF_BIN}" -h "${file}") ||
    fail "not an AArch64 ELF shared library: ${file}"
}

require_symbol() {
  local file="$1"
  local symbol="$2"
  grep -Eq "[[:space:]]${symbol}$" < <("${READELF_BIN}" -Ws "${file}") ||
    fail "missing exported symbol ${symbol}: ${file}"
}

require_go_tls() {
  local file="$1"
  grep -Eq 'TLS' < <("${READELF_BIN}" -l "${file}") || fail "missing PT_TLS: ${file}"
  grep -Eq 'R_AARCH64_TLSDESC|TLSDESC' < <("${READELF_BIN}" -r "${file}") ||
    fail "missing AArch64 TLSDESC relocation: ${file}"
}

XRAY="${PREBUILT_DIR}/libxray.so"
SINGBOX="${PREBUILT_DIR}/libsingbox.so"
TUN2SOCKS="${PREBUILT_DIR}/libheytun2socks.so"
HEV="${PREBUILT_DIR}/libhevsocks5tun.so"

for library in "${XRAY}" "${SINGBOX}" "${TUN2SOCKS}" "${HEV}"; do
  require_file "${library}"
done

require_symbol "${XRAY}" CGoInvoke
require_symbol "${XRAY}" CGoFree
require_go_tls "${XRAY}"

require_symbol "${SINGBOX}" CGoStartSingBox
require_symbol "${SINGBOX}" CGoStopSingBox
require_symbol "${SINGBOX}" CGoSetTunFd
require_symbol "${SINGBOX}" CGoSingBoxVersion
require_go_tls "${SINGBOX}"

require_symbol "${TUN2SOCKS}" HeyTun2SocksStart
require_symbol "${TUN2SOCKS}" HeyTun2SocksStop
require_symbol "${TUN2SOCKS}" HeyTun2SocksUploadBytes
require_symbol "${TUN2SOCKS}" HeyTun2SocksDownloadBytes
require_go_tls "${TUN2SOCKS}"

require_symbol "${HEV}" hev_socks5_tunnel_main_from_str
require_symbol "${HEV}" hev_socks5_tunnel_quit
require_symbol "${HEV}" hev_socks5_tunnel_stats

grep -Fq 'export const startHevTun:' \
  "${ROOT_DIR}/entry/src/main/cpp/types/libheyvpn/Index.d.ts" ||
  fail "native type declarations do not expose startHevTun"

echo "native prebuilt verification passed: AArch64 libraries, bridge symbols, Go TLSDESC"
