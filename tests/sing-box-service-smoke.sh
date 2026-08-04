#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "$(id -u)" == 0 ]] || {
  printf 'sing-box systemd 冒烟测试必须以 root 运行。\n' >&2
  exit 1
}
[[ "$(< /proc/1/comm)" == systemd ]] || {
  printf 'PID 1 不是 systemd；拒绝运行 sing-box systemd 冒烟测试。\n' >&2
  exit 1
}

# shellcheck source=versions.env
source "$ROOT/versions.env"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/firewall.sh
source "$ROOT/lib/firewall.sh"

work="$(mktemp -d /var/tmp/neko-sing-box-smoke.XXXXXX)"
client_pid=""
mihomo_pid=""
client_ns="neko-sb-client"
host_veth="neko-sb-host"
client_veth="neko-sb-peer"
client_ns_created=0
ufw_enabled=0
test_ipv6="2001:db8::10"
test_ipv6_added=0
test_url="http://deb.debian.org/debian/"
cleanup() {
  if [[ -n "$client_pid" ]]; then
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  if [[ -n "$mihomo_pid" ]]; then
    kill "$mihomo_pid" 2>/dev/null || true
    wait "$mihomo_pid" 2>/dev/null || true
  fi
  if (( client_ns_created == 1 )); then
    ip netns delete "$client_ns" >/dev/null 2>&1 || true
  fi
  systemctl disable --now neko-sing-box.service >/dev/null 2>&1 || true
  if (( test_ipv6_added == 1 )); then
    ip -6 address del "${test_ipv6}/128" dev lo >/dev/null 2>&1 || true
  fi
  if (( ufw_enabled == 1 )); then
    [[ ! -r /etc/neko/state.json ]] || remove_firewall >/dev/null 2>&1 || true
    ufw --force delete allow 22/tcp >/dev/null 2>&1 || true
    ufw --force disable >/dev/null 2>&1 || true
  fi
  rm -f -- /etc/systemd/system/neko-sing-box.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf -- /etc/neko /var/lib/neko
  rm -rf -- "$work"
}
trap cleanup EXIT

guest_ipv4="$(
  ip -4 route get 1.1.1.1 \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
)"
is_ipv4_literal "$guest_ipv4" || die "无法确定 VM 的 IPv4 地址。"

download_verified "sing-box ${SING_BOX_VERSION}" \
  "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz" \
  "$SING_BOX_AMD64_SHA256" "$work/sing-box.tar.gz"
tar --no-same-owner -xzf "$work/sing-box.tar.gz" -C "$work"
sing_box="$work/sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box"
[[ -x "$sing_box" ]] || die "sing-box 测试二进制不存在。"
download_verified "Mihomo ${MIHOMO_VERSION}" \
  "https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-amd64-v${MIHOMO_VERSION}.gz" \
  "$MIHOMO_AMD64_SHA256" "$work/mihomo.gz"
gzip -dc "$work/mihomo.gz" > "$work/mihomo"
chmod 0755 "$work/mihomo"

install -d -m 0755 /usr/local/libexec/neko
install -m 0755 "$sing_box" /usr/local/libexec/neko/sing-box
install -d -m 0750 -o root -g neko-proxy \
  /etc/neko /etc/neko/config /var/lib/neko /var/lib/neko/lego \
  /var/lib/neko/lego/certificates

jq --arg address "$guest_ipv4" '
  .network.mode = "ipv4-only"
  | .subscription.ipv4_address = $address
' "$ROOT/tests/fixtures/state.json" > /etc/neko/state.json
chmod 0600 /etc/neko/state.json

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=example.com -addext subjectAltName=DNS:example.com \
  -keyout /var/lib/neko/lego/certificates/example.com.key \
  -out /var/lib/neko/lego/certificates/example.com.crt \
  >/dev/null 2>&1
chown -R root:neko-proxy /var/lib/neko/lego/certificates
find /var/lib/neko/lego/certificates -type d -exec chmod 0750 {} +
find /var/lib/neko/lego/certificates -type f -exec chmod 0640 {} +

NEKO_ETC=/etc/neko NEKO_VAR=/var/lib/neko NEKO_STATE=/etc/neko/state.json \
  NEKO_USER=neko-proxy bash -c '
    source "$1"
    source "$2"
    load_state
    render_sing_box
    render_subscriptions
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw --force enable >/dev/null
ufw_enabled=1
configure_firewall

ip netns add "$client_ns"
client_ns_created=1
ip link add "$host_veth" type veth peer name "$client_veth"
ip link set "$client_veth" netns "$client_ns"
ip address add 198.18.0.1/30 dev "$host_veth"
ip link set "$host_veth" up
ip netns exec "$client_ns" ip link set lo up
ip netns exec "$client_ns" ip address add 198.18.0.2/30 dev "$client_veth"
ip netns exec "$client_ns" ip link set "$client_veth" up
ip netns exec "$client_ns" ip route add default via 198.18.0.1

/usr/local/libexec/neko/sing-box check -c /etc/neko/config/sing-box.json
install -m 0644 "$ROOT/systemd/neko-sing-box.service" \
  /etc/systemd/system/neko-sing-box.service
systemctl daemon-reload
systemctl enable --now neko-sing-box.service
sleep 2
if ! systemctl is-active --quiet neko-sing-box.service; then
  journalctl -u neko-sing-box.service -n 100 --no-pager >&2 || true
  die "真实 sing-box 未能在 shipped systemd unit 下保持运行。"
fi

jq -n \
  --arg server "$guest_ipv4" \
  --arg tuic_uuid "11111111-1111-4111-8111-111111111111" \
  --arg tuic_password "test-tuic-password" \
  --arg ss_password "MDEyMzQ1Njc4OWFiY2RlZg==" \
  --arg anytls_password "test-anytls-password" \
  --arg trojan_password "test-trojan-password" \
  '{
    log: {level: "info", timestamp: true},
    inbounds: [
      {type: "mixed", tag: "tuic-client", listen: "127.0.0.1", listen_port: 41001},
      {type: "mixed", tag: "ss-client", listen: "127.0.0.1", listen_port: 41002},
      {type: "mixed", tag: "anytls-client", listen: "127.0.0.1", listen_port: 41003},
      {type: "mixed", tag: "trojan-client", listen: "127.0.0.1", listen_port: 41004}
    ],
    outbounds: [
      {
        type: "tuic", tag: "tuic", server: $server, server_port: 22000,
        uuid: $tuic_uuid, password: $tuic_password,
        congestion_control: "bbr", udp_relay_mode: "native",
        tls: {enabled: true, server_name: "example.com", insecure: true, alpn: ["h3"]}
      },
      {
        type: "shadowsocks", tag: "ss", server: $server, server_port: 23000,
        method: "2022-blake3-aes-128-gcm", password: $ss_password
      },
      {
        type: "anytls", tag: "anytls", server: $server, server_port: 24000,
        password: $anytls_password,
        tls: {enabled: true, server_name: "example.com", insecure: true, alpn: ["h2", "http/1.1"]}
      },
      {
        type: "trojan", tag: "trojan", server: $server, server_port: 24500,
        password: $trojan_password,
        tls: {enabled: true, server_name: "example.com", insecure: true}
      }
    ],
    route: {
      rules: [
        {inbound: ["tuic-client"], action: "route", outbound: "tuic"},
        {inbound: ["ss-client"], action: "route", outbound: "ss"},
        {inbound: ["anytls-client"], action: "route", outbound: "anytls"},
        {inbound: ["trojan-client"], action: "route", outbound: "trojan"}
      ],
      final: "ss"
    }
  }' > "$work/client.json"

"$sing_box" check -c "$work/client.json"
ip netns exec "$client_ns" \
  "$sing_box" run -c "$work/client.json" >"$work/client.log" 2>&1 &
client_pid=$!
sleep 2
if ! kill -0 "$client_pid" 2>/dev/null; then
  cat "$work/client.log" >&2
  die "sing-box 测试客户端未能保持运行。"
fi

for proxy_port in 41001 41002 41003 41004; do
  if ! ip netns exec "$client_ns" \
      curl --silent --show-error --output /dev/null \
      --connect-timeout 8 --max-time 20 \
      --socks5-hostname "127.0.0.1:${proxy_port}" "$test_url"; then
    printf 'SOCKS 端口 %s 的协议往返失败。\n' "$proxy_port" >&2
    cat "$work/client.log" >&2 || true
    journalctl -u neko-sing-box.service -n 100 --no-pager >&2 || true
    exit 1
  fi
done

mihomo_port=42000
for proxy_name in TUIC-v5 SS2022 AnyTLS Trojan-TLS; do
  ((mihomo_port += 1))
  mihomo_dir="$work/mihomo-${proxy_name}"
  mkdir -p "$mihomo_dir"
  sed \
    -e "s/^mixed-port: .*/mixed-port: ${mihomo_port}/" \
    -e "s/proxies: \[HY2, TUIC-v5, SS2022, AnyTLS, Trojan-TLS, VLESS-Reality-Vision, VLESS-Reality-XHTTP\]/proxies: [${proxy_name}]/" \
    -e 's/skip-cert-verify: false/skip-cert-verify: true/g' \
    /etc/neko/subscriptions/mihomo-v4.yaml > "$mihomo_dir/config.yaml"
  ip netns exec "$client_ns" \
    "$work/mihomo" -d "$mihomo_dir" -f "$mihomo_dir/config.yaml" \
    >"$mihomo_dir/client.log" 2>&1 &
  mihomo_pid=$!
  sleep 2
  if ! kill -0 "$mihomo_pid" 2>/dev/null; then
    cat "$mihomo_dir/client.log" >&2
    die "Mihomo 的 ${proxy_name} 测试客户端未能保持运行。"
  fi
  if ! ip netns exec "$client_ns" \
      curl --silent --show-error --output /dev/null \
      --connect-timeout 8 --max-time 20 \
      --socks5-hostname "127.0.0.1:${mihomo_port}" "$test_url"; then
    cat "$mihomo_dir/client.log" >&2 || true
    journalctl -u neko-sing-box.service -n 100 --no-pager >&2 || true
    die "生成的 Mihomo 订阅中 ${proxy_name} 往返失败。"
  fi
  kill "$mihomo_pid" 2>/dev/null || true
  wait "$mihomo_pid" 2>/dev/null || true
  mihomo_pid=""
done

ip -6 address add "${test_ipv6}/128" dev lo
test_ipv6_added=1
jq --arg address "$test_ipv6" '
  .network.mode = "dual"
  | .subscription.ipv6_address = $address
' /etc/neko/state.json > "$work/state-dual.json"
install -m 0600 "$work/state-dual.json" /etc/neko/state.json
NEKO_ETC=/etc/neko NEKO_VAR=/var/lib/neko NEKO_STATE=/etc/neko/state.json \
  NEKO_USER=neko-proxy bash -c '
    source "$1"
    source "$2"
    load_state
    render_sing_box
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
/usr/local/libexec/neko/sing-box check -c /etc/neko/config/sing-box.json
systemctl restart neko-sing-box.service
sleep 2
if ! systemctl is-active --quiet neko-sing-box.service; then
  journalctl -u neko-sing-box.service -n 100 --no-pager >&2 || true
  die "双栈配置下的真实 sing-box 未能保持运行。"
fi

# A server restart invalidates the existing TUIC/QUIC session. Recreate the
# client so this phase tests a fresh connection, as a real client would after
# reconnecting, instead of waiting on a stale transport session.
kill "$client_pid" 2>/dev/null || true
wait "$client_pid" 2>/dev/null || true
client_pid=""
ip netns exec "$client_ns" \
  "$sing_box" run -c "$work/client.json" >"$work/client-dual.log" 2>&1 &
client_pid=$!
sleep 2
if ! kill -0 "$client_pid" 2>/dev/null; then
  cat "$work/client-dual.log" >&2
  die "双栈测试的 sing-box 客户端未能保持运行。"
fi
for proxy_port in 41001 41002 41003 41004; do
  if ! ip netns exec "$client_ns" \
      curl --silent --show-error --output /dev/null \
      --connect-timeout 8 --max-time 20 \
      --socks5-hostname "127.0.0.1:${proxy_port}" "$test_url"; then
    printf '双栈配置下 SOCKS 端口 %s 的域名往返失败。\n' \
      "$proxy_port" >&2
    cat "$work/client-dual.log" >&2 || true
    journalctl -u neko-sing-box.service -n 100 --no-pager >&2 || true
    exit 1
  fi
done

printf '真实 sing-box systemd 服务、UFW 入站及生成的 Mihomo 四协议订阅往返通过。\n'
