#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"
SING_BOX_BIN="${SING_BOX_BIN:?}"
XRAY_BIN="${XRAY_BIN:?}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-default-anyreality.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/work/bin" "$WORK/etc" "$WORK/var"
ln -s "$SING_BOX_BIN" "$WORK/work/bin/sing-box"
ln -s "$XRAY_BIN" "$WORK/work/bin/xray"

bash -c '
  set -Eeuo pipefail
  source "$1"
  NEKO_ETC="$2/etc"
  NEKO_VAR="$2/var"
  NEKO_STATE="$2/etc/state.json"
  NEKO_USER=root
  NEKO_SUB_DIR="$2/etc/subscriptions"
  NEKO_CONFIG_DIR="$2/etc/config"
  WORKDIR="$2/work"
  DOMAIN=example.com
  ACME_EMAIL=admin@example.com
  ACME_METHOD=http-01
  NETWORK_MODE=dual
  OS_ID=debian
  OS_VERSION=12
  ARCH=amd64
  SUBSCRIPTION_DOMAIN_IPV4=v4.example.com
  SUBSCRIPTION_DOMAIN_IPV6=v6.example.com
  SUBSCRIPTION_IPV4_ADDRESS=192.0.2.10
  SUBSCRIPTION_IPV6_ADDRESS=2001:db8::10
  generate_reality_pair() {
    printf "%s %s\n" \
      "kF-xXmV_yq2mtuzBfBZw9g-VAqO712QGpKFVfOqbv1Q" \
      "BdhFQXLg2ajaJ3BbMQ5esGMIUCGph36ShM2DfzmyOyM"
  }
  chown() { :; }
  write_initial_state
  source "$3"
  render_all
' _ "$ROOT/install.sh" "$WORK" "$ROOT/lib/render.sh"

state="$WORK/etc/state.json"
jq -e --arg release "$NEKO_RELEASE" '
  .release == $release
  and .experimental.anyreality.enabled == true
  and (.experimental.anyreality.port | type == "number")
  and (.experimental.anyreality.cross_port | type == "number")
  and (.experimental.anyreality.password | test("^[A-Za-z0-9_-]{16,128}$"))
  and (.experimental.anyreality.private_key | test("^[A-Za-z0-9_-]{43}$"))
  and (.experimental.anyreality.public_key | test("^[A-Za-z0-9_-]{43}$"))
  and (.experimental.anyreality.short_id | test("^[0-9a-f]{16}$"))
  and ([
    .ports.hysteria2_start, .ports.hysteria2_end,
    .ports.tuic, .ports.ss2022, .ports.anytls, .ports.trojan,
    .ports.vless_reality_vision, .ports.vless_reality_xhttp,
    .ports.cross.tuic, .ports.cross.ss2022, .ports.cross.anytls,
    .ports.cross.trojan, .ports.cross.vless_reality_vision,
    .ports.cross.vless_reality_xhttp,
    .experimental.anyreality.port, .experimental.anyreality.cross_port
  ] | length == (unique | length))
' "$state" >/dev/null

jq -e '.outbounds[] | select(.tag == "AnyReality")' \
  "$WORK/etc/subscriptions/sing-box-v4.json" >/dev/null
grep -Fq 'name: "AnyReality"' "$WORK/etc/subscriptions/shadowrocket-v4.txt"
for unsupported in \
  "$WORK/etc/subscriptions/mihomo-v4.yaml" \
  "$WORK/etc/subscriptions/stash-v4.yaml"; do
  if grep -qE 'AnyReality|anyreality' "$unsupported"; then
    printf '不支持 AnyReality 的订阅意外包含该节点：%s\n' "$unsupported" >&2
    exit 1
  fi
done

printf '新安装默认生成 AnyReality，并仅加入 sing-box 与 Shadowrocket。\n'
