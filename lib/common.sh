#!/usr/bin/env bash

# Shared helpers for the installer and the installed terminal panel.

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
CLOUDFLARE_DNS_TOKEN_FILE="${NEKO_VAR}/credentials/cloudflare-dns-api-token"

ACME_METHOD_HTTP="http-01"
ACME_METHOD_CLOUDFLARE="cloudflare-dns-01"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BLUE=$'\033[1;34m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
  C_RESET=$'\033[0m'
else
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_root() {
  (( EUID == 0 )) || die "请使用 root 运行。"
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：${command_name}"
  done
}

detect_platform() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  [[ -r "$os_release_file" ]] || die "无法读取 ${os_release_file}。"

  local id version_id
  id="$(. "$os_release_file"; printf '%s' "${ID:-}")"
  version_id="$(. "$os_release_file"; printf '%s' "${VERSION_ID:-}")"
  id="${id,,}"

  case "$id:$version_id" in
    debian:12|debian:13)
      OS_FAMILY="debian"
      ;;
    ubuntu:24.04|ubuntu:26.04)
      OS_FAMILY="debian"
      ;;
    rocky:9|rocky:9.*|rocky:10|rocky:10.*|almalinux:9|almalinux:9.*|almalinux:10|almalinux:10.*)
      OS_FAMILY="rhel"
      ;;
    *)
      die "不支持的系统：${id:-unknown} ${version_id:-unknown}。支持 Debian 12/13、Ubuntu 24.04/26.04、Rocky Linux 9/10、AlmaLinux 9/10。"
      ;;
  esac

  OS_ID="$id"
  OS_VERSION="$version_id"

  case "${ARCH_OVERRIDE:-$(uname -m)}" in
    x86_64|amd64)
      ARCH="amd64"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      ;;
    *)
      die "不支持的 CPU 架构：$(uname -m)。仅支持 amd64 与 arm64。"
      ;;
  esac

  export OS_ID OS_VERSION OS_FAMILY ARCH
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "系统缺少 systemd。"
  if [[ "${NEKO_TEST_MODE:-0}" != "1" ]]; then
    local pid1_comm=""
    [[ -r /proc/1/comm ]] && IFS= read -r pid1_comm < /proc/1/comm
    [[ "$pid1_comm" == "systemd" ]] || die "PID 1 不是 systemd；请在完整系统而非普通容器中安装。"
  fi
}

install_dependencies() {
  info "安装基础依赖……"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl jq openssl tar unzip iproute2 procps \
      nftables util-linux passwd kmod findutils
  else
    local rhel_package_manager
    if command -v dnf >/dev/null 2>&1; then
      rhel_package_manager=dnf
    elif command -v microdnf >/dev/null 2>&1; then
      rhel_package_manager=microdnf
    else
      die "找不到 dnf 或 microdnf。"
    fi
    "$rhel_package_manager" -y install \
      ca-certificates curl jq openssl tar unzip iproute procps-ng \
      nftables util-linux shadow-utils kmod findutils
  fi
}

validate_domain() {
  local domain="${1,,}"
  [[ -n "$domain" ]] || return 1
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. ]] || return 1
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] || return 1
  # An IPv4 literal such as 1.2.3.4 is not a bound domain name.
  [[ "${domain##*.}" =~ [a-z] ]] || return 1

  local label
  IFS='.' read -r -a _domain_labels <<< "$domain"
  for label in "${_domain_labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

normalize_acme_method() {
  case "${1,,}" in
    http|http-01)
      printf '%s' "$ACME_METHOD_HTTP"
      ;;
    cloudflare|dns|dns-01|cloudflare-dns|cloudflare-dns-01)
      printf '%s' "$ACME_METHOD_CLOUDFLARE"
      ;;
    *)
      return 1
      ;;
  esac
}

validate_cloudflare_dns_token() {
  local token="$1"
  [[ ${#token} -ge 20 && ${#token} -le 256 ]] || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]]
}

write_cloudflare_dns_token() {
  local token="$1" credentials_dir tmp
  validate_cloudflare_dns_token "$token" \
    || die "Cloudflare API Token 格式无效；应为 20 到 256 位且只包含字母、数字、下划线或连字符。"

  credentials_dir="$(dirname -- "$CLOUDFLARE_DNS_TOKEN_FILE")"
  install -d -m 0700 "$credentials_dir"
  tmp="$(mktemp "${credentials_dir}/.cloudflare-dns-token.XXXXXX")"
  printf '%s\n' "$token" > "$tmp"
  chmod 0600 "$tmp"
  if (( EUID == 0 )); then
    chown root:root "$credentials_dir" "$tmp"
  fi
  mv -f -- "$tmp" "$CLOUDFLARE_DNS_TOKEN_FILE"
}

assert_cloudflare_dns_token_file() {
  local credentials_dir token owner_uid mode dir_owner_uid dir_mode expected_uid
  credentials_dir="$(dirname -- "$CLOUDFLARE_DNS_TOKEN_FILE")"
  [[ -d "$credentials_dir" && ! -L "$credentials_dir" ]] \
    || die "Cloudflare 凭据目录缺失或不安全：${credentials_dir}"
  [[ -f "$CLOUDFLARE_DNS_TOKEN_FILE" && ! -L "$CLOUDFLARE_DNS_TOKEN_FILE" \
    && -r "$CLOUDFLARE_DNS_TOKEN_FILE" ]] \
    || die "Cloudflare DNS API Token 文件缺失或不安全：${CLOUDFLARE_DNS_TOKEN_FILE}"

  dir_owner_uid="$(stat -c '%u' "$credentials_dir")"
  dir_mode="$(stat -c '%a' "$credentials_dir")"
  owner_uid="$(stat -c '%u' "$CLOUDFLARE_DNS_TOKEN_FILE")"
  mode="$(stat -c '%a' "$CLOUDFLARE_DNS_TOKEN_FILE")"
  if [[ "${NEKO_TEST_MODE:-0}" == "1" || "${NEKO_UPDATE_TEST_MODE:-0}" == "1" ]]; then
    expected_uid="$(id -u)"
  else
    expected_uid=0
  fi
  [[ "$dir_owner_uid" == "$expected_uid" && "$dir_mode" == "700" ]] \
    || die "Cloudflare 凭据目录必须由 root 持有且权限为 0700。"
  [[ "$owner_uid" == "$expected_uid" && "$mode" == "600" ]] \
    || die "Cloudflare DNS API Token 必须由 root 持有且权限为 0600。"

  token="$(<"$CLOUDFLARE_DNS_TOKEN_FILE")"
  validate_cloudflare_dns_token "$token" \
    || die "Cloudflare DNS API Token 文件内容无效。"
}

run_lego_acme() {
  local lego_binary="$1" http_mode="$2"
  shift 2
  [[ -x "$lego_binary" ]] || die "lego 不可执行：${lego_binary}"

  case "${ACME_METHOD:-$ACME_METHOD_HTTP}" in
    "$ACME_METHOD_HTTP")
      case "$http_mode" in
        standalone)
          "$lego_binary" "$@" --http
          ;;
        webroot)
          "$lego_binary" "$@" --http --http.webroot "$NEKO_VAR/acme"
          ;;
        *)
          die "未知的 HTTP-01 运行模式：${http_mode}"
          ;;
      esac
      ;;
    "$ACME_METHOD_CLOUDFLARE")
      assert_cloudflare_dns_token_file
      env \
        -u CF_API_EMAIL \
        -u CF_API_KEY \
        -u CF_DNS_API_TOKEN \
        -u CF_ZONE_API_TOKEN \
        -u CF_API_EMAIL_FILE \
        -u CF_API_KEY_FILE \
        -u CF_DNS_API_TOKEN_FILE \
        -u CF_ZONE_API_TOKEN_FILE \
        -u CF_BASE_URL \
        -u CF_BASE_URL_FILE \
        -u CLOUDFLARE_API_KEY \
        -u CLOUDFLARE_DNS_API_TOKEN \
        -u CLOUDFLARE_EMAIL \
        -u CLOUDFLARE_ZONE_API_TOKEN \
        -u CLOUDFLARE_BASE_URL \
        -u CLOUDFLARE_API_KEY_FILE \
        -u CLOUDFLARE_DNS_API_TOKEN_FILE \
        -u CLOUDFLARE_EMAIL_FILE \
        -u CLOUDFLARE_ZONE_API_TOKEN_FILE \
        -u CLOUDFLARE_BASE_URL_FILE \
        CF_DNS_API_TOKEN_FILE="$CLOUDFLARE_DNS_TOKEN_FILE" \
        "$lego_binary" "$@" --dns cloudflare
      ;;
    *)
      die "不支持的 ACME 验证方式：${ACME_METHOD:-empty}"
      ;;
  esac
}

resolved_addresses() {
  { getent ahosts "$1" 2>/dev/null || true; } | awk '{print $1}' | sort -u
}

resolved_ipv4_addresses() {
  { getent ahostsv4 "$1" 2>/dev/null || true; } \
    | awk '$1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print $1}' \
    | sort -u
}

resolved_ipv6_addresses() {
  { getent ahostsv6 "$1" 2>/dev/null || true; } \
    | awk '$1 ~ /:/ && $1 ~ /^[0-9A-Fa-f:]+$/ {print tolower($1)}' \
    | sort -u
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
  local parsed
  [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  parsed="$({ getent ahostsv6 "$1" 2>/dev/null || true; } \
    | awk '$1 ~ /:/ && !found {value=$1; found=1} END {if (found) print value}')"
  [[ -n "$parsed" ]]
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

check_strict_dual_stack_dns() {
  local domain="$1" base_v4 base_v6 v4_addresses v6_addresses v4_wrong v6_wrong
  local v4_count v6_count
  derive_subscription_domains "$domain"

  v4_addresses="$(resolved_ipv4_addresses "$SUBSCRIPTION_DOMAIN_IPV4")"
  v6_addresses="$(resolved_ipv6_addresses "$SUBSCRIPTION_DOMAIN_IPV6")"
  v4_count="$(awk 'NF {count++} END {print count + 0}' <<< "$v4_addresses")"
  v6_count="$(awk 'NF {count++} END {print count + 0}' <<< "$v6_addresses")"
  SUBSCRIPTION_IPV4_ADDRESS="$(awk 'NF {value=$0} END {if (value != "") print value}' <<< "$v4_addresses")"
  SUBSCRIPTION_IPV6_ADDRESS="$(awk 'NF {value=$0} END {if (value != "") print value}' <<< "$v6_addresses")"
  v4_wrong="$(first_resolved_ipv6 "$SUBSCRIPTION_DOMAIN_IPV4")"
  v6_wrong="$(first_resolved_ipv4 "$SUBSCRIPTION_DOMAIN_IPV6")"

  (( v4_count == 1 )) || die \
    "${SUBSCRIPTION_DOMAIN_IPV4} 必须且只能配置 1 条直连 VPS 的 A 记录；当前检测到 ${v4_count} 条。"
  [[ -z "$v4_wrong" ]] || die \
    "${SUBSCRIPTION_DOMAIN_IPV4} 检测到 AAAA（${v4_wrong}）；严格 IPv4 域名不能有 AAAA，请关闭 Cloudflare 橙云并删除该记录。"
  (( v6_count == 1 )) || die \
    "${SUBSCRIPTION_DOMAIN_IPV6} 必须且只能配置 1 条直连 VPS 的 AAAA 记录；当前检测到 ${v6_count} 条。"
  [[ -z "$v6_wrong" ]] || die \
    "${SUBSCRIPTION_DOMAIN_IPV6} 检测到 A（${v6_wrong}）；严格 IPv6 域名不能有 A，请关闭 Cloudflare 橙云并删除该记录。"

  base_v4="$(resolved_ipv4_addresses "$domain")"
  base_v6="$(resolved_ipv6_addresses "$domain")"
  [[ "$base_v4" == "$v4_addresses" ]] || die \
    "基础域名 ${domain} 必须且只能使用与 ${SUBSCRIPTION_DOMAIN_IPV4} 相同的 A 记录。"
  [[ "${base_v6,,}" == "${v6_addresses,,}" ]] || die \
    "基础域名 ${domain} 必须且只能使用与 ${SUBSCRIPTION_DOMAIN_IPV6} 相同的 AAAA 记录。"

  info "严格双栈 DNS 检查通过："
  printf '  - IPv4：%s -> %s\n' "$SUBSCRIPTION_DOMAIN_IPV4" "$SUBSCRIPTION_IPV4_ADDRESS"
  printf '  - IPv6：%s -> %s\n' "$SUBSCRIPTION_DOMAIN_IPV6" "$SUBSCRIPTION_IPV6_ADDRESS"
  warn "三个域名都必须保持 Cloudflare DNS only（灰云）；安装还会执行所选的 ACME 域名验证。"
}

assert_dual_stack_kernel() {
  local disable_ipv6 ipv4_default_routes ipv6_default_routes
  disable_ipv6="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf 1)"
  [[ "$disable_ipv6" == "0" ]] || die "系统内核已禁用 IPv6，无法提供严格 IPv6 订阅。"
  ipv4_default_routes="$(ip -4 route show default 2>/dev/null || true)"
  ipv6_default_routes="$(ip -6 route show default 2>/dev/null || true)"
  [[ -n "$ipv4_default_routes" ]] || die "系统没有 IPv4 默认路由，无法提供严格 IPv4 订阅。"
  [[ -n "$ipv6_default_routes" ]] || die "系统没有 IPv6 默认路由，无法提供严格 IPv6 订阅。"
}

assert_strict_addresses_local() {
  local route_v4 route_v6
  route_v4="$(ip -4 route get "$SUBSCRIPTION_IPV4_ADDRESS" 2>/dev/null || true)"
  route_v6="$(ip -6 route get "$SUBSCRIPTION_IPV6_ADDRESS" 2>/dev/null || true)"
  [[ "$(awk 'NR == 1 {print $1}' <<< "$route_v4")" == "local" ]] || die \
    "${SUBSCRIPTION_IPV4_ADDRESS} 不是本机网卡地址；无法把 IPv4 入站和出站严格绑定到它。"
  [[ "$(awk 'NR == 1 {print $1}' <<< "$route_v6")" == "local" ]] || die \
    "${SUBSCRIPTION_IPV6_ADDRESS} 不是本机网卡地址；无法把 IPv6 入站和出站严格绑定到它。"
}

random_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes"
}

random_urlsafe() {
  local bytes="$1"
  openssl rand -base64 "$bytes" | tr -d '\n=' | tr '+/' '-_'
}

random_base64() {
  local bytes="$1"
  openssl rand -base64 "$bytes" | tr -d '\n'
}

new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr 'A-F' 'a-f' < /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-F' 'a-f'
  else
    local hex
    hex="$(random_hex 16)"
    printf '%s-%s-4%s-%x%s-%s\n' \
      "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
      "$(( (16#${hex:16:1} & 3) | 8 ))" "${hex:17:3}" "${hex:20:12}"
  fi
}

random_number() {
  local min="$1" max="$2" value
  value="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
  printf '%d\n' "$(( min + value % (max - min + 1) ))"
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

sha_for_arch() {
  local component="$1" key
  key="${component}_${ARCH^^}_SHA256"
  printf '%s' "${!key:-}"
}

download_verified() {
  local label="$1" url="$2" expected="$3" output="$4"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "${label} 缺少固定 SHA-256。"
  info "下载 ${label}……"
  curl --fail --location --silent --show-error \
    --retry 4 --retry-all-errors --connect-timeout 15 \
    --proto '=https' --tlsv1.2 \
    --output "$output" "$url"
  printf '%s  %s\n' "$expected" "$output" | sha256sum --check --status \
    || die "${label} 的 SHA-256 校验失败。"
}

atomic_json_update() {
  local filter="$1"
  shift
  local tmp
  tmp="$(mktemp "${NEKO_STATE}.tmp.XXXXXX")"
  jq "$@" "$filter" "$NEKO_STATE" > "$tmp"
  chmod 0600 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$NEKO_STATE"
}

state_value() {
  jq -er "$1" "$NEKO_STATE"
}

load_state() {
  local state_schema expected_ipv4_domain expected_ipv6_domain
  [[ -r "$NEKO_STATE" ]] || die "找不到安装状态：${NEKO_STATE}"

  state_schema="$(state_value '.schema')"
  [[ "$state_schema" == "2" ]] \
    || die "安装状态 schema 为 ${state_schema}；请先运行当前版本的升级脚本。"
  DOMAIN="$(state_value '.domain')"
  ACME_EMAIL="$(state_value '.acme_email')"
  validate_domain "$DOMAIN" || die "state.json 中的基础域名无效。"
  validate_email "$ACME_EMAIL" || die "state.json 中的 ACME 邮箱无效。"
  ACME_METHOD="$(jq -r '.acme.method // "http-01"' "$NEKO_STATE")"
  ACME_METHOD="$(normalize_acme_method "$ACME_METHOD")" \
    || die "state.json 中的 ACME 验证方式无效。"
  HY2_START="$(state_value '.ports.hysteria2_start')"
  HY2_END="$(state_value '.ports.hysteria2_end')"
  TUIC_PORT="$(state_value '.ports.tuic')"
  SS_PORT="$(state_value '.ports.ss2022')"
  ANYTLS_PORT="$(state_value '.ports.anytls')"
  VISION_PORT="$(state_value '.ports.vless_reality_vision')"
  XHTTP_PORT="$(state_value '.ports.vless_reality_xhttp')"
  HY2_PASSWORD="$(state_value '.credentials.hysteria2_password')"
  HY2_OBFS_PASSWORD="$(state_value '.credentials.hysteria2_obfs_password')"
  TUIC_UUID="$(state_value '.credentials.tuic_uuid')"
  TUIC_PASSWORD="$(state_value '.credentials.tuic_password')"
  SS_PASSWORD="$(state_value '.credentials.ss2022_password')"
  ANYTLS_PASSWORD="$(state_value '.credentials.anytls_password')"
  VISION_UUID="$(state_value '.credentials.vision_uuid')"
  XHTTP_UUID="$(state_value '.credentials.xhttp_uuid')"
  VISION_PRIVATE_KEY="$(state_value '.reality.vision_private_key')"
  VISION_PUBLIC_KEY="$(state_value '.reality.vision_public_key')"
  VISION_SHORT_ID="$(state_value '.reality.vision_short_id')"
  XHTTP_PRIVATE_KEY="$(state_value '.reality.xhttp_private_key')"
  XHTTP_PUBLIC_KEY="$(state_value '.reality.xhttp_public_key')"
  XHTTP_SHORT_ID="$(state_value '.reality.xhttp_short_id')"
  XHTTP_PATH="$(state_value '.reality.xhttp_path')"
  SUB_TOKEN="$(state_value '.subscription.token')"
  [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
    || die "state.json 中的订阅令牌格式无效。"
  SUBSCRIPTION_DOMAIN_IPV4="$(jq -r '.subscription.ipv4_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_DOMAIN_IPV6="$(jq -r '.subscription.ipv6_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV4_ADDRESS="$(jq -r '.subscription.ipv4_address // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV6_ADDRESS="$(jq -r '.subscription.ipv6_address // empty' "$NEKO_STATE")"
  [[ -n "$SUBSCRIPTION_DOMAIN_IPV4" && -n "$SUBSCRIPTION_DOMAIN_IPV6" \
    && -n "$SUBSCRIPTION_IPV4_ADDRESS" && -n "$SUBSCRIPTION_IPV6_ADDRESS" ]] \
    || die "安装状态缺少严格双栈订阅字段；请先运行当前版本的升级脚本。"
  validate_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
    || die "state.json 中的 IPv4 订阅域名无效。"
  validate_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
    || die "state.json 中的 IPv6 订阅域名无效。"
  expected_ipv4_domain="v4.${DOMAIN}"
  expected_ipv6_domain="v6.${DOMAIN}"
  [[ "$SUBSCRIPTION_DOMAIN_IPV4" == "$expected_ipv4_domain" ]] \
    || die "state.json 中的 IPv4 订阅域名不是 ${expected_ipv4_domain}。"
  [[ "$SUBSCRIPTION_DOMAIN_IPV6" == "$expected_ipv6_domain" ]] \
    || die "state.json 中的 IPv6 订阅域名不是 ${expected_ipv6_domain}。"
  is_ipv4_literal "$SUBSCRIPTION_IPV4_ADDRESS" \
    || die "state.json 中的严格 IPv4 地址无效。"
  is_ipv6_literal "$SUBSCRIPTION_IPV6_ADDRESS" \
    || die "state.json 中的严格 IPv6 地址无效。"
  LISTEN_ADDRESS="$(jq -r '.network.listen_address // "::"' "$NEKO_STATE")"
  [[ "$LISTEN_ADDRESS" == "::" ]] \
    || die "严格双栈模式要求 network.listen_address 为 ::。"
  CERT_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.crt"
  KEY_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.key"
}

urlencode_path() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//\//%2F}"
  value="${value// /%20}"
  printf '%s' "$value"
}

show_subscription_links() {
  load_state
  printf '\nMihomo IPv4（严格）：\nhttps://%s/%s/mihomo.yaml\n\n' \
    "$SUBSCRIPTION_DOMAIN_IPV4" "$SUB_TOKEN"
  printf 'Mihomo IPv6（严格）：\nhttps://%s/%s/mihomo.yaml\n\n' \
    "$SUBSCRIPTION_DOMAIN_IPV6" "$SUB_TOKEN"
  printf 'Stash IPv4（严格）：\nhttps://%s/%s/stash.yaml\n\n' \
    "$SUBSCRIPTION_DOMAIN_IPV4" "$SUB_TOKEN"
  printf 'Stash IPv6（严格）：\nhttps://%s/%s/stash.yaml\n\n' \
    "$SUBSCRIPTION_DOMAIN_IPV6" "$SUB_TOKEN"
  printf 'Shadowrocket IPv4（严格）：\nhttps://%s/%s/shadowrocket.txt\n\n' \
    "$SUBSCRIPTION_DOMAIN_IPV4" "$SUB_TOKEN"
  printf 'Shadowrocket IPv6（严格）：\nhttps://%s/%s/shadowrocket.txt\n\n' \
    "$SUBSCRIPTION_DOMAIN_IPV6" "$SUB_TOKEN"
}

show_required_ports() {
  load_state
  if [[ "$ACME_METHOD" == "$ACME_METHOD_HTTP" ]]; then
    printf 'IPv4 与 IPv6 云防火墙 TCP：80, 443, %s, %s, %s, %s\n' \
      "$SS_PORT" "$ANYTLS_PORT" "$VISION_PORT" "$XHTTP_PORT"
  else
    printf 'IPv4 与 IPv6 云防火墙 TCP：443, %s, %s, %s, %s\n' \
      "$SS_PORT" "$ANYTLS_PORT" "$VISION_PORT" "$XHTTP_PORT"
    printf 'TCP 80：DNS-01 模式无需公网放行（Caddy 仍会在本机监听 HTTP 跳转）。\n'
  fi
  printf 'IPv4 与 IPv6 云防火墙 UDP：%s-%s, %s, %s\n' \
    "$HY2_START" "$HY2_END" "$TUIC_PORT" "$SS_PORT"
  printf '仅回环 TCP：8443（不要对公网放行）\n'
}
