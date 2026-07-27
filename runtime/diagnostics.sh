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
NEKO_DIAG_CPU_SECONDS="${NEKO_DIAG_CPU_SECONDS:-3}"
NEKO_DIAG_DISK_MIB="${NEKO_DIAG_DISK_MIB:-128}"
NEKO_DIAG_DNS_TIMEOUT="${NEKO_DIAG_DNS_TIMEOUT:-12}"
NEKO_DIAG_NETWORK_TIMEOUT="${NEKO_DIAG_NETWORK_TIMEOUT:-5}"

# shellcheck source=lib/common.sh
source "${NEKO_LIBEXEC}/lib/common.sh"

DIAG_OK_COUNT=0
DIAG_WARN_COUNT=0
DIAG_SKIP_COUNT=0
DIAG_BENCH_FILE=""

diag_cleanup() {
  local base="${NEKO_DIAG_TMP_DIR%/}"
  if [[ -n "$DIAG_BENCH_FILE" && -n "$base" \
    && "$DIAG_BENCH_FILE" == "$base"/.neko-disk-bench.* ]]; then
    rm -f -- "$DIAG_BENCH_FILE"
  fi
  DIAG_BENCH_FILE=""
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

show_routing_registration() {
  local family="$1" source_address="$2"
  local network_json prefix asns prefix_json holders announced
  local rpki_json rpki_status ptr observed_ip="$source_address"
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
  show_routing_registration "$family" "$address"
}

show_network_report() {
  local resolvers=""
  diag_section "严格网络、IP 与线路"
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

  printf '\n  说明：“原生 IP”没有统一、权威的公开字段。这里报告可核验的\n'
  printf '  出口 IP、ASN、BGP 前缀、PTR 与 RPKI，不用单一数据库硬下结论。\n'
  if network_mode_has_ipv4 "$NETWORK_MODE"; then
    show_family_network ipv4
  fi
  if network_mode_has_ipv6 "$NETWORK_MODE"; then
    show_family_network ipv6
  fi
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

run_report() {
  local mode="$1"
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
    printf 'VPS 硬件、IP 与网络体检\n'
    printf '========================\n'
    printf '1. 一键完整体检（推荐，只读）\n'
    printf '2. 只看系统与硬件（离线、只读）\n'
    printf '3. 只查 Neko、IPv4/IPv6、IP 与线路（联网、只读）\n'
    printf '4. 轻量性能测试（明确确认后才运行）\n'
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-4]：" choice
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
        run_benchmark_menu
        continue
        ;;
      *)
        warn "请输入 0 到 4。"
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
  --network         检查已安装地址族、出口与路由注册
  --full            完整只读体检（不运行性能测试）
  --benchmark-cpu   运行明确请求的轻量 CPU 测试
  --benchmark-disk  运行明确请求的轻量磁盘测试
  -h, --help        显示帮助

不提供选项时打开交互菜单。性能测试永远不会包含在 --full 中。
EOF
}

main() {
  case "${1:-}" in
    "") interactive_menu ;;
    --system) run_report system ;;
    --neko) run_report neko ;;
    --network) run_report network ;;
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
