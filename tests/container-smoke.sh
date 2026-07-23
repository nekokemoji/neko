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

printf '通过：%s %s / %s（Bash %s）\n' \
  "$OS_ID" "$OS_VERSION" "$ARCH" "${BASH_VERSION}"

# Debian 12 ships mawk 1.3.4.20200120, which does not understand interval
# expressions such as {1,3}.  Exercise the real distro awk while mocking only
# the resolver, so the strict IPv4 parser remains portable across the matrix.
getent() {
  case "${1:-}:${2:-}" in
    ahostsv4:v4.neko-test.invalid.)
      printf '%s\n' \
        '192.0.2.44 STREAM' \
        '192.0.2.44 DGRAM' \
        '999.0.0.1 RAW' \
        'not-an-address RAW'
      ;;
  esac
}
[[ "$(resolved_ipv4_addresses v4.neko-test.invalid)" == "192.0.2.44" ]]
unset -f getent

if [[ -n "${NEKO_CONTAINER_BOOTSTRAP_ARCHIVE:-}" ]]; then
  NEKO_BOOTSTRAP_ARCHIVE="$NEKO_CONTAINER_BOOTSTRAP_ARCHIVE" \
    NEKO_BOOTSTRAP_WORK_BASE=/tmp \
    NEKO_BOOTSTRAP_TEST_MODE=1 \
    bash "$ROOT/bootstrap.sh"
fi
