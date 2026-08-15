#!/usr/bin/env bash

# Platform detection, dependency setup, logging, and shared runtime service
# operations. Loaded through lib/common.sh.

NEKO_RUNTIME_SERVICES=(neko-caddy neko-sing-box neko-xray neko-hysteria)

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

runtime_common_fail() {
  printf '运行公共接口参数无效：%s\n' "$*" >&2
  return 64
}

runtime_run_checked() {
  local output_mode="$1"
  shift
  case "$output_mode" in
    visible) "$@" ;;
    stdout-quiet) "$@" >/dev/null ;;
    all-quiet) "$@" >/dev/null 2>&1 ;;
    *) runtime_common_fail "未知输出模式 ${output_mode}。" ;;
  esac
}

runtime_validate_core_configs() {
  local libexec_dir="" config_dir="" subscription_dir="" network_mode=""
  local output_mode="" normalized_mode profile
  local -a subscription_profiles=()
  while (( $# > 0 )); do
    case "$1" in
      --libexec-dir)
        (( $# >= 2 )) || runtime_common_fail "--libexec-dir 缺少值。" || return
        libexec_dir="$2"
        shift 2
        ;;
      --config-dir)
        (( $# >= 2 )) || runtime_common_fail "--config-dir 缺少值。" || return
        config_dir="$2"
        shift 2
        ;;
      --subscription-dir)
        (( $# >= 2 )) || runtime_common_fail "--subscription-dir 缺少值。" || return
        subscription_dir="$2"
        shift 2
        ;;
      --network-mode)
        (( $# >= 2 )) || runtime_common_fail "--network-mode 缺少值。" || return
        network_mode="$2"
        shift 2
        ;;
      --output)
        (( $# >= 2 )) || runtime_common_fail "--output 缺少值。" || return
        output_mode="$2"
        shift 2
        ;;
      *) runtime_common_fail "未知选项 $1。" || return ;;
    esac
  done
  [[ -n "$libexec_dir" && -n "$config_dir" && -n "$subscription_dir" \
    && -n "$network_mode" && -n "$output_mode" ]] \
    || runtime_common_fail "核心校验选项不完整。" || return
  normalized_mode="$(normalize_network_mode "$network_mode")" \
    || runtime_common_fail "未知网络模式 ${network_mode}。" || return
  case "$output_mode" in
    visible|stdout-quiet|all-quiet) ;;
    *) runtime_common_fail "未知输出模式 ${output_mode}。" || return ;;
  esac

  subscription_profiles+=(sing-box-v4.json)
  if [[ "$normalized_mode" == "$NETWORK_MODE_IPV6" ]]; then
    subscription_profiles=(sing-box-v6.json)
  elif [[ "$normalized_mode" == "$NETWORK_MODE_DUAL" ]]; then
    subscription_profiles+=(
      sing-box-v6.json sing-box-v4-to-v6.json sing-box-v6-to-v4.json
    )
  fi
  runtime_run_checked "$output_mode" \
    "$libexec_dir/sing-box" check -c "$config_dir/sing-box.json" || return
  for profile in "${subscription_profiles[@]}"; do
    runtime_run_checked "$output_mode" \
      "$libexec_dir/sing-box" check -c "$subscription_dir/$profile" || return
  done
  runtime_run_checked "$output_mode" \
    "$libexec_dir/xray" run -test -c "$config_dir/xray.json" || return
  runtime_run_checked "$output_mode" \
    "$libexec_dir/caddy" validate \
      --config "$config_dir/Caddyfile" --adapter caddyfile
}

runtime_set_lego_permissions() {
  local lego_dir="" service_user="" ownership="" path_policy=""
  while (( $# > 0 )); do
    case "$1" in
      --lego-dir)
        (( $# >= 2 )) || runtime_common_fail "--lego-dir 缺少值。" || return
        lego_dir="$2"
        shift 2
        ;;
      --service-user)
        (( $# >= 2 )) || runtime_common_fail "--service-user 缺少值。" || return
        service_user="$2"
        shift 2
        ;;
      --ownership)
        (( $# >= 2 )) || runtime_common_fail "--ownership 缺少值。" || return
        ownership="$2"
        shift 2
        ;;
      --path-policy)
        (( $# >= 2 )) || runtime_common_fail "--path-policy 缺少值。" || return
        path_policy="$2"
        shift 2
        ;;
      *) runtime_common_fail "未知选项 $1。" || return ;;
    esac
  done
  [[ -n "$lego_dir" && -n "$ownership" && -n "$path_policy" ]] \
    || runtime_common_fail "lego 权限选项不完整。" || return
  case "$ownership" in
    managed)
      [[ -n "$service_user" ]] \
        || runtime_common_fail "managed 所有权需要服务用户。" || return
      ;;
    preserve) ;;
    *) runtime_common_fail "所有权模式必须是 managed 或 preserve。" || return ;;
  esac
  case "$path_policy" in
    trusted) ;;
    reject-symlinks)
      [[ -d "$lego_dir" && ! -L "$lego_dir" \
        && -d "$lego_dir/certificates" && ! -L "$lego_dir/certificates" ]] \
        || return 1
      ;;
    *) runtime_common_fail "路径策略必须是 trusted 或 reject-symlinks。" || return ;;
  esac

  if [[ "$ownership" == managed ]]; then
    chown -R root:root "$lego_dir" || return
  fi
  find "$lego_dir" -type d -exec chmod 0700 {} + || return
  find "$lego_dir" -type f -exec chmod 0600 {} + || return
  if [[ "$ownership" == managed ]]; then
    chown "root:${service_user}" "$lego_dir" || return
  fi
  chmod 0750 "$lego_dir" || return
  if [[ "$ownership" == managed ]]; then
    chown -R "root:${service_user}" "$lego_dir/certificates" || return
  fi
  find "$lego_dir/certificates" -type d -exec chmod 0750 {} + || return
  find "$lego_dir/certificates" -type f -exec chmod 0640 {} +
}

runtime_services_are_active() {
  local systemctl_command=""
  local -a services=()
  while (( $# > 0 )); do
    case "$1" in
      --systemctl-command)
        (( $# >= 2 )) \
          || runtime_common_fail "--systemctl-command 缺少值。" || return
        systemctl_command="$2"
        shift 2
        ;;
      --)
        shift
        services=("$@")
        break
        ;;
      *) runtime_common_fail "未知选项 $1。" || return ;;
    esac
  done
  [[ -n "$systemctl_command" && ${#services[@]} -gt 0 ]] \
    || runtime_common_fail "服务 active 检查选项不完整。" || return
  local service
  for service in "${services[@]}"; do
    "$systemctl_command" is-active --quiet "${service}.service" || return
  done
}

runtime_restart_service_set() {
  local systemctl_command="" wait_seconds=""
  local -a services=() units=()
  while (( $# > 0 )); do
    case "$1" in
      --systemctl-command)
        (( $# >= 2 )) \
          || runtime_common_fail "--systemctl-command 缺少值。" || return
        systemctl_command="$2"
        shift 2
        ;;
      --wait-seconds)
        (( $# >= 2 )) || runtime_common_fail "--wait-seconds 缺少值。" || return
        wait_seconds="$2"
        shift 2
        ;;
      --)
        shift
        services=("$@")
        break
        ;;
      *) runtime_common_fail "未知选项 $1。" || return ;;
    esac
  done
  [[ -n "$systemctl_command" && "$wait_seconds" =~ ^[0-9]+$ \
    && ${#services[@]} -gt 0 ]] \
    || runtime_common_fail "服务重启选项不完整。" || return
  local service
  for service in "${services[@]}"; do
    units+=("${service}.service")
  done
  "$systemctl_command" restart "${units[@]}" || return
  sleep "$wait_seconds"
  runtime_services_are_active \
    --systemctl-command "$systemctl_command" -- "${services[@]}"
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
      nftables util-linux passwd kmod findutils bind9-dnsutils iputils-ping
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
      nftables util-linux shadow-utils kmod findutils bind-utils iputils
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
