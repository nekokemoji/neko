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
ACME_RATE_LIMIT_EXIT=75
ACME_TIMEOUT_EXIT=124
ACME_DEFAULT_TIMEOUT_SECONDS=600
NETWORK_MODE_IPV4="ipv4-only"
NETWORK_MODE_IPV6="ipv6-only"
NETWORK_MODE_DUAL="dual"

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

network_mode_label() {
  case "${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" in
    "$NETWORK_MODE_IPV4") printf '仅 IPv4' ;;
    "$NETWORK_MODE_IPV6") printf '仅 IPv6' ;;
    "$NETWORK_MODE_DUAL") printf 'IPv4 + IPv6 双栈' ;;
    *) return 1 ;;
  esac
}

network_mode_link_count() {
  if [[ "${1:-${NETWORK_MODE:-$NETWORK_MODE_DUAL}}" == "$NETWORK_MODE_DUAL" ]]; then
    printf '8'
  else
    printf '4'
  fi
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
      nftables util-linux passwd kmod findutils bind9-dnsutils
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
      nftables util-linux shadow-utils kmod findutils bind-utils
  fi
}

ensure_dns_query_tool() {
  command -v dig >/dev/null 2>&1 && return 0

  info "旧安装缺少严格 DNS 检查工具，正在自动补齐……"
  if command -v apt-get >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get update \
      || ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bind9-dnsutils; then
      die "自动安装 bind9-dnsutils 失败；原安装尚未修改。"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install bind-utils \
      || die "自动安装 bind-utils 失败；原安装尚未修改。"
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf -y install bind-utils \
      || die "自动安装 bind-utils 失败；原安装尚未修改。"
  else
    die "系统缺少 dig，且找不到 apt-get、dnf 或 microdnf；原安装尚未修改。"
  fi

  command -v dig >/dev/null 2>&1 \
    || die "安装 DNS 工具后仍找不到 dig；原安装尚未修改。"
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

stop_acme_guard_process() {
  local guard_pid="$1" child
  local -a children=()

  [[ "$guard_pid" =~ ^[0-9]+$ ]] || return 0
  if [[ -r "/proc/${guard_pid}/task/${guard_pid}/children" ]]; then
    read -r -a children \
      < "/proc/${guard_pid}/task/${guard_pid}/children" || true
  fi

  for child in "${children[@]}"; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$child" 2>/dev/null || true
  done
  kill -TERM "$guard_pid" 2>/dev/null || true
}

run_acme_command_guarded() (
  local timeout_seconds="${NEKO_ACME_TIMEOUT_SECONDS:-$ACME_DEFAULT_TIMEOUT_SECONDS}"
  local guard_pid output_fd line retry_after="" acme_rc=0
  local rate_limited=0 exact_set_limited=0

  command -v timeout >/dev/null 2>&1 \
    || die "系统缺少证书申请超时保护命令：timeout"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
    || die "证书申请超时必须是正整数秒。"
  (( timeout_seconds <= 3600 )) \
    || die "证书申请超时不能超过 3600 秒。"

  coproc NEKO_ACME_GUARD {
    exec timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" \
      "$@" 2>&1
  }
  guard_pid="$NEKO_ACME_GUARD_PID"
  output_fd="${NEKO_ACME_GUARD[0]}"

  trap 'stop_acme_guard_process "$guard_pid"; exit 130' INT
  trap 'stop_acme_guard_process "$guard_pid"; exit 143' TERM

  while IFS= read -r line <&"$output_fd"; do
    printf '%s\n' "$line"
    if (( rate_limited == 0 )) \
      && [[ "$line" == *"urn:ietf:params:acme:error:rateLimited"* ]]; then
      rate_limited=1
      [[ "$line" != *"exact set of identifiers"* ]] || exact_set_limited=1
      if [[ "$line" =~ retry[[:space:]]after[[:space:]]([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]UTC) ]]; then
        retry_after="${BASH_REMATCH[1]}"
      fi
      stop_acme_guard_process "$guard_pid"
    fi
  done

  if wait "$guard_pid"; then
    acme_rc=0
  else
    acme_rc=$?
  fi
  trap - INT TERM

  if (( rate_limited == 1 )); then
    if (( exact_set_limited == 1 )); then
      warn "Let’s Encrypt 已限制这组完全相同的域名；脚本已停止长时间等待。"
    else
      warn "Let’s Encrypt 已触发证书签发额度；脚本已停止长时间等待。"
    fi
    if [[ -n "$retry_after" ]]; then
      warn "官方允许再次尝试的时间：${retry_after}。"
    fi
    warn "请到恢复时间后再运行；不要连续重装或反复申请证书。"
    return "$ACME_RATE_LIMIT_EXIT"
  fi

  if (( acme_rc == ACME_TIMEOUT_EXIT )); then
    warn "证书申请超过 ${timeout_seconds} 秒，已主动停止；不会继续无限等待。"
    warn "请检查上方 ACME 输出和网络/DNS 后再试。"
  fi
  return "$acme_rc"
)

run_lego_acme() {
  local lego_binary="$1" http_mode="$2"
  local -a lego_command=()
  shift 2
  [[ -x "$lego_binary" ]] || die "lego 不可执行：${lego_binary}"

  case "${ACME_METHOD:-$ACME_METHOD_HTTP}" in
    "$ACME_METHOD_HTTP")
      case "$http_mode" in
        standalone)
          lego_command=("$lego_binary" "$@" --http)
          ;;
        webroot)
          lego_command=(
            "$lego_binary" "$@" --http --http.webroot "$NEKO_VAR/acme"
          )
          ;;
        *)
          die "未知的 HTTP-01 运行模式：${http_mode}"
          ;;
      esac
      ;;
    "$ACME_METHOD_CLOUDFLARE")
      assert_cloudflare_dns_token_file
      lego_command=(env \
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
        "$lego_binary" "$@" --dns cloudflare)
      ;;
    *)
      die "不支持的 ACME 验证方式：${ACME_METHOD:-empty}"
      ;;
  esac

  run_acme_command_guarded "${lego_command[@]}"
}

absolute_dns_name() {
  local name="${1%.}"
  printf '%s.\n' "$name"
}

dns_records() {
  local record_type="${1^^}" query_name output status
  query_name="$(absolute_dns_name "$2")"
  case "$record_type" in
    A|AAAA) ;;
    *) die "不支持的 DNS 记录类型：${record_type}" ;;
  esac

  if ! output="$(dig +time=4 +tries=2 +noall +answer +comments \
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

download_optional_verified() {
  local label="$1" url="$2" expected="$3" output="$4"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    warn "${label} 缺少固定 SHA-256；跳过这个可选组件。"
    return 1
  fi
  info "下载可选组件 ${label}……"
  if ! curl --fail --location --silent --show-error \
      --retry 4 --retry-all-errors --connect-timeout 15 \
      --max-time 120 --speed-limit 1024 --speed-time 30 \
      --proto '=https' --tlsv1.2 \
      --output "$output" "$url"; then
    rm -f -- "$output"
    warn "${label} 下载失败；Neko 仍会继续安装，文字订阅链接不受影响。"
    return 1
  fi
  if ! printf '%s  %s\n' "$expected" "$output" \
      | sha256sum --check --status; then
    rm -f -- "$output"
    warn "${label} 的 SHA-256 校验失败；已丢弃文件，文字订阅链接不受影响。"
    return 1
  fi
  return 0
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
  [[ "$state_schema" == "3" ]] \
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
  TROJAN_PORT="$(state_value '.ports.trojan')"
  VISION_PORT="$(state_value '.ports.vless_reality_vision')"
  XHTTP_PORT="$(state_value '.ports.vless_reality_xhttp')"
  HY2_PASSWORD="$(state_value '.credentials.hysteria2_password')"
  HY2_OBFS_PASSWORD="$(state_value '.credentials.hysteria2_obfs_password')"
  TUIC_UUID="$(state_value '.credentials.tuic_uuid')"
  TUIC_PASSWORD="$(state_value '.credentials.tuic_password')"
  SS_PASSWORD="$(state_value '.credentials.ss2022_password')"
  ANYTLS_PASSWORD="$(state_value '.credentials.anytls_password')"
  TROJAN_PASSWORD="$(state_value '.credentials.trojan_password')"
  VISION_UUID="$(state_value '.credentials.vision_uuid')"
  XHTTP_UUID="$(state_value '.credentials.xhttp_uuid')"
  VISION_PRIVATE_KEY="$(state_value '.reality.vision_private_key')"
  VISION_PUBLIC_KEY="$(state_value '.reality.vision_public_key')"
  VISION_SHORT_ID="$(state_value '.reality.vision_short_id')"
  XHTTP_PRIVATE_KEY="$(state_value '.reality.xhttp_private_key')"
  XHTTP_PUBLIC_KEY="$(state_value '.reality.xhttp_public_key')"
  XHTTP_SHORT_ID="$(state_value '.reality.xhttp_short_id')"
  XHTTP_PATH="$(state_value '.reality.xhttp_path')"
  NETWORK_MODE="$(jq -r '.network.mode // empty' "$NEKO_STATE")"
  NETWORK_MODE="$(normalize_network_mode "$NETWORK_MODE")" \
    || die "state.json 中的网络安装模式无效。"
  SUB_TOKEN_IPV4="$(jq -r '.subscription.ipv4_token // empty' "$NEKO_STATE")"
  SUB_TOKEN_IPV6="$(jq -r '.subscription.ipv6_token // empty' "$NEKO_STATE")"
  SUBSCRIPTION_DOMAIN_IPV4="$(jq -r '.subscription.ipv4_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_DOMAIN_IPV6="$(jq -r '.subscription.ipv6_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV4_ADDRESS="$(jq -r '.subscription.ipv4_address // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV6_ADDRESS="$(jq -r '.subscription.ipv6_address // empty' "$NEKO_STATE")"
  expected_ipv4_domain="v4.${DOMAIN}"
  expected_ipv6_domain="v6.${DOMAIN}"
  if network_mode_has_ipv4 "$NETWORK_MODE"; then
    [[ "$SUB_TOKEN_IPV4" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv4 订阅令牌格式无效。"
    validate_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
      || die "state.json 中的 IPv4 订阅域名无效。"
    [[ "$SUBSCRIPTION_DOMAIN_IPV4" == "$expected_ipv4_domain" ]] \
      || die "state.json 中的 IPv4 订阅域名不是 ${expected_ipv4_domain}。"
    is_ipv4_literal "$SUBSCRIPTION_IPV4_ADDRESS" \
      || die "state.json 中的严格 IPv4 地址无效。"
  else
    SUB_TOKEN_IPV4=""
    SUBSCRIPTION_DOMAIN_IPV4=""
    SUBSCRIPTION_IPV4_ADDRESS=""
  fi
  if network_mode_has_ipv6 "$NETWORK_MODE"; then
    [[ "$SUB_TOKEN_IPV6" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv6 订阅令牌格式无效。"
    validate_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
      || die "state.json 中的 IPv6 订阅域名无效。"
    [[ "$SUBSCRIPTION_DOMAIN_IPV6" == "$expected_ipv6_domain" ]] \
      || die "state.json 中的 IPv6 订阅域名不是 ${expected_ipv6_domain}。"
    is_ipv6_literal "$SUBSCRIPTION_IPV6_ADDRESS" \
      || die "state.json 中的严格 IPv6 地址无效。"
  else
    SUB_TOKEN_IPV6=""
    SUBSCRIPTION_DOMAIN_IPV6=""
    SUBSCRIPTION_IPV6_ADDRESS=""
  fi
  CERT_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.crt"
  KEY_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.key"
}

active_certificate_domains() {
  printf '%s\n' "$DOMAIN"
  if network_mode_has_ipv4; then
    printf '%s\n' "$SUBSCRIPTION_DOMAIN_IPV4"
  fi
  if network_mode_has_ipv6; then
    printf '%s\n' "$SUBSCRIPTION_DOMAIN_IPV6"
  fi
}

certificate_has_active_domains() {
  local certificate_file="$1" certificate_domain
  [[ -s "$certificate_file" ]] || return 1
  while IFS= read -r certificate_domain; do
    openssl x509 -in "$certificate_file" -noout -checkhost "$certificate_domain" \
      >/dev/null 2>&1 || return 1
  done < <(active_certificate_domains)
}

urlencode_path() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//\//%2F}"
  value="${value// /%20}"
  printf '%s' "$value"
}

subscription_client_label() {
  case "$1" in
    mihomo) printf 'Mihomo' ;;
    stash) printf 'Stash' ;;
    shadowrocket) printf 'Shadowrocket' ;;
    sing-box) printf 'sing-box' ;;
    *) return 1 ;;
  esac
}

subscription_client_filename() {
  case "$1" in
    mihomo) printf 'mihomo.yaml' ;;
    stash) printf 'stash.yaml' ;;
    shadowrocket) printf 'shadowrocket.txt' ;;
    sing-box) printf 'sing-box.json' ;;
    *) return 1 ;;
  esac
}

subscription_url() {
  local family="$1" client="$2" family_path token filename
  filename="$(subscription_client_filename "$client")" || return 1
  case "$family" in
    ipv4)
      network_mode_has_ipv4 || return 1
      token="$SUB_TOKEN_IPV4"
      family_path=v4
      ;;
    ipv6)
      network_mode_has_ipv6 || return 1
      token="$SUB_TOKEN_IPV6"
      family_path=v6
      ;;
    *)
      return 1
      ;;
  esac
  [[ -n "$DOMAIN" && -n "$token" ]] || return 1
  printf 'https://%s/%s/%s/%s' \
    "$DOMAIN" "$token" "$family_path" "$filename"
}

show_subscription_links() {
  local family client family_label client_label url
  load_state
  printf '\n当前模式：%s\n' "$(network_mode_label)"
  printf '下载入口：基础域名（只负责取回配置，节点连接与出口仍严格分族）\n'
  for family in ipv4 ipv6; do
    if [[ "$family" == ipv4 ]]; then
      network_mode_has_ipv4 || continue
      family_label=IPv4
    else
      network_mode_has_ipv6 || continue
      family_label=IPv6
    fi
    for client in mihomo stash shadowrocket sing-box; do
      client_label="$(subscription_client_label "$client")"
      url="$(subscription_url "$family" "$client")"
      printf '\n%s %s（严格）：\n%s\n' \
        "$client_label" "$family_label" "$url"
    done
  done
  printf '\n'
}

terminal_columns() {
  local size rows columns
  if [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] && (( COLUMNS > 0 )); then
    printf '%s' "$COLUMNS"
    return 0
  fi
  if command -v stty >/dev/null 2>&1; then
    size="$(stty size 2>/dev/null < /dev/tty || true)"
    rows="${size%% *}"
    columns="${size##* }"
    if [[ "$rows" =~ ^[0-9]+$ && "$columns" =~ ^[0-9]+$ ]] \
      && (( rows > 0 && columns > 0 )); then
      printf '%s' "$columns"
      return 0
    fi
  fi
  printf '80'
}

unicode_qr_width() {
  local output="$1" line normalized line_width width=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # sed replaces each three-byte block glyph with one ASCII byte, so the
    # result is correct even when a minimal image starts Bash in LC_ALL=C.
    normalized="$(
      printf '%s' "$line" \
        | sed 's/▀/#/g; s/▄/#/g; s/█/#/g'
    )"
    line_width="${#normalized}"
    if (( line_width > width )); then
      width="$line_width"
    fi
  done <<< "$output"
  printf '%s' "$width"
}

show_terminal_qr() {
  local url="$1" qrc_binary qr_output qr_width columns
  local -a qrc_command
  qrc_binary="${NEKO_QRC_BINARY:-${NEKO_LIBEXEC}/qrc}"

  if [[ ! -x "$qrc_binary" ]]; then
    warn "二维码组件不可用；上面的文字订阅链接仍可正常使用。"
    return 0
  fi
  if [[ "${NEKO_QR_TEST_MODE:-0}" != "1" ]] \
    && { [[ ! -t 1 ]] || [[ "${TERM:-dumb}" == dumb ]]; }; then
    warn "当前输出不是可显示二维码的交互终端；请直接使用上面的文字链接。"
    return 0
  fi

  qrc_command=(
    "$qrc_binary"
    --output-format unicode
    --invert
    --ec-level M
    --scale 1
    --border 4
  )
  if command -v timeout >/dev/null 2>&1; then
    qrc_command=(timeout 5 "${qrc_command[@]}")
  fi
  if ! qr_output="$(
      printf '%s' "$url" | "${qrc_command[@]}" 2>/dev/null
    )" || [[ -z "$qr_output" ]]; then
    warn "二维码生成失败；上面的文字订阅链接仍可正常使用。"
    return 0
  fi

  qr_width="$(unicode_qr_width "$qr_output")"
  columns="$(terminal_columns)"
  if [[ "$qr_width" =~ ^[0-9]+$ && "$columns" =~ ^[0-9]+$ ]] \
    && (( qr_width > columns )); then
    warn "当前终端约 ${columns} 列，二维码需要 ${qr_width} 列。请横屏或缩小终端字体后重试；文字链接不受影响。"
    return 0
  fi

  # qrc's compact Unicode mode packs two modules into one row. Explicit
  # foreground/background colors keep the code readable on both light and
  # dark terminal themes; the URL itself is only supplied over stdin.
  printf '\n\033[30;47m%s\033[0m\n' "$qr_output"
  warn "二维码等同于订阅密码；请勿分享二维码、截图或上方完整链接。"
}

show_required_ports() {
  load_state
  local family_label
  family_label="$(network_mode_label)"
  if [[ "$ACME_METHOD" == "$ACME_METHOD_HTTP" ]]; then
    printf '%s 云防火墙 TCP：80, 443, %s, %s, %s, %s, %s\n' "$family_label" \
      "$SS_PORT" "$ANYTLS_PORT" "$TROJAN_PORT" "$VISION_PORT" "$XHTTP_PORT"
  else
    printf '%s 云防火墙 TCP：443, %s, %s, %s, %s, %s\n' "$family_label" \
      "$SS_PORT" "$ANYTLS_PORT" "$TROJAN_PORT" "$VISION_PORT" "$XHTTP_PORT"
    printf 'TCP 80：DNS-01 模式无需公网放行（Caddy 仍会在本机监听 HTTP 跳转）。\n'
  fi
  printf '%s 云防火墙 UDP：%s-%s, %s, %s\n' \
    "$family_label" "$HY2_START" "$HY2_END" "$TUIC_PORT" "$SS_PORT"
  printf '仅回环 TCP：8443（不要对公网放行）\n'
}
