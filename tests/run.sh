#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
readonly -a SUITE_NAMES=(
  static
  state
  acme
  render
  panel-transactions
  upgrade
)

if [[ "${1:-}" == --list-suites ]]; then
  (( $# == 1 )) || {
    printf '%s\n' '--list-suites 不接受其他参数。' >&2
    exit 64
  }
  printf '%s\n' "${SUITE_NAMES[@]}"
  exit 0
fi
(( $# == 0 )) || {
  printf '未知测试参数：%s\n' "$1" >&2
  exit 64
}

XRAY="${XRAY_BIN:-$TOOLS/xray}"
SING_BOX="${SING_BOX_BIN:-$TOOLS/sing-box}"
HYSTERIA="${HYSTERIA_BIN:-$TOOLS/hysteria}"
CADDY="${CADDY_BIN:-$TOOLS/caddy}"
LEGO="${LEGO_BIN:-$TOOLS/lego}"
MIHOMO="${MIHOMO_BIN:-$TOOLS/mihomo}"
QRC="${QRC_BIN:-$TOOLS/qrc}"
NEXTTRACE="${NEXTTRACE_BIN:-$TOOLS/nexttrace-tiny}"

for binary in \
  "$XRAY" "$SING_BOX" "$HYSTERIA" "$CADDY" "$LEGO" "$MIHOMO" \
  "$QRC" "$NEXTTRACE"; do
  [[ -x "$binary" ]] || {
    printf '缺少测试工具 %s；先运行 tests/fetch-pinned-tools.sh。\n' "$binary" >&2
    exit 1
  }
done

source "$ROOT/versions.env"

NEKO_TEST_SUITE_CONTEXT=1
# Suites are sourced, not spawned, so the render fixture remains available to
# the later panel and upgrade suites exactly as it was in the unified runner.
for suite_name in "${SUITE_NAMES[@]}"; do
  source "$ROOT/tests/suites/${suite_name}.sh"
done
unset NEKO_TEST_SUITE_CONTEXT
