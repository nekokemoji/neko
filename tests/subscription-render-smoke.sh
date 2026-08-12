#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-subscription-smoke.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

command -v jq >/dev/null 2>&1 \
  || { printf '跨发行版订阅渲染测试缺少 jq。\n' >&2; exit 1; }

mkdir -p "$WORK/etc"
cp -a -- "$ROOT/tests/fixtures/state.json" "$WORK/etc/state.json"

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

mapfile -t subscription_files < <(
  find "$WORK/etc/subscriptions" -maxdepth 1 -type f -printf '%f\n' | sort
)
expected_files=(
  mihomo-v4-to-v6.yaml
  mihomo-v4.yaml
  mihomo-v6-to-v4.yaml
  mihomo-v6.yaml
  shadowrocket-v4-to-v6.txt
  shadowrocket-v4.txt
  shadowrocket-v6-to-v4.txt
  shadowrocket-v6.txt
  sing-box-v4-to-v6.json
  sing-box-v4.json
  sing-box-v6-to-v4.json
  sing-box-v6.json
  stash-v4-to-v6.yaml
  stash-v4.yaml
  stash-v6-to-v4.yaml
  stash-v6.yaml
)
if [[ "${subscription_files[*]}" != "${expected_files[*]}" ]]; then
  printf '订阅渲染文件清单与预期不一致。\n实际：%s\n预期：%s\n' \
    "${subscription_files[*]}" "${expected_files[*]}" >&2
  exit 1
fi

check_profile() {
  local etc_dir="$1" profile="$2" address="$3" dns_server="$4"
  local dns_mode="$5" dns_strategy="$6" rejected_ip_version="$7"
  local hy2_ports="$8" tuic_port="$9" ss_port="${10}" anytls_port="${11}"
  local trojan_port="${12}" vision_port="${13}"
  local vision_public_key vision_short_id
  vision_public_key="$(jq -r '.reality.vision_public_key' "$WORK/etc/state.json")"
  vision_short_id="$(jq -r '.reality.vision_short_id' "$WORK/etc/state.json")"
  jq -e \
    --arg address "$address" \
    --arg dns_server "$dns_server" \
    --arg dns_mode "$dns_mode" \
    --arg dns_strategy "$dns_strategy" \
    --arg vision_public_key "$vision_public_key" \
    --arg vision_short_id "$vision_short_id" \
    --arg hy2_ports "$hy2_ports" \
    --argjson rejected_ip_version "$rejected_ip_version" \
    --argjson tuic_port "$tuic_port" \
    --argjson ss_port "$ss_port" \
    --argjson anytls_port "$anytls_port" \
    --argjson trojan_port "$trojan_port" \
    --argjson vision_port "$vision_port" \
    '
      .dns.strategy == $dns_strategy
      and (if $dns_mode == "akdns" then
        .dns.final == "smart-akdns"
        and .dns.servers == [{
          type: "tcp",
          tag: "smart-akdns",
          server: $dns_server,
          server_port: 53,
          detour: "PROXY"
        }]
      else
        .dns.final == "strict-doh"
        and .dns.servers == [{
          type: "https",
          tag: "strict-doh",
          server: $dns_server,
          server_port: 443,
          path: "/dns-query",
          tls: {
            enabled: true,
            server_name: "cloudflare-dns.com",
            insecure: false
          },
          detour: "PROXY"
        }]
      end)
      and (.inbounds | length == 1)
      and .inbounds[0].type == "tun"
      and .inbounds[0].auto_route
      and .inbounds[0].strict_route
      and (.outbounds | length == 7)
      and .outbounds[0].type == "selector"
      and .outbounds[0].tag == "PROXY"
      and .outbounds[0].outbounds == [
        "HY2",
        "TUIC-v5",
        "SS2022",
        "AnyTLS",
        "Trojan-TLS",
        "VLESS-Reality-Vision"
      ]
      and ([.outbounds[] | select(.tag != "PROXY") | .server] | length == 6)
      and ([.outbounds[] | select(.tag != "PROXY") | .server] | all(. == $address))
      and ([.outbounds[] | .type] | index("direct") == null)
      and .route.final == "PROXY"
      and .route.rules == [
        {protocol: "dns", action: "hijack-dns"},
        {ip_version: $rejected_ip_version, action: "reject"}
      ]
      and ([.outbounds[]
        | select(.tag == "HY2"
          or .tag == "TUIC-v5"
          or .tag == "AnyTLS"
          or .tag == "Trojan-TLS"
          or .tag == "VLESS-Reality-Vision")
        | .tls.server_name] | all(. == "example.com"))
      and ([.outbounds[]
        | select(.tls != null)
        | .tls.insecure] | all(. == false))
      and .outbounds[1].server_ports == [$hy2_ports]
      and .outbounds[2].server_port == $tuic_port
      and .outbounds[3].server_port == $ss_port
      and .outbounds[4].server_port == $anytls_port
      and .outbounds[5].server_port == $trojan_port
      and .outbounds[6].server_port == $vision_port
      and .outbounds[6].tls.reality.public_key == $vision_public_key
      and .outbounds[6].tls.reality.short_id == $vision_short_id
    ' "$etc_dir/subscriptions/sing-box-${profile}.json" >/dev/null
}

check_profile "$WORK/etc" v4 127.0.0.1 1.1.1.1 public ipv4_only 6 \
  21000:21127 22000 23000 24000 24500 25000
check_profile "$WORK/etc" v6 ::1 2606:4700:4700::1111 public ipv6_only 4 \
  21000:21127 22000 23000 24000 24500 25000
check_profile "$WORK/etc" v4-to-v6 127.0.0.1 2606:4700:4700::1111 public ipv6_only 4 \
  27000:27127 28000 29000 30000 31000 32000
check_profile "$WORK/etc" v6-to-v4 ::1 1.1.1.1 public ipv4_only 6 \
  27000:27127 28000 29000 30000 31000 32000

mkdir -p "$WORK/etc-akdns"
cp -a -- "$ROOT/tests/fixtures/state.json" "$WORK/etc-akdns/state.json"
NEKO_ETC="$WORK/etc-akdns" \
  NEKO_VAR="$WORK/var-akdns" \
  NEKO_STATE="$WORK/etc-akdns/state.json" \
  NEKO_USER=root \
  NEKO_AKDNS_CLIENT_MODE=on \
  NEKO_AKDNS_CLIENT_RESOLVER=66.66.66.66 \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    source "$2"
    render_all
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

check_profile "$WORK/etc-akdns" v4 127.0.0.1 66.66.66.66 akdns ipv4_only 6 \
  21000:21127 22000 23000 24000 24500 25000
check_profile "$WORK/etc-akdns" v6 ::1 2606:4700:4700::1111 public ipv6_only 4 \
  21000:21127 22000 23000 24000 24500 25000
check_profile "$WORK/etc-akdns" v4-to-v6 127.0.0.1 2606:4700:4700::1111 public ipv6_only 4 \
  27000:27127 28000 29000 30000 31000 32000
check_profile "$WORK/etc-akdns" v6-to-v4 ::1 66.66.66.66 akdns ipv4_only 6 \
  27000:27127 28000 29000 30000 31000 32000

for profile in v4 v6-to-v4; do
  grep -Fq 'respect-rules: true' \
    "$WORK/etc-akdns/subscriptions/mihomo-${profile}.yaml"
  grep -Fq 'tcp://66.66.66.66#PROXY' \
    "$WORK/etc-akdns/subscriptions/mihomo-${profile}.yaml"
  grep -Fq 'follow-rule: true' \
    "$WORK/etc-akdns/subscriptions/stash-${profile}.yaml"
  grep -Fq '    - "tcp://66.66.66.66"' \
    "$WORK/etc-akdns/subscriptions/stash-${profile}.yaml"
done
for profile in v6 v4-to-v6; do
  if grep -Fq '66.66.66.66' \
      "$WORK/etc-akdns/subscriptions/mihomo-${profile}.yaml"; then
    printf 'IPv6 出口 Mihomo 订阅不应使用 AKDNS：%s\n' "$profile" >&2
    exit 1
  fi
  if grep -Fq '66.66.66.66' \
      "$WORK/etc-akdns/subscriptions/stash-${profile}.yaml"; then
    printf 'IPv6 出口 Stash 订阅不应使用 AKDNS：%s\n' "$profile" >&2
    exit 1
  fi
done

# The normal upgrade/panel render path uses auto detection rather than the
# explicit transaction override.  Exercise the root-owned status + exact
# resolv.conf match that permits that transition.
mkdir -p "$WORK/etc-auto" "$WORK/var-auto/akdns" "$WORK/system-auto"
cp -a -- "$ROOT/tests/fixtures/state.json" "$WORK/etc-auto/state.json"
printf 'resolver=108.160.138.51\n' > "$WORK/var-auto/akdns/status"
printf 'nameserver 108.160.138.51\noptions use-vc\n' \
  > "$WORK/system-auto/resolv.conf"
NEKO_ETC="$WORK/etc-auto" \
  NEKO_VAR="$WORK/var-auto" \
  NEKO_STATE="$WORK/etc-auto/state.json" \
  NEKO_RESOLV_CONF="$WORK/system-auto/resolv.conf" \
  NEKO_USER=root \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    source "$2"
    render_all
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
check_profile "$WORK/etc-auto" v4 127.0.0.1 108.160.138.51 akdns ipv4_only 6 \
  21000:21127 22000 23000 24000 24500 25000

caddy="$WORK/etc/config/Caddyfile"
grep -Fq 'rewrite * /sing-box-v4.json' "$caddy"
grep -Fq 'rewrite * /sing-box-v6.json' "$caddy"
grep -Fq 'rewrite * /sing-box-v4-to-v6.json' "$caddy"
grep -Fq 'rewrite * /sing-box-v6-to-v4.json' "$caddy"
grep -Fq 'handle /test-subscription-token/v4/sing-box.json' "$caddy"
grep -Fq 'handle /test-subscription-token/v6/sing-box.json' "$caddy"
grep -Fq 'handle /test-v4-to-v6-token/v4-to-v6/sing-box.json' "$caddy"
grep -Fq 'handle /test-v6-to-v4-token/v6-to-v4/sing-box.json' "$caddy"
grep -Fq 'handle /test-subscription-token/sing-box.json' "$caddy"
[[ "$(grep -Fc 'header Content-Type "application/json; charset=utf-8"' "$caddy")" == 6 ]]

printf '十六份订阅跨发行版渲染测试通过。\n'
