#!/usr/bin/env bash

# Read-only VPS, Neko and network diagnostics.  Expensive benchmarks are kept
# behind a separate, explicit menu and never run as part of the normal report.

set -uo pipefail
umask 0077
export LC_ALL=C

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_DIAG_PROC_ROOT="${NEKO_DIAG_PROC_ROOT:-/proc}"
NEKO_DIAG_SYS_ROOT="${NEKO_DIAG_SYS_ROOT:-/sys}"
NEKO_DIAG_OS_RELEASE_FILE="${NEKO_DIAG_OS_RELEASE_FILE:-/etc/os-release}"
NEKO_DIAG_RESOLV_CONF="${NEKO_DIAG_RESOLV_CONF:-/etc/resolv.conf}"
NEKO_DIAG_ROOT_PATH="${NEKO_DIAG_ROOT_PATH:-/}"
NEKO_DIAG_TMP_DIR="${NEKO_DIAG_TMP_DIR:-/var/tmp}"
NEKO_DIAG_TRACE_URL="${NEKO_DIAG_TRACE_URL:-https://cloudflare.com/cdn-cgi/trace}"
NEKO_DIAG_RIPE_BASE="${NEKO_DIAG_RIPE_BASE:-https://stat.ripe.net/data}"
NEKO_DIAG_IPAPI_URL="${NEKO_DIAG_IPAPI_URL:-https://api.ipapi.is/}"
NEKO_DIAG_PROXYCHECK_URL="${NEKO_DIAG_PROXYCHECK_URL:-https://proxycheck.io/v3/}"
NEKO_DIAG_IPWHO_URL="${NEKO_DIAG_IPWHO_URL:-https://ipwho.is}"
NEKO_DIAG_IPQUERY_URL="${NEKO_DIAG_IPQUERY_URL:-https://api.ipquery.io}"
NEKO_DIAG_NEXTTRACE="${NEKO_DIAG_NEXTTRACE:-${NEKO_LIBEXEC}/nexttrace-tiny}"
NEKO_DIAG_CPU_SECONDS="${NEKO_DIAG_CPU_SECONDS:-3}"
NEKO_DIAG_DISK_MIB="${NEKO_DIAG_DISK_MIB:-128}"
NEKO_DIAG_DNS_TIMEOUT="${NEKO_DIAG_DNS_TIMEOUT:-12}"
NEKO_DIAG_NETWORK_TIMEOUT="${NEKO_DIAG_NETWORK_TIMEOUT:-5}"
NEKO_DIAG_ROUTE_TIMEOUT="${NEKO_DIAG_ROUTE_TIMEOUT:-35}"
NEKO_DIAG_ROUTE_PROVIDER="${NEKO_DIAG_ROUTE_PROVIDER:-LeoMoeAPI}"
NEKO_DIAG_ROUTE_REGION="${NEKO_DIAG_ROUTE_REGION:-gd}"
NEKO_DIAG_ROUTE_V4_CT="${NEKO_DIAG_ROUTE_V4_CT:-gd-ct-v4.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V4_CU="${NEKO_DIAG_ROUTE_V4_CU:-gd-cu-v4.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V4_CM="${NEKO_DIAG_ROUTE_V4_CM:-gd-cm-v4.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V6_CT="${NEKO_DIAG_ROUTE_V6_CT:-gd-ct-v6.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V6_CU="${NEKO_DIAG_ROUTE_V6_CU:-gd-cu-v6.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V6_CM="${NEKO_DIAG_ROUTE_V6_CM:-gd-cm-v6.ip.zstaticcdn.com}"

# shellcheck source=lib/common.sh
source "${NEKO_LIBEXEC}/lib/common.sh"

DIAG_OK_COUNT=0
DIAG_WARN_COUNT=0
DIAG_SKIP_COUNT=0
DIAG_BENCH_FILE=""
DIAG_QUALITY_DIR=""
DIAG_ROUTE_DIR=""
ROUTE_COMPLETED_COUNT=0
ROUTE_FAILED_COUNT=0
ROUTE_REPORT_HAS_SUMMARY=0
declare -A ROUTE_SUMMARY_LATENCY=()
declare -A ROUTE_SUMMARY_LINE=()
declare -A ROUTE_SUMMARY_STATUS=()

diag_cleanup() {
  local base="${NEKO_DIAG_TMP_DIR%/}"
  if [[ -n "$DIAG_BENCH_FILE" && -n "$base" \
    && "$DIAG_BENCH_FILE" == "$base"/.neko-disk-bench.* ]]; then
    rm -f -- "$DIAG_BENCH_FILE"
  fi
  DIAG_BENCH_FILE=""
  if [[ -n "$DIAG_QUALITY_DIR" && -n "$base" \
    && "$DIAG_QUALITY_DIR" == "$base"/.neko-ip-quality.* ]]; then
    rm -rf -- "$DIAG_QUALITY_DIR"
  fi
  DIAG_QUALITY_DIR=""
  if [[ -n "$DIAG_ROUTE_DIR" && -n "$base" \
    && "$DIAG_ROUTE_DIR" == "$base"/.neko-route.* ]]; then
    rm -rf -- "$DIAG_ROUTE_DIR"
  fi
  DIAG_ROUTE_DIR=""
}

trap diag_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

diag_section() {
  printf '\n%s\n' "$1"
  printf '%*s\n' "${#1}" '' | tr ' ' '-'
}

diag_fact() {
  printf '  %-18s %s\n' "$1：" "${2:-未知}"
}

diag_ok() {
  ((DIAG_OK_COUNT += 1))
  printf '  %s[正常]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

diag_warn() {
  ((DIAG_WARN_COUNT += 1))
  printf '  %s[提醒]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

diag_skip() {
  ((DIAG_SKIP_COUNT += 1))
  printf '  [未测] %s\n' "$1"
}

diag_reset_counts() {
  DIAG_OK_COUNT=0
  DIAG_WARN_COUNT=0
  DIAG_SKIP_COUNT=0
}

diag_summary() {
  diag_section "体检小结"
  printf '  正常 %d 项，提醒 %d 项，未测 %d 项。\n' \
    "$DIAG_OK_COUNT" "$DIAG_WARN_COUNT" "$DIAG_SKIP_COUNT"
  if (( DIAG_WARN_COUNT == 0 )); then
    printf '  本次已完成的检查没有发现明显异常。\n'
  else
    printf '  “提醒”需要结合上方文字判断，不代表 Neko 一定发生故障。\n'
  fi
  printf '  报告不会显示订阅令牌、协议密码、证书私钥或 Cloudflare Token。\n'
  printf '  公网 IP 仍属于隐私信息，分享截图前请自行遮挡。\n'
}

human_kib() {
  local value="${1:-0}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  awk -v kib="$value" '
    BEGIN {
      if (kib >= 1073741824) printf "%.2f TiB", kib / 1073741824
      else if (kib >= 1048576) printf "%.2f GiB", kib / 1048576
      else if (kib >= 1024) printf "%.2f MiB", kib / 1024
      else printf "%d KiB", kib
    }'
}

read_os_name() {
  local value=""
  if [[ -r "$NEKO_DIAG_OS_RELEASE_FILE" ]]; then
    value="$(
      awk -F= '
        $1 == "PRETTY_NAME" {
          value = substr($0, index($0, "=") + 1)
          gsub(/^"|"$/, "", value)
          print value
          exit
        }' "$NEKO_DIAG_OS_RELEASE_FILE"
    )"
  fi
  printf '%s' "${value:-未知}"
}

read_cpu_model() {
  local cpuinfo="${NEKO_DIAG_PROC_ROOT}/cpuinfo"
  [[ -r "$cpuinfo" ]] || { printf '未知'; return 0; }
  awk -F: '
    /^model name[[:space:]]*:/ {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      print value
      exit
    }
    /^(Model|Hardware)[[:space:]]*:/ && fallback == "" {
      fallback=$2
      sub(/^[[:space:]]+/, "", fallback)
    }
    END {
      if (NR > 0 && value == "" && fallback != "") print fallback
    }' "$cpuinfo"
}

read_cpu_count() {
  local cpuinfo="${NEKO_DIAG_PROC_ROOT}/cpuinfo" count=""
  if command -v getconf >/dev/null 2>&1; then
    count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if [[ ! "$count" =~ ^[0-9]+$ || "$count" == 0 ]] && [[ -r "$cpuinfo" ]]; then
    count="$(
      awk -F: '/^processor[[:space:]]*:/ {count++} END {print count + 0}' \
        "$cpuinfo"
    )"
  fi
  printf '%s' "${count:-未知}"
}

read_cpu_mhz() {
  local cpuinfo="${NEKO_DIAG_PROC_ROOT}/cpuinfo"
  [[ -r "$cpuinfo" ]] || return 0
  awk -F: '
    /^cpu MHz[[:space:]]*:/ {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      printf "%.0f MHz", value
      exit
    }' "$cpuinfo"
}

show_system_report() {
  local cpuinfo="${NEKO_DIAG_PROC_ROOT}/cpuinfo"
  local meminfo="${NEKO_DIAG_PROC_ROOT}/meminfo"
  local uptime_file="${NEKO_DIAG_PROC_ROOT}/uptime"
  local loadavg_file="${NEKO_DIAG_PROC_ROOT}/loadavg"
  local cpu_flags="" cpu_aes="未暴露" cpu_virt="未暴露"
  local cpu_mhz virt uptime_seconds uptime_text load_average
  local mem_total=0 mem_available=0 mem_used=0 swap_total=0 swap_free=0 swap_used=0
  local disk_line disk_total=0 disk_used=0 disk_available=0 disk_percent="未知"
  local inode_line inode_percent="未知" mount_info="未知" root_source=""
  local rotation="" rotation_label="未知" tcp_cc="未知" time_sync="未知"

  diag_section "系统与硬件（只读）"
  diag_fact "系统" "$(read_os_name)"
  diag_fact "内核" "$(uname -r 2>/dev/null || printf '未知')"
  diag_fact "架构" "$(uname -m 2>/dev/null || printf '未知')"

  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in
    ""|none) virt="未检测到（不等于一定是独立服务器）" ;;
  esac
  diag_fact "虚拟化" "$virt"

  uptime_seconds="$(
    awk 'NR == 1 {printf "%.0f", $1}' "$uptime_file" 2>/dev/null || true
  )"
  if [[ "$uptime_seconds" =~ ^[0-9]+$ ]]; then
    uptime_text="$((uptime_seconds / 86400)) 天 $(((uptime_seconds % 86400) / 3600)) 小时 $(((uptime_seconds % 3600) / 60)) 分"
  else
    uptime_text="未知"
  fi
  diag_fact "运行时间" "$uptime_text"
  load_average="$(
    awk 'NR == 1 {print $1 ", " $2 ", " $3}' "$loadavg_file" \
      2>/dev/null || true
  )"
  diag_fact "负载 1/5/15 分钟" "${load_average:-未知}"

  diag_section "CPU"
  diag_fact "型号" "$(read_cpu_model)"
  diag_fact "可用 vCPU" "$(read_cpu_count)"
  cpu_mhz="$(read_cpu_mhz)"
  [[ -z "$cpu_mhz" ]] || diag_fact "当前频率样本" "$cpu_mhz"
  if [[ -r "$cpuinfo" ]]; then
    cpu_flags="$(
      awk -F: '
        /^(flags|Features)[[:space:]]*:/ {
          value=$2
          sub(/^[[:space:]]+/, "", value)
          print value
          exit
        }' "$cpuinfo"
    )"
  fi
  if grep -Eq '(^|[[:space:]])aes([[:space:]]|$)' <<< "$cpu_flags"; then
    cpu_aes="已暴露"
  fi
  if grep -Eq '(^|[[:space:]])(vmx|svm)([[:space:]]|$)' <<< "$cpu_flags"; then
    cpu_virt="已暴露"
  fi
  diag_fact "AES 指令" "$cpu_aes"
  diag_fact "嵌套虚拟化指令" "$cpu_virt"

  diag_section "内存"
  if [[ -r "$meminfo" ]]; then
    mem_total="$(awk '$1 == "MemTotal:" {print $2}' "$meminfo")"
    mem_available="$(awk '$1 == "MemAvailable:" {print $2}' "$meminfo")"
    swap_total="$(awk '$1 == "SwapTotal:" {print $2}' "$meminfo")"
    swap_free="$(awk '$1 == "SwapFree:" {print $2}' "$meminfo")"
  fi
  for value_name in mem_total mem_available swap_total swap_free; do
    [[ "${!value_name:-}" =~ ^[0-9]+$ ]] || printf -v "$value_name" 0
  done
  (( mem_available <= mem_total )) || mem_available=0
  (( swap_free <= swap_total )) || swap_free=0
  mem_used=$((mem_total - mem_available))
  swap_used=$((swap_total - swap_free))
  diag_fact "内存总量" "$(human_kib "$mem_total")"
  diag_fact "内存已用/可用" "$(human_kib "$mem_used") / $(human_kib "$mem_available")"
  diag_fact "Swap 已用/总量" "$(human_kib "$swap_used") / $(human_kib "$swap_total")"

  diag_section "根文件系统"
  disk_line="$(df -Pk -- "$NEKO_DIAG_ROOT_PATH" 2>/dev/null \
    | awk 'NR == 2 {print $2, $3, $4, $5}')"
  read -r disk_total disk_used disk_available disk_percent <<< "$disk_line"
  diag_fact "容量" "$(human_kib "${disk_total:-0}")"
  diag_fact "已用/可用" "$(human_kib "${disk_used:-0}") / $(human_kib "${disk_available:-0}")"
  diag_fact "空间使用率" "${disk_percent:-未知}"
  inode_line="$(df -Pi -- "$NEKO_DIAG_ROOT_PATH" 2>/dev/null \
    | awk 'NR == 2 {print $5}')"
  [[ -z "$inode_line" ]] || inode_percent="$inode_line"
  diag_fact "Inode 使用率" "$inode_percent"
  if command -v findmnt >/dev/null 2>&1; then
    mount_info="$(findmnt -n -o SOURCE,FSTYPE --target "$NEKO_DIAG_ROOT_PATH" \
      2>/dev/null || true)"
  fi
  diag_fact "设备与格式" "${mount_info:-未知}"
  root_source="${mount_info%% *}"
  if [[ "$root_source" == /dev/* ]] && command -v lsblk >/dev/null 2>&1; then
    rotation="$(
      lsblk -ndo ROTA -- "$root_source" 2>/dev/null \
        | awk 'NR == 1 {value=$1} END {if (value != "") print value}'
    )"
    case "$rotation" in
      0) rotation_label="内核标记为非旋转盘" ;;
      1) rotation_label="内核标记为旋转盘" ;;
    esac
  fi
  diag_fact "磁盘介质标记" "$rotation_label"

  diag_section "内核网络参数"
  tcp_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  diag_fact "TCP 拥塞控制" "${tcp_cc:-未知}"
  if command -v timedatectl >/dev/null 2>&1; then
    time_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    case "$time_sync" in
      yes) time_sync="已同步" ;;
      no) time_sync="未同步" ;;
      *) time_sync="未知" ;;
    esac
  fi
  diag_fact "系统时间同步" "$time_sync"
}

load_diag_state() {
  [[ -r "$NEKO_STATE" ]] || return 1
  jq -e '.schema == 3 and (.network.mode | type == "string")' \
    "$NEKO_STATE" >/dev/null 2>&1 || return 1

  DOMAIN="$(jq -r '.domain // empty' "$NEKO_STATE")"
  NETWORK_MODE="$(jq -r '.network.mode // empty' "$NEKO_STATE")"
  NETWORK_MODE="$(normalize_network_mode "$NETWORK_MODE")" || return 1
  SUBSCRIPTION_DOMAIN_IPV4="$(jq -r '.subscription.ipv4_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_DOMAIN_IPV6="$(jq -r '.subscription.ipv6_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV4_ADDRESS="$(jq -r '.subscription.ipv4_address // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV6_ADDRESS="$(jq -r '.subscription.ipv6_address // empty' "$NEKO_STATE")"
  CERT_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.crt"
  KEY_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.key"
  return 0
}

certificate_days_remaining() {
  local not_after="$1" expiry now
  expiry="$(date -d "$not_after" +%s 2>/dev/null || true)"
  now="$(date +%s 2>/dev/null || true)"
  if [[ "$expiry" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]]; then
    printf '%d' "$(((expiry - now) / 86400))"
  fi
}

show_neko_report() {
  local release state_mode state_mode_label state_mode_raw state_mode_valid=1
  local state_mode_perms="未知" certificate_issuer certificate_end certificate_days
  local certificate_ok=1 certificate_domain status service

  diag_section "Neko 服务与证书"
  if ! load_diag_state; then
    diag_skip "没有找到可读取的 Neko schema 3 安装状态。"
    return 0
  fi

  release="$(jq -r '.release // "未知"' "$NEKO_STATE")"
  state_mode_raw="$(jq -r '.network.mode // empty' "$NEKO_STATE")"
  state_mode="$(normalize_network_mode "$state_mode_raw" 2>/dev/null || true)"
  if [[ -z "$state_mode" ]]; then
    state_mode_valid=0
    state_mode_label="无效：${state_mode_raw:-空}"
  else
    state_mode_label="$(network_mode_label "$state_mode")"
  fi
  diag_fact "Neko 版本" "$release"
  diag_fact "安装模式" "$state_mode_label"
  diag_fact "基础域名" "$DOMAIN"

  state_mode_perms="$(stat -c '%a' "$NEKO_STATE" 2>/dev/null || true)"
  if [[ "$state_mode_perms" == 600 ]]; then
    diag_ok "安装状态文件权限为 0600。"
  else
    diag_warn "安装状态文件权限为 ${state_mode_perms:-未知}，预期为 0600。"
  fi

  if (( state_mode_valid == 0 )); then
    diag_warn "网络安装模式无效，跳过依赖地址族的检查。"
    return 0
  fi

  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    status="$(systemctl is-active "${service}.service" 2>/dev/null || true)"
    if [[ "$status" == active ]]; then
      diag_ok "${service} 正在运行。"
    else
      diag_warn "${service} 当前状态为 ${status:-未知}。"
    fi
  done
  status="$(systemctl is-active neko-renew.timer 2>/dev/null || true)"
  if [[ "$status" == active ]]; then
    diag_ok "证书自动续期定时器正在运行。"
  else
    diag_warn "证书自动续期定时器状态为 ${status:-未知}。"
  fi

  if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
    diag_warn "证书或私钥文件缺失。"
    return 0
  fi
  if ! openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
    diag_warn "证书文件无法由 OpenSSL 解析。"
    return 0
  fi

  certificate_issuer="$(
    openssl x509 -in "$CERT_FILE" -noout -issuer 2>/dev/null \
      | sed 's/^issuer=//'
  )"
  certificate_end="$(
    openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null \
      | sed 's/^notAfter=//'
  )"
  certificate_days="$(certificate_days_remaining "$certificate_end")"
  diag_fact "证书签发者" "${certificate_issuer:-未知}"
  diag_fact "证书到期时间" "${certificate_end:-未知}"
  [[ -z "$certificate_days" ]] || diag_fact "剩余有效期" "${certificate_days} 天"
  if [[ "$certificate_days" =~ ^-?[0-9]+$ ]] && (( certificate_days < 14 )); then
    diag_warn "证书剩余有效期不足 14 天。"
  else
    diag_ok "证书仍在安全有效期内。"
  fi

  while IFS= read -r certificate_domain; do
    if ! openssl x509 -in "$CERT_FILE" -noout \
      -checkhost "$certificate_domain" >/dev/null 2>&1; then
      certificate_ok=0
      diag_warn "证书没有覆盖 ${certificate_domain}。"
    fi
  done < <(
    printf '%s\n' "$DOMAIN"
    network_mode_has_ipv4 "$NETWORK_MODE" \
      && printf '%s\n' "$SUBSCRIPTION_DOMAIN_IPV4"
    network_mode_has_ipv6 "$NETWORK_MODE" \
      && printf '%s\n' "$SUBSCRIPTION_DOMAIN_IPV6"
  )
  (( certificate_ok == 0 )) || diag_ok "证书覆盖全部已安装域名。"
}

address_is_local() {
  local family="$1" address="$2" output=""
  case "$family" in
    ipv4)
      output="$(ip -4 -o address show to "${address}/32" 2>/dev/null || true)"
      ;;
    ipv6)
      output="$(ip -6 -o address show to "${address}/128" 2>/dev/null || true)"
      ;;
    *) return 1 ;;
  esac
  [[ -n "$output" ]]
}

default_route_for_family() {
  local family="$1"
  case "$family" in
    ipv4) ip -4 route show default 2>/dev/null || true ;;
    ipv6) ip -6 route show default 2>/dev/null || true ;;
  esac
}

strict_dns_check_bounded() {
  local timeout_seconds="$NEKO_DIAG_DNS_TIMEOUT"
  local common_file="${NEKO_LIBEXEC}/lib/common.sh"
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] \
    && (( timeout_seconds >= 2 && timeout_seconds <= 30 )) \
    || timeout_seconds=12
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" bash -c '
      source "$1"
      check_strict_stack_dns "$2" "$3" >/dev/null 2>&1
    ' _ "$common_file" "$DOMAIN" "$NETWORK_MODE"
  else
    (
      check_strict_stack_dns "$DOMAIN" "$NETWORK_MODE" >/dev/null 2>&1
    )
  fi
}

route_selection_for_family() {
  local family="$1" source_address="$2" target
  case "$family" in
    ipv4)
      target=1.1.1.1
      ip -4 route get "$target" from "$source_address" 2>/dev/null || true
      ;;
    ipv6)
      target=2606:4700:4700::1111
      ip -6 route get "$target" from "$source_address" 2>/dev/null || true
      ;;
  esac
}

curl_family_args() {
  local family="$1" source_address="$2"
  if [[ "$family" == ipv4 ]]; then
    printf '%s\0' --ipv4 --interface "$source_address"
  else
    printf '%s\0' --ipv6 --interface "$source_address"
  fi
}

trace_family() {
  local family="$1" source_address="$2"
  local resolve_target response observed_ip loc colo connect_time first_byte
  local connect_ms first_byte_ms timeout_seconds="$NEKO_DIAG_NETWORK_TIMEOUT"
  local -a family_args=()

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] \
    && (( timeout_seconds >= 2 && timeout_seconds <= 30 )) \
    || timeout_seconds=5
  mapfile -d '' -t family_args < <(curl_family_args "$family" "$source_address")
  if [[ "$family" == ipv4 ]]; then
    resolve_target='cloudflare.com:443:1.1.1.1'
  else
    resolve_target='cloudflare.com:443:[2606:4700:4700::1111]'
  fi

  response="$(
    curl --fail --silent --show-error --location --max-redirs 2 \
      --connect-timeout 3 --max-time "$timeout_seconds" \
      "${family_args[@]}" \
      --resolve "$resolve_target" \
      --write-out $'\n__NEKO_CONNECT__=%{time_connect}\n__NEKO_FIRST_BYTE__=%{time_starttransfer}\n' \
      "$NEKO_DIAG_TRACE_URL" 2>/dev/null
  )" || {
    diag_warn "${family/ipv/IPv} 无法在 ${timeout_seconds} 秒内完成严格来源绑定的 HTTPS 检查。"
    return 0
  }

  observed_ip="$(sed -n 's/^ip=//p' <<< "$response" \
    | awk 'NF {value=$0} END {if (value != "") print value}')"
  loc="$(sed -n 's/^loc=//p' <<< "$response" \
    | awk 'NF {value=$0} END {if (value != "") print value}')"
  colo="$(sed -n 's/^colo=//p' <<< "$response" \
    | awk 'NF {value=$0} END {if (value != "") print value}')"
  connect_time="$(sed -n 's/^__NEKO_CONNECT__=//p' <<< "$response")"
  first_byte="$(sed -n 's/^__NEKO_FIRST_BYTE__=//p' <<< "$response")"
  connect_ms="$(awk -v seconds="$connect_time" \
    'BEGIN {if (seconds ~ /^[0-9.]+$/) printf "%.0f", seconds * 1000}')"
  first_byte_ms="$(awk -v seconds="$first_byte" \
    'BEGIN {if (seconds ~ /^[0-9.]+$/) printf "%.0f", seconds * 1000}')"

  if [[ "$family" == ipv4 ]] && is_ipv4_literal "$observed_ip"; then
    diag_fact "IPv4 公网出口" "$observed_ip"
  elif [[ "$family" == ipv6 ]] && is_ipv6_literal "$observed_ip"; then
    diag_fact "IPv6 公网出口" "$observed_ip"
  else
    diag_warn "${family/ipv/IPv} HTTPS 已连接，但没有得到有效的出口 IP。"
    return 0
  fi
  diag_fact "${family/ipv/IPv} 位置提示" "${loc:-未知} / Cloudflare ${colo:-未知}"
  [[ -z "$connect_ms" ]] || diag_fact "${family/ipv/IPv} TCP 建连" "${connect_ms} ms"
  [[ -z "$first_byte_ms" ]] || diag_fact "${family/ipv/IPv} 首字节" "${first_byte_ms} ms"

  if address_is_local "$family" "$observed_ip"; then
    diag_ok "${family/ipv/IPv} 对外看到的地址属于本机。"
  else
    diag_warn "${family/ipv/IPv} 对外出口 ${observed_ip} 不属于本机；可能存在 NAT、转发或上游改写。"
  fi
}

ripe_request() {
  local family="$1" source_address="$2" endpoint="$3"
  shift 3
  local timeout_seconds="$NEKO_DIAG_NETWORK_TIMEOUT"
  local -a family_args=() request_args=()
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] \
    && (( timeout_seconds >= 2 && timeout_seconds <= 30 )) \
    || timeout_seconds=5
  mapfile -d '' -t family_args < <(curl_family_args "$family" "$source_address")
  while (( $# )); do
    request_args+=(--data-urlencode "$1")
    shift
  done
  curl --fail --silent --show-error \
    --connect-timeout 3 --max-time "$timeout_seconds" \
    "${family_args[@]}" --get "${request_args[@]}" \
    "${NEKO_DIAG_RIPE_BASE}/${endpoint}/data.json" 2>/dev/null
}

quality_request() {
  local provider="$1" family="$2" source_address="$3"
  local timeout_seconds="$NEKO_DIAG_NETWORK_TIMEOUT"
  local -a family_args=()

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] \
    && (( timeout_seconds >= 2 && timeout_seconds <= 30 )) \
    || timeout_seconds=5
  mapfile -d '' -t family_args < <(curl_family_args "$family" "$source_address")
  case "$provider" in
    ipapi)
      curl --fail --silent --show-error --location --max-redirs 1 \
        --connect-timeout 3 --max-time "$timeout_seconds" \
        --max-filesize 524288 --header 'Accept: application/json' \
        "${family_args[@]}" --get --data-urlencode "q=${source_address}" \
        "$NEKO_DIAG_IPAPI_URL" 2>/dev/null
      ;;
    proxycheck)
      curl --fail --silent --show-error --location --max-redirs 1 \
        --connect-timeout 3 --max-time "$timeout_seconds" \
        --max-filesize 524288 --header 'Accept: application/json' \
        "${family_args[@]}" --request POST \
        --data-urlencode "ips=${source_address}" \
        "$NEKO_DIAG_PROXYCHECK_URL" 2>/dev/null
      ;;
    ipwho)
      curl --fail --silent --show-error --location --max-redirs 1 \
        --connect-timeout 3 --max-time "$timeout_seconds" \
        --max-filesize 524288 --header 'Accept: application/json' \
        "${family_args[@]}" \
        "${NEKO_DIAG_IPWHO_URL%/}/${source_address}" 2>/dev/null
      ;;
    ipquery)
      curl --fail --silent --show-error --location --max-redirs 1 \
        --connect-timeout 3 --max-time "$timeout_seconds" \
        --max-filesize 524288 --header 'Accept: application/json' \
        "${family_args[@]}" \
        "${NEKO_DIAG_IPQUERY_URL%/}/${source_address}" 2>/dev/null
      ;;
    *) return 2 ;;
  esac
}

quality_response_valid() {
  local provider="$1" address="$2" file="$3"
  [[ -s "$file" ]] || return 1
  case "$provider" in
    ipapi)
      jq -e --arg ip "$address" \
        '(.error? == null) and (.ip == $ip)' "$file" >/dev/null 2>&1
      ;;
    proxycheck)
      jq -e --arg ip "$address" \
        '(.status == "ok") and (.[ $ip ] | type == "object")' \
        "$file" >/dev/null 2>&1
      ;;
    ipwho)
      jq -e --arg ip "$address" \
        '(.success == true) and (.ip == $ip)' "$file" >/dev/null 2>&1
      ;;
    ipquery)
      jq -e --arg ip "$address" \
        '(.ip == $ip) and (.risk | type == "object")' \
        "$file" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

normalize_asn_label() {
  local value="${1:-}"
  value="${value^^}"
  case "$value" in
    AS[0-9]*) [[ "${value#AS}" =~ ^[0-9]+$ ]] && printf '%s' "$value" ;;
    [0-9]*) [[ "$value" =~ ^[0-9]+$ ]] && printf 'AS%s' "$value" ;;
  esac
}

show_ip_quality() {
  local family="$1" source_address="$2"
  local ipapi_file proxycheck_file ipwho_file ipquery_file provider file pid
  local ipapi_ok=0 proxycheck_ok=0 ipwho_ok=0 ipquery_ok=0
  local ipapi_host="" ipapi_type="" ipapi_country="" ipapi_city=""
  local ipapi_asn="" ipapi_org="" ipapi_flags=""
  local proxy_host="" proxy_type="" proxy_country="" proxy_city=""
  local proxy_asn="" proxy_org="" proxy_flags="" proxy_risk=""
  local ipwho_country="" ipwho_city="" ipwho_asn="" ipwho_org=""
  local ipquery_host="" ipquery_type="" ipquery_country="" ipquery_city=""
  local ipquery_asn="" ipquery_org="" ipquery_flags="" ipquery_risk=""
  local hosting_yes=0 hosting_no=0 hosting_total=0
  local security_sources=0 security_detail="" country_detail_text=""
  local majority_count=0 majority_code="" total_countries=0
  local type_summary="" location_summary="" detail=""
  local -a providers=(ipapi proxycheck ipwho ipquery)
  local -a pids=() ipapi_fields=() proxy_fields=() ipwho_fields=()
  local -a ipquery_fields=()
  local -a country_codes=() country_details=()

  diag_section "${family/ipv/IPv} IP 质量（数据库参考）"
  if [[ ! -d "$NEKO_DIAG_TMP_DIR" || ! -w "$NEKO_DIAG_TMP_DIR" ]]; then
    diag_skip "临时目录不可写，未查询 ${family/ipv/IPv} IP 质量。"
    return 0
  fi
  DIAG_QUALITY_DIR="$(
    mktemp -d "${NEKO_DIAG_TMP_DIR%/}/.neko-ip-quality.XXXXXX"
  )" || {
    DIAG_QUALITY_DIR=""
    diag_skip "无法创建临时目录，未查询 ${family/ipv/IPv} IP 质量。"
    return 0
  }
  ipapi_file="${DIAG_QUALITY_DIR}/ipapi.json"
  proxycheck_file="${DIAG_QUALITY_DIR}/proxycheck.json"
  ipwho_file="${DIAG_QUALITY_DIR}/ipwho.json"
  ipquery_file="${DIAG_QUALITY_DIR}/ipquery.json"
  for provider in "${providers[@]}"; do
    case "$provider" in
      ipapi) file="$ipapi_file" ;;
      proxycheck) file="$proxycheck_file" ;;
      ipwho) file="$ipwho_file" ;;
      ipquery) file="$ipquery_file" ;;
    esac
    (
      quality_request "$provider" "$family" "$source_address" > "$file" \
        && quality_response_valid "$provider" "$source_address" "$file"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  if quality_response_valid ipapi "$source_address" "$ipapi_file"; then
    ipapi_ok=1
    mapfile -t ipapi_fields < <(
      jq -r '
        def clean:
          tostring
          | gsub("[[:cntrl:]]"; " ")
          | .[0:160];
        [
          (if .is_datacenter == true then "yes"
           elif .is_datacenter == false then "no" else "" end),
          (.company.type // "" | clean),
          (.location.country_code // "" | clean),
          (.location.city // "" | clean),
          (.asn.asn // "" | clean),
          (.asn.org // .company.name // "" | clean),
          ([
            if .is_proxy == true then "代理" else empty end,
            if .is_vpn == true then "VPN" else empty end,
            if .is_tor == true then "Tor" else empty end,
            if .is_abuser == true then "滥用记录" else empty end
          ] | join("、"))
        ] | .[]' "$ipapi_file"
    )
    ipapi_host="${ipapi_fields[0]:-}"
    ipapi_type="${ipapi_fields[1]:-}"
    ipapi_country="${ipapi_fields[2]:-}"
    ipapi_city="${ipapi_fields[3]:-}"
    ipapi_asn="$(normalize_asn_label "${ipapi_fields[4]:-}")"
    ipapi_org="${ipapi_fields[5]:-}"
    ipapi_flags="${ipapi_fields[6]:-}"
  fi

  if quality_response_valid proxycheck "$source_address" "$proxycheck_file"; then
    proxycheck_ok=1
    mapfile -t proxy_fields < <(
      jq -r --arg ip "$source_address" '
        def clean:
          tostring
          | gsub("[[:cntrl:]]"; " ")
          | .[0:160];
        .[$ip] as $r
        | [
          (if (($r.detections.hosting? == true)
                or (($r.network.type? // "" | ascii_downcase) == "hosting"))
           then "yes"
           elif (($r.detections.hosting? == false)
                 or ($r.network.type? != null))
           then "no" else "" end),
          ($r.network.type // "" | clean),
          ($r.location.country_code // "" | clean),
          ($r.location.city_name // "" | clean),
          ($r.network.asn // "" | clean),
          ($r.network.organisation // $r.network.provider // "" | clean),
          ([
            if $r.detections.proxy? == true then "代理" else empty end,
            if $r.detections.vpn? == true then "VPN" else empty end,
            if $r.detections.tor? == true then "Tor" else empty end,
            if $r.detections.compromised? == true then "被入侵" else empty end,
            if $r.detections.scraper? == true then "爬虫" else empty end,
            if $r.detections.anonymous? == true then "匿名网络" else empty end
          ] | join("、")),
          ($r.detections.risk // "" | clean)
        ] | .[]' "$proxycheck_file"
    )
    proxy_host="${proxy_fields[0]:-}"
    proxy_type="${proxy_fields[1]:-}"
    proxy_country="${proxy_fields[2]:-}"
    proxy_city="${proxy_fields[3]:-}"
    proxy_asn="$(normalize_asn_label "${proxy_fields[4]:-}")"
    proxy_org="${proxy_fields[5]:-}"
    proxy_flags="${proxy_fields[6]:-}"
    proxy_risk="${proxy_fields[7]:-}"
  fi

  if quality_response_valid ipwho "$source_address" "$ipwho_file"; then
    ipwho_ok=1
    mapfile -t ipwho_fields < <(
      jq -r '
        def clean:
          tostring
          | gsub("[[:cntrl:]]"; " ")
          | .[0:160];
        [
          (.country_code // "" | clean),
          (.city // "" | clean),
          (.connection.asn // "" | clean),
          (.connection.org // .connection.isp // "" | clean)
        ] | .[]' "$ipwho_file"
    )
    ipwho_country="${ipwho_fields[0]:-}"
    ipwho_city="${ipwho_fields[1]:-}"
    ipwho_asn="$(normalize_asn_label "${ipwho_fields[2]:-}")"
    ipwho_org="${ipwho_fields[3]:-}"
  fi

  if quality_response_valid ipquery "$source_address" "$ipquery_file"; then
    ipquery_ok=1
    mapfile -t ipquery_fields < <(
      jq -r '
        def clean:
          tostring
          | gsub("[[:cntrl:]]"; " ")
          | .[0:160];
        [
          (if .risk.is_datacenter == true then "yes"
           elif .risk.is_datacenter == false then "no" else "" end),
          (if .risk.is_datacenter == true then "datacenter"
           elif .risk.is_mobile == true then "mobile" else "" end),
          (.location.country_code // "" | clean),
          (.location.city // "" | clean),
          (.isp.asn // "" | clean),
          (.isp.org // .isp.isp // "" | clean),
          ([
            if .risk.is_proxy == true then "代理" else empty end,
            if .risk.is_vpn == true then "VPN" else empty end,
            if .risk.is_tor == true then "Tor" else empty end,
            if .risk.is_mobile == true then "移动网络" else empty end
          ] | join("、")),
          (.risk.risk_score // "" | clean)
        ] | .[]' "$ipquery_file"
    )
    ipquery_host="${ipquery_fields[0]:-}"
    ipquery_type="${ipquery_fields[1]:-}"
    ipquery_country="${ipquery_fields[2]:-}"
    ipquery_city="${ipquery_fields[3]:-}"
    ipquery_asn="$(normalize_asn_label "${ipquery_fields[4]:-}")"
    ipquery_org="${ipquery_fields[5]:-}"
    ipquery_flags="${ipquery_fields[6]:-}"
    ipquery_risk="${ipquery_fields[7]:-}"
  fi

  for detail in "$ipapi_host" "$proxy_host" "$ipquery_host"; do
    case "$detail" in
      yes) ((hosting_yes += 1, hosting_total += 1)) ;;
      no) ((hosting_no += 1, hosting_total += 1)) ;;
    esac
  done
  if (( hosting_total == 0 )); then
    type_summary="相关数据库未返回可用的网络类型"
  elif (( hosting_yes == hosting_total )); then
    type_summary="数据中心/托管 IP（${hosting_yes}/${hosting_total} 个来源一致）"
  elif (( hosting_no == hosting_total )); then
    type_summary="未被这 ${hosting_total} 个来源标为托管；不能据此认定住宅或原生"
  else
    type_summary="数据库意见不一致（托管 ${hosting_yes}，非托管 ${hosting_no}）"
  fi
  diag_fact "小白结论 · 类型" "$type_summary"

  if (( ipapi_ok == 1 )); then
    ((security_sources += 1))
    [[ -z "$ipapi_flags" ]] \
      || security_detail="ipapi.is：${ipapi_flags}"
  fi
  if (( proxycheck_ok == 1 )); then
    ((security_sources += 1))
    if [[ -n "$proxy_flags" ]]; then
      [[ -z "$security_detail" ]] \
        || security_detail+="；"
      security_detail+="proxycheck.io：${proxy_flags}"
    fi
  fi
  if (( ipquery_ok == 1 )); then
    ((security_sources += 1))
    if [[ -n "$ipquery_flags" ]]; then
      [[ -z "$security_detail" ]] \
        || security_detail+="；"
      security_detail+="ipquery.io：${ipquery_flags}"
    fi
  fi
  if [[ -n "$security_detail" ]]; then
    diag_warn "${family/ipv/IPv} 风控数据库检测到：${security_detail}。"
  elif (( security_sources > 0 )); then
    diag_fact "小白结论 · 风控" \
      "当前未见明显代理/VPN/Tor/滥用标签（不等于永久干净）"
  else
    diag_skip "${family/ipv/IPv} 风控标签数据库暂时不可用。"
  fi

  for detail in \
    "ipapi.is:${ipapi_country}" \
    "proxycheck.io:${proxy_country}" \
    "ipwho.is:${ipwho_country}" \
    "ipquery.io:${ipquery_country}"; do
    provider="${detail%%:*}"
    detail="${detail#*:}"
    detail="${detail^^}"
    if [[ "$detail" =~ ^[A-Z]{2}$ ]]; then
      country_codes+=("$detail")
      country_details+=("${provider}=${detail}")
    fi
  done
  total_countries="${#country_codes[@]}"
  if (( total_countries > 0 )); then
    read -r majority_count majority_code < <(
      printf '%s\n' "${country_codes[@]}" \
        | sort | uniq -c | sort -nr \
        | awk 'NR == 1 {print $1, $2}'
    )
    for detail in "${country_details[@]}"; do
      [[ -z "$country_detail_text" ]] \
        || country_detail_text+="；"
      country_detail_text+="$detail"
    done
    if (( total_countries == 1 )); then
      location_summary="${majority_code}（仅 1 个来源返回）"
    elif (( majority_count * 2 > total_countries )); then
      location_summary="${majority_code}（${majority_count}/${total_countries} 个来源一致）"
    else
      location_summary="数据库不一致（${country_detail_text}）"
    fi
    diag_fact "小白结论 · 位置" "$location_summary"
  else
    diag_skip "${family/ipv/IPv} 位置数据库暂时不可用。"
  fi
  diag_fact "原生 IP 结论" \
    "没有统一权威标准；不把单一数据库标签冒充原生结论"

  if (( ipapi_ok == 1 )); then
    detail="${ipapi_asn:-ASN 未知} ${ipapi_org:-机构未知}；${ipapi_country:-位置未知}"
    [[ -z "$ipapi_city" ]] || detail+="/${ipapi_city}"
    detail+="；类型 ${ipapi_type:-未知}"
    [[ -z "$ipapi_flags" ]] || detail+="；标签 ${ipapi_flags}"
    diag_fact "ipapi.is" "$detail"
  else
    diag_skip "${family/ipv/IPv} ipapi.is 数据暂时不可用。"
  fi
  if (( proxycheck_ok == 1 )); then
    detail="${proxy_asn:-ASN 未知} ${proxy_org:-机构未知}；${proxy_country:-位置未知}"
    [[ -z "$proxy_city" ]] || detail+="/${proxy_city}"
    detail+="；类型 ${proxy_type:-未知}"
    [[ -z "$proxy_flags" ]] || detail+="；标签 ${proxy_flags}"
    [[ -z "$proxy_risk" ]] || detail+="；风险分 ${proxy_risk}/100"
    diag_fact "proxycheck.io" "$detail"
  else
    diag_skip "${family/ipv/IPv} proxycheck.io 数据暂时不可用。"
  fi
  if (( ipwho_ok == 1 )); then
    detail="${ipwho_asn:-ASN 未知} ${ipwho_org:-机构未知}；${ipwho_country:-位置未知}"
    [[ -z "$ipwho_city" ]] || detail+="/${ipwho_city}"
    diag_fact "ipwho.is" "$detail"
  else
    diag_skip "${family/ipv/IPv} ipwho.is 数据暂时不可用。"
  fi
  if (( ipquery_ok == 1 )); then
    detail="${ipquery_asn:-ASN 未知} ${ipquery_org:-机构未知}；${ipquery_country:-位置未知}"
    [[ -z "$ipquery_city" ]] || detail+="/${ipquery_city}"
    detail+="；类型 ${ipquery_type:-未知}"
    [[ -z "$ipquery_flags" ]] || detail+="；标签 ${ipquery_flags}"
    [[ -z "$ipquery_risk" ]] || detail+="；风险分 ${ipquery_risk}/100"
    diag_fact "ipquery.io" "$detail"
  else
    diag_skip "${family/ipv/IPv} ipquery.io 数据暂时不可用。"
  fi
  printf '  注：数据库会更新，也可能误判；类型和位置只作选购/排障参考。\n'

  rm -rf -- "$DIAG_QUALITY_DIR"
  DIAG_QUALITY_DIR=""
}

show_routing_registration() {
  local family="$1" source_address="$2"
  local network_json prefix asns prefix_json holders announced
  local rpki_json rpki_status ptr observed_ip="$source_address"
  local whois_json registry_country registry_name registry_source registry_detail
  local -a asn_list=()

  network_json="$(ripe_request "$family" "$source_address" \
    network-info "resource=${observed_ip}")" || {
    diag_skip "${family/ipv/IPv} 的 RIPEstat 路由注册信息暂时不可用。"
    return 0
  }
  prefix="$(jq -r '.data.prefix // empty' <<< "$network_json" 2>/dev/null)"
  mapfile -t asn_list < <(
    jq -r '.data.asns[]? | select(type == "number")' \
      <<< "$network_json" 2>/dev/null
  )
  if [[ -z "$prefix" || ${#asn_list[@]} -eq 0 ]]; then
    diag_warn "${family/ipv/IPv} 地址没有查到已公布的 BGP 前缀和 ASN。"
    return 0
  fi
  asns="$(printf 'AS%s, ' "${asn_list[@]}")"
  asns="${asns%, }"
  diag_fact "${family/ipv/IPv} BGP 前缀" "$prefix"
  diag_fact "${family/ipv/IPv} 源 ASN" "$asns"

  prefix_json="$(ripe_request "$family" "$source_address" \
    prefix-overview "resource=${prefix}")" || prefix_json=""
  holders="$(
    jq -r '
      [.data.asns[]? | "AS\(.asn) \(.holder // "未知持有者")"]
      | join("；")' <<< "$prefix_json" 2>/dev/null
  )"
  announced="$(jq -r '.data.announced // empty' \
    <<< "$prefix_json" 2>/dev/null)"
  [[ -z "$holders" ]] || diag_fact "${family/ipv/IPv} 网络名称" "$holders"
  if [[ "$announced" == true ]]; then
    diag_ok "${family/ipv/IPv} 前缀可在 RIPE RIS 中看到。"
  elif [[ -n "$announced" ]]; then
    diag_warn "${family/ipv/IPv} 前缀当前未被 RIPE RIS 标记为已公布。"
  fi

  if (( ${#asn_list[@]} == 1 )); then
    rpki_json="$(ripe_request "$family" "$source_address" \
      rpki-validation "resource=${asn_list[0]}" "prefix=${prefix}")" \
      || rpki_json=""
    rpki_status="$(jq -r '.data.status // empty' \
      <<< "$rpki_json" 2>/dev/null)"
    case "$rpki_status" in
      valid)
        diag_ok "${family/ipv/IPv} BGP 源 ASN 与 RPKI ROA 匹配。"
        ;;
      unknown)
        diag_warn "${family/ipv/IPv} 前缀没有可用于这条公告的 RPKI ROA。"
        ;;
      invalid_asn|invalid_length)
        diag_warn "${family/ipv/IPv} RPKI 状态为 ${rpki_status}，建议联系 VPS 商家。"
        ;;
      *)
        diag_skip "${family/ipv/IPv} RPKI 状态暂时不可用。"
        ;;
    esac
  else
    diag_skip "${family/ipv/IPv} 是多源 ASN 公告，未用单一 ASN 简化判断 RPKI。"
  fi

  whois_json="$(ripe_request "$family" "$source_address" \
    whois "resource=${observed_ip}")" || whois_json=""
  if jq -e '.status == "ok" and (.data.records | type == "array")' \
      <<< "$whois_json" >/dev/null 2>&1; then
    registry_country="$(
      jq -r '
        [
          .data.records[]?[]?
          | select((.key // "" | tostring | ascii_downcase) == "country")
          | (.value // "" | tostring | ascii_upcase)
          | select(test("^[A-Z]{2}$"))
        ]
        | unique
        | join("/")' <<< "$whois_json" 2>/dev/null
    )"
    registry_name="$(
      jq -r '
        def clean:
          tostring
          | gsub("[[:cntrl:]]"; " ")
          | .[0:120];
        first(
          .data.records[]?[]?
          | select(
              ((.key // "" | tostring | ascii_downcase) == "netname")
              or ((.key // "" | tostring | ascii_downcase) == "organization")
            )
          | (.value // "" | clean)
        ) // ""' <<< "$whois_json" 2>/dev/null
    )"
    registry_source="$(
      jq -r '
        [.data.authorities[]? | tostring | ascii_upcase]
        | unique
        | join("/")' <<< "$whois_json" 2>/dev/null
    )"
    registry_detail="${registry_source:-来源未知}"
    registry_detail+="；国家/地区 ${registry_country:-未提供}"
    [[ -z "$registry_name" ]] || registry_detail+="；登记名称 ${registry_name}"
    diag_fact "${family/ipv/IPv} RIR 登记" "$registry_detail"
    printf '  注：RIR 登记国家/地区是地址注册资料，不等于 VPS 机房位置。\n'
  else
    diag_skip "${family/ipv/IPv} 的 RIR 地址登记资料暂时不可用。"
  fi

  if command -v dig >/dev/null 2>&1; then
    ptr="$(
      dig +time=3 +tries=1 +short -x "$observed_ip" 2>/dev/null \
        | awk 'NF {values = values (values == "" ? "" : ", ") $0} END {print values}'
    )"
    diag_fact "${family/ipv/IPv} PTR 反向解析" "${ptr:-未配置}"
  fi
}

show_family_network() {
  local family="$1" domain address route selection interface mtu=""
  if [[ "$family" == ipv4 ]]; then
    domain="$SUBSCRIPTION_DOMAIN_IPV4"
    address="$SUBSCRIPTION_IPV4_ADDRESS"
  else
    domain="$SUBSCRIPTION_DOMAIN_IPV6"
    address="$SUBSCRIPTION_IPV6_ADDRESS"
  fi

  diag_section "${family/ipv/IPv} 网络"
  diag_fact "严格订阅域名" "$domain"
  diag_fact "配置地址" "$address"
  if [[ "$family" == ipv4 ]] && ! is_ipv4_literal "$address"; then
    diag_warn "安装状态中的 IPv4 地址无效，停止这个地址族的联网检查。"
    return 0
  elif [[ "$family" == ipv6 ]] && ! is_ipv6_literal "$address"; then
    diag_warn "安装状态中的 IPv6 地址无效，停止这个地址族的联网检查。"
    return 0
  fi
  route="$(default_route_for_family "$family")"
  if [[ -n "$route" ]]; then
    diag_ok "${family/ipv/IPv} 默认路由存在。"
    diag_fact "默认路由" "$(awk 'NR == 1 {print; exit}' <<< "$route")"
  else
    diag_warn "${family/ipv/IPv} 默认路由缺失。"
  fi
  if address_is_local "$family" "$address"; then
    diag_ok "${family/ipv/IPv} 配置地址仍属于本机。"
  else
    diag_warn "${family/ipv/IPv} 配置地址已不在本机网卡上。"
  fi

  selection="$(route_selection_for_family "$family" "$address")"
  if [[ -n "$selection" ]]; then
    diag_fact "绑定源地址的路由" "$(awk 'NR == 1 {print; exit}' <<< "$selection")"
    interface="$(
      awk 'NR == 1 {
        for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}
      }' <<< "$selection"
    )"
    if [[ -n "$interface" ]]; then
      mtu="$(
        ip -o link show dev "$interface" 2>/dev/null \
          | sed -nE 's/.* mtu ([0-9]+) .*/\1/p' \
          | awk 'NR == 1 {value=$0} END {if (value != "") print value}'
      )"
      diag_fact "出口网卡/MTU" "${interface} / ${mtu:-未知}"
    fi
  else
    diag_warn "${family/ipv/IPv} 无法按配置源地址选择到公网的路由。"
  fi

  trace_family "$family" "$address"
  show_ip_quality "$family" "$address"
  diag_section "${family/ipv/IPv} BGP 注册（不是实际线路）"
  show_routing_registration "$family" "$address"
}

show_network_report() {
  local resolvers=""
  diag_section "严格网络、IP 质量与 BGP"
  if ! load_diag_state; then
    diag_skip "没有可用的 Neko 安装状态，无法按已安装地址族检查。"
    return 0
  fi

  if [[ -r "$NEKO_DIAG_RESOLV_CONF" ]]; then
    resolvers="$(
      awk '$1 == "nameserver" && NF >= 2 {
        values = values (values == "" ? "" : ", ") $2
      } END {print values}' "$NEKO_DIAG_RESOLV_CONF"
    )"
  fi
  diag_fact "系统 DNS" "${resolvers:-未知}"

  if strict_dns_check_bounded; then
    diag_ok "基础域名与已安装专用域名仍符合严格 DNS 规则。"
  else
    diag_warn "当前 DNS 已不符合安装模式；可先核对 Cloudflare 灰云记录。"
  fi

  printf '\n  说明：IP 类型、位置和风控会交叉查询多个数据库，但都可能误判。\n'
  printf '  BGP 注册只能说明地址归属；真实三网路径请在菜单中单独运行。\n'
  if network_mode_has_ipv4 "$NETWORK_MODE"; then
    show_family_network ipv4
  fi
  if network_mode_has_ipv6 "$NETWORK_MODE"; then
    show_family_network ipv6
  fi
}

run_nexttrace_probe() {
  local family="$1" source_address="$2" target="$3" output_file="$4"
  local family_flag timeout_seconds="$NEKO_DIAG_ROUTE_TIMEOUT"

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] \
    && (( timeout_seconds >= 10 && timeout_seconds <= 90 )) \
    || timeout_seconds=35
  if [[ "$family" == ipv4 ]]; then
    family_flag=--ipv4
  else
    family_flag=--ipv6
  fi
  timeout --kill-after=2 "$timeout_seconds" \
    "$NEKO_DIAG_NEXTTRACE" \
    "$family_flag" --tcp --port 80 \
    --source "$source_address" \
    --queries 1 --max-attempts 2 --parallel-requests 6 \
    --max-hops 30 --timeout 1000 --send-time 50 --ttl-time 100 \
    --no-rdns --data-provider "$NEKO_DIAG_ROUTE_PROVIDER" \
    --json --map --no-color "$target" \
    > "$output_file" 2> "${output_file}.err"
}

normalize_route_region() {
  case "${1,,}" in
    ""|1|gd|guangdong|guangzhou)
      printf 'gd'
      ;;
    2|sh|shanghai)
      printf 'sh'
      ;;
    3|bj|beijing)
      printf 'bj'
      ;;
    4|sc|sichuan|cd|chengdu)
      printf 'sc'
      ;;
    5|all)
      printf 'all'
      ;;
    6|hb|hubei)
      printf 'hb'
      ;;
    7|ln|liaoning)
      printf 'ln'
      ;;
    *)
      return 1
      ;;
  esac
}

route_region_label() {
  case "$1" in
    gd) printf '广东' ;;
    sh) printf '上海' ;;
    bj) printf '北京' ;;
    sc) printf '四川' ;;
    hb) printf '湖北' ;;
    ln) printf '辽宁' ;;
    *) return 1 ;;
  esac
}

route_target() {
  local region="$1" family="$2" carrier="$3"
  local family_token override_name override_value legacy_value=""

  if [[ "$family" == ipv4 ]]; then
    family_token=V4
  else
    family_token=V6
  fi
  override_name="NEKO_DIAG_ROUTE_${region^^}_${family_token}_${carrier^^}"
  override_value="${!override_name:-}"
  if [[ -n "$override_value" ]]; then
    printf '%s' "$override_value"
    return 0
  fi

  # Keep the original Guangdong override names working for existing tests and
  # administrators who already use them.
  if [[ "$region" == gd ]]; then
    case "${family}:${carrier}" in
      ipv4:ct) legacy_value="$NEKO_DIAG_ROUTE_V4_CT" ;;
      ipv4:cu) legacy_value="$NEKO_DIAG_ROUTE_V4_CU" ;;
      ipv4:cm) legacy_value="$NEKO_DIAG_ROUTE_V4_CM" ;;
      ipv6:ct) legacy_value="$NEKO_DIAG_ROUTE_V6_CT" ;;
      ipv6:cu) legacy_value="$NEKO_DIAG_ROUTE_V6_CU" ;;
      ipv6:cm) legacy_value="$NEKO_DIAG_ROUTE_V6_CM" ;;
    esac
  fi
  if [[ -n "$legacy_value" ]]; then
    printf '%s' "$legacy_value"
  else
    printf '%s-%s-%s.ip.zstaticcdn.com' \
      "$region" "$carrier" "${family/ipv/v}"
  fi
}

route_result_valid() {
  local file="$1"
  [[ -s "$file" ]] \
    && jq -e '.Hops | type == "array"' "$file" >/dev/null 2>&1
}

route_asn_path() {
  local file="$1"
  jq -r '
    def asn:
      tostring
      | ascii_upcase
      | sub("^AS"; "")
      | select(test("^[0-9]+$"))
      | "AS" + .;
    reduce (
      .Hops[][]?
      | select(.Success == true)
      | .Geo.asnumber?
      | select(. != null and . != "")
      | asn
    ) as $item (
      [];
      if index($item) == null then . + [$item] else . end
    )
    | join(" → ")' "$file" 2>/dev/null
}

route_hop_count() {
  local file="$1"
  jq -r '
    [
      .Hops[]?
      | [.[]? | select(.Success == true)]
      | length
      | select(. > 0)
    ] | length' "$file" 2>/dev/null
}

route_last_latency_ms() {
  local file="$1"
  local rtt_ns
  rtt_ns="$(
    jq -r '
    [
      .Hops[][]?
      | select(.Success == true)
      | .RTT
      | select(type == "number" and . >= 0)
    ]
    | last // empty' "$file" 2>/dev/null
  )"
  [[ "$rtt_ns" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  awk -v ns="$rtt_ns" 'BEGIN {printf "%.2f", ns / 1000000}'
}

classify_carrier_route() {
  local carrier="$1" asn_path="$2"
  local token label result=""
  local -a path_tokens=()

  # Preserve path order and show every recognized carrier backbone. This is
  # more honest than hiding an international transit ASN just because the
  # destination belongs to a different carrier.
  read -r -a path_tokens <<< "$asn_path"
  for token in "${path_tokens[@]}"; do
    case "$token" in
      AS4809) label='CN2（AS4809）' ;;
      AS4134) label='电信 163（AS4134）' ;;
      AS9929) label='联通 9929/CUII（AS9929）' ;;
      AS4837) label='联通 169（AS4837）' ;;
      AS10099) label='中国联通国际（AS10099）' ;;
      AS58807) label='移动 CMIN2（AS58807）' ;;
      AS58453) label='中国移动国际 CMI（AS58453）' ;;
      AS9808) label='移动 CMNET（AS9808）' ;;
      *) continue ;;
    esac
    [[ -z "$result" ]] || result+=" → "
    result+="$label"
  done
  if [[ -n "$result" ]]; then
    printf '%s' "$result"
    return 0
  fi
  case "$carrier" in
    ct) printf '未识别常见电信骨干' ;;
    cu) printf '未识别常见联通骨干' ;;
    cm) printf '未识别常见移动骨干' ;;
  esac
}

show_carrier_route_result() {
  local region="$1" family="$2" carrier="$3" label="$4" file="$5"
  local asn_path hop_count latency latency_display judgment key
  key="${region}:${family}:${carrier}"

  if ! route_result_valid "$file"; then
    ((ROUTE_FAILED_COUNT += 1, DIAG_SKIP_COUNT += 1))
    ROUTE_SUMMARY_STATUS["$key"]="failed"
    printf '  %s%s%s｜未完成（超时、无响应或线路元数据不可用）\n' \
      "$C_YELLOW" "$label" "$C_RESET"
    return 0
  fi
  hop_count="$(route_hop_count "$file")"
  if [[ ! "$hop_count" =~ ^[0-9]+$ ]] || (( hop_count == 0 )); then
    ((ROUTE_FAILED_COUNT += 1, DIAG_SKIP_COUNT += 1))
    ROUTE_SUMMARY_STATUS["$key"]="failed"
    printf '  %s%s%s｜未完成（没有收到有效响应）\n' \
      "$C_YELLOW" "$label" "$C_RESET"
    return 0
  fi
  asn_path="$(route_asn_path "$file")"
  latency="$(route_last_latency_ms "$file")"
  if [[ -n "$asn_path" ]]; then
    judgment="$(classify_carrier_route "$carrier" "$asn_path")"
  else
    judgment="已测到路径，ASN 暂不可用"
  fi
  ((ROUTE_COMPLETED_COUNT += 1))
  ROUTE_SUMMARY_STATUS["$key"]="ok"
  ROUTE_SUMMARY_LATENCY["$key"]="${latency:-未知}"
  ROUTE_SUMMARY_LINE["$key"]="$judgment"
  if [[ -n "$latency" ]]; then
    latency_display="${latency} ms"
  else
    latency_display="未知"
  fi
  printf '  %s%s%s｜末跳 %s｜%s\n' \
    "$C_GREEN" "$label" "$C_RESET" \
    "$latency_display" "$judgment"
  printf '        ASN 路径：%s（%s 跳有响应）\n' \
    "${asn_path:-无 ASN 数据}" "$hop_count"
}

show_carrier_routes_for_family() {
  local region="$1" family="$2" source_address="$3"
  local pid
  local -a carriers=(ct cu cm) labels=(电信 联通 移动)
  local -a targets=() files=() pids=()
  local index region_label

  region_label="$(route_region_label "$region")"
  for index in 0 1 2; do
    targets+=("$(route_target "$region" "$family" "${carriers[$index]}")")
  done
  files=(
    "${DIAG_ROUTE_DIR}/${region}-${family}-ct.json"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cu.json"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cm.json"
  )

  printf '\n%s【%s · %s 回程】%s\n' \
    "$C_BLUE" "$region_label" "${family/ipv/IPv}" "$C_RESET"
  for index in 0 1 2; do
    (
      run_nexttrace_probe \
        "$family" "$source_address" "${targets[$index]}" "${files[$index]}"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  for index in 0 1 2; do
    show_carrier_route_result \
      "$region" "$family" "${carriers[$index]}" "${labels[$index]}" \
      "${files[$index]}"
  done
}

mark_route_family_unavailable() {
  local region="$1" family="$2" reason="$3"
  local carrier key region_label
  local -a carriers=(ct cu cm)
  region_label="$(route_region_label "$region")"
  printf '\n%s【%s · %s 回程】%s\n' \
    "$C_BLUE" "$region_label" "${family/ipv/IPv}" "$C_RESET"
  printf '  [未测] %s\n' "$reason"
  for carrier in "${carriers[@]}"; do
    key="${region}:${family}:${carrier}"
    ROUTE_SUMMARY_STATUS["$key"]="failed"
    ((ROUTE_FAILED_COUNT += 1))
  done
  ((DIAG_SKIP_COUNT += 1))
}

show_route_region_summary() {
  local region="$1" region_label family carrier label key
  local -a families=(ipv4 ipv6)
  local -a carriers=(ct cu cm) labels=(电信 联通 移动)
  local index status latency judgment

  region_label="$(route_region_label "$region")"
  printf '\n%s【%s · 本次延迟结论】%s\n' \
    "$C_BLUE" "$region_label" "$C_RESET"
  for family in "${families[@]}"; do
    if [[ "$family" == ipv4 ]]; then
      network_mode_has_ipv4 "$NETWORK_MODE" || continue
    else
      network_mode_has_ipv6 "$NETWORK_MODE" || continue
    fi
    for index in 0 1 2; do
      carrier="${carriers[$index]}"
      label="${labels[$index]}"
      key="${region}:${family}:${carrier}"
      status="${ROUTE_SUMMARY_STATUS[$key]:-failed}"
      if [[ "$status" == ok ]]; then
        latency="${ROUTE_SUMMARY_LATENCY[$key]:-未知}"
        judgment="${ROUTE_SUMMARY_LINE[$key]:-线路未知}"
        [[ "$latency" == 未知 ]] || latency+=" ms"
        printf '  %s %s：%s，%s\n' \
          "${family/ipv/IPv}" "$label" "$latency" "$judgment"
      else
        printf '  %s %s：本次未测到有效结果\n' \
          "${family/ipv/IPv}" "$label"
      fi
    done
  done
}

show_route_report_summary() {
  ROUTE_REPORT_HAS_SUMMARY=1
  printf '\n%s========== 线路测试小结 ==========%s\n' \
    "$C_BLUE" "$C_RESET"
  printf '  已完成 %d 条，未完成 %d 条。\n' \
    "$ROUTE_COMPLETED_COUNT" "$ROUTE_FAILED_COUNT"
  printf '  回程：已按所选地区测试（VPS → 国内参考目标）。\n'
  printf '  去程：未测试；它需要国内探针主动访问这台 VPS。\n'
  printf '  “末跳”是最后一个有响应路由节点的本次样本，不等同于带宽或晚高峰速度。\n'
  printf '  ASN 只能辅助识别骨干；AS4809 不能单独证明 CN2 GT 或 GIA。\n'
}

show_route_report() {
  local requested_region="${1:-$NEKO_DIAG_ROUTE_REGION}"
  local selected_region region separator=""
  local -a regions=()

  selected_region="$(normalize_route_region "$requested_region")" || {
    warn "不支持的线路地区：${requested_region}。可用值：gd、sh、bj、sc、hb、ln、all。"
    return 2
  }
  if [[ "$selected_region" == all ]]; then
    regions=(gd sh bj sc hb ln)
  else
    regions=("$selected_region")
  fi
  ROUTE_COMPLETED_COUNT=0
  ROUTE_FAILED_COUNT=0
  ROUTE_REPORT_HAS_SUMMARY=0
  ROUTE_SUMMARY_LATENCY=()
  ROUTE_SUMMARY_LINE=()
  ROUTE_SUMMARY_STATUS=()

  printf '\n%s========== Neko 三网线路检测 ==========%s\n' \
    "$C_BLUE" "$C_RESET"
  if ! load_diag_state; then
    diag_skip "没有可用的 Neko 安装状态，无法绑定已安装地址族。"
    return 0
  fi
  if [[ ! -x "$NEKO_DIAG_NEXTTRACE" ]]; then
    diag_skip "可选 NextTrace 组件不可用；安装与代理服务不受影响。"
    return 0
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    diag_skip "系统缺少 timeout，未运行有严格时限的线路测试。"
    return 0
  fi
  if [[ ! -d "$NEKO_DIAG_TMP_DIR" || ! -w "$NEKO_DIAG_TMP_DIR" ]]; then
    diag_skip "临时目录不可写，未运行线路测试。"
    return 0
  fi
  DIAG_ROUTE_DIR="$(
    mktemp -d "${NEKO_DIAG_TMP_DIR%/}/.neko-route.XXXXXX"
  )" || {
    DIAG_ROUTE_DIR=""
    diag_skip "无法创建线路测试临时目录。"
    return 0
  }

  printf '  测试地区：'
  for region in "${regions[@]}"; do
    printf '%s%s' "$separator" "$(route_region_label "$region")"
    separator="、"
  done
  printf '\n'
  printf '  测试方向：%s回程%s（这台 VPS → 国内三网参考目标）。\n' \
    "$C_GREEN" "$C_RESET"
  printf '  去程状态：%s未测试%s（需要国内探针 → 这台 VPS）。\n' \
    "$C_YELLOW" "$C_RESET"
  printf '  说明：结果只代表本次路径；失败会显示“未测”，不会修改或停止 Neko。\n'

  for region in "${regions[@]}"; do
    if network_mode_has_ipv4 "$NETWORK_MODE"; then
      if is_ipv4_literal "$SUBSCRIPTION_IPV4_ADDRESS" \
        && address_is_local ipv4 "$SUBSCRIPTION_IPV4_ADDRESS"; then
        show_carrier_routes_for_family \
          "$region" ipv4 "$SUBSCRIPTION_IPV4_ADDRESS"
      else
        mark_route_family_unavailable "$region" ipv4 \
          "IPv4 配置地址无效或已不属于本机。"
      fi
    fi
    if network_mode_has_ipv6 "$NETWORK_MODE"; then
      if is_ipv6_literal "$SUBSCRIPTION_IPV6_ADDRESS" \
        && address_is_local ipv6 "$SUBSCRIPTION_IPV6_ADDRESS"; then
        show_carrier_routes_for_family \
          "$region" ipv6 "$SUBSCRIPTION_IPV6_ADDRESS"
      else
        mark_route_family_unavailable "$region" ipv6 \
          "IPv6 配置地址无效或已不属于本机。"
      fi
    fi
    show_route_region_summary "$region"
  done
  rm -rf -- "$DIAG_ROUTE_DIR"
  DIAG_ROUTE_DIR=""
  show_route_report_summary
}

run_cpu_benchmark() {
  local seconds="$NEKO_DIAG_CPU_SECONDS" output speed_value numeric_speed
  if [[ ! "$seconds" =~ ^[0-9]+$ ]] || (( seconds < 1 || seconds > 30 )); then
    seconds=3
  fi
  diag_section "CPU 轻量测试"
  printf '  只占用一个 CPU 线程约 %d 秒；不会修改系统配置。\n' "$seconds"
  output="$(
    openssl speed -elapsed -seconds "$seconds" sha256 2>&1
  )" || {
    diag_warn "OpenSSL SHA-256 测试未完成；代理服务未受修改。"
    return 0
  }
  speed_value="$(
    awk '$1 == "sha256" {value=$NF} END {if (value != "") print value}' \
      <<< "$output"
  )"
  if [[ "$speed_value" =~ ^[0-9.]+k$ ]]; then
    numeric_speed="${speed_value%k}"
    numeric_speed="$(awk -v kib="$numeric_speed" 'BEGIN {printf "%.1f", kib / 1024}')"
    diag_fact "SHA-256 16KiB 块" "${numeric_speed} MiB/s"
    diag_ok "CPU 轻量测试完成。"
  else
    diag_warn "CPU 测试完成，但当前 OpenSSL 输出格式无法稳定解析。"
  fi
  printf '  这个数字只适合与相同 OpenSSL 命令比较，不是通用 CPU 排名。\n'
}

run_disk_benchmark() {
  local mib="$NEKO_DIAG_DISK_MIB" available_kib start_ns end_ns elapsed_ns
  local speed
  if [[ ! "$mib" =~ ^[0-9]+$ ]] || (( mib < 1 || mib > 1024 )); then
    mib=128
  fi
  diag_section "磁盘轻量写入测试"
  printf '  将在 %s 临时写入 %d MiB，并在完成或中断时删除。\n' \
    "$NEKO_DIAG_TMP_DIR" "$mib"
  [[ -d "$NEKO_DIAG_TMP_DIR" && -w "$NEKO_DIAG_TMP_DIR" ]] || {
    diag_warn "临时目录不可写，跳过磁盘测试：${NEKO_DIAG_TMP_DIR}"
    return 0
  }
  available_kib="$(
    df -Pk -- "$NEKO_DIAG_TMP_DIR" 2>/dev/null \
      | awk 'NR == 2 {print $4}'
  )"
  if [[ ! "$available_kib" =~ ^[0-9]+$ ]] \
    || (( available_kib < mib * 4 * 1024 )); then
    diag_warn "临时目录剩余空间不足以安全运行 ${mib} MiB 写入测试。"
    return 0
  fi

  DIAG_BENCH_FILE="$(
    mktemp "${NEKO_DIAG_TMP_DIR%/}/.neko-disk-bench.XXXXXX"
  )" || {
    diag_warn "无法创建磁盘测试临时文件。"
    return 0
  }
  start_ns="$(date +%s%N 2>/dev/null || true)"
  if ! dd if=/dev/zero of="$DIAG_BENCH_FILE" bs=1M count="$mib" \
    conv=fdatasync status=none 2>/dev/null; then
    diag_warn "磁盘写入测试未完成；正在清理临时文件。"
    diag_cleanup
    return 0
  fi
  end_ns="$(date +%s%N 2>/dev/null || true)"
  if [[ "$start_ns" =~ ^[0-9]+$ && "$end_ns" =~ ^[0-9]+$ ]] \
    && (( end_ns > start_ns )); then
    elapsed_ns=$((end_ns - start_ns))
    speed="$(
      awk -v mib="$mib" -v ns="$elapsed_ns" \
        'BEGIN {printf "%.1f", mib / (ns / 1000000000)}'
    )"
    diag_fact "顺序写入 + fdatasync" "${speed} MiB/s"
    diag_ok "磁盘轻量写入测试完成。"
  else
    diag_warn "磁盘写入完成，但系统计时器无法计算稳定速度。"
  fi
  diag_cleanup
  printf '  共享存储会随邻居负载波动；一次结果不能代表长期性能。\n'
}

run_benchmark_menu() {
  local choice answer
  while true; do
    clear 2>/dev/null || true
    printf '轻量性能测试（不会自动运行）\n'
    printf '============================\n'
    printf '1. CPU：单线程约 %s 秒\n' "$NEKO_DIAG_CPU_SECONDS"
    printf '2. 磁盘：临时写入 %s MiB\n' "$NEKO_DIAG_DISK_MIB"
    printf '3. CPU 与磁盘都测试\n'
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-3]：" choice
    case "$choice" in
      0|"") return 0 ;;
      1|2|3) ;;
      *)
        warn "请输入 0 到 3。"
        sleep 1
        continue
        ;;
    esac
    warn "性能测试会短时占用 CPU 或磁盘；不会停止或修改 Neko 服务。"
    read -r -p "输入 BENCH 确认运行：" answer
    [[ "$answer" == BENCH ]] || continue
    diag_reset_counts
    [[ "$choice" == 2 ]] || run_cpu_benchmark
    [[ "$choice" == 1 ]] || run_disk_benchmark
    diag_summary
    printf '\n'
    read -r -p "按 Enter 返回体检菜单……" _
  done
}

run_route_menu() {
  local choice selected_region answer region_text duration_text
  while true; do
    clear 2>/dev/null || true
    printf '%sNeko 三网回程线路检测%s\n' "$C_BLUE" "$C_RESET"
    printf '========================\n'
    printf '1. 广东（默认，适合香港/华南 VPS）\n'
    printf '2. 上海（华东）\n'
    printf '3. 北京（华北）\n'
    printf '4. 四川（西南，双栈省级目标）\n'
    printf '5. 全部地区（六地）\n'
    printf '6. 湖北（华中，双栈省级目标）\n'
    printf '7. 辽宁（东北，双栈省级目标）\n'
    printf '0. 返回\n\n'
    printf '说明：本机只能可靠测试回程（VPS → 国内）；去程需要国内探针。\n\n'
    read -r -p "请选择 [0-7]：" choice
    case "$choice" in
      0) return 0 ;;
    esac
    selected_region="$(normalize_route_region "$choice")" || {
      warn "请输入 0 到 7。"
      sleep 1
      continue
    }
    if [[ "$selected_region" == all ]]; then
      region_text="广东、上海、北京、四川、湖北、辽宁"
      duration_text="全部六地双栈在连续超时时可能接近 7 分钟"
    else
      region_text="$(route_region_label "$selected_region")"
      duration_text="通常需要几十秒"
    fi
    warn "将从 VPS 向${region_text}三网目标发送少量 TCP 探测包；${duration_text}，不会修改服务。"
    read -r -p "输入 ROUTE 确认运行：" answer
    [[ "$answer" == ROUTE ]] || continue
    run_report routes "$selected_region"
    printf '\n'
    read -r -p "按 Enter 返回线路地区菜单……" _
  done
}

run_report() {
  local mode="$1" route_region="${2:-$NEKO_DIAG_ROUTE_REGION}"
  diag_reset_counts
  case "$mode" in
    system)
      show_system_report
      ;;
    neko)
      show_neko_report
      ;;
    network)
      show_network_report
      ;;
    routes)
      show_route_report "$route_region" || return $?
      if (( ROUTE_REPORT_HAS_SUMMARY == 0 )); then
        diag_summary
      fi
      return 0
      ;;
    full)
      show_system_report
      show_neko_report
      show_network_report
      ;;
  esac
  diag_summary
}

interactive_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '%sNeko VPS 硬件、IP 与网络体检%s\n' \
      "$C_BLUE" "$C_RESET"
    printf '========================\n'
    printf '1. 一键完整体检（推荐，只读）\n'
    printf '2. 只看系统与硬件（离线、只读）\n'
    printf '3. 只查 Neko、IP 质量与 BGP（联网、只读）\n'
    printf '4. 真实三网线路（约几十秒，明确确认后运行）\n'
    printf '5. 轻量性能测试（明确确认后才运行）\n'
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-5]：" choice
    case "$choice" in
      0|"") return 0 ;;
      1) run_report full ;;
      2) run_report system ;;
      3)
        diag_reset_counts
        show_neko_report
        show_network_report
        diag_summary
        ;;
      4)
        run_route_menu
        continue
        ;;
      5)
        run_benchmark_menu
        continue
        ;;
      *)
        warn "请输入 0 到 5。"
        sleep 1
        continue
        ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回体检菜单……" _
  done
}

usage() {
  cat <<'EOF'
用法：diagnostics.sh [选项]

  --system          只显示离线系统与硬件信息
  --neko            只检查 Neko 服务与证书
  --network         检查已安装地址族、IP 质量与 BGP 注册
  --routes [地区]   运行三网回程测试：gd、sh、bj、sc、hb、ln 或 all（默认 gd）
  --full            完整只读体检（不运行性能测试）
  --benchmark-cpu   运行明确请求的轻量 CPU 测试
  --benchmark-disk  运行明确请求的轻量磁盘测试
  -h, --help        显示帮助

不提供选项时打开交互菜单。三网线路和性能测试都不会包含在 --full 中。
EOF
}

main() {
  local route_region
  case "${1:-}" in
    "") interactive_menu ;;
    --system) run_report system ;;
    --neko) run_report neko ;;
    --network) run_report network ;;
    --routes)
      if (( $# > 2 )); then
        usage >&2
        return 2
      fi
      route_region="$(
        normalize_route_region "${2:-$NEKO_DIAG_ROUTE_REGION}"
      )" || {
        warn "线路地区只能是 gd、sh、bj、sc、hb、ln 或 all。"
        return 2
      }
      run_report routes "$route_region"
      ;;
    --full) run_report full ;;
    --benchmark-cpu)
      diag_reset_counts
      run_cpu_benchmark
      diag_summary
      ;;
    --benchmark-disk)
      diag_reset_counts
      run_disk_benchmark
      diag_summary
      ;;
    -h|--help) usage ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
