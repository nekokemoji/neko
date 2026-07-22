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
