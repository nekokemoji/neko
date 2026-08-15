#!/usr/bin/env bash

# Validated route context model shared by strict subscription renderers. Loaded
# through lib/render.sh.

route_context_fail() {
  printf '线路上下文无效：%s\n' "$*" >&2
  return 64
}

# A route context is a validated associative array. Callers declare routing and
# DNS intent by name; this file alone expands the selected normal/cross ports.
route_context_is_associative() {
  local context_name="${1:-}" declaration
  [[ "$context_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
  declaration="$(declare -p "$context_name" 2>/dev/null)" || return 1
  [[ "$declaration" == 'declare -A '* ]]
}

route_context_port_is_valid() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

route_context_set_ports() {
  local context_name="${1:-}" port_set="${2:-}"
  route_context_is_associative "$context_name" \
    || route_context_fail "必须传入关联数组。" || return
  local -n route_ports_ref="$context_name"

  case "$port_set" in
    normal)
      route_ports_ref["hy2_start"]="$HY2_START"
      route_ports_ref["hy2_end"]="$HY2_END"
      route_ports_ref["tuic_port"]="$TUIC_PORT"
      route_ports_ref["ss_port"]="$SS_PORT"
      route_ports_ref["anytls_port"]="$ANYTLS_PORT"
      route_ports_ref["trojan_port"]="$TROJAN_PORT"
      route_ports_ref["vision_port"]="$VISION_PORT"
      route_ports_ref["xhttp_port"]="$XHTTP_PORT"
      route_ports_ref["anyreality_port"]="${ANYREALITY_PORT:-}"
      ;;
    cross)
      route_ports_ref["hy2_start"]="$CROSS_HY2_START"
      route_ports_ref["hy2_end"]="$CROSS_HY2_END"
      route_ports_ref["tuic_port"]="$CROSS_TUIC_PORT"
      route_ports_ref["ss_port"]="$CROSS_SS_PORT"
      route_ports_ref["anytls_port"]="$CROSS_ANYTLS_PORT"
      route_ports_ref["trojan_port"]="$CROSS_TROJAN_PORT"
      route_ports_ref["vision_port"]="$CROSS_VISION_PORT"
      route_ports_ref["xhttp_port"]="$CROSS_XHTTP_PORT"
      route_ports_ref["anyreality_port"]="${CROSS_ANYREALITY_PORT:-}"
      ;;
    *) route_context_fail "端口集必须是 normal 或 cross。" || return ;;
  esac
  route_ports_ref["port_set"]="$port_set"
  route_ports_ref["anyreality_enabled"]="$ANYREALITY_ENABLED"
}

route_context_validate() {
  local context_name="${1:-}" field key expected_ingress expected_egress
  local expected_rejected expected_port_set expected_dns_strategy
  local -a required_fields=(
    profile server ingress_family egress_family
    dns_mode dns_server dns_strategy rejected_ip_family port_set
    hy2_start hy2_end tuic_port ss_port anytls_port trojan_port
    vision_port xhttp_port anyreality_enabled anyreality_port
  )
  local -A allowed_fields=()

  route_context_is_associative "$context_name" \
    || route_context_fail "必须传入关联数组。" || return
  local -n route_validate_ref="$context_name"

  for field in "${required_fields[@]}"; do
    allowed_fields[$field]=1
    [[ -n "${route_validate_ref[$field]+present}" ]] \
      || route_context_fail "缺少字段 ${field}。" || return
  done
  for key in "${!route_validate_ref[@]}"; do
    [[ -n "${allowed_fields[$key]+allowed}" ]] \
      || route_context_fail "未知字段 ${key}。" || return
  done

  case "${route_validate_ref[profile]}" in
    v4)
      expected_ingress=ipv4
      expected_egress=ipv4
      expected_port_set=normal
      ;;
    v6)
      expected_ingress=ipv6
      expected_egress=ipv6
      expected_port_set=normal
      ;;
    v4-to-v6)
      expected_ingress=ipv4
      expected_egress=ipv6
      expected_port_set=cross
      ;;
    v6-to-v4)
      expected_ingress=ipv6
      expected_egress=ipv4
      expected_port_set=cross
      ;;
    *) route_context_fail "未知线路 ${route_validate_ref[profile]}。" || return ;;
  esac
  [[ "${route_validate_ref[ingress_family]}" == "$expected_ingress" ]] \
    || route_context_fail "${route_validate_ref[profile]} 的入站地址族不一致。" || return
  [[ "${route_validate_ref[egress_family]}" == "$expected_egress" ]] \
    || route_context_fail "${route_validate_ref[profile]} 的出站地址族不一致。" || return
  [[ "${route_validate_ref[port_set]}" == "$expected_port_set" ]] \
    || route_context_fail "${route_validate_ref[profile]} 的端口集不一致。" || return

  case "$expected_ingress" in
    ipv4) is_ipv4_literal "${route_validate_ref[server]}" ;;
    ipv6) is_ipv6_literal "${route_validate_ref[server]}" ;;
  esac || route_context_fail "server 与入站地址族不一致。" || return

  case "$expected_egress" in
    ipv4)
      expected_rejected=ipv6
      expected_dns_strategy=ipv4_only
      ;;
    ipv6)
      expected_rejected=ipv4
      expected_dns_strategy=ipv6_only
      ;;
  esac
  [[ "${route_validate_ref[rejected_ip_family]}" == "$expected_rejected" ]] \
    || route_context_fail "拒绝地址族与出站方向不一致。" || return
  [[ "${route_validate_ref[dns_strategy]}" == "$expected_dns_strategy" ]] \
    || route_context_fail "DNS 策略与出站方向不一致。" || return
  case "${route_validate_ref[dns_mode]}" in
    public)
      case "$expected_egress" in
        ipv4) is_ipv4_literal "${route_validate_ref[dns_server]}" ;;
        ipv6) is_ipv6_literal "${route_validate_ref[dns_server]}" ;;
      esac || route_context_fail "公共 DNS 与出站地址族不一致。" || return
      ;;
    akdns)
      [[ "$expected_egress" == ipv4 ]] \
        && is_ipv4_literal "${route_validate_ref[dns_server]}" \
        || route_context_fail "AKDNS 只接受 IPv4 出站解析地址。" || return
      ;;
    *) route_context_fail "DNS 模式必须是 public 或 akdns。" || return ;;
  esac

  for field in \
    hy2_start hy2_end tuic_port ss_port anytls_port trojan_port \
    vision_port xhttp_port; do
    route_context_port_is_valid "${route_validate_ref[$field]}" \
      || route_context_fail "${field} 不是有效端口。" || return
  done
  (( 10#${route_validate_ref[hy2_start]} <= 10#${route_validate_ref[hy2_end]} )) \
    || route_context_fail "Hysteria2 端口范围倒置。" || return
  case "${route_validate_ref[anyreality_enabled]}" in
    true)
      route_context_port_is_valid "${route_validate_ref[anyreality_port]}" \
        || route_context_fail "AnyReality 已启用但端口无效。" || return
      ;;
    false)
      [[ -z "${route_validate_ref[anyreality_port]}" ]] \
        || route_context_fail "AnyReality 已禁用但仍提供端口。" || return
      ;;
    *) route_context_fail "AnyReality 能力必须是 true 或 false。" || return ;;
  esac
}
