#!/usr/bin/env bash

set -Eeuo pipefail
umask 0077

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_AKDNS_TEST_MODE="${NEKO_AKDNS_TEST_MODE:-0}"

if [[ "$NEKO_AKDNS_TEST_MODE" == "1" ]]; then
  AKDNS_SYSTEM_ROOT="${NEKO_AKDNS_SYSTEM_ROOT:-/}"
  AKDNS_TMP_BASE="${NEKO_AKDNS_TMP_BASE:-${TMPDIR:-/tmp}}"
  AKDNS_LOCK_FILE="${NEKO_AKDNS_LOCK_FILE:-${AKDNS_TMP_BASE%/}/neko-akdns.lock}"
  AKDNS_SYSTEMCTL="${NEKO_AKDNS_SYSTEMCTL:-systemctl}"
  AKDNS_TEST_SCRIPT="${NEKO_AKDNS_TEST_SCRIPT:-}"
  AKDNS_TEST_VALIDATOR="${NEKO_AKDNS_TEST_VALIDATOR:-}"
else
  # Test hooks must never be able to redirect a production DNS transaction.
  AKDNS_SYSTEM_ROOT="/"
  AKDNS_TMP_BASE="/var/tmp"
  AKDNS_LOCK_FILE="/run/lock/neko-maintenance.lock"
  AKDNS_SYSTEMCTL="systemctl"
  AKDNS_TEST_SCRIPT=""
  AKDNS_TEST_VALIDATOR=""
fi

export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_STATE

# shellcheck source=versions.env
source "${NEKO_LIBEXEC}/versions.env"
# shellcheck source=lib/common.sh
source "${NEKO_LIBEXEC}/lib/common.sh"

AKDNS_SOURCE_URL="https://raw.githubusercontent.com/akile-network/aktools/${AKDNS_SOURCE_COMMIT}/akdns.sh"
AKDNS_DATA_DIR="${NEKO_VAR}/akdns"
AKDNS_ORIGINAL_SNAPSHOT="${AKDNS_DATA_DIR}/pre-akdns"
AKDNS_STATUS_FILE="${AKDNS_DATA_DIR}/status"
AKDNS_TRANSACTION_DIR=""
AKDNS_TRANSACTION_ACTIVE=0
AKDNS_KEEP_TRANSACTION=0
AKDNS_DOWNLOADED_SCRIPT=""
AKDNS_LOCK_FD=""

declare -a AKDNS_OFFICIAL_SERVERS=(
  "66.66.66.66"
  "45.207.157.146"
  "108.160.138.51"
  "139.180.133.239"
  "45.76.83.113"
  "45.76.71.83"
  "45.63.99.176"
  "166.0.199.207"
)

system_path() {
  local path="$1"
  if [[ "$AKDNS_SYSTEM_ROOT" == "/" ]]; then
    printf '%s\n' "$path"
  else
    printf '%s%s\n' "${AKDNS_SYSTEM_ROOT%/}" "$path"
  fi
}

RESOLV_CONF="$(system_path /etc/resolv.conf)"
NSSWITCH_CONF="$(system_path /etc/nsswitch.conf)"
NETWORKMANAGER_CONF="$(system_path /etc/NetworkManager/conf.d/akdns-dns.conf)"
NSSWITCH_BACKUP="$(system_path /etc/nsswitch.conf.akdns.bak)"

assert_safe_paths() {
  local path
  [[ "$AKDNS_SYSTEM_ROOT" == /* && -d "$AKDNS_SYSTEM_ROOT" \
    && ! -L "$AKDNS_SYSTEM_ROOT" ]] \
    || die "AKDNS 系统根目录不安全；没有修改 DNS。"
  [[ "$AKDNS_TMP_BASE" == /* && -d "$AKDNS_TMP_BASE" \
    && "$AKDNS_TMP_BASE" != "/" ]] \
    || die "AKDNS 临时目录不安全；没有修改 DNS。"
  for path in "$NEKO_VAR" "$AKDNS_DATA_DIR"; do
    [[ "$path" == /* ]] || die "AKDNS 数据路径不是绝对路径；没有修改 DNS。"
    case "$path" in
      ""|/|/etc|/var|/var/lib|/usr|/usr/local|/usr/local/libexec|*"/../"*|*"/.."|*"/./"*|*"/."|*"//"*)
        die "AKDNS 数据路径不安全；没有修改 DNS。"
        ;;
    esac
  done
  [[ -d "$NEKO_VAR" && ! -L "$NEKO_VAR" ]] \
    || die "Neko 数据目录缺失或是符号链接；没有修改 DNS。"
  if [[ -e "$AKDNS_DATA_DIR" ]]; then
    [[ -d "$AKDNS_DATA_DIR" && ! -L "$AKDNS_DATA_DIR" ]] \
      || die "AKDNS 数据目录类型异常；没有修改 DNS。"
  fi
}

systemctl_akdns() {
  "$AKDNS_SYSTEMCTL" "$@"
}

service_active_state() {
  if systemctl_akdns is-active --quiet "$1" 2>/dev/null; then
    printf 'active\n'
  else
    printf 'inactive\n'
  fi
}

service_enabled_state() {
  local state
  state="$(systemctl_akdns is-enabled "$1" 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|disabled|masked|masked-runtime|static|indirect|generated|transient|alias)
      printf '%s\n' "$state"
      ;;
    *)
      printf 'not-found\n'
      ;;
  esac
}

file_is_immutable() {
  local attributes
  [[ -f "$1" && ! -L "$1" ]] || return 1
  command -v lsattr >/dev/null 2>&1 || return 1
  attributes="$(lsattr -d -- "$1" 2>/dev/null | awk 'NR == 1 {print $1}')"
  [[ "$attributes" == *i* ]]
}

clear_immutable() {
  [[ -e "$1" || -L "$1" ]] || return 0
  file_is_immutable "$1" || return 0
  command -v chattr >/dev/null 2>&1 || return 1
  chattr -i -- "$1" 2>/dev/null
}

set_immutable() {
  command -v chattr >/dev/null 2>&1 \
    || { warn "系统缺少 chattr，无法恢复 resolv.conf 的 immutable 属性。"; return 1; }
  chattr +i -- "$1"
}

capture_path() {
  local snapshot="$1" key="$2" path="$3" kind immutable=no
  if [[ -L "$path" ]]; then
    kind="symlink"
    printf '%s' "$(readlink -- "$path")" > "${snapshot}/${key}.link" \
      || return 1
  elif [[ -e "$path" ]]; then
    [[ -f "$path" ]] || {
      warn "系统文件 ${path} 不是普通文件或符号链接。"
      return 1
    }
    kind="file"
    cp -a -- "$path" "${snapshot}/${key}.file" || return 1
    file_is_immutable "$path" && immutable=yes
  else
    kind="absent"
  fi
  printf '%s\n' "$kind" > "${snapshot}/${key}.kind" || return 1
  printf '%s\n' "$immutable" > "${snapshot}/${key}.immutable" || return 1
}

capture_service() {
  local snapshot="$1" key="$2" service="$3"
  service_active_state "$service" > "${snapshot}/${key}.active"
  service_enabled_state "$service" > "${snapshot}/${key}.enabled"
}

capture_system_snapshot() {
  local snapshot="$1"
  install -d -m 0700 "$snapshot" || return 1
  printf '1\n' > "${snapshot}/format" || return 1
  capture_path "$snapshot" resolv "$RESOLV_CONF" || return 1
  capture_path "$snapshot" nsswitch "$NSSWITCH_CONF" || return 1
  capture_path "$snapshot" nsswitch_backup "$NSSWITCH_BACKUP" || return 1
  capture_path "$snapshot" networkmanager "$NETWORKMANAGER_CONF" || return 1
  capture_service "$snapshot" resolved systemd-resolved.service || return 1
  capture_service "$snapshot" resolvconf resolvconf.service || return 1
}

snapshot_is_valid() {
  local snapshot="$1" key kind immutable
  [[ -d "$snapshot" && ! -L "$snapshot" \
    && -f "$snapshot/format" && ! -L "$snapshot/format" \
    && "$(<"$snapshot/format")" == "1" ]] || return 1
  for key in resolv nsswitch nsswitch_backup networkmanager; do
    [[ -f "$snapshot/${key}.kind" && ! -L "$snapshot/${key}.kind" \
      && -f "$snapshot/${key}.immutable" \
      && ! -L "$snapshot/${key}.immutable" ]] \
      || return 1
    kind="$(<"$snapshot/${key}.kind")"
    immutable="$(<"$snapshot/${key}.immutable")"
    [[ "$immutable" == yes || "$immutable" == no ]] || return 1
    case "$kind" in
      file) [[ -f "$snapshot/${key}.file" && ! -L "$snapshot/${key}.file" ]] || return 1 ;;
      symlink) [[ -f "$snapshot/${key}.link" && ! -L "$snapshot/${key}.link" ]] || return 1 ;;
      absent) ;;
      *) return 1 ;;
    esac
  done
  for key in resolved resolvconf; do
    [[ -f "$snapshot/${key}.active" && ! -L "$snapshot/${key}.active" \
      && -f "$snapshot/${key}.enabled" \
      && ! -L "$snapshot/${key}.enabled" ]] \
      || return 1
    case "$(<"$snapshot/${key}.active")" in active|inactive) ;; *) return 1 ;; esac
  done
}

restore_path() {
  local snapshot="$1" key="$2" path="$3" kind immutable parent tmp
  kind="$(<"$snapshot/${key}.kind")"
  immutable="$(<"$snapshot/${key}.immutable")"
  parent="$(dirname -- "$path")"
  clear_immutable "$path" || return 1
  if [[ -d "$path" && ! -L "$path" ]]; then
    warn "拒绝用 DNS 备份覆盖异常目录：${path}"
    return 1
  fi
  rm -f -- "$path" || return 1
  case "$kind" in
    absent)
      ;;
    symlink)
      [[ ! -L "$parent" ]] || return 1
      [[ -d "$parent" ]] || mkdir -p -- "$parent" || return 1
      ln -s -- "$(<"$snapshot/${key}.link")" "$path" || return 1
      ;;
    file)
      [[ ! -L "$parent" ]] || return 1
      [[ -d "$parent" ]] || mkdir -p -- "$parent" || return 1
      tmp="${path}.neko-akdns-restore.$$"
      rm -f -- "$tmp" || return 1
      cp -a -- "$snapshot/${key}.file" "$tmp" || return 1
      mv -f -- "$tmp" "$path" || return 1
      ;;
    *)
      return 1
      ;;
  esac
  if [[ "$immutable" == yes ]]; then
    [[ -f "$path" && ! -L "$path" ]] || return 1
    set_immutable "$path"
  fi
}

restore_service() {
  local snapshot="$1" key="$2" service="$3" active enabled
  active="$(<"$snapshot/${key}.active")"
  enabled="$(<"$snapshot/${key}.enabled")"
  case "$enabled" in
    not-found)
      return 0
      ;;
    masked)
      systemctl_akdns mask "$service" >/dev/null 2>&1 || return 1
      ;;
    masked-runtime)
      systemctl_akdns mask --runtime "$service" >/dev/null 2>&1 || return 1
      ;;
    *)
      systemctl_akdns unmask "$service" >/dev/null 2>&1 || true
      case "$enabled" in
        enabled)
          systemctl_akdns enable "$service" >/dev/null 2>&1 || return 1
          ;;
        enabled-runtime)
          systemctl_akdns enable --runtime "$service" >/dev/null 2>&1 || return 1
          ;;
        disabled)
          systemctl_akdns disable "$service" >/dev/null 2>&1 || return 1
          ;;
        static|indirect|generated|transient|alias)
          ;;
      esac
      ;;
  esac
  case "$active" in
    active)
      if [[ "$service" == systemd-resolved.service ]]; then
        # A restart clears an AKDNS temporary `resolvectl dns` override.
        systemctl_akdns restart "$service" >/dev/null 2>&1 || return 1
      else
        systemctl_akdns start "$service" >/dev/null 2>&1 || return 1
      fi
      ;;
    inactive)
      systemctl_akdns stop "$service" >/dev/null 2>&1 || return 1
      ;;
  esac
}

reload_networkmanager_dns() {
  command -v nmcli >/dev/null 2>&1 || return 0
  systemctl_akdns is-active --quiet NetworkManager.service 2>/dev/null || return 0
  nmcli general reload >/dev/null 2>&1 || {
    warn "NetworkManager DNS 配置已恢复，但动态重载失败。"
    return 1
  }
}

restore_system_snapshot() {
  local snapshot="$1" restored=1
  snapshot_is_valid "$snapshot" || {
    warn "AKDNS 恢复快照不完整：${snapshot}"
    return 1
  }

  # Restore resolver managers before the exact resolv.conf object.  Starting
  # systemd-resolved first may otherwise replace the restored link or file.
  restore_path "$snapshot" nsswitch "$NSSWITCH_CONF" || restored=0
  restore_path "$snapshot" nsswitch_backup "$NSSWITCH_BACKUP" || restored=0
  restore_path "$snapshot" networkmanager "$NETWORKMANAGER_CONF" || restored=0
  restore_service "$snapshot" resolved systemd-resolved.service || restored=0
  restore_service "$snapshot" resolvconf resolvconf.service || restored=0
  restore_path "$snapshot" resolv "$RESOLV_CONF" || restored=0
  reload_networkmanager_dns || restored=0
  (( restored == 1 ))
}

path_fingerprint() {
  local label="$1" path="$2" hash attributes="-"
  if [[ -L "$path" ]]; then
    printf '%s\tsymlink\t%s\n' "$label" "$(readlink -- "$path")"
  elif [[ -f "$path" ]]; then
    hash="$(sha256sum -- "$path" | awk '{print $1}')"
    file_is_immutable "$path" && attributes=immutable
    printf '%s\tfile\t%s\t%s\t%s\n' \
      "$label" "$hash" "$(stat -c '%a:%u:%g' -- "$path")" "$attributes"
  elif [[ -e "$path" ]]; then
    printf '%s\tother\n' "$label"
  else
    printf '%s\tabsent\n' "$label"
  fi
}

system_fingerprint() {
  {
    path_fingerprint resolv "$RESOLV_CONF"
    path_fingerprint nsswitch "$NSSWITCH_CONF"
    path_fingerprint nsswitch_backup "$NSSWITCH_BACKUP"
    path_fingerprint networkmanager "$NETWORKMANAGER_CONF"
    printf 'resolved\t%s\t%s\n' \
      "$(service_active_state systemd-resolved.service)" \
      "$(service_enabled_state systemd-resolved.service)"
    printf 'resolvconf\t%s\t%s\n' \
      "$(service_active_state resolvconf.service)" \
      "$(service_enabled_state resolvconf.service)"
  } | sha256sum | awk '{print $1}'
}

is_official_server() {
  local candidate="$1" server
  for server in "${AKDNS_OFFICIAL_SERVERS[@]}"; do
    [[ "$candidate" != "$server" ]] || return 0
  done
  return 1
}

current_akdns_server() {
  local server count=0 selected=""
  [[ -f "$RESOLV_CONF" && ! -L "$RESOLV_CONF" ]] || return 1
  while IFS= read -r server; do
    [[ -n "$server" ]] || continue
    is_official_server "$server" || return 1
    selected="$server"
    ((count += 1))
  done < <(awk '$1 == "nameserver" {print $2}' "$RESOLV_CONF")
  (( count == 1 )) || return 1
  printf '%s\n' "$selected"
}

akdns_is_active() {
  current_akdns_server >/dev/null 2>&1
}

validate_neko_runtime() {
  local restart_services="${1:-0}" service
  if [[ "$NEKO_AKDNS_TEST_MODE" == "1" && -n "$AKDNS_TEST_VALIDATOR" ]]; then
    "$AKDNS_TEST_VALIDATOR" "$restart_services"
    return
  fi

  load_state
  if ! (check_strict_stack_dns "$DOMAIN" "$NETWORK_MODE" >/dev/null); then
    warn "AKDNS 切换后，Neko 的严格 A/AAAA 域名验证失败。"
    return 1
  fi
  "$NEKO_LIBEXEC/sing-box" check \
    -c "${NEKO_CONFIG_DIR}/sing-box.json" >/dev/null || return 1
  if network_mode_has_ipv4; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v4.json" >/dev/null || return 1
  fi
  if network_mode_has_ipv6; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v6.json" >/dev/null || return 1
  fi
  if network_mode_has_cross_routes; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v4-to-v6.json" >/dev/null || return 1
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v6-to-v4.json" >/dev/null || return 1
  fi
  "$NEKO_LIBEXEC/xray" run -test \
    -c "${NEKO_CONFIG_DIR}/xray.json" >/dev/null || return 1
  "$NEKO_LIBEXEC/caddy" validate \
    --config "${NEKO_CONFIG_DIR}/Caddyfile" --adapter caddyfile \
    >/dev/null || return 1

  if (( restart_services == 1 )); then
    systemctl_akdns restart \
      neko-caddy.service neko-sing-box.service neko-xray.service \
      neko-hysteria.service || return 1
    sleep "${NEKO_AKDNS_SERVICE_WAIT_SECONDS:-1}"
  fi
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    systemctl_akdns is-active --quiet "${service}.service" || return 1
  done
}

download_verified_akdns() {
  local target="$1" actual size
  if [[ "$NEKO_AKDNS_TEST_MODE" == "1" && -n "$AKDNS_TEST_SCRIPT" ]]; then
    [[ -f "$AKDNS_TEST_SCRIPT" && ! -L "$AKDNS_TEST_SCRIPT" ]] \
      || die "AKDNS 测试脚本不可读。"
    cp -- "$AKDNS_TEST_SCRIPT" "$target"
  else
    info "下载固定的 AKDNS ${AKDNS_VERSION}（${AKDNS_SOURCE_COMMIT:0:12}）……"
    curl --fail --location --silent --show-error \
      --retry 4 --connect-timeout 15 --max-time 180 \
      --speed-limit 1024 --speed-time 30 \
      --proto '=https' --tlsv1.2 \
      "$AKDNS_SOURCE_URL" --output "$target"
    actual="$(sha256sum -- "$target" | awk '{print $1}')"
    [[ "$actual" == "$AKDNS_SHA256" ]] \
      || die "AKDNS 下载内容的 SHA-256 不匹配；已拒绝执行。"
    size="$(stat -c '%s' -- "$target")"
    (( size >= 10000 && size <= 1048576 )) \
      || die "AKDNS 下载文件大小异常；已拒绝执行。"
  fi
  bash -n "$target" || die "AKDNS 脚本语法校验失败；已拒绝执行。"
  chmod 0700 "$target"
}

write_managed_status() {
  local server="$1" tmp
  install -d -m 0700 "$AKDNS_DATA_DIR" || return 1
  tmp="$(mktemp "${AKDNS_DATA_DIR}/.status.XXXXXX")" || return 1
  {
    printf 'version=%s\n' "$AKDNS_VERSION"
    printf 'source_commit=%s\n' "$AKDNS_SOURCE_COMMIT"
    printf 'resolver=%s\n' "$server"
    printf 'applied_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp" || return 1
  chmod 0600 "$tmp" || return 1
  mv -f -- "$tmp" "$AKDNS_STATUS_FILE" || return 1
}

save_original_snapshot() {
  local source="$1" staged
  [[ ! -e "$AKDNS_ORIGINAL_SNAPSHOT" ]] || return 0
  install -d -m 0700 "$AKDNS_DATA_DIR" || return 1
  staged="$(mktemp -d "${AKDNS_DATA_DIR}/.pre-akdns.XXXXXX")" || return 1
  if ! cp -a -- "$source/." "$staged/" \
      || ! snapshot_is_valid "$staged" \
      || ! mv -- "$staged" "$AKDNS_ORIGINAL_SNAPSHOT"; then
    rm -rf -- "$staged"
    return 1
  fi
}

clear_managed_snapshot() {
  [[ "$AKDNS_ORIGINAL_SNAPSHOT" == "$AKDNS_DATA_DIR/pre-akdns" \
    && "$AKDNS_DATA_DIR" != "/" ]] || return 1
  rm -rf -- "$AKDNS_ORIGINAL_SNAPSHOT" || return 1
  rm -f -- "$AKDNS_STATUS_FILE" || return 1
}

transaction_path_is_safe() {
  local base="${AKDNS_TMP_BASE%/}"
  [[ -n "$AKDNS_TRANSACTION_DIR" && "$base" != "/" \
    && "$AKDNS_TRANSACTION_DIR" == "$base"/neko-akdns.* \
    && -d "$AKDNS_TRANSACTION_DIR" && ! -L "$AKDNS_TRANSACTION_DIR" ]]
}

cleanup_transaction() {
  if [[ -n "$AKDNS_DOWNLOADED_SCRIPT" ]]; then
    rm -f -- "$AKDNS_DOWNLOADED_SCRIPT" || return 1
  fi
  AKDNS_DOWNLOADED_SCRIPT=""
  if [[ -n "$AKDNS_TRANSACTION_DIR" && "$AKDNS_KEEP_TRANSACTION" == "0" ]]; then
    if transaction_path_is_safe; then
      rm -rf -- "$AKDNS_TRANSACTION_DIR" || return 1
    else
      warn "AKDNS 临时目录路径异常，未自动清理：${AKDNS_TRANSACTION_DIR}"
      return 1
    fi
  fi
  AKDNS_TRANSACTION_DIR=""
}

release_lock() {
  [[ -n "$AKDNS_LOCK_FD" ]] || return 0
  flock -u "$AKDNS_LOCK_FD" 2>/dev/null || true
  exec {AKDNS_LOCK_FD}>&-
  AKDNS_LOCK_FD=""
}

rollback_transaction() {
  local restored=1 snapshot="${AKDNS_TRANSACTION_DIR}/before"
  set +e
  warn "AKDNS 操作未完成，正在恢复操作前的 DNS 与 Neko 服务……"
  restore_system_snapshot "$snapshot" || restored=0
  validate_neko_runtime 1 || restored=0
  AKDNS_TRANSACTION_ACTIVE=0
  if (( restored == 1 )); then
    warn "已恢复操作前的 DNS、resolver 服务和 Neko 服务。"
  else
    AKDNS_KEEP_TRANSACTION=1
    warn "自动恢复未完全成功；恢复快照保留在 ${snapshot}。"
    warn "请不要再次修改 DNS，并根据上方错误人工恢复。"
  fi
  set -e
  (( restored == 1 ))
}

finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if (( AKDNS_TRANSACTION_ACTIVE == 1 )); then
    rollback_transaction || rc=1
  fi
  cleanup_transaction || rc=1
  release_lock
  exit "$rc"
}

acquire_lock() {
  local lock_parent
  lock_parent="$(dirname -- "$AKDNS_LOCK_FILE")"
  [[ ! -L "$lock_parent" ]] || die "AKDNS 维护锁目录是符号链接。"
  [[ -d "$lock_parent" ]] || install -d -m 0755 "$lock_parent"
  exec {AKDNS_LOCK_FD}>"$AKDNS_LOCK_FILE"
  flock -n "$AKDNS_LOCK_FD" \
    || die "另一个 Neko 维护任务正在运行，请稍后重试。"
}

start_transaction() {
  AKDNS_TRANSACTION_DIR="$(mktemp -d "${AKDNS_TMP_BASE%/}/neko-akdns.XXXXXX")"
  transaction_path_is_safe || die "无法建立安全的 AKDNS 事务目录。"
  capture_system_snapshot "$AKDNS_TRANSACTION_DIR/before" \
    || die "无法备份当前 DNS；没有运行 AKDNS。"
  AKDNS_TRANSACTION_ACTIVE=1
}

commit_transaction() {
  AKDNS_TRANSACTION_ACTIVE=0
}

run_akdns() {
  local before_fingerprint after_fingerprint before_active=0 after_active=0
  local script_rc=0 server=""

  validate_neko_runtime 0 \
    || die "Neko 当前 DNS、配置或服务不健康；请先修复，未运行 AKDNS。"
  akdns_is_active && before_active=1
  before_fingerprint="$(system_fingerprint)"
  start_transaction

  AKDNS_DOWNLOADED_SCRIPT="${AKDNS_TRANSACTION_DIR}/akdns.sh"
  download_verified_akdns "$AKDNS_DOWNLOADED_SCRIPT"
  warn "即将进入 AKDNS 官方交互界面；它会修改整台 VPS 的系统 DNS。"
  warn '其中“流媒体解锁检测”还会运行 AKDNS 上游选择的另一份第三方脚本。'
  warn "需要还原时请退出上游界面，再用 Neko AKDNS 菜单的紧急恢复。"
  bash "$AKDNS_DOWNLOADED_SCRIPT" --lang zh || script_rc=$?
  (( script_rc == 0 )) || {
    warn "AKDNS 官方脚本退出码为 ${script_rc}。"
    return 1
  }

  after_fingerprint="$(system_fingerprint)"
  akdns_is_active && after_active=1
  if [[ "$before_fingerprint" == "$after_fingerprint" ]]; then
    validate_neko_runtime 0 || {
      warn "AKDNS 临时操作后的严格 DNS、配置或 Neko 服务验证失败。"
      return 1
    }
    commit_transaction
    ok "AKDNS 没有留下永久系统配置改动；Neko 验证通过。"
    return 0
  fi

  if (( before_active == 0 && after_active == 0 )); then
    warn "AKDNS 改动了 resolver，但结果不是已知的官方 AKDNS 配置。"
    return 1
  fi

  if (( before_active == 1 && after_active == 0 )) \
      && [[ -d "$AKDNS_ORIGINAL_SNAPSHOT" ]]; then
    info "使用 Neko 保存的精确快照恢复 AKDNS 启用前状态……"
    restore_system_snapshot "$AKDNS_ORIGINAL_SNAPSHOT" || return 1
  fi

  validate_neko_runtime 1 || {
    warn "AKDNS 改动后的严格 DNS、配置或 Neko 服务验证失败。"
    return 1
  }

  if (( after_active == 1 )); then
    server="$(current_akdns_server)" || return 1
    if (( before_active == 0 )); then
      save_original_snapshot "${AKDNS_TRANSACTION_DIR}/before" || {
        warn "无法持久保存 AKDNS 启用前快照。"
        return 1
      }
    fi
    if [[ -d "$AKDNS_ORIGINAL_SNAPSHOT" ]]; then
      write_managed_status "$server" || return 1
    fi
    commit_transaction
    ok "AKDNS ${AKDNS_VERSION} 已启用并通过 Neko 严格 DNS 与服务验证：${server}"
  else
    clear_managed_snapshot || return 1
    commit_transaction
    ok "AKDNS 已关闭；启用前的 DNS 与 resolver 服务状态已恢复并验证。"
  fi
}

restore_original() {
  [[ -d "$AKDNS_ORIGINAL_SNAPSHOT" ]] \
    || die "没有 Neko 管理的 AKDNS 启用前快照，无内容可恢复。"
  snapshot_is_valid "$AKDNS_ORIGINAL_SNAPSHOT" \
    || die "AKDNS 启用前快照不完整；拒绝继续覆盖系统 DNS。"
  start_transaction
  restore_system_snapshot "$AKDNS_ORIGINAL_SNAPSHOT" || return 1
  validate_neko_runtime 1 || {
    warn "恢复后的严格 DNS、配置或 Neko 服务验证失败。"
    return 1
  }
  clear_managed_snapshot || return 1
  commit_transaction
  ok "已恢复 AKDNS 启用前的精确 DNS 与 resolver 服务状态。"
}

show_status() {
  local server="" managed=no
  [[ -d "$AKDNS_ORIGINAL_SNAPSHOT" ]] && managed=yes
  server="$(current_akdns_server 2>/dev/null || true)"
  printf 'AKDNS 固定版本：%s\n' "$AKDNS_VERSION"
  printf '上游提交：%s\n' "$AKDNS_SOURCE_COMMIT"
  if [[ -n "$server" ]]; then
    printf '当前系统 DNS：AKDNS（%s）\n' "$server"
  else
    printf '当前系统 DNS：不是已知的官方 AKDNS 单服务器配置\n'
  fi
  if [[ "$managed" == yes ]]; then
    printf 'Neko 恢复快照：可用（%s）\n' "$AKDNS_ORIGINAL_SNAPSHOT"
  else
    printf 'Neko 恢复快照：无\n'
  fi
}

main() {
  require_root
  require_commands flock sha256sum awk stat cp mv rm install mktemp readlink
  assert_safe_paths
  install -d -m 0700 "$AKDNS_DATA_DIR"
  acquire_lock
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  case "${1:---run}" in
    --run)
      require_commands bash
      if [[ "$NEKO_AKDNS_TEST_MODE" != "1" || -z "$AKDNS_TEST_SCRIPT" ]]; then
        require_commands curl
      fi
      run_akdns
      ;;
    --restore)
      restore_original
      ;;
    --status)
      show_status
      ;;
    --managed)
      [[ -d "$AKDNS_ORIGINAL_SNAPSHOT" ]]
      ;;
    *)
      die "用法：$0 [--run|--restore|--status|--managed]"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
