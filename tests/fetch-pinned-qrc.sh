#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"

ARCH="${1:-}"
DEST="${2:-}"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "qrc 测试工具架构必须是 amd64 或 arm64。" ;;
esac
[[ -n "$DEST" ]] || die "必须提供 qrc 输出路径。"
export ARCH

WORK="$(mktemp -d "$ROOT/tests/fetch-qrc.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
qrc_asset="qrc_${QRC_VERSION}_linux_${ARCH}.tar.gz"

download_verified "qrc ${QRC_VERSION} (${ARCH})" \
  "https://github.com/fumiyas/qrc/releases/download/v${QRC_VERSION}/${qrc_asset}" \
  "$(sha_for_arch QRC)" "$WORK/qrc.tar.gz"
tar --no-same-owner -xzf "$WORK/qrc.tar.gz" -C "$WORK" qrc
mkdir -p -- "$(dirname -- "$DEST")"
install -m 0755 "$WORK/qrc" "$DEST"
