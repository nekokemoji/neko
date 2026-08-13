#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-family-render.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

command -v jq >/dev/null 2>&1 \
  || { printf '地址族渲染测试缺少 jq。\n' >&2; exit 1; }

prepare_state() {
  local mode="$1" target="$2"
  mkdir -p "$target/etc"
  case "$mode" in
    ipv4-only)
      jq '
        .network.mode = "ipv4-only"
        | .subscription.ipv6_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv6_domain = null
        | .subscription.ipv6_address = null
        | .ports.cross = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    ipv6-only)
      jq '
        .network.mode = "ipv6-only"
        | .subscription.ipv4_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv4_domain = null
        | .subscription.ipv4_address = null
        | .ports.cross = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    dual)
      cp -a -- "$ROOT/tests/fixtures/state.json" "$target/etc/state.json"
      ;;
  esac
}

render_mode() {
  local target="$1"
  NEKO_ETC="$target/etc" \
    NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" \
    NEKO_USER=root \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      source "$2"
      render_all
    ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
}

invalid="$WORK/invalid-cross-port"
mkdir -p "$invalid/etc"
jq '.ports.cross.tuic = .ports.tuic' \
  "$ROOT/tests/fixtures/state.json" > "$invalid/etc/state.json"
if NEKO_ETC="$invalid/etc" NEKO_VAR="$invalid/var" \
  NEKO_STATE="$invalid/etc/state.json" NEKO_USER=root \
  bash -c 'source "$1"; load_state' _ "$ROOT/lib/common.sh" \
    >/dev/null 2>&1; then
  printf '状态加载错误接受了同族/跨族重复端口。\n' >&2
  exit 1
fi

assert_family() {
  local target="$1" family="$2" address="$3"
  local opposite="$4"
  [[ -s "$target/etc/subscriptions/mihomo-${family}.yaml" ]]
  [[ -s "$target/etc/subscriptions/stash-${family}.yaml" ]]
  [[ -s "$target/etc/subscriptions/shadowrocket-${family}.txt" ]]
  [[ -s "$target/etc/subscriptions/sing-box-${family}.json" ]]
  grep -Fq "server: \"${address}\"" \
    "$target/etc/subscriptions/mihomo-${family}.yaml"
  jq -e --arg address "$address" '
    [.outbounds[] | select(.tag != "PROXY") | .server]
    | length == 6 and all(. == $address)
  ' "$target/etc/subscriptions/sing-box-${family}.json" >/dev/null
  if grep -R -Fq -- "server: \"${opposite}\"" "$target/etc/subscriptions"; then
    printf '%s 模式订阅泄漏了未启用地址：%s\n' "$family" "$opposite" >&2
    exit 1
  fi
}

assert_server_dns_isolation() {
  local target="$1" mode="$2" has_v4=false has_v6=false
  local config
  [[ "$mode" == ipv6-only ]] || has_v4=true
  [[ "$mode" == ipv4-only ]] || has_v6=true

  jq -e \
    --argjson has_v4 "$has_v4" \
    --argjson has_v6 "$has_v6" '
      .dns.servers == (
        [{type: "local", tag: "local", prefer_go: true}]
        + (if $has_v6 then [{
          type: "https",
          tag: "strict-v6",
          server: "2606:4700:4700::1111",
          server_port: 443,
          path: "/dns-query",
          tls: {
            enabled: true,
            server_name: "cloudflare-dns.com",
            insecure: false
          }
        }] else [] end)
      )
      and .route.rules[0] == {
        port: [80, 443],
        action: "sniff",
        sniffer: ["http", "tls", "quic"],
        timeout: "1s"
      }
      and (if $has_v4 then
        any(.outbounds[];
          .tag == "direct-v4"
          and .domain_resolver == {
            server: "local", strategy: "ipv4_only"
          })
        and any(.route.rules[];
          .action == "resolve"
          and .server == "local"
          and .strategy == "ipv4_only")
      else true end)
      and (if $has_v6 then
        any(.outbounds[];
          .tag == "direct-v6"
          and .domain_resolver == {
            server: "strict-v6", strategy: "ipv6_only"
          })
        and any(.route.rules[];
          .action == "resolve"
          and .server == "strict-v6"
          and .strategy == "ipv6_only")
      else true end)
    ' "$target/etc/config/sing-box.json" >/dev/null

  jq -e \
    --argjson has_v4 "$has_v4" \
    --argjson has_v6 "$has_v6" '
      .dns == {
        queryStrategy: "UseIP",
        servers: (
          (if $has_v4 then [{
            address: "localhost", queryStrategy: "UseIPv4"
          }] else [] end)
          + (if $has_v6 then [{
            address: "https+local://[2606:4700:4700::1111]/dns-query",
            queryStrategy: "UseIPv6"
          }] else [] end)
        )
      }
      and ([.inbounds[].sniffing
        | .enabled == true
          and .routeOnly == false
          and .destOverride == ["http", "tls", "quic"]]
        | all)
    ' "$target/etc/config/xray.json" >/dev/null

  while IFS= read -r -d '' config; do
    grep -Fq 'sniff:' "$config"
    grep -Fq '  enable: true' "$config"
    grep -Fq '  rewriteDomain: false' "$config"
    grep -Fq '  tcpPorts: "80,443"' "$config"
    grep -Fq '  udpPorts: "443"' "$config"
    if grep -Fq '      mode: 6' "$config"; then
      grep -Fq 'resolver:' "$config"
      grep -Fq '    addr: "[2606:4700:4700::1111]:443"' "$config"
      grep -Fq '    sni: cloudflare-dns.com' "$config"
    elif grep -Fq 'resolver:' "$config"; then
      printf 'IPv4 出站 Hysteria 不应绕过系统 AKDNS：%s\n' "$config" >&2
      exit 1
    fi
  done < <(find "$target/etc/config" -maxdepth 1 -type f \
    -name 'hysteria-*.yaml' -print0)
}

for mode in ipv4-only ipv6-only dual; do
  target="$WORK/$mode"
  prepare_state "$mode" "$target"
  render_mode "$target"
  assert_server_dns_isolation "$target" "$mode"

  mapfile -t files < <(
    find "$target/etc/subscriptions" -maxdepth 1 -type f -printf '%f\n' | sort
  )
  case "$mode" in
    ipv4-only)
      expected=(
        mihomo-v4.yaml shadowrocket-v4.txt sing-box-v4.json stash-v4.yaml
      )
      [[ "${files[*]}" == "${expected[*]}" ]]
      assert_family "$target" v4 127.0.0.1 ::1
      [[ -s "$target/etc/config/hysteria-v4.yaml" ]]
      [[ ! -e "$target/etc/config/hysteria-v6.yaml" ]]
      [[ ! -e "$target/etc/config/hysteria-v4-to-v6.yaml" ]]
      [[ ! -e "$target/etc/config/hysteria-v6-to-v4.yaml" ]]
      jq -e '
        (.inbounds | length) == 4
        and ([.inbounds[].tag] | all(endswith("-v4-in")))
        and [.outbounds[].tag] == ["direct-v4"]
        and .route.final == "direct-v4"
      ' "$target/etc/config/sing-box.json" >/dev/null
      jq -e '
        (.inbounds | length) == 2
        and ([.inbounds[].tag] | all(contains("-v4-in")))
        and [.outbounds[].tag] == ["direct-v4", "blocked"]
      ' "$target/etc/config/xray.json" >/dev/null
      grep -Fq 'https://v4.example.com {' "$target/etc/config/Caddyfile"
      ! grep -Fq 'https://v6.example.com {' "$target/etc/config/Caddyfile"
      grep -Fq '/test-subscription-token/v4/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      ! grep -Fq '/test-subscription-token/v6/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      ;;
    ipv6-only)
      expected=(
        mihomo-v6.yaml shadowrocket-v6.txt sing-box-v6.json stash-v6.yaml
      )
      [[ "${files[*]}" == "${expected[*]}" ]]
      assert_family "$target" v6 ::1 127.0.0.1
      [[ ! -e "$target/etc/config/hysteria-v4.yaml" ]]
      [[ -s "$target/etc/config/hysteria-v6.yaml" ]]
      [[ ! -e "$target/etc/config/hysteria-v4-to-v6.yaml" ]]
      [[ ! -e "$target/etc/config/hysteria-v6-to-v4.yaml" ]]
      jq -e '
        (.inbounds | length) == 4
        and ([.inbounds[].tag] | all(endswith("-v6-in")))
        and [.outbounds[].tag] == ["direct-v6"]
        and .route.final == "direct-v6"
      ' "$target/etc/config/sing-box.json" >/dev/null
      jq -e '
        (.inbounds | length) == 2
        and ([.inbounds[].tag] | all(contains("-v6-in")))
        and [.outbounds[].tag] == ["direct-v6", "blocked"]
      ' "$target/etc/config/xray.json" >/dev/null
      ! grep -Fq 'https://v4.example.com {' "$target/etc/config/Caddyfile"
      grep -Fq 'https://v6.example.com {' "$target/etc/config/Caddyfile"
      ! grep -Fq '/test-subscription-token/v4/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      grep -Fq '/test-subscription-token/v6/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      ;;
    dual)
      [[ "${#files[@]}" == 16 ]]
      [[ -s "$target/etc/config/hysteria-v4.yaml" ]]
      [[ -s "$target/etc/config/hysteria-v6.yaml" ]]
      [[ -s "$target/etc/config/hysteria-v4-to-v6.yaml" ]]
      [[ -s "$target/etc/config/hysteria-v6-to-v4.yaml" ]]
      grep -Fq 'mode: 6' "$target/etc/config/hysteria-v4-to-v6.yaml"
      grep -Fq 'bindIPv6: ::1' "$target/etc/config/hysteria-v4-to-v6.yaml"
      grep -Fq 'mode: 4' "$target/etc/config/hysteria-v6-to-v4.yaml"
      grep -Fq 'bindIPv4: 127.0.0.1' "$target/etc/config/hysteria-v6-to-v4.yaml"
      jq -e '
        (.inbounds | length) == 16
        and [.outbounds[].tag] == ["direct-v4", "direct-v6"]
        and ([.route.rules[]
          | select(.outbound == "direct-v6")
          | .inbound[]] | index("tuic-v4-to-v6-in") != null)
        and ([.route.rules[]
          | select(.outbound == "direct-v4")
          | .inbound[]] | index("tuic-v6-to-v4-in") != null)
      ' "$target/etc/config/sing-box.json" >/dev/null
      jq -e '
        (.inbounds | length) == 8
        and [.outbounds[].tag] == ["direct-v4", "direct-v6", "blocked"]
        and ([.routing.rules[]
          | select(.outboundTag == "direct-v6")
          | .inboundTag[]] | index("vless-reality-vision-v4-to-v6-in") != null)
        and ([.routing.rules[]
          | select(.outboundTag == "direct-v4")
          | .inboundTag[]] | index("vless-reality-vision-v6-to-v4-in") != null)
      ' "$target/etc/config/xray.json" >/dev/null
      grep -Fq '/test-subscription-token/v4/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      grep -Fq '/test-subscription-token/v6/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      grep -Fq '/test-v4-to-v6-token/v4-to-v6/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      grep -Fq '/test-v6-to-v4-token/v6-to-v4/mihomo.yaml' \
        "$target/etc/config/Caddyfile"
      ;;
  esac
done

printf '三种地址族模式的跨发行版渲染测试通过。\n'
