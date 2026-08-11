#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"

ARCH="${1:-}"
DEST="${2:-}"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "NextTrace 测试工具架构必须是 amd64 或 arm64。" ;;
esac
[[ -n "$DEST" ]] || die "必须提供 NextTrace 输出路径。"
export ARCH

WORK="$(mktemp -d "$ROOT/tests/fetch-nexttrace.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
nexttrace_asset="nexttrace-tiny_linux_${ARCH}"

download_verified "NextTrace Tiny ${NEXTTRACE_VERSION} (${ARCH})" \
  "https://github.com/nxtrace/NTrace-core/releases/download/v${NEXTTRACE_VERSION}/${nexttrace_asset}" \
  "$(sha_for_arch NEXTTRACE)" "$WORK/nexttrace-tiny"
mkdir -p -- "$(dirname -- "$DEST")"
install -m 0755 "$WORK/nexttrace-tiny" "$DEST"
