#!/usr/bin/env bash

# Network-mode, DNS, address, kernel, and proxy-port contracts. Loaded through
# lib/common.sh.

NETWORK_MODE_IPV4="ipv4-only"
NETWORK_MODE_IPV6="ipv6-only"
NETWORK_MODE_DUAL="dual"

normalize_network_mode() {
  case "${1,,}" in
    4|ipv4|ipv4-only|v4)
      printf '%s' "$NETWORK_MODE_IPV4"
      ;;
    6|ipv6|ipv6-only|v6)
      printf '%s' "$NETWORK_MODE_IPV6"
      ;;
    both|dual|dual-stack)
      printf '%s' "$NETWORK_MODE_DUAL"
      ;;
    *)
      return 1
      ;;
  esac
}

network_mode_has_ipv4() {
  case "${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" in
    "$NETWORK_MODE_IPV4"|"$NETWORK_MODE_DUAL") return 0 ;;
    *) return 1 ;;
  esac
}

network_mode_has_ipv6() {
  case "${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" in
    "$NETWORK_MODE_IPV6"|"$NETWORK_MODE_DUAL") return 0 ;;
    *) return 1 ;;
  esac
}

network_mode_has_cross_routes() {
  [[ "${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" == "$NETWORK_MODE_DUAL" ]]
}

network_mode_label() {
  case "${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" in
    "$NETWORK_MODE_IPV4") printf '仅 IPv4' ;;
    "$NETWORK_MODE_IPV6") printf '仅 IPv6' ;;
    "$NETWORK_MODE_DUAL") printf 'IPv4 + IPv6 双栈' ;;
    *) return 1 ;;
  esac
}

network_mode_link_count() {
  if network_mode_has_cross_routes "${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}"; then
    printf '16'
  else
    printf '4'
  fi
}

absolute_dns_name() {
  local name="${1%.}"
  printf '%s.\n' "$name"
}

managed_akdns_resolver() {
  local status_file="${NEKO_VAR}/akdns/status"
  local resolv_file="${NEKO_RESOLV_CONF:-/etc/resolv.conf}"
  local resolver="" status_count nameserver_count

  [[ -f "$status_file" && ! -L "$status_file" \
    && -f "$resolv_file" && ! -L "$resolv_file" ]] || return 1
  status_count="$(awk -F= '$1 == "resolver" {count++; value=$2} END {
    if (count == 1) print count " " value
  }' "$status_file")"
  [[ "$status_count" == "1 "* ]] || return 1
  resolver="${status_count#1 }"
  is_ipv4_literal "$resolver" || return 1
  case "$resolver" in
    66.66.66.66|45.207.157.146|108.160.138.51|139.180.133.239|\
    45.76.83.113|45.76.71.83|45.63.99.176|166.0.199.207) ;;
    *) return 1 ;;
  esac

  nameserver_count="$(awk -v wanted="$resolver" '
    $1 == "nameserver" {count++; if ($2 == wanted) matched++}
    END {print count + 0, matched + 0}
  ' "$resolv_file")"
  [[ "$nameserver_count" == "1 1" ]] || return 1
  printf '%s\n' "$resolver"
}

strict_dns_resolver() {
  local resolver="${NEKO_STRICT_DNS_SERVER:-}"
  if [[ -n "$resolver" ]]; then
    is_safe_ip_literal "$resolver" || return 1
    printf '%s\n' "$resolver"
    return 0
  fi
  # Smart DNS resolvers can intentionally synthesize, suppress, or filter
  # records.  Once Neko has positively identified its managed AKDNS state,
  # strict endpoint ownership must therefore be checked through a neutral
  # public resolver instead of the modified system resolver.
  managed_akdns_resolver >/dev/null 2>&1 || return 1
  printf '1.1.1.1\n'
}

dns_records() {
  local record_type="${1^^}" query_name output status resolver=""
  local -a resolver_argument=()
  query_name="$(absolute_dns_name "$2")"
  case "$record_type" in
    A|AAAA) ;;
    *) die "不支持的 DNS 记录类型：${record_type}" ;;
  esac

  if [[ -n "${NEKO_STRICT_DNS_SERVER:-}" ]]; then
    resolver="$(strict_dns_resolver)" \
      || die "严格 DNS 解析器地址无效：${NEKO_STRICT_DNS_SERVER}"
  else
    resolver="$(strict_dns_resolver 2>/dev/null || true)"
  fi
  [[ -z "$resolver" ]] || resolver_argument=("@${resolver}")
  if ! output="$(dig "${resolver_argument[@]}" \
    +time=4 +tries=2 +noall +answer +comments \
    "$query_name" "$record_type" 2>&1)"; then
    die "DNS 查询失败：${query_name} ${record_type}。请检查 VPS 的 DNS 与网络后重试。"
  fi
  status="$(
    sed -nE 's/^;; ->>HEADER<<- opcode: [A-Z]+, status: ([A-Z]+),.*/\1/p' \
      <<< "$output" | awk 'NR == 1 {print}'
  )"
  case "$status" in
    NOERROR|NXDOMAIN) ;;
    "")
      die "无法解析 DNS 查询结果：${query_name} ${record_type}。"
      ;;
    *)
      die "DNS 查询返回 ${status}：${query_name} ${record_type}。请稍后重试。"
      ;;
  esac

  # Only accept an RR owned by the queried name itself.  A CNAME followed by
  # an address for its target is not a direct A/AAAA record and must not pass
  # the strict endpoint check.
  awk -v wanted="$record_type" -v owner="${query_name,,}" \
    'tolower($1) == owner && $4 == wanted {print $5}' <<< "$output"
}

resolved_addresses() {
  {
    resolved_ipv4_addresses "$1"
    resolved_ipv6_addresses "$1"
  } | sort -u
}

resolved_ipv4_addresses() {
  local address records
  records="$(dns_records A "$1")"
  while IFS= read -r address; do
    if is_ipv4_literal "$address"; then
      printf '%s\n' "$address"
    fi
  done <<< "$records" | sort -u
}

resolved_ipv6_addresses() {
  local address records
  records="$(dns_records AAAA "$1")"
  while IFS= read -r address; do
    address="${address,,}"
    if is_ipv6_literal "$address"; then
      printf '%s\n' "$address"
    fi
  done <<< "$records" | sort -u
}

first_resolved_ipv4() {
  # Consume the complete stream.  Exiting awk early can make sort receive
  # SIGPIPE and turn a successful lookup into a failure under pipefail.
  resolved_ipv4_addresses "$1" \
    | awk 'NR == 1 {value=$0} END {if (NR > 0) print value}'
}

first_resolved_ipv6() {
  resolved_ipv6_addresses "$1" \
    | awk 'NR == 1 {value=$0} END {if (NR > 0) print value}'
}

is_ipv4_literal() {
  local value="$1" octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a _ip_octets <<< "$value"
  for octet in "${_ip_octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

is_ipv6_literal() {
  local value="$1" left right hextet
  local -a hextets=()
  local -i count=0

  # Validate the literal itself.  getent ahostsv6 applies AI_ADDRCONFIG on
  # several libc implementations and can reject valid IPv6 syntax whenever
  # the current network namespace has no configured IPv6 address.
  [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "$value" != *:::* ]] || return 1
  [[ "$value" != :* || "$value" == ::* ]] || return 1
  [[ "$value" != *: || "$value" == *:: ]] || return 1

  if [[ "$value" == *::* ]]; then
    left="${value%%::*}"
    right="${value#*::}"
    # Only one compression marker is permitted.
    [[ "$right" != *::* ]] || return 1

    if [[ -n "$left" ]]; then
      IFS=':' read -r -a hextets <<< "$left"
      for hextet in "${hextets[@]}"; do
        [[ "$hextet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      done
      ((count += ${#hextets[@]}))
    fi

    hextets=()
    if [[ -n "$right" ]]; then
      IFS=':' read -r -a hextets <<< "$right"
      for hextet in "${hextets[@]}"; do
        [[ "$hextet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      done
      ((count += ${#hextets[@]}))
    fi

    # "::" must replace at least one of the eight 16-bit groups.
    ((count < 8))
    return
  fi

  IFS=':' read -r -a hextets <<< "$value"
  ((${#hextets[@]} == 8)) || return 1
  for hextet in "${hextets[@]}"; do
    [[ "$hextet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done
}

is_safe_ip_literal() {
  is_ipv4_literal "$1" || is_ipv6_literal "$1"
}

check_domain_resolution() {
  local domain="$1" addresses
  addresses="$(resolved_addresses "$domain")"
  [[ -n "$addresses" ]] || die "域名 ${domain} 没有可用的 A/AAAA 解析；安装不会继续。"
  info "${domain} 当前解析为："
  while IFS= read -r address; do
    printf '  - %s\n' "$address"
  done <<< "$addresses"
  warn "请确认这些是本机直连地址，未开启 CDN/代理；安装还会执行所选的 ACME 域名验证。"
}

derive_subscription_domains() {
  local domain="$1"
  SUBSCRIPTION_DOMAIN_IPV4="v4.${domain}"
  SUBSCRIPTION_DOMAIN_IPV6="v6.${domain}"
  validate_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
    || die "派生的 IPv4 订阅域名无效：${SUBSCRIPTION_DOMAIN_IPV4}"
  validate_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
    || die "派生的 IPv6 订阅域名无效：${SUBSCRIPTION_DOMAIN_IPV6}"
}

check_strict_stack_dns() {
  local domain="$1" requested_mode="${2:-${NETWORK_MODE:-}}"
  local base_v4 base_v6 v4_addresses="" v6_addresses="" v4_wrong="" v6_wrong=""
  local v4_count v6_count
  requested_mode="$(normalize_network_mode "$requested_mode")" \
    || die "不支持的网络安装模式：${requested_mode:-empty}"
  derive_subscription_domains "$domain"

  SUBSCRIPTION_IPV4_ADDRESS=""
  SUBSCRIPTION_IPV6_ADDRESS=""
  if network_mode_has_ipv4 "$requested_mode"; then
    v4_addresses="$(resolved_ipv4_addresses "$SUBSCRIPTION_DOMAIN_IPV4")"
    v4_wrong="$(first_resolved_ipv6 "$SUBSCRIPTION_DOMAIN_IPV4")"
  fi
  if network_mode_has_ipv6 "$requested_mode"; then
    v6_addresses="$(resolved_ipv6_addresses "$SUBSCRIPTION_DOMAIN_IPV6")"
    v6_wrong="$(first_resolved_ipv4 "$SUBSCRIPTION_DOMAIN_IPV6")"
  fi
  v4_count="$(awk 'NF {count++} END {print count + 0}' <<< "$v4_addresses")"
  v6_count="$(awk 'NF {count++} END {print count + 0}' <<< "$v6_addresses")"
  SUBSCRIPTION_IPV4_ADDRESS="$(awk 'NF {value=$0} END {if (value != "") print value}' <<< "$v4_addresses")"
  SUBSCRIPTION_IPV6_ADDRESS="$(awk 'NF {value=$0} END {if (value != "") print value}' <<< "$v6_addresses")"

  base_v4="$(resolved_ipv4_addresses "$domain")"
  base_v6="$(resolved_ipv6_addresses "$domain")"

  if network_mode_has_ipv4 "$requested_mode"; then
    (( v4_count == 1 )) || die \
      "${SUBSCRIPTION_DOMAIN_IPV4} 必须且只能配置 1 条直连 VPS 的 A 记录；当前检测到 ${v4_count} 条。"
    [[ -z "$v4_wrong" ]] || die \
      "${SUBSCRIPTION_DOMAIN_IPV4} 检测到 AAAA（${v4_wrong}）；严格 IPv4 域名不能有 AAAA，请关闭 Cloudflare 橙云并删除该记录。"
    [[ "$base_v4" == "$v4_addresses" ]] || die \
      "基础域名 ${domain} 必须且只能使用与 ${SUBSCRIPTION_DOMAIN_IPV4} 相同的 A 记录。"
  else
    [[ -z "$base_v4" ]] || die \
      "当前选择仅 IPv6，但基础域名 ${domain} 仍有 A 记录；请删除 A 后重试。"
  fi

  if network_mode_has_ipv6 "$requested_mode"; then
    (( v6_count == 1 )) || die \
      "${SUBSCRIPTION_DOMAIN_IPV6} 必须且只能配置 1 条直连 VPS 的 AAAA 记录；当前检测到 ${v6_count} 条。"
    [[ -z "$v6_wrong" ]] || die \
      "${SUBSCRIPTION_DOMAIN_IPV6} 检测到 A（${v6_wrong}）；严格 IPv6 域名不能有 A，请关闭 Cloudflare 橙云并删除该记录。"
    [[ "${base_v6,,}" == "${v6_addresses,,}" ]] || die \
      "基础域名 ${domain} 必须且只能使用与 ${SUBSCRIPTION_DOMAIN_IPV6} 相同的 AAAA 记录。"
  else
    [[ -z "$base_v6" ]] || die \
      "当前选择仅 IPv4，但基础域名 ${domain} 仍有 AAAA 记录；请删除 AAAA 后重试。"
  fi

  info "严格 $(network_mode_label "$requested_mode") DNS 检查通过："
  if network_mode_has_ipv4 "$requested_mode"; then
    printf '  - IPv4：%s -> %s\n' \
      "$SUBSCRIPTION_DOMAIN_IPV4" "$SUBSCRIPTION_IPV4_ADDRESS"
  fi
  if network_mode_has_ipv6 "$requested_mode"; then
    printf '  - IPv6：%s -> %s\n' \
      "$SUBSCRIPTION_DOMAIN_IPV6" "$SUBSCRIPTION_IPV6_ADDRESS"
  fi
  warn "基础域名和已启用的订阅域名必须保持 DNS only（灰云）；安装还会执行所选的 ACME 域名验证。"
}

check_strict_dual_stack_dns() {
  check_strict_stack_dns "$1" "$NETWORK_MODE_DUAL"
}

assert_network_mode_kernel() {
  local requested_mode="${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}"
  local disable_ipv6 ipv4_default_routes ipv6_default_routes
  requested_mode="$(normalize_network_mode "$requested_mode")" \
    || die "不支持的网络安装模式：${requested_mode:-empty}"
  if network_mode_has_ipv4 "$requested_mode"; then
    ipv4_default_routes="$(ip -4 route show default 2>/dev/null || true)"
    [[ -n "$ipv4_default_routes" ]] \
      || die "系统没有 IPv4 默认路由，无法提供严格 IPv4 订阅。"
  fi
  if network_mode_has_ipv6 "$requested_mode"; then
    disable_ipv6="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf 1)"
    [[ "$disable_ipv6" == "0" ]] \
      || die "系统内核已禁用 IPv6，无法提供严格 IPv6 订阅。"
    ipv6_default_routes="$(ip -6 route show default 2>/dev/null || true)"
    [[ -n "$ipv6_default_routes" ]] \
      || die "系统没有 IPv6 默认路由，无法提供严格 IPv6 订阅。"
  fi
}

assert_dual_stack_kernel() {
  assert_network_mode_kernel "$NETWORK_MODE_DUAL"
}

assert_strict_addresses_local() {
  local requested_mode="${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" route_v4 route_v6
  requested_mode="$(normalize_network_mode "$requested_mode")" \
    || die "不支持的网络安装模式：${requested_mode:-empty}"
  if network_mode_has_ipv4 "$requested_mode"; then
    route_v4="$(ip -4 route get "$SUBSCRIPTION_IPV4_ADDRESS" 2>/dev/null || true)"
    [[ "$(awk 'NR == 1 {print $1}' <<< "$route_v4")" == "local" ]] || die \
      "${SUBSCRIPTION_IPV4_ADDRESS} 不是本机网卡地址；无法把 IPv4 入站和出站严格绑定到它。"
  fi
  if network_mode_has_ipv6 "$requested_mode"; then
    route_v6="$(ip -6 route get "$SUBSCRIPTION_IPV6_ADDRESS" 2>/dev/null || true)"
    [[ "$(awk 'NR == 1 {print $1}' <<< "$route_v6")" == "local" ]] || die \
      "${SUBSCRIPTION_IPV6_ADDRESS} 不是本机网卡地址；无法把 IPv6 入站和出站严格绑定到它。"
  fi
}

declare -Ag NEKO_RESERVED_PORTS=()

collect_listening_ports() {
  { ss -H -lntu 2>/dev/null || true; } \
    | awk '{print $5}' \
    | sed -nE 's/.*:([0-9]+)$/\1/p' \
    | sort -nu
}

initialize_port_reservations() {
  local port listening_ports
  NEKO_RESERVED_PORTS=([80]=1 [443]=1 [8443]=1)
  listening_ports="$(collect_listening_ports)"
  while IFS= read -r port; do
    [[ -n "$port" ]] && NEKO_RESERVED_PORTS["$port"]=1
  done <<< "$listening_ports"
  return 0
}

reserve_loaded_proxy_ports() {
  local reserved_mode="${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" port
  for ((port = HY2_START; port <= HY2_END; port++)); do
    NEKO_RESERVED_PORTS["$port"]=1
  done
  for port in \
    "$TUIC_PORT" "$SS_PORT" "$ANYTLS_PORT" "$TROJAN_PORT" "$VISION_PORT" "$XHTTP_PORT"; do
    NEKO_RESERVED_PORTS["$port"]=1
  done
  if network_mode_has_cross_routes "$reserved_mode"; then
    for ((port = CROSS_HY2_START; port <= CROSS_HY2_END; port++)); do
      NEKO_RESERVED_PORTS["$port"]=1
    done
    for port in \
      "$CROSS_TUIC_PORT" "$CROSS_SS_PORT" "$CROSS_ANYTLS_PORT" \
      "$CROSS_TROJAN_PORT" "$CROSS_VISION_PORT" "$CROSS_XHTTP_PORT"; do
      NEKO_RESERVED_PORTS["$port"]=1
    done
  fi
  if [[ "${ANYREALITY_ENABLED:-false}" == "true" ]]; then
    NEKO_RESERVED_PORTS["$ANYREALITY_PORT"]=1
    if network_mode_has_cross_routes "$reserved_mode"; then
      NEKO_RESERVED_PORTS["$CROSS_ANYREALITY_PORT"]=1
    fi
  fi
}

reserve_random_port() {
  local result_variable="$1" candidate attempts=0
  [[ "$result_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "无效的端口变量名。"
  while (( attempts++ < 5000 )); do
    candidate="$(random_number 10000 60000)"
    if [[ -z "${NEKO_RESERVED_PORTS[$candidate]+x}" ]]; then
      NEKO_RESERVED_PORTS["$candidate"]=1
      printf -v "$result_variable" '%s' "$candidate"
      return 0
    fi
  done
  die "无法找到空闲随机端口。"
}

reserve_random_range() {
  local width="$1" start_variable="$2" end_variable="$3"
  local start end port attempts=0 conflict
  [[ "$start_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "无效的端口变量名。"
  [[ "$end_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "无效的端口变量名。"
  while (( attempts++ < 5000 )); do
    start="$(random_number 10000 "$((60000 - width + 1))")"
    end="$((start + width - 1))"
    conflict=0
    for ((port = start; port <= end; port++)); do
      if [[ -n "${NEKO_RESERVED_PORTS[$port]+x}" ]]; then
        conflict=1
        break
      fi
    done
    if (( conflict == 0 )); then
      for ((port = start; port <= end; port++)); do
        NEKO_RESERVED_PORTS["$port"]=1
      done
      printf -v "$start_variable" '%s' "$start"
      printf -v "$end_variable" '%s' "$end"
      return 0
    fi
  done
  die "无法找到连续的空闲随机端口范围。"
}

assert_public_ports_free() {
  local port listeners
  for port in 80 443; do
    listeners="$(ss -H -ltn "sport = :${port}" 2>/dev/null || true)"
    if [[ -n "$listeners" ]]; then
      die "TCP ${port} 已被占用。为避免破坏现有网站，安装不会继续。"
    fi
  done
  listeners="$(ss -H -ltn "sport = :8443" 2>/dev/null || true)"
  if [[ -n "$listeners" ]]; then
    die "TCP 8443 已被占用；它被保留给本机 REALITY 证书回落站点。"
  fi
}

validate_proxy_port_layout() {
  local index label port start end
  local -a range_labels=("Hysteria2")
  local -a range_starts=("$HY2_START")
  local -a range_ends=("$HY2_END")
  local -a port_labels=("TUIC" "SS2022" "AnyTLS" "Trojan" "VLESS Vision" "VLESS XHTTP")
  local -a port_values=(
    "$TUIC_PORT" "$SS_PORT" "$ANYTLS_PORT" "$TROJAN_PORT" "$VISION_PORT" "$XHTTP_PORT"
  )
  local -A seen_ports=()

  if network_mode_has_cross_routes; then
    range_labels+=("跨族 Hysteria2")
    range_starts+=("$CROSS_HY2_START")
    range_ends+=("$CROSS_HY2_END")
    port_labels+=(
      "跨族 TUIC" "跨族 SS2022" "跨族 AnyTLS" "跨族 Trojan"
      "跨族 VLESS Vision" "跨族 VLESS XHTTP"
    )
    port_values+=(
      "$CROSS_TUIC_PORT" "$CROSS_SS_PORT" "$CROSS_ANYTLS_PORT"
      "$CROSS_TROJAN_PORT" "$CROSS_VISION_PORT" "$CROSS_XHTTP_PORT"
    )
  fi

  if [[ "${ANYREALITY_ENABLED:-false}" == "true" ]]; then
    port_labels+=("AnyReality")
    port_values+=("$ANYREALITY_PORT")
    if network_mode_has_cross_routes; then
      port_labels+=("跨族 AnyReality")
      port_values+=("$CROSS_ANYREALITY_PORT")
    fi
  fi

  for index in "${!range_labels[@]}"; do
    label="${range_labels[$index]}"
    start="${range_starts[$index]}"
    end="${range_ends[$index]}"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] \
      || die "state.json 中的 ${label} 端口范围格式无效。"
    (( start >= 10000 && end <= 60000 && end - start == 127 )) \
      || die "state.json 中的 ${label} 端口范围无效；必须是 10000-60000 内连续 128 个端口。"
    for ((port = start; port <= end; port++)); do
      [[ -z "${seen_ports[$port]+x}" ]] \
        || die "state.json 中的代理端口 ${port} 重复。"
      seen_ports["$port"]="$label"
    done
  done

  for index in "${!port_labels[@]}"; do
    label="${port_labels[$index]}"
    port="${port_values[$index]}"
    [[ "$port" =~ ^[0-9]+$ ]] \
      || die "state.json 中的 ${label} 端口格式无效。"
    (( port >= 10000 && port <= 60000 )) \
      || die "state.json 中的 ${label} 端口不在 10000-60000。"
    [[ -z "${seen_ports[$port]+x}" ]] \
      || die "state.json 中的 ${label} 端口 ${port} 与 ${seen_ports[$port]} 冲突。"
    seen_ports["$port"]="$label"
  done
}
