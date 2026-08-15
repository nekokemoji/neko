#!/usr/bin/env bash

# Strict same-family and cross-family subscription orchestration. Loaded through
# lib/render.sh.

render_subscription_route() {
  local context_name="${1:-}"
  (( $# == 1 )) || route_context_fail "渲染入口只接受一个具名上下文。" || return
  route_context_validate "$context_name" || return
  local -n route_render_ref="$context_name"
  local profile="${route_render_ref[profile]}"
  local server="${route_render_ref[server]}"
  local ingress_ip_version="${route_render_ref[ingress_family]}"
  local dns_server="${route_render_ref[dns_server]}"
  local dns_mode="${route_render_ref[dns_mode]}"
  local dns_strategy="${route_render_ref[dns_strategy]}"
  local rejected_ip_version
  local route_hy2_start="${route_render_ref[hy2_start]}"
  local route_hy2_end="${route_render_ref[hy2_end]}"
  local route_tuic_port="${route_render_ref[tuic_port]}"
  local route_ss_port="${route_render_ref[ss_port]}"
  local route_anytls_port="${route_render_ref[anytls_port]}"
  local route_trojan_port="${route_render_ref[trojan_port]}"
  local route_vision_port="${route_render_ref[vision_port]}"
  local route_xhttp_port="${route_render_ref[xhttp_port]}"
  local route_anyreality_port="${route_render_ref[anyreality_port]}"
  local route_anyreality_enabled="${route_render_ref[anyreality_enabled]}"

  case "${route_render_ref[rejected_ip_family]}" in
    ipv4) rejected_ip_version=4 ;;
    ipv6) rejected_ip_version=6 ;;
  esac

  render_client_yaml "${NEKO_SUB_DIR}/mihomo-${profile}.yaml" yes \
    "$server" "$ingress_ip_version" \
    "$route_hy2_start" "$route_hy2_end" "$route_tuic_port" "$route_ss_port" \
    "$route_anytls_port" "$route_trojan_port" "$route_vision_port" "$route_xhttp_port" \
    "$dns_mode" "$dns_server"
  # Stash does not implement XHTTP; each strict route has six nodes.
  render_stash_yaml "${NEKO_SUB_DIR}/stash-${profile}.yaml" "$server" \
    "$route_hy2_start" "$route_hy2_end" "$route_tuic_port" "$route_ss_port" \
    "$route_anytls_port" "$route_trojan_port" "$route_vision_port" \
    "$dns_mode" "$dns_server"
  render_shadowrocket "${NEKO_SUB_DIR}/shadowrocket-${profile}.txt" "$server" \
    "$route_hy2_start" "$route_hy2_end" "$route_tuic_port" "$route_ss_port" \
    "$route_anytls_port" "$route_trojan_port" "$route_vision_port" "$route_xhttp_port" \
    "$route_anyreality_port" "$route_anyreality_enabled"
  # Official sing-box Remote Profiles are complete JSON configurations.
  render_sing_box_client "${NEKO_SUB_DIR}/sing-box-${profile}.json" \
    "$server" "$dns_server" "$dns_mode" "$dns_strategy" "$rejected_ip_version" \
    "$route_hy2_start" "$route_hy2_end" "$route_tuic_port" "$route_ss_port" \
    "$route_anytls_port" "$route_trojan_port" "$route_vision_port" \
    "$route_anyreality_port" "$route_anyreality_enabled"
}

render_subscriptions() {
  local akdns_resolver="" v4_dns_mode=public v4_dns_server=1.1.1.1
  local -A route_context=()
  case "${NEKO_AKDNS_CLIENT_MODE:-auto}" in
    on)
      akdns_resolver="${NEKO_AKDNS_CLIENT_RESOLVER:-}"
      is_ipv4_literal "$akdns_resolver" \
        || die "AKDNS 客户端解析地址无效：${akdns_resolver:-empty}"
      ;;
    off) ;;
    auto)
      akdns_resolver="$(managed_akdns_resolver 2>/dev/null || true)"
      ;;
    *) die "不支持的 AKDNS 客户端渲染模式：${NEKO_AKDNS_CLIENT_MODE}" ;;
  esac
  if [[ -n "$akdns_resolver" ]]; then
    v4_dns_mode=akdns
    v4_dns_server="$akdns_resolver"
  fi
  mkdir -p "$NEKO_SUB_DIR"
  rm -f -- \
    "${NEKO_SUB_DIR}/mihomo-v4.yaml" \
    "${NEKO_SUB_DIR}/mihomo-v6.yaml" \
    "${NEKO_SUB_DIR}/stash-v4.yaml" \
    "${NEKO_SUB_DIR}/stash-v6.yaml" \
    "${NEKO_SUB_DIR}/shadowrocket-v4.txt" \
    "${NEKO_SUB_DIR}/shadowrocket-v6.txt" \
    "${NEKO_SUB_DIR}/sing-box-v4.json" \
    "${NEKO_SUB_DIR}/sing-box-v6.json" \
    "${NEKO_SUB_DIR}/mihomo-v4-to-v6.yaml" \
    "${NEKO_SUB_DIR}/mihomo-v6-to-v4.yaml" \
    "${NEKO_SUB_DIR}/stash-v4-to-v6.yaml" \
    "${NEKO_SUB_DIR}/stash-v6-to-v4.yaml" \
    "${NEKO_SUB_DIR}/shadowrocket-v4-to-v6.txt" \
    "${NEKO_SUB_DIR}/shadowrocket-v6-to-v4.txt" \
    "${NEKO_SUB_DIR}/sing-box-v4-to-v6.json" \
    "${NEKO_SUB_DIR}/sing-box-v6-to-v4.json"
  if network_mode_has_ipv4; then
    route_context=(
      [profile]=v4
      [server]="$SUBSCRIPTION_IPV4_ADDRESS"
      [ingress_family]=ipv4
      [egress_family]=ipv4
      [dns_mode]="$v4_dns_mode"
      [dns_server]="$v4_dns_server"
      [dns_strategy]=ipv4_only
      [rejected_ip_family]=ipv6
    )
    route_context_set_ports route_context normal
    render_subscription_route route_context
  fi
  if network_mode_has_ipv6; then
    route_context=(
      [profile]=v6
      [server]="$SUBSCRIPTION_IPV6_ADDRESS"
      [ingress_family]=ipv6
      [egress_family]=ipv6
      [dns_mode]=public
      [dns_server]="2606:4700:4700::1111"
      [dns_strategy]=ipv6_only
      [rejected_ip_family]=ipv4
    )
    route_context_set_ports route_context normal
    render_subscription_route route_context
  fi
  if network_mode_has_cross_routes; then
    route_context=(
      [profile]=v4-to-v6
      [server]="$SUBSCRIPTION_IPV4_ADDRESS"
      [ingress_family]=ipv4
      [egress_family]=ipv6
      [dns_mode]=public
      [dns_server]="2606:4700:4700::1111"
      [dns_strategy]=ipv6_only
      [rejected_ip_family]=ipv4
    )
    route_context_set_ports route_context cross
    render_subscription_route route_context
    route_context=(
      [profile]=v6-to-v4
      [server]="$SUBSCRIPTION_IPV6_ADDRESS"
      [ingress_family]=ipv6
      [egress_family]=ipv4
      [dns_mode]="$v4_dns_mode"
      [dns_server]="$v4_dns_server"
      [dns_strategy]=ipv4_only
      [rejected_ip_family]=ipv6
    )
    route_context_set_ports route_context cross
    render_subscription_route route_context
  fi
}
