#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64; xray_asset=Xray-linux-64.zip ;;
  aarch64|arm64) ARCH=arm64; xray_asset=Xray-linux-arm64-v8a.zip ;;
  *) die "测试工具只提供 amd64/arm64。" ;;
esac
export ARCH

DEST="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
WORK="$(mktemp -d "$ROOT/tests/fetch.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$DEST" "$WORK/unpack"

download_verified "Xray ${XRAY_VERSION}" \
  "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${xray_asset}" \
  "$(sha_for_arch XRAY)" "$WORK/xray.zip"
download_verified "sing-box ${SING_BOX_VERSION}" \
  "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz" \
  "$(sha_for_arch SING_BOX)" "$WORK/sing-box.tar.gz"
download_verified "Hysteria ${HYSTERIA_VERSION}" \
  "https://github.com/apernet/hysteria/releases/download/app%2Fv${HYSTERIA_VERSION}/hysteria-linux-${ARCH}" \
  "$(sha_for_arch HYSTERIA)" "$WORK/hysteria"
download_verified "Caddy ${CADDY_VERSION}" \
  "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz" \
  "$(sha_for_arch CADDY)" "$WORK/caddy.tar.gz"
download_verified "lego ${LEGO_VERSION}" \
  "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${ARCH}.tar.gz" \
  "$(sha_for_arch LEGO)" "$WORK/lego.tar.gz"

unzip -q "$WORK/xray.zip" -d "$WORK/unpack/xray"
tar --no-same-owner -xzf "$WORK/sing-box.tar.gz" -C "$WORK/unpack"
mkdir -p "$WORK/unpack/caddy" "$WORK/unpack/lego"
tar --no-same-owner -xzf "$WORK/caddy.tar.gz" -C "$WORK/unpack/caddy"
tar --no-same-owner -xzf "$WORK/lego.tar.gz" -C "$WORK/unpack/lego"

install -m 0755 "$WORK/unpack/xray/xray" "$DEST/xray"
install -m 0755 "$WORK/unpack/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" "$DEST/sing-box"
install -m 0755 "$WORK/hysteria" "$DEST/hysteria"
install -m 0755 "$WORK/unpack/caddy/caddy" "$DEST/caddy"
install -m 0755 "$WORK/unpack/lego/lego" "$DEST/lego"

printf '冻结测试工具已放到：%s\n' "$DEST"

