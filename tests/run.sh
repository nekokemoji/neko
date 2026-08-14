#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
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
# shellcheck source=tests/suites/static.sh
source "$ROOT/tests/suites/static.sh"
# shellcheck source=tests/suites/state.sh
source "$ROOT/tests/suites/state.sh"
# shellcheck source=tests/suites/acme.sh
source "$ROOT/tests/suites/acme.sh"
# shellcheck source=tests/suites/render.sh
source "$ROOT/tests/suites/render.sh"
# shellcheck source=tests/suites/panel-transactions.sh
source "$ROOT/tests/suites/panel-transactions.sh"
# shellcheck source=tests/suites/upgrade.sh
source "$ROOT/tests/suites/upgrade.sh"
unset NEKO_TEST_SUITE_CONTEXT
