#!/usr/bin/env bash

# Shared helpers for the installer and the installed terminal panel.

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"

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

resolved_addresses() {
  { getent ahosts "$1" 2>/dev/null || true; } | awk '{print $1}' | sort -u
}

check_domain_resolution() {
  local domain="$1" addresses
  addresses="$(resolved_addresses "$domain")"
  [[ -n "$addresses" ]] || die "域名 ${domain} 没有可用的 A/AAAA 解析；安装不会继续。"
  info "${domain} 当前解析为："
  while IFS= read -r address; do
    printf '  - %s\n' "$address"
  done <<< "$addresses"
  warn "请确认这些是本机直连地址，未开启 CDN/代理；最终还会用 ACME HTTP-01 验证域名控制权。"
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
  local port
  for port in 80 443; do
    if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
      die "TCP ${port} 已被占用。为避免破坏现有网站，安装不会继续。"
    fi
  done
  if ss -H -ltn "sport = :8443" 2>/dev/null | grep -q .; then
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
  [[ -r "$NEKO_STATE" ]] || die "找不到安装状态：${NEKO_STATE}"

  DOMAIN="$(state_value '.domain')"
  ACME_EMAIL="$(state_value '.acme_email')"
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
  LISTEN_ADDRESS="$(jq -r '.network.listen_address // "::"' "$NEKO_STATE")"
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
  printf '\nMihomo：\nhttps://%s/%s/mihomo.yaml\n\n' "$DOMAIN" "$SUB_TOKEN"
  printf 'Stash：\nhttps://%s/%s/stash.yaml\n\n' "$DOMAIN" "$SUB_TOKEN"
  printf 'Shadowrocket：\nhttps://%s/%s/shadowrocket.txt\n\n' "$DOMAIN" "$SUB_TOKEN"
}

show_required_ports() {
  load_state
  printf '云防火墙 TCP：80, 443, %s, %s, %s, %s\n' \
    "$SS_PORT" "$ANYTLS_PORT" "$VISION_PORT" "$XHTTP_PORT"
  printf '云防火墙 UDP：%s-%s, %s, %s\n' \
    "$HY2_START" "$HY2_END" "$TUIC_PORT" "$SS_PORT"
  printf '仅回环 TCP：8443（不要对公网放行）\n'
}
