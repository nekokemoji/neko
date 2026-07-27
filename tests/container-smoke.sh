#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_ID="$1"
EXPECTED_VERSION="$2"
EXPECTED_FAMILY="$3"
EXPECTED_ARCH="$4"

shopt -s globstar nullglob
shell_files=("$ROOT"/**/*.sh)
bash -n "${shell_files[@]}"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
ARCH_OVERRIDE="$EXPECTED_ARCH"
detect_platform

[[ "$OS_ID" == "$EXPECTED_ID" ]]
[[ "$OS_VERSION" == "$EXPECTED_VERSION" || "$OS_VERSION" == "$EXPECTED_VERSION".* ]]
[[ "$OS_FAMILY" == "$EXPECTED_FAMILY" ]]
[[ "$ARCH" == "$EXPECTED_ARCH" ]]

diagnostics_output="$(
  NEKO_LIBEXEC="$ROOT" bash "$ROOT/runtime/diagnostics.sh" --system
)"
[[ "$diagnostics_output" == *'系统与硬件（只读）'* ]]
[[ "$diagnostics_output" == *'根文件系统'* ]]
[[ "$diagnostics_output" == *'体检小结'* ]]

printf '通过：%s %s / %s（Bash %s）\n' \
  "$OS_ID" "$OS_VERSION" "$ARCH" "${BASH_VERSION}"

if [[ -n "${NEKO_CONTAINER_QRC:-}" ]]; then
  [[ -x "$NEKO_CONTAINER_QRC" ]]
  qrc_help="$("$NEKO_CONTAINER_QRC" --help 2>&1)"
  [[ "$qrc_help" == *'--output-format=<auto|ansi|sixel|unicode>'* ]]
  qrc_output="$(
    printf 'https://v4.neko-test.invalid/token/mihomo.yaml' \
      | "$NEKO_CONTAINER_QRC" --output-format unicode --invert \
        --ec-level M --scale 1 --border 4
  )"
  [[ -n "$qrc_output" && "$qrc_output" == *'█'* ]]
fi

# Exercise each distro's real awk while mocking only the explicit DNS query,
# so malformed A answers are rejected consistently across the matrix.
dig() {
  printf '%s\n' \
    ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1' \
    'v4.neko-test.invalid. 60 IN A 192.0.2.44' \
    'v4.neko-test.invalid. 60 IN A 999.0.0.1' \
    'v4.neko-test.invalid. 60 IN A not-an-address'
}
[[ "$(resolved_ipv4_addresses v4.neko-test.invalid)" == "192.0.2.44" ]]
unset -f dig

if [[ -n "${NEKO_CONTAINER_BOOTSTRAP_ARCHIVE:-}" ]]; then
  NEKO_BOOTSTRAP_ARCHIVE="$NEKO_CONTAINER_BOOTSTRAP_ARCHIVE" \
    NEKO_BOOTSTRAP_WORK_BASE=/tmp \
    NEKO_BOOTSTRAP_TEST_MODE=1 \
    bash "$ROOT/bootstrap.sh"
fi

if ! command -v jq >/dev/null 2>&1; then
  case "$EXPECTED_FAMILY" in
    debian)
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq
      ;;
    rhel)
      if command -v microdnf >/dev/null 2>&1; then
        microdnf -y install jq
      else
        dnf -y install jq
      fi
      ;;
    *)
      printf '无法为未知系统族安装 jq：%s\n' "$EXPECTED_FAMILY" >&2
      exit 1
      ;;
  esac
fi

bash "$ROOT/tests/subscription-render-smoke.sh"
bash "$ROOT/tests/family-render-smoke.sh"
