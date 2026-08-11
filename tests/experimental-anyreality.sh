#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-anyreality.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/etc"
if [[ -n "${SING_BOX_BIN:-}" ]]; then
  mkdir -p "$WORK/var/lego/certificates"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj /CN=example.com \
    -keyout "$WORK/var/lego/certificates/example.com.key" \
    -out "$WORK/var/lego/certificates/example.com.crt" >/dev/null 2>&1
fi
jq '
  .experimental.anyreality = {
    enabled: true,
    port: 34000,
    cross_port: 35000,
    password: "test-anyreality-password",
    private_key: .reality.vision_private_key,
    public_key: .reality.vision_public_key,
    short_id: "2122232425262728"
  }
' "$ROOT/tests/fixtures/state.json" > "$WORK/etc/state.json"

NEKO_ETC="$WORK/etc" \
  NEKO_VAR="$WORK/var" \
  NEKO_STATE="$WORK/etc/state.json" \
  NEKO_USER=root \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    source "$2"
    render_all
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

server="$WORK/etc/config/sing-box.json"
jq -e '
  ([.inbounds[] | select(.tag | startswith("anyreality-"))] | length) == 4
  and ([.inbounds[] | select(.tag | startswith("anyreality-")) | .type]
    | all(. == "anytls"))
  and ([.inbounds[] | select(.tag | startswith("anyreality-"))
    | .tls.reality.handshake] | all(. == {server: "127.0.0.1", server_port: 8443}))
  and ([.inbounds[] | select(.tag | startswith("anyreality-"))
    | .tls.reality.private_key]
    | all(. == "kF-xXmV_yq2mtuzBfBZw9g-VAqO712QGpKFVfOqbv1Q"))
  and (.inbounds[] | select(.tag == "anyreality-v4-in").listen_port == 34000)
  and (.inbounds[] | select(.tag == "anyreality-v6-in").listen_port == 34000)
  and (.inbounds[] | select(.tag == "anyreality-v4-to-v6-in").listen_port == 35000)
  and (.inbounds[] | select(.tag == "anyreality-v6-to-v4-in").listen_port == 35000)
' "$server" >/dev/null

if [[ -n "${SING_BOX_BIN:-}" ]]; then
  "$SING_BOX_BIN" check -c "$server" >/dev/null
fi

for profile in v4 v6; do
  port=34000
  client="$WORK/etc/subscriptions/sing-box-${profile}.json"
  jq -e --argjson port "$port" '
    .outbounds[0].outbounds == [
      "HY2", "TUIC-v5", "SS2022", "AnyTLS", "Trojan-TLS",
      "VLESS-Reality-Vision", "AnyReality"
    ]
    and (.outbounds[] | select(.tag == "AnyReality")
      | .type == "anytls"
      and .server_port == $port
      and .password == "test-anyreality-password"
      and .tls.utls == {enabled: true, fingerprint: "chrome"}
      and .tls.reality == {
        enabled: true,
        public_key: "BdhFQXLg2ajaJ3BbMQ5esGMIUCGph36ShM2DfzmyOyM",
        short_id: "2122232425262728"
      })
  ' "$client" >/dev/null
  if [[ -n "${SING_BOX_BIN:-}" ]]; then
    "$SING_BOX_BIN" check -c "$client" >/dev/null
  fi
done

for profile in v4-to-v6 v6-to-v4; do
  client="$WORK/etc/subscriptions/sing-box-${profile}.json"
  jq -e '
    .outbounds[] | select(.tag == "AnyReality") | .server_port == 35000
  ' "$client" >/dev/null
  if [[ -n "${SING_BOX_BIN:-}" ]]; then
    "$SING_BOX_BIN" check -c "$client" >/dev/null
  fi
done

for unsupported_profile in \
  "$WORK/etc/subscriptions"/mihomo-*.yaml \
  "$WORK/etc/subscriptions"/stash-*.yaml; do
  if grep -qE 'AnyReality|anyreality' "$unsupported_profile"; then
    printf 'AnyReality 不应出现在 %s。\n' "$unsupported_profile" >&2
    exit 1
  fi
done

for profile in v4 v6; do
  shadowrocket="$WORK/etc/subscriptions/shadowrocket-${profile}.txt"
  grep -Fq 'name: "AnyReality"' "$shadowrocket"
  grep -Fq 'type: anytls' "$shadowrocket"
  grep -Fq 'port: 34000' "$shadowrocket"
  grep -Fq 'password: "test-anyreality-password"' "$shadowrocket"
  grep -Fq 'public-key: "BdhFQXLg2ajaJ3BbMQ5esGMIUCGph36ShM2DfzmyOyM"' "$shadowrocket"
  grep -Fq 'short-id: "2122232425262728"' "$shadowrocket"
done
for profile in v4-to-v6 v6-to-v4; do
  shadowrocket="$WORK/etc/subscriptions/shadowrocket-${profile}.txt"
  grep -A8 -F 'name: "AnyReality"' "$shadowrocket" | grep -Fq 'port: 35000'
done

NEKO_ETC="$WORK/etc" \
  NEKO_VAR="$WORK/var" \
  NEKO_STATE="$WORK/etc/state.json" \
  NEKO_USER=root \
  UFW_PROFILE_FILE="$WORK/neko-proxy" \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    source "$2"
    load_state
    write_ufw_profile_file
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/firewall.sh"
grep -Eq 'ports=.*34000.*35000.*/tcp' "$WORK/neko-proxy"

anyreality_before="$(jq -cS '.experimental.anyreality' "$WORK/etc/state.json")"
printf 'ROTATE\n' \
  | NEKO_ETC="$WORK/etc" \
    NEKO_VAR="$WORK/var" \
    NEKO_STATE="$WORK/etc/state.json" \
    NEKO_LIBEXEC="$ROOT" \
    NEKO_USER=root \
    NEKO_PANEL_TMP_DIR="$WORK" \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      acquire_maintenance_lock() { :; }
      release_maintenance_lock() { :; }
      generate_anyreality_pair() {
        printf "%s %s\n" \
          "2JjE4cO-TqYTqFzBjYczbtN85c0EEmeJ8fifIDuav3g" \
          "FVuHPI9DrVZksjPE01p9Kbifs2M4DsnXlz6F_HId7SU"
      }
      render_all() { :; }
      validate_runtime_configs() { load_state; }
      restart_runtime_services() { :; }
      show_subscription_links() { :; }
      rotate_node_credentials false >/dev/null
    ' _ "$ROOT/runtime/panel.sh"
jq -e --argjson before "$anyreality_before" '
  .experimental.anyreality.enabled == true
  and .experimental.anyreality.port == 34000
  and .experimental.anyreality.cross_port == 35000
  and .experimental.anyreality.password != $before.password
  and .experimental.anyreality.private_key != $before.private_key
  and .experimental.anyreality.public_key != $before.public_key
  and .experimental.anyreality.short_id != $before.short_id
' "$WORK/etc/state.json" >/dev/null

if grep -Eq 'manage_anyreality|install_anyreality|uninstall_anyreality|实验性协议' \
    "$ROOT/runtime/panel.sh"; then
  printf '面板不应保留 AnyReality 按需安装或卸载入口。\n' >&2
  exit 1
fi

printf 'AnyReality 默认渲染、严格路由、客户端隔离与防火墙测试通过。\n'
