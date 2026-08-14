#!/usr/bin/env bash

set -Eeuo pipefail

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
NEKO_PANEL_TMP_DIR="${NEKO_PANEL_TMP_DIR:-/var/tmp}"
NEKO_MAINTENANCE_LOCK_FILE="${NEKO_MAINTENANCE_LOCK_FILE:-/run/lock/neko-maintenance.lock}"
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

source "${NEKO_LIBEXEC}/lib/common.sh"
source "${NEKO_LIBEXEC}/lib/render.sh"
source "${NEKO_LIBEXEC}/lib/firewall.sh"

SYSCTL_FILE="${NEKO_BBR_SYSCTL_FILE:-/etc/sysctl.d/99-neko-bbr.conf}"
FAMILY_BACKUP_DIR=""
FAMILY_TRANSACTION_ACTIVE=0
declare -a FAMILY_FIREWALL_ADDED_ZONES=()
ACCESS_BACKUP_DIR=""
ACCESS_TRANSACTION_ACTIVE=0
BBR_BACKUP_DIR=""
BBR_TRANSACTION_ACTIVE=0
BBR_RELEASE_LOCK_ON_FINISH=0
BBR_SYSCTL_FILE_EXISTED=0
BBR_SYSCTL_TMP=""
BBR_SNAPSHOT_QDISC=""
BBR_SNAPSHOT_CC=""
BBR_SNAPSHOT_AVAILABLE_CC=""
BBR_SNAPSHOT_TCP_BBR_LOADED=false
BBR_SNAPSHOT_SCH_FQ_LOADED=false

family_restore_paths_are_safe() {
  local target
  for target in "$NEKO_ETC" "$NEKO_VAR/lego"; do
    [[ "$target" == /* ]] || return 1
    case "$target" in
      ""|/|/etc|/var|/var/lib|/usr|/usr/local|/usr/local/libexec)
        return 1
        ;;
      *"/../"*|*"/.."|*"/./"*|*"//"*)
        return 1
        ;;
    esac
  done
}

assert_family_source_trees() {
  family_restore_paths_are_safe \
    || die "地址族补装的恢复路径不安全；未修改现有安装。"
  [[ -d "$NEKO_ETC" && ! -L "$NEKO_ETC" ]] \
    || die "Neko 配置目录缺失或是符号链接；未开始补装。"
  [[ -d "$NEKO_VAR/lego" && ! -L "$NEKO_VAR/lego" ]] \
    || die "Neko 证书目录缺失或是符号链接；未开始补装。"
}

cleanup_family_backup() {
  local base="${NEKO_PANEL_TMP_DIR%/}"
  [[ -n "$FAMILY_BACKUP_DIR" ]] || return 0
  if [[ -n "$base" \
    && "$FAMILY_BACKUP_DIR" == "$base"/neko-family-backup.* ]] \
    && rm -rf -- "$FAMILY_BACKUP_DIR"; then
    FAMILY_BACKUP_DIR=""
    return 0
  fi
  return 1
}

acquire_maintenance_lock() {
  exec {MAINTENANCE_LOCK_FD}>"$NEKO_MAINTENANCE_LOCK_FILE"
  flock -n "$MAINTENANCE_LOCK_FD" \
    || die "另一个 Neko 维护任务正在运行，请稍后重试。"
}

release_maintenance_lock() {
  flock -u "$MAINTENANCE_LOCK_FD" 2>/dev/null || true
  exec {MAINTENANCE_LOCK_FD}>&-
}

remove_uninstall_files() {
  rm -f -- \
    /etc/systemd/system/neko-caddy.service \
    /etc/systemd/system/neko-sing-box.service \
    /etc/systemd/system/neko-xray.service \
    /etc/systemd/system/neko-hysteria.service \
    /etc/systemd/system/neko-renew.service \
    /etc/systemd/system/neko-renew.timer \
    /usr/local/bin/neko \
    /run/lock/neko-install.lock
  rm -rf -- /etc/neko /var/lib/neko /usr/local/libexec/neko
}

access_backup_path_is_safe() {
  local base="${NEKO_PANEL_TMP_DIR%/}"
  [[ -n "$base" && "$base" != "/" ]] || return 1
  [[ -n "$ACCESS_BACKUP_DIR" \
    && "$ACCESS_BACKUP_DIR" == "$base"/neko-access-backup.* \
    && -d "$ACCESS_BACKUP_DIR" \
    && ! -L "$ACCESS_BACKUP_DIR" ]]
}

cleanup_access_backup() {
  [[ -n "$ACCESS_BACKUP_DIR" ]] || return 0
  if access_backup_path_is_safe && rm -rf -- "$ACCESS_BACKUP_DIR"; then
    ACCESS_BACKUP_DIR=""
    return 0
  fi
  return 1
}

assert_access_source_tree() {
  local temp_base="${NEKO_PANEL_TMP_DIR%/}"
  [[ "$NEKO_ETC" == /* ]] \
    || die "订阅与节点凭据的配置路径不安全；没有修改任何内容。"
  case "$NEKO_ETC" in
    ""|/|/etc|*"/../"*|*"/.."|*"/./"*|*"/."|*"//"*)
      die "订阅与节点凭据的配置路径不安全；没有修改任何内容。"
      ;;
  esac
  [[ -d "$NEKO_ETC" && ! -L "$NEKO_ETC" ]] \
    || die "Neko 配置目录缺失或是符号链接；没有修改任何内容。"
  [[ -f "$NEKO_STATE" && ! -L "$NEKO_STATE" ]] \
    || die "Neko 安装状态缺失或是符号链接；没有修改任何内容。"
  [[ -d "$NEKO_CONFIG_DIR" && ! -L "$NEKO_CONFIG_DIR" ]] \
    || die "Neko 运行配置目录缺失或是符号链接；没有修改任何内容。"
  [[ -d "$NEKO_SUB_DIR" && ! -L "$NEKO_SUB_DIR" ]] \
    || die "Neko 订阅目录缺失或是符号链接；没有修改任何内容。"
  [[ "$temp_base" == /* && "$temp_base" != "/" ]] \
    || die "维护操作临时目录路径不安全；没有修改任何内容。"
  case "$temp_base" in
    *"/../"*|*"/.."|*"/./"*|*"/."|*"//"*)
      die "维护操作临时目录路径不安全；没有修改任何内容。"
      ;;
  esac
  [[ -d "$NEKO_PANEL_TMP_DIR" && -w "$NEKO_PANEL_TMP_DIR" ]] \
    || die "维护操作临时目录不可写：${NEKO_PANEL_TMP_DIR}"
}

rollback_access_transaction() {
  local rollback_ok=1
  set +e
  trap - EXIT INT TERM
  warn "订阅或节点凭据更新未完成，正在恢复原来的配置和服务……"

  if access_backup_path_is_safe; then
    cp -a -- "$ACCESS_BACKUP_DIR/etc/." "$NEKO_ETC/" || rollback_ok=0
  else
    rollback_ok=0
  fi
  validate_runtime_configs || rollback_ok=0
  restart_runtime_services || rollback_ok=0

  ACCESS_TRANSACTION_ACTIVE=0
  release_maintenance_lock
  if (( rollback_ok == 1 )); then
    if cleanup_access_backup; then
      warn "已恢复原来的订阅、节点凭据、配置和服务。"
    else
      rollback_ok=0
      warn "运行内容已恢复，但临时备份无法清理：${ACCESS_BACKUP_DIR}"
    fi
  else
    warn "自动恢复未完全成功；备份保留在 ${ACCESS_BACKUP_DIR}，请不要再次操作面板。"
  fi
  return "$((1 - rollback_ok))"
}

finish_access_transaction() {
  local rc=$?
  trap - EXIT INT TERM
  if (( ACCESS_TRANSACTION_ACTIVE == 1 )); then
    rollback_access_transaction || true
  fi
  exit "$rc"
}

validate_runtime_configs() {
  load_state
  runtime_validate_core_configs \
    --libexec-dir "$NEKO_LIBEXEC" --config-dir "$NEKO_CONFIG_DIR" \
    --subscription-dir "$NEKO_SUB_DIR" \
    --network-mode "$NETWORK_MODE" --output stdout-quiet
}

restart_runtime_services() {
  runtime_restart_service_set \
    --systemctl-command systemctl --wait-seconds 1 \
    -- "${NEKO_RUNTIME_SERVICES[@]}"
}

bbr_managed_sysctl_content() {
  printf '%s\n' \
    '# Managed by Neko. Removed, and previous live values restored, on uninstall.' \
    'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr'
}

bbr_sysctl_file_is_managed() {
  [[ -f "$SYSCTL_FILE" && ! -L "$SYSCTL_FILE" ]] || return 1
  [[ "$(<"$SYSCTL_FILE")" == "$(bbr_managed_sysctl_content)" ]]
}

bbr_module_is_loaded() {
  [[ -d "/sys/module/$1" ]]
}

bbr_current_qdisc() {
  sysctl -n net.core.default_qdisc 2>/dev/null
}

bbr_current_cc() {
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null
}

bbr_available_cc() {
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null
}

bbr_apply_sysctl_files() {
  sysctl --system >/dev/null
}

bbr_set_qdisc() {
  sysctl -w "net.core.default_qdisc=$1" >/dev/null
}

bbr_set_cc() {
  sysctl -w "net.ipv4.tcp_congestion_control=$1" >/dev/null
}

bbr_paths_are_safe() {
  local sysctl_parent temp_base
  sysctl_parent="${SYSCTL_FILE%/*}"
  temp_base="${NEKO_PANEL_TMP_DIR%/}"
  [[ "$SYSCTL_FILE" == /* && "$NEKO_STATE" == /* \
    && -n "$sysctl_parent" && "$sysctl_parent" != "/" \
    && "$temp_base" == /* && "$temp_base" != "/" ]] || return 1
  case "$SYSCTL_FILE:$NEKO_STATE:$temp_base" in
    *"/../"*|*"/..:"*|*"/.."|*"/./"*|*"/.:"*|*"/."|*"//"*) return 1 ;;
  esac
  [[ -d "$sysctl_parent" && ! -L "$sysctl_parent" \
    && -f "$NEKO_STATE" && ! -L "$NEKO_STATE" \
    && -d "$NEKO_PANEL_TMP_DIR" && -w "$NEKO_PANEL_TMP_DIR" ]]
}

bbr_backup_path_is_safe() {
  local temp_base="${NEKO_PANEL_TMP_DIR%/}"
  [[ -n "$temp_base" && "$temp_base" != "/" \
    && -n "$BBR_BACKUP_DIR" \
    && "$BBR_BACKUP_DIR" == "$temp_base"/neko-bbr-backup.* \
    && -d "$BBR_BACKUP_DIR" && ! -L "$BBR_BACKUP_DIR" ]]
}

cleanup_bbr_backup() {
  [[ -z "$BBR_SYSCTL_TMP" ]] || rm -f -- "$BBR_SYSCTL_TMP"
  BBR_SYSCTL_TMP=""
  [[ -n "$BBR_BACKUP_DIR" ]] || return 0
  if bbr_backup_path_is_safe && rm -rf -- "$BBR_BACKUP_DIR"; then
    BBR_BACKUP_DIR=""
    return 0
  fi
  return 1
}

bbr_capture_live_snapshot() {
  BBR_SNAPSHOT_QDISC="$(bbr_current_qdisc)" || return
  BBR_SNAPSHOT_CC="$(bbr_current_cc)" || return
  BBR_SNAPSHOT_AVAILABLE_CC="$(bbr_available_cc)" || return
  [[ -n "$BBR_SNAPSHOT_QDISC" && -n "$BBR_SNAPSHOT_CC" \
    && -n "$BBR_SNAPSHOT_AVAILABLE_CC" ]] || return 1
  if bbr_module_is_loaded tcp_bbr; then
    BBR_SNAPSHOT_TCP_BBR_LOADED=true
  else
    BBR_SNAPSHOT_TCP_BBR_LOADED=false
  fi
  if bbr_module_is_loaded sch_fq; then
    BBR_SNAPSHOT_SCH_FQ_LOADED=true
  else
    BBR_SNAPSHOT_SCH_FQ_LOADED=false
  fi
}

begin_bbr_transaction() {
  if ! BBR_BACKUP_DIR="$(
      mktemp -d "${NEKO_PANEL_TMP_DIR%/}/neko-bbr-backup.XXXXXX"
    )"; then
    BBR_BACKUP_DIR=""
    return 1
  fi
  if ! cp -a -- "$NEKO_STATE" "$BBR_BACKUP_DIR/state.json"; then
    cleanup_bbr_backup || true
    return 1
  fi
  BBR_SYSCTL_FILE_EXISTED=0
  if [[ -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" ]]; then
    if ! bbr_sysctl_file_is_managed \
      || ! cp -a -- "$SYSCTL_FILE" "$BBR_BACKUP_DIR/sysctl.conf"; then
      cleanup_bbr_backup || true
      return 1
    fi
    BBR_SYSCTL_FILE_EXISTED=1
  fi
  BBR_TRANSACTION_ACTIVE=1
  trap finish_bbr_transaction EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

bbr_write_managed_sysctl_file() {
  BBR_SYSCTL_TMP="$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")" || return
  bbr_managed_sysctl_content > "$BBR_SYSCTL_TMP" || return
  chmod 0644 "$BBR_SYSCTL_TMP" || return
  mv -f -- "$BBR_SYSCTL_TMP" "$SYSCTL_FILE" || return
  BBR_SYSCTL_TMP=""
}

bbr_remove_managed_sysctl_file() {
  rm -f -- "$SYSCTL_FILE"
}

bbr_restore_state_file() {
  local restore_tmp
  bbr_backup_path_is_safe \
    && [[ -f "$BBR_BACKUP_DIR/state.json" \
      && ! -L "$BBR_BACKUP_DIR/state.json" ]] || return 1
  [[ ! -L "$NEKO_STATE" ]] || return 1
  restore_tmp="$(mktemp "${NEKO_STATE}.bbr-restore.XXXXXX")" || return
  if ! cp -a -- "$BBR_BACKUP_DIR/state.json" "$restore_tmp" \
    || ! mv -f -- "$restore_tmp" "$NEKO_STATE"; then
    rm -f -- "$restore_tmp"
    return 1
  fi
}

bbr_restore_sysctl_file() {
  local restore_tmp
  bbr_backup_path_is_safe || return 1
  if (( BBR_SYSCTL_FILE_EXISTED == 1 )); then
    [[ -f "$BBR_BACKUP_DIR/sysctl.conf" \
      && ! -L "$BBR_BACKUP_DIR/sysctl.conf" \
      && ! -L "$SYSCTL_FILE" ]] || return 1
    restore_tmp="$(mktemp "${SYSCTL_FILE}.restore.XXXXXX")" || return
    if ! cp -a -- "$BBR_BACKUP_DIR/sysctl.conf" "$restore_tmp" \
      || ! mv -f -- "$restore_tmp" "$SYSCTL_FILE"; then
      rm -f -- "$restore_tmp"
      return 1
    fi
  elif [[ -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" ]]; then
    bbr_sysctl_file_is_managed || return 1
    rm -f -- "$SYSCTL_FILE" || return
  fi
}

bbr_load_snapshot_modules() {
  local ok=0
  if [[ "$BBR_SNAPSHOT_SCH_FQ_LOADED" == true ]] \
    && ! bbr_module_is_loaded sch_fq; then
    modprobe sch_fq 2>/dev/null || ok=1
  fi
  if [[ "$BBR_SNAPSHOT_TCP_BBR_LOADED" == true ]] \
    && ! bbr_module_is_loaded tcp_bbr; then
    modprobe tcp_bbr 2>/dev/null || ok=1
  fi
  return "$ok"
}

bbr_unload_extra_snapshot_modules() {
  local ok=0
  if [[ "$BBR_SNAPSHOT_TCP_BBR_LOADED" == false ]] \
    && bbr_module_is_loaded tcp_bbr; then
    modprobe -r tcp_bbr 2>/dev/null || ok=1
  fi
  if [[ "$BBR_SNAPSHOT_SCH_FQ_LOADED" == false ]] \
    && bbr_module_is_loaded sch_fq; then
    modprobe -r sch_fq 2>/dev/null || ok=1
  fi
  return "$ok"
}

bbr_restore_live_snapshot() {
  local ok=0
  bbr_set_qdisc "$BBR_SNAPSHOT_QDISC" || ok=1
  bbr_set_cc "$BBR_SNAPSHOT_CC" || ok=1
  return "$ok"
}

bbr_live_snapshot_matches() {
  [[ "$(bbr_current_qdisc)" == "$BBR_SNAPSHOT_QDISC" \
    && "$(bbr_current_cc)" == "$BBR_SNAPSHOT_CC" \
    && "$(bbr_available_cc)" == "$BBR_SNAPSHOT_AVAILABLE_CC" ]] || return
  if [[ "$BBR_SNAPSHOT_TCP_BBR_LOADED" == true ]]; then
    bbr_module_is_loaded tcp_bbr || return
  else
    ! bbr_module_is_loaded tcp_bbr || return
  fi
  if [[ "$BBR_SNAPSHOT_SCH_FQ_LOADED" == true ]]; then
    bbr_module_is_loaded sch_fq || return
  else
    ! bbr_module_is_loaded sch_fq || return
  fi
}

rollback_bbr_transaction() {
  local rollback_ok=1 sysctl_file_ok=1
  set +e
  trap - EXIT INT TERM
  warn "BBR 更新未完成，正在恢复原来的状态、sysctl 文件和内核值……"
  [[ -z "$BBR_SYSCTL_TMP" ]] || rm -f -- "$BBR_SYSCTL_TMP"
  BBR_SYSCTL_TMP=""

  bbr_restore_sysctl_file || {
    rollback_ok=0
    sysctl_file_ok=0
  }
  bbr_restore_state_file || rollback_ok=0
  bbr_load_snapshot_modules || rollback_ok=0
  if (( sysctl_file_ok == 1 )); then
    bbr_apply_sysctl_files || rollback_ok=0
  fi
  bbr_restore_live_snapshot || rollback_ok=0
  bbr_unload_extra_snapshot_modules || rollback_ok=0
  bbr_live_snapshot_matches || rollback_ok=0

  BBR_TRANSACTION_ACTIVE=0
  if (( BBR_RELEASE_LOCK_ON_FINISH == 1 )); then
    release_maintenance_lock
  fi
  if (( rollback_ok == 1 )); then
    if cleanup_bbr_backup; then
      warn "已恢复原来的 BBR 状态、sysctl 文件和内核值。"
    else
      rollback_ok=0
      warn "BBR 运行状态已恢复，但临时备份无法清理：${BBR_BACKUP_DIR}"
    fi
  else
    warn "BBR 自动恢复未完全成功；备份保留在 ${BBR_BACKUP_DIR}。"
  fi
  return "$((1 - rollback_ok))"
}

finish_bbr_transaction() {
  local rc=$?
  trap - EXIT INT TERM
  if (( BBR_TRANSACTION_ACTIVE == 1 )); then
    rollback_bbr_transaction || true
  fi
  exit "$rc"
}

abort_bbr_transaction() {
  local restored_message="$1" failed_message="$2"
  if rollback_bbr_transaction; then
    die "$restored_message"
  fi
  die "$failed_message"
}

complete_bbr_transaction() {
  BBR_TRANSACTION_ACTIVE=0
  trap - EXIT INT TERM
  cleanup_bbr_backup \
    || warn "BBR 操作已完成，但临时备份无法清理：${BBR_BACKUP_DIR}"
  if (( BBR_RELEASE_LOCK_ON_FINISH == 1 )); then
    release_maintenance_lock
  fi
}

bbr_recorded_module_state() {
  local key="$1"
  jq -r --arg key "$key" '
    if (.bbr | type) == "object" and (.bbr | has($key)) then
      .bbr[$key] | if . == true then "true" elif . == false then "false" else "null" end
    else "null" end
  ' "$NEKO_STATE"
}

bbr_validate_recorded_value() {
  local value="$1"
  [[ -z "$value" || "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

bbr_validate_recorded_available_cc() {
  [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_\ -]+$ ]]
}

bbr_load_modules_for_restore() {
  local tcp_bbr_state="$1" sch_fq_state="$2" ok=0
  if [[ "$sch_fq_state" == true ]] && ! bbr_module_is_loaded sch_fq; then
    modprobe sch_fq 2>/dev/null || ok=1
  fi
  if [[ "$tcp_bbr_state" == true ]] && ! bbr_module_is_loaded tcp_bbr; then
    modprobe tcp_bbr 2>/dev/null || ok=1
  fi
  return "$ok"
}

bbr_unload_modules_for_restore() {
  local tcp_bbr_state="$1" sch_fq_state="$2" ok=0
  if [[ "$tcp_bbr_state" == false ]] && bbr_module_is_loaded tcp_bbr; then
    modprobe -r tcp_bbr 2>/dev/null || ok=1
  fi
  if [[ "$sch_fq_state" == false ]] && bbr_module_is_loaded sch_fq; then
    modprobe -r sch_fq 2>/dev/null || ok=1
  fi
  return "$ok"
}

bbr_recorded_state_matches() {
  local qdisc="$1" cc="$2" available_cc="$3"
  local tcp_bbr_state="$4" sch_fq_state="$5"
  [[ -z "$qdisc" || "$(bbr_current_qdisc)" == "$qdisc" ]] || return
  [[ -z "$cc" || "$(bbr_current_cc)" == "$cc" ]] || return
  [[ -z "$available_cc" \
    || "$(bbr_available_cc)" == "$available_cc" ]] || return
  [[ "$tcp_bbr_state" != true ]] || bbr_module_is_loaded tcp_bbr || return
  [[ "$tcp_bbr_state" != false ]] || ! bbr_module_is_loaded tcp_bbr || return
  [[ "$sch_fq_state" != true ]] || bbr_module_is_loaded sch_fq || return
  [[ "$sch_fq_state" != false ]] || ! bbr_module_is_loaded sch_fq || return
}

enable_bbr() {
  local managed recorded_qdisc recorded_cc recorded_available_cc
  local recorded_tcp_bbr_loaded recorded_sch_fq_loaded available_cc
  BBR_RELEASE_LOCK_ON_FINISH=1
  acquire_maintenance_lock
  load_state
  bbr_paths_are_safe || {
    release_maintenance_lock
    die "BBR 事务路径不安全；没有修改状态、sysctl 文件或内核值。"
  }
  managed="$(jq -r '.bbr.managed // false' "$NEKO_STATE")"
  if [[ "$managed" != true && ( -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" ) ]]; then
    release_maintenance_lock
    die "${SYSCTL_FILE} 已存在但不是本工具管理的文件，拒绝覆盖。"
  fi
  if [[ "$managed" == true && ( -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" ) ]] \
    && ! bbr_sysctl_file_is_managed; then
    release_maintenance_lock
    die "${SYSCTL_FILE} 已被修改或替换，拒绝覆盖可能属于用户的文件。"
  fi
  if ! bbr_capture_live_snapshot; then
    release_maintenance_lock
    die "无法读取当前 qdisc、拥塞控制或可用算法；没有启用 BBR。"
  fi
  if [[ "$managed" != true && "$BBR_SNAPSHOT_CC" == bbr ]]; then
    release_maintenance_lock
    info "系统原本已启用 BBR；Neko 不会接管或写入状态和 sysctl 文件。"
    return 0
  fi
  if [[ "$managed" == true \
    && "$BBR_SNAPSHOT_QDISC" == fq && "$BBR_SNAPSHOT_CC" == bbr \
    && -e "$SYSCTL_FILE" ]] && bbr_sysctl_file_is_managed; then
    release_maintenance_lock
    ok "BBR 已由 Neko 管理并保持生效。"
    return 0
  fi

  if [[ "$managed" == true ]]; then
    recorded_qdisc="$(jq -r '.bbr.previous_qdisc // empty' "$NEKO_STATE")"
    recorded_cc="$(jq -r '.bbr.previous_congestion_control // empty' "$NEKO_STATE")"
    recorded_available_cc="$(
      jq -r '.bbr.previous_available_congestion_control // empty' "$NEKO_STATE"
    )"
    recorded_tcp_bbr_loaded="$(
      bbr_recorded_module_state previous_tcp_bbr_loaded
    )"
    recorded_sch_fq_loaded="$(
      bbr_recorded_module_state previous_sch_fq_loaded
    )"
  else
    recorded_qdisc="$BBR_SNAPSHOT_QDISC"
    recorded_cc="$BBR_SNAPSHOT_CC"
    recorded_available_cc="$BBR_SNAPSHOT_AVAILABLE_CC"
    recorded_tcp_bbr_loaded="$BBR_SNAPSHOT_TCP_BBR_LOADED"
    recorded_sch_fq_loaded="$BBR_SNAPSHOT_SCH_FQ_LOADED"
  fi
  if ! bbr_validate_recorded_value "$recorded_qdisc" \
    || ! bbr_validate_recorded_value "$recorded_cc" \
    || ! bbr_validate_recorded_available_cc "$recorded_available_cc"; then
    release_maintenance_lock
    die "BBR 恢复信息损坏；没有修改状态、sysctl 文件或内核值。"
  fi
  begin_bbr_transaction || {
    release_maintenance_lock
    die "无法创建 BBR 维护备份；没有修改状态、sysctl 文件或内核值。"
  }

  if ! bbr_module_is_loaded sch_fq; then
    modprobe sch_fq 2>/dev/null || true
  fi
  available_cc="$(bbr_available_cc)" || \
    abort_bbr_transaction \
      "无法读取 BBR 可用性，已恢复原状态。" \
      "无法读取 BBR 可用性，且自动恢复未完全成功。"
  if ! grep -qw bbr <<< "$available_cc"; then
    if ! modprobe tcp_bbr 2>/dev/null; then
      abort_bbr_transaction \
        "当前内核没有可用的 tcp_bbr 模块；已恢复原状态。" \
        "tcp_bbr 模块不可用，且自动恢复未完全成功。"
    fi
    available_cc="$(bbr_available_cc)" || \
      abort_bbr_transaction \
        "加载 tcp_bbr 后无法读取可用算法；已恢复原状态。" \
        "加载 tcp_bbr 后读取失败，且自动恢复未完全成功。"
  fi
  if ! grep -qw bbr <<< "$available_cc"; then
    abort_bbr_transaction \
      "当前内核没有公布 bbr 拥塞控制算法；已恢复原状态。" \
      "bbr 算法不可用，且自动恢复未完全成功。"
  fi
  bbr_write_managed_sysctl_file || \
    abort_bbr_transaction \
      "BBR sysctl 文件写入失败，已恢复原状态。" \
      "BBR sysctl 文件写入失败，且自动恢复未完全成功。"
  bbr_apply_sysctl_files || \
    abort_bbr_transaction \
      "sysctl --system 应用失败，已恢复原状态。" \
      "sysctl --system 应用失败，且自动恢复未完全成功。"
  if [[ "$(bbr_current_qdisc)" != fq \
    || "$(bbr_current_cc)" != bbr ]]; then
    abort_bbr_transaction \
      "BBR 即时内核值验证失败，已恢复原状态。" \
      "BBR 即时内核值验证失败，且自动恢复未完全成功。"
  fi
  if ! atomic_json_update \
      '.bbr = {
        managed: true,
        previous_qdisc: $qdisc,
        previous_congestion_control: $cc,
        previous_available_congestion_control: $available_cc,
        previous_tcp_bbr_loaded: $tcp_bbr_loaded,
        previous_sch_fq_loaded: $sch_fq_loaded
      }' \
      --arg qdisc "$recorded_qdisc" \
      --arg cc "$recorded_cc" \
      --arg available_cc "$recorded_available_cc" \
      --argjson tcp_bbr_loaded "$recorded_tcp_bbr_loaded" \
      --argjson sch_fq_loaded "$recorded_sch_fq_loaded"; then
    abort_bbr_transaction \
      "BBR 状态提交失败，已恢复原状态。" \
      "BBR 状态提交失败，且自动恢复未完全成功。"
  fi

  complete_bbr_transaction
  ok "已启用内核 tcp_bbr（通常称 BBRv1；具体实现由发行版内核决定）。"
}

restore_bbr() {
  [[ -r "$NEKO_STATE" ]] || return 0
  local managed previous_qdisc previous_cc previous_available_cc
  local previous_tcp_bbr_loaded previous_sch_fq_loaded
  BBR_RELEASE_LOCK_ON_FINISH=0
  managed="$(jq -r '.bbr.managed // false' "$NEKO_STATE")"
  [[ "$managed" == true ]] || return 0
  bbr_paths_are_safe \
    || die "BBR 恢复路径不安全；没有修改状态、sysctl 文件或内核值。"
  if [[ -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" ]]; then
    bbr_sysctl_file_is_managed \
      || die "${SYSCTL_FILE} 已被修改或替换，拒绝删除可能属于用户的文件。"
  fi
  previous_qdisc="$(jq -r '.bbr.previous_qdisc // empty' "$NEKO_STATE")"
  previous_cc="$(jq -r '.bbr.previous_congestion_control // empty' "$NEKO_STATE")"
  previous_available_cc="$(
    jq -r '.bbr.previous_available_congestion_control // empty' "$NEKO_STATE"
  )"
  previous_tcp_bbr_loaded="$(
    bbr_recorded_module_state previous_tcp_bbr_loaded
  )"
  previous_sch_fq_loaded="$(
    bbr_recorded_module_state previous_sch_fq_loaded
  )"
  if ! bbr_validate_recorded_value "$previous_qdisc" \
    || ! bbr_validate_recorded_value "$previous_cc" \
    || ! bbr_validate_recorded_available_cc "$previous_available_cc" \
    || [[ "$previous_tcp_bbr_loaded" != true \
      && "$previous_tcp_bbr_loaded" != false \
      && "$previous_tcp_bbr_loaded" != null ]] \
    || [[ "$previous_sch_fq_loaded" != true \
      && "$previous_sch_fq_loaded" != false \
      && "$previous_sch_fq_loaded" != null ]]; then
    die "BBR 恢复信息损坏；没有修改状态、sysctl 文件或内核值。"
  fi
  bbr_capture_live_snapshot \
    || die "无法读取当前 BBR 内核状态；没有开始恢复。"
  begin_bbr_transaction \
    || die "无法创建 BBR 恢复备份；没有修改状态、sysctl 文件或内核值。"

  if [[ -e "$SYSCTL_FILE" ]]; then
    bbr_remove_managed_sysctl_file || \
      abort_bbr_transaction \
        "无法删除 Neko BBR 文件，已恢复原状态。" \
        "无法删除 Neko BBR 文件，且自动恢复未完全成功。"
  fi
  bbr_apply_sysctl_files || \
    abort_bbr_transaction \
      "BBR 恢复时 sysctl --system 失败，已恢复原状态。" \
      "BBR 恢复时 sysctl --system 失败，且自动恢复未完全成功。"
  bbr_load_modules_for_restore \
      "$previous_tcp_bbr_loaded" "$previous_sch_fq_loaded" || \
    abort_bbr_transaction \
      "原内核模块重新加载失败，已恢复 Neko BBR 状态。" \
      "原内核模块重新加载失败，且自动恢复未完全成功。"
  if [[ -n "$previous_qdisc" ]] && ! bbr_set_qdisc "$previous_qdisc"; then
    abort_bbr_transaction \
      "原 qdisc 恢复失败，已恢复 Neko BBR 状态。" \
      "原 qdisc 恢复失败，且自动恢复未完全成功。"
  fi
  if [[ -n "$previous_cc" ]] && ! bbr_set_cc "$previous_cc"; then
    abort_bbr_transaction \
      "原拥塞控制恢复失败，已恢复 Neko BBR 状态。" \
      "原拥塞控制恢复失败，且自动恢复未完全成功。"
  fi
  bbr_unload_modules_for_restore \
      "$previous_tcp_bbr_loaded" "$previous_sch_fq_loaded" || \
    abort_bbr_transaction \
      "原内核模块状态恢复失败，已恢复 Neko BBR 状态。" \
      "原内核模块状态恢复失败，且自动恢复未完全成功。"
  bbr_recorded_state_matches \
      "$previous_qdisc" "$previous_cc" "$previous_available_cc" \
      "$previous_tcp_bbr_loaded" "$previous_sch_fq_loaded" || \
    abort_bbr_transaction \
      "原 BBR 内核值验证失败，已恢复 Neko BBR 状态。" \
      "原 BBR 内核值验证失败，且自动恢复未完全成功。"
  if ! atomic_json_update \
      '.bbr = {
        managed: false,
        previous_qdisc: "",
        previous_congestion_control: ""
      }'; then
    abort_bbr_transaction \
      "BBR 恢复状态提交失败，已恢复 Neko BBR 状态。" \
      "BBR 恢复状态提交失败，且自动恢复未完全成功。"
  fi

  complete_bbr_transaction
}

rotate_subscription() {
  local answer choice candidate existing
  local new_ipv4_token="" new_ipv6_token=""
  local new_ipv4_to_ipv6_token="" new_ipv6_to_ipv4_token=""
  local rotate_ipv4=0 rotate_ipv6=0
  local has_cross=false
  local -a new_tokens=() old_tokens=()
  load_state
  printf '此操作只让所选地址族的旧下载 URL 失效，不会撤销已经导入客户端的节点凭据。\n\n'
  printf '1. 重置 IPv4 入口的订阅 URL\n'
  printf '2. 重置 IPv6 入口的订阅 URL\n'
  printf '3. 同时重置全部入口的订阅 URL\n'
  printf '0. 返回\n'
  read -r -p "请选择 [0-3]：" choice
  case "$choice" in
    0|"") return 0 ;;
    1)
      if ! network_mode_has_ipv4; then
        info "IPv4 尚未安装，没有 IPv4 订阅 URL 可重置。"
        return 0
      fi
      rotate_ipv4=1
      ;;
    2)
      if ! network_mode_has_ipv6; then
        info "IPv6 尚未安装，没有 IPv6 订阅 URL 可重置。"
        return 0
      fi
      rotate_ipv6=1
      ;;
    3)
      if [[ "$NETWORK_MODE" == "$NETWORK_MODE_DUAL" ]]; then
        rotate_ipv4=1
        rotate_ipv6=1
      elif network_mode_has_ipv4; then
        warn "IPv6 尚未安装，没有 IPv6 订阅 URL。"
        read -r -p "是否只重置已安装的 IPv4 订阅 URL？[y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
        rotate_ipv4=1
      else
        warn "IPv4 尚未安装，没有 IPv4 订阅 URL。"
        read -r -p "是否只重置已安装的 IPv6 订阅 URL？[y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
        rotate_ipv6=1
      fi
      ;;
    *)
      warn "请输入 0 到 3。"
      return 0
      ;;
  esac

  read -r -p "确认重置所选订阅 URL？[y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  acquire_maintenance_lock
  load_state
  assert_access_source_tree
  if (( rotate_ipv4 == 1 )) && ! network_mode_has_ipv4; then
    release_maintenance_lock
    die "IPv4 安装状态在确认期间发生变化；没有重置任何订阅 URL。"
  fi
  if (( rotate_ipv6 == 1 )) && ! network_mode_has_ipv6; then
    release_maintenance_lock
    die "IPv6 安装状态在确认期间发生变化；没有重置任何订阅 URL。"
  fi
  network_mode_has_cross_routes && has_cross=true

  (( rotate_ipv4 == 0 )) || new_ipv4_token="$(random_urlsafe 24)"
  (( rotate_ipv6 == 0 )) || new_ipv6_token="$(random_urlsafe 24)"
  if [[ "$has_cross" == true ]]; then
    (( rotate_ipv4 == 0 )) \
      || new_ipv4_to_ipv6_token="$(random_urlsafe 24)"
    (( rotate_ipv6 == 0 )) \
      || new_ipv6_to_ipv4_token="$(random_urlsafe 24)"
  fi

  old_tokens=(
    "$SUB_TOKEN_IPV4" "$SUB_TOKEN_IPV6"
    "$SUB_TOKEN_IPV4_TO_IPV6" "$SUB_TOKEN_IPV6_TO_IPV4"
  )
  (( rotate_ipv4 == 0 )) || new_tokens+=("$new_ipv4_token")
  (( rotate_ipv6 == 0 )) || new_tokens+=("$new_ipv6_token")
  if [[ "$has_cross" == true ]]; then
    (( rotate_ipv4 == 0 )) || new_tokens+=("$new_ipv4_to_ipv6_token")
    (( rotate_ipv6 == 0 )) || new_tokens+=("$new_ipv6_to_ipv4_token")
  fi
  for candidate in "${new_tokens[@]}"; do
    [[ -n "$candidate" ]] || {
      release_maintenance_lock
      die "随机生成了空订阅令牌；没有修改订阅 URL，请重新运行。"
    }
    for existing in "${old_tokens[@]}"; do
      if [[ -n "$existing" && "$candidate" == "$existing" ]]; then
        release_maintenance_lock
        die "随机生成的新订阅令牌与现有令牌意外相同；没有修改订阅 URL，请重新运行。"
      fi
    done
  done
  if (( ${#new_tokens[@]} != $(printf '%s\n' "${new_tokens[@]}" | sort -u | wc -l) )); then
    release_maintenance_lock
    die "随机生成的新订阅令牌意外重复；没有修改订阅 URL，请重新运行。"
  fi

  if ! ACCESS_BACKUP_DIR="$(
      mktemp -d "${NEKO_PANEL_TMP_DIR%/}/neko-access-backup.XXXXXX"
    )"; then
    ACCESS_BACKUP_DIR=""
    release_maintenance_lock
    die "无法创建维护备份；没有重置任何订阅 URL。"
  fi
  if ! cp -a -- "$NEKO_ETC" "$ACCESS_BACKUP_DIR/etc"; then
    cleanup_access_backup || true
    release_maintenance_lock
    die "无法完整备份当前配置；没有重置任何订阅 URL。"
  fi

  ACCESS_TRANSACTION_ACTIVE=1
  trap finish_access_transaction EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! atomic_json_update \
      'if $rotate_ipv4 then .subscription.ipv4_token = $ipv4_token else . end
       | if $rotate_ipv6 then .subscription.ipv6_token = $ipv6_token else . end
       | if ($has_cross and $rotate_ipv4) then
           .subscription.ipv4_to_ipv6_token = $ipv4_to_ipv6_token
         else . end
       | if ($has_cross and $rotate_ipv6) then
           .subscription.ipv6_to_ipv4_token = $ipv6_to_ipv4_token
         else . end' \
      --argjson rotate_ipv4 "$([[ $rotate_ipv4 == 1 ]] && printf true || printf false)" \
      --argjson rotate_ipv6 "$([[ $rotate_ipv6 == 1 ]] && printf true || printf false)" \
      --argjson has_cross "$has_cross" \
      --arg ipv4_token "$new_ipv4_token" \
      --arg ipv6_token "$new_ipv6_token" \
      --arg ipv4_to_ipv6_token "$new_ipv4_to_ipv6_token" \
      --arg ipv6_to_ipv4_token "$new_ipv6_to_ipv4_token"; then
    if rollback_access_transaction; then
      die "订阅令牌写入失败，已恢复原订阅、原配置和服务。"
    fi
    die "订阅令牌写入失败，且自动恢复未完全成功；请保留上方备份并停止继续操作。"
  fi

  if render_all \
    && validate_runtime_configs \
    && restart_runtime_services; then
    ACCESS_TRANSACTION_ACTIVE=0
    trap - EXIT INT TERM
    cleanup_access_backup \
      || warn "订阅 URL 已重置，但临时备份无法清理：${ACCESS_BACKUP_DIR}"
    release_maintenance_lock
    ok "所选订阅 URL 已重置；对应旧 URL 不可再访问。"
    show_subscription_links
    return 0
  fi

  if rollback_access_transaction; then
    die "订阅 URL 重置失败，已恢复原订阅、原配置和服务。"
  fi
  die "订阅 URL 重置失败，且自动恢复未完全成功；请保留上方备份并停止继续操作。"
}

rotate_node_credentials() {
  local rotate_urls="${1:-false}" confirmation
  local has_ipv4=false has_ipv6=false has_cross=false
  local has_anyreality=false
  local new_hy2_password new_hy2_obfs_password
  local new_tuic_uuid new_tuic_password new_ss_password
  local new_anytls_password new_trojan_password new_vision_uuid new_xhttp_uuid
  local new_anyreality_password="" new_anyreality_pair=""
  local new_anyreality_private="" new_anyreality_public="" new_anyreality_short_id=""
  local new_ipv4_token="" new_ipv6_token=""
  local new_ipv4_to_ipv6_token="" new_ipv6_to_ipv4_token=""

  case "$rotate_urls" in
    true|false) ;;
    *) die "内部节点凭据重置模式无效；没有修改任何内容。" ;;
  esac

  load_state
  if [[ "$rotate_urls" == true ]]; then
    warn "紧急全部换新会让旧订阅 URL 和全部已导入节点立即失效。"
    printf '完成后必须使用新链接重新添加或刷新所有客户端。\n'
    read -r -p "输入 REVOKE 确认紧急全部换新：" confirmation
    [[ "$confirmation" == REVOKE ]] || return 0
  else
    warn "此操作会重置全部已安装协议的节点凭据，并短暂重启代理服务。"
    printf '当前订阅 URL 保持不变；完成后必须在所有客户端刷新订阅。\n'
    read -r -p "输入 ROTATE 确认重置全部节点凭据：" confirmation
    [[ "$confirmation" == ROTATE ]] || return 0
  fi

  acquire_maintenance_lock
  load_state
  assert_access_source_tree
  network_mode_has_ipv4 && has_ipv4=true
  network_mode_has_ipv6 && has_ipv6=true
  network_mode_has_cross_routes && has_cross=true
  [[ "$ANYREALITY_ENABLED" == true ]] && has_anyreality=true

  new_hy2_password="$(random_urlsafe 24)"
  new_hy2_obfs_password="$(random_urlsafe 24)"
  new_tuic_uuid="$(new_uuid)"
  new_tuic_password="$(random_urlsafe 24)"
  new_ss_password="$(random_base64 16)"
  new_anytls_password="$(random_urlsafe 24)"
  new_trojan_password="$(random_urlsafe 24)"
  new_vision_uuid="$(new_uuid)"
  new_xhttp_uuid="$(new_uuid)"
  if [[ "$has_anyreality" == true ]]; then
    new_anyreality_pair="$(generate_anyreality_pair)" || {
      release_maintenance_lock
      die "无法生成 AnyReality REALITY 密钥；没有修改节点凭据。"
    }
    read -r new_anyreality_private new_anyreality_public <<< "$new_anyreality_pair"
    new_anyreality_password="$(random_urlsafe 24)"
    new_anyreality_short_id="$(random_hex 8)"
  fi
  if [[ "$rotate_urls" == true ]]; then
    [[ "$has_ipv4" != true ]] || new_ipv4_token="$(random_urlsafe 24)"
    [[ "$has_ipv6" != true ]] || new_ipv6_token="$(random_urlsafe 24)"
    [[ "$has_cross" != true ]] \
      || new_ipv4_to_ipv6_token="$(random_urlsafe 24)"
    [[ "$has_cross" != true ]] \
      || new_ipv6_to_ipv4_token="$(random_urlsafe 24)"
  fi
  if [[ "$new_hy2_password" == "$HY2_PASSWORD" \
    || "$new_hy2_obfs_password" == "$HY2_OBFS_PASSWORD" \
    || "$new_tuic_uuid" == "$TUIC_UUID" \
    || "$new_tuic_password" == "$TUIC_PASSWORD" \
    || "$new_ss_password" == "$SS_PASSWORD" \
    || "$new_anytls_password" == "$ANYTLS_PASSWORD" \
    || "$new_trojan_password" == "$TROJAN_PASSWORD" \
    || "$new_vision_uuid" == "$VISION_UUID" \
    || "$new_xhttp_uuid" == "$XHTTP_UUID" \
    || ( "$has_anyreality" == true \
      && "$new_anyreality_password" == "$ANYREALITY_PASSWORD" ) \
    || ( "$has_anyreality" == true \
      && "$new_anyreality_private" == "$ANYREALITY_PRIVATE_KEY" ) \
    || ( "$has_anyreality" == true \
      && "$new_anyreality_public" == "$ANYREALITY_PUBLIC_KEY" ) \
    || ( "$has_anyreality" == true \
      && "$new_anyreality_short_id" == "$ANYREALITY_SHORT_ID" ) \
    || ( "$rotate_urls" == true \
      && "$has_ipv4" == true \
      && "$new_ipv4_token" == "$SUB_TOKEN_IPV4" ) \
    || ( "$rotate_urls" == true \
      && "$has_ipv6" == true \
      && "$new_ipv6_token" == "$SUB_TOKEN_IPV6" ) \
    || ( "$rotate_urls" == true \
      && "$has_cross" == true \
      && "$new_ipv4_to_ipv6_token" == "$SUB_TOKEN_IPV4_TO_IPV6" ) \
    || ( "$rotate_urls" == true \
      && "$has_cross" == true \
      && "$new_ipv6_to_ipv4_token" == "$SUB_TOKEN_IPV6_TO_IPV4" ) ]]; then
    release_maintenance_lock
    die "随机生成的新值与旧值意外相同；没有修改订阅或节点凭据，请重新运行。"
  fi

  if ! ACCESS_BACKUP_DIR="$(
      mktemp -d "${NEKO_PANEL_TMP_DIR%/}/neko-access-backup.XXXXXX"
    )"; then
    ACCESS_BACKUP_DIR=""
    release_maintenance_lock
    die "无法创建维护备份；没有修改订阅或节点凭据。"
  fi
  if ! cp -a -- "$NEKO_ETC" "$ACCESS_BACKUP_DIR/etc"; then
    cleanup_access_backup || true
    release_maintenance_lock
    die "无法完整备份当前配置；没有修改订阅或节点凭据。"
  fi

  ACCESS_TRANSACTION_ACTIVE=1
  trap finish_access_transaction EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! atomic_json_update \
      '.credentials.hysteria2_password = $hy2_password
       | .credentials.hysteria2_obfs_password = $hy2_obfs_password
       | .credentials.tuic_uuid = $tuic_uuid
       | .credentials.tuic_password = $tuic_password
       | .credentials.ss2022_password = $ss_password
       | .credentials.anytls_password = $anytls_password
       | .credentials.trojan_password = $trojan_password
       | .credentials.vision_uuid = $vision_uuid
       | .credentials.xhttp_uuid = $xhttp_uuid
       | if $has_anyreality then
           .experimental.anyreality.password = $anyreality_password
           | .experimental.anyreality.private_key = $anyreality_private
           | .experimental.anyreality.public_key = $anyreality_public
           | .experimental.anyreality.short_id = $anyreality_short_id
         else . end
       | if ($rotate_urls and $has_ipv4) then
           .subscription.ipv4_token = $ipv4_token
         else . end
       | if ($rotate_urls and $has_ipv6) then
           .subscription.ipv6_token = $ipv6_token
         else . end
       | if ($rotate_urls and $has_cross) then
           .subscription.ipv4_to_ipv6_token = $ipv4_to_ipv6_token
           | .subscription.ipv6_to_ipv4_token = $ipv6_to_ipv4_token
         else . end' \
      --arg hy2_password "$new_hy2_password" \
      --arg hy2_obfs_password "$new_hy2_obfs_password" \
      --arg tuic_uuid "$new_tuic_uuid" \
      --arg tuic_password "$new_tuic_password" \
      --arg ss_password "$new_ss_password" \
      --arg anytls_password "$new_anytls_password" \
      --arg trojan_password "$new_trojan_password" \
      --arg vision_uuid "$new_vision_uuid" \
      --arg xhttp_uuid "$new_xhttp_uuid" \
      --arg anyreality_password "$new_anyreality_password" \
      --arg anyreality_private "$new_anyreality_private" \
      --arg anyreality_public "$new_anyreality_public" \
      --arg anyreality_short_id "$new_anyreality_short_id" \
      --argjson has_anyreality "$has_anyreality" \
      --argjson rotate_urls "$rotate_urls" \
      --argjson has_ipv4 "$has_ipv4" \
      --argjson has_ipv6 "$has_ipv6" \
      --argjson has_cross "$has_cross" \
      --arg ipv4_token "$new_ipv4_token" \
      --arg ipv6_token "$new_ipv6_token" \
      --arg ipv4_to_ipv6_token "$new_ipv4_to_ipv6_token" \
      --arg ipv6_to_ipv4_token "$new_ipv6_to_ipv4_token"; then
    ACCESS_TRANSACTION_ACTIVE=0
    trap - EXIT INT TERM
    cleanup_access_backup || true
    release_maintenance_lock
    die "无法写入新节点凭据；原状态和运行服务均未修改。"
  fi

  if render_all \
    && validate_runtime_configs \
    && restart_runtime_services; then
    ACCESS_TRANSACTION_ACTIVE=0
    trap - EXIT INT TERM
    cleanup_access_backup \
      || warn "节点已换新，但临时备份无法清理：${ACCESS_BACKUP_DIR}"
    release_maintenance_lock
    if [[ "$rotate_urls" == true ]]; then
      ok "旧订阅 URL 与旧节点凭据已全部失效。"
      warn "请删除客户端中的旧订阅，并使用下方新链接或二维码重新添加。"
    else
      ok "全部已安装协议的节点凭据已换新；订阅 URL 保持不变。"
      warn "请立即在所有客户端刷新订阅；手工导入的旧节点需要重新导入。"
    fi
    show_subscription_links
    return 0
  fi

  if rollback_access_transaction; then
    die "节点凭据更新失败，已恢复原订阅、原节点和服务。"
  fi
  die "节点凭据更新失败，且自动恢复未完全成功；请保留上方备份并停止继续操作。"
}

manage_subscription_access() {
  local choice
  load_state
  printf '当前网络：%s\n\n' "$(network_mode_label)"
  printf '1. 重置订阅 URL\n'
  printf '   旧链接失效，但已经导入的节点仍可使用。\n'
  printf '2. 重置全部节点凭据\n'
  printf '   旧节点失效，当前订阅 URL 保持不变。\n'
  printf '3. 紧急全部换新\n'
  printf '   旧订阅 URL 和旧节点全部失效。\n'
  printf '0. 返回\n'
  read -r -p "请选择 [0-3]：" choice
  case "$choice" in
    0|"") return 0 ;;
    1) rotate_subscription ;;
    2) rotate_node_credentials false ;;
    3) rotate_node_credentials true ;;
    *) warn "请输入 0 到 3。" ;;
  esac
}

refresh_subscription_endpoints() {
  local answer backup old_ipv4_address old_ipv6_address update_applied=0
  local changed=0
  load_state
  read -r -p "重新解析当前 $(network_mode_label) 地址并刷新 $(network_mode_link_count "$NETWORK_MODE") 份订阅？[y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  acquire_maintenance_lock
  load_state
  old_ipv4_address="$SUBSCRIPTION_IPV4_ADDRESS"
  old_ipv6_address="$SUBSCRIPTION_IPV6_ADDRESS"
  assert_network_mode_kernel "$NETWORK_MODE"
  check_strict_stack_dns "$DOMAIN" "$NETWORK_MODE"
  assert_strict_addresses_local "$NETWORK_MODE"

  if network_mode_has_ipv4 \
    && [[ "$SUBSCRIPTION_IPV4_ADDRESS" != "$old_ipv4_address" ]]; then
    changed=1
  fi
  if network_mode_has_ipv6 \
    && [[ "$SUBSCRIPTION_IPV6_ADDRESS" != "$old_ipv6_address" ]]; then
    changed=1
  fi
  if (( changed == 0 )); then
    release_maintenance_lock
    info "当前 $(network_mode_label) 端点没有变化；未修改配置，也没有重启服务。"
    return 0
  fi

  backup="$(mktemp "${NEKO_STATE}.backup.XXXXXX")"
  if ! cp -a -- "$NEKO_STATE" "$backup"; then
    rm -f -- "$backup"
    release_maintenance_lock
    die "无法备份安装状态；未修改地址和配置。"
  fi

  if atomic_json_update \
      'if $has_ipv4 then
         .subscription.ipv4_domain = $v4_domain
         | .subscription.ipv4_address = $v4_address
       else . end
       | if $has_ipv6 then
         .subscription.ipv6_domain = $v6_domain
         | .subscription.ipv6_address = $v6_address
       else . end' \
      --argjson has_ipv4 "$(network_mode_has_ipv4 && printf true || printf false)" \
      --argjson has_ipv6 "$(network_mode_has_ipv6 && printf true || printf false)" \
      --arg v4_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
      --arg v6_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
      --arg v4_address "$SUBSCRIPTION_IPV4_ADDRESS" \
      --arg v6_address "$SUBSCRIPTION_IPV6_ADDRESS"; then
    update_applied=1
  fi

  if (( update_applied == 1 )) \
    && render_all \
    && validate_runtime_configs \
    && restart_runtime_services; then
    rm -f -- "$backup"
    release_maintenance_lock
    ok "当前 $(network_mode_label) 端点与 $(network_mode_link_count "$NETWORK_MODE") 份订阅已刷新。"
    show_subscription_links
    return 0
  fi

  if (( update_applied == 0 )); then
    rm -f -- "$backup"
    release_maintenance_lock
    die "端点刷新失败；原状态和运行配置均未修改。"
  fi

  warn "端点刷新失败，正在恢复原地址、配置和服务……"
  if cp -a -- "$backup" "$NEKO_STATE" \
    && render_all \
    && validate_runtime_configs \
    && restart_runtime_services; then
    rm -f -- "$backup"
    release_maintenance_lock
    die "端点刷新失败，已恢复原地址和订阅。"
  fi

  release_maintenance_lock
  die "端点刷新失败，且自动恢复未完全成功；状态备份保留在 ${backup}。"
}

set_runtime_certificate_permissions() {
  runtime_set_lego_permissions \
    --lego-dir "$NEKO_VAR/lego" --service-user "$NEKO_USER" \
    --ownership managed --path-policy trusted
}

preflight_family_firewall_add() {
  local target_mode="$1" manager
  manager="$(jq -r '.firewall.manager // "none"' "$NEKO_STATE")"
  case "$manager" in
    firewalld)
      firewalld_is_active \
        || die "原安装由 firewalld 管理，但 firewalld 当前未运行；未开始补装。"
      [[ -s "$FIREWALLD_SERVICE_FILE" ]] \
        || die "Neko 的 firewalld 服务文件缺失；未开始补装。"
      ;;
    ufw)
      ufw_is_active \
        || die "原安装由 UFW 管理，但 UFW 当前未运行；未开始补装。"
      [[ -s "$UFW_PROFILE_FILE" ]] \
        || die "Neko 的 UFW 应用配置缺失；未开始补装。"
      if network_mode_has_ipv6 "$target_mode" \
        && [[ -r /etc/default/ufw ]] \
        && grep -Eq \
          '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*no[[:space:]]*$' \
          /etc/default/ufw; then
        die "UFW 已禁用 IPv6 规则管理；未开始补装 IPv6。请先设置 IPV6=yes 并重载 UFW。"
      fi
      ;;
    none) ;;
    *) die "state.json 中记录了未知防火墙管理器：${manager}" ;;
  esac
}

sync_firewall_for_family_add() {
  local manager zone old_zone
  local -a old_zones=() desired_zones=()
  manager="$(jq -r '.firewall.manager // "none"' "$NEKO_STATE")"
  case "$manager" in
    firewalld)
      mapfile -t old_zones < <(
        jq -r '.firewall.zones[]? // empty' "$NEKO_STATE"
      )
      if (( ${#old_zones[@]} == 0 )); then
        old_zone="$(jq -r '.firewall.zone // empty' "$NEKO_STATE")"
        [[ -z "$old_zone" ]] || old_zones=("$old_zone")
      fi
      mapfile -t desired_zones < <(firewalld_target_zones)
      (( ${#desired_zones[@]} > 0 )) \
        || die "无法确定补装地址族使用的 firewalld 区域。"
      for zone in "${desired_zones[@]}"; do
        if printf '%s\n' "${old_zones[@]}" | grep -Fxq -- "$zone"; then
          continue
        fi
        if firewall-cmd --permanent --zone="$zone" \
          --query-service=neko-proxy >/dev/null 2>&1; then
          # The rule already existed outside the state snapshot.  Record the
          # zone in state, but never claim ownership or remove it on rollback.
          continue
        fi
        firewall-cmd --permanent --zone="$zone" --add-service=neko-proxy \
          >/dev/null \
          || die "无法在 firewalld 区域 ${zone} 放行 Neko 服务。"
        FAMILY_FIREWALL_ADDED_ZONES+=("$zone")
      done
      write_firewalld_service_file
      firewall-cmd --reload >/dev/null \
        || die "补装地址族后 firewalld 重载失败。"
      for zone in "${desired_zones[@]}"; do
        firewall-cmd --zone="$zone" --query-service=neko-proxy >/dev/null \
          || die "firewalld 区域 ${zone} 的 Neko 规则未生效。"
      done
      set_firewall_manager firewalld "${desired_zones[@]}"
      ;;
    ufw)
      write_ufw_profile_file
      ufw app update NekoProxy >/dev/null \
        || die "补装地址族后 UFW 应用配置更新失败。"
      grep -Fq NekoProxy <<< "$(ufw status 2>/dev/null || true)" \
        || die "补装地址族后 UFW 的 NekoProxy 规则未生效。"
      ;;
    none) ;;
  esac
}

rollback_family_transaction() {
  local rollback_ok=1 zone service firewall_manager
  set +e
  trap - EXIT INT TERM
  warn "地址族补装未完成，正在恢复原来的安装状态……"

  if family_restore_paths_are_safe; then
    rm -rf -- "$NEKO_ETC"
    cp -a -- "$FAMILY_BACKUP_DIR/etc" "$NEKO_ETC" || rollback_ok=0
    rm -rf -- "$NEKO_VAR/lego"
    cp -a -- "$FAMILY_BACKUP_DIR/lego" "$NEKO_VAR/lego" || rollback_ok=0
  else
    rollback_ok=0
  fi

  firewall_manager="$(jq -r '.firewall.manager // "none"' "$NEKO_STATE" 2>/dev/null)"
  case "$firewall_manager" in
    firewalld)
      cp -a -- "$FAMILY_BACKUP_DIR/firewall-profile" \
        "$FIREWALLD_SERVICE_FILE" || rollback_ok=0
      if command -v firewall-cmd >/dev/null 2>&1; then
        for zone in "${FAMILY_FIREWALL_ADDED_ZONES[@]}"; do
          firewall-cmd --permanent --zone="$zone" --remove-service=neko-proxy \
            >/dev/null 2>&1 || rollback_ok=0
        done
        firewall-cmd --reload >/dev/null 2>&1 || rollback_ok=0
      else
        rollback_ok=0
      fi
      ;;
    ufw)
      cp -a -- "$FAMILY_BACKUP_DIR/firewall-profile" \
        "$UFW_PROFILE_FILE" || rollback_ok=0
      if command -v ufw >/dev/null 2>&1; then
        ufw app update NekoProxy >/dev/null 2>&1 || rollback_ok=0
      else
        rollback_ok=0
      fi
      ;;
    none) ;;
    *) rollback_ok=0 ;;
  esac

  systemctl restart \
    neko-caddy.service neko-sing-box.service neko-xray.service neko-hysteria.service \
    >/dev/null 2>&1 || rollback_ok=0
  sleep 1
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    systemctl is-active --quiet "${service}.service" || rollback_ok=0
  done

  FAMILY_TRANSACTION_ACTIVE=0
  release_maintenance_lock
  if (( rollback_ok == 1 )); then
    if cleanup_family_backup; then
      warn "已恢复补装前的地址族、证书、配置和服务；原订阅仍可使用。"
    else
      rollback_ok=0
      warn "安装内容已恢复，但临时备份无法清理：${FAMILY_BACKUP_DIR}"
    fi
  else
    warn "自动恢复未完全成功；备份保留在 ${FAMILY_BACKUP_DIR}，请不要再次操作面板。"
  fi
  return "$((1 - rollback_ok))"
}

finish_family_transaction() {
  local rc=$?
  trap - EXIT INT TERM
  if (( FAMILY_TRANSACTION_ACTIVE == 1 )); then
    rollback_family_transaction || true
  fi
  exit "$rc"
}

add_missing_address_family() {
  local requested="$1" answer old_mode target_mode
  local new_ipv4_token="" new_ipv6_token="" certificate_domain
  local new_ipv4_to_ipv6_token new_ipv6_to_ipv4_token
  local cross_hy2_start cross_hy2_end cross_tuic_port cross_ss_port
  local cross_anytls_port cross_trojan_port cross_vision_port cross_xhttp_port
  local cross_anyreality_port="null"
  local service
  local -a domain_args=()

  load_state
  old_mode="$NETWORK_MODE"
  case "$requested" in
    ipv4)
      if network_mode_has_ipv4; then
        info "IPv4 已经安装，订阅链接已经存在；没有修改任何内容。"
        show_subscription_links
        return 0
      fi
      ;;
    ipv6)
      if network_mode_has_ipv6; then
        info "IPv6 已经安装，订阅链接已经存在；没有修改任何内容。"
        show_subscription_links
        return 0
      fi
      ;;
    both)
      if [[ "$NETWORK_MODE" == "$NETWORK_MODE_DUAL" ]]; then
        info "IPv4 与 IPv6 都已经安装；没有修改任何内容。"
        show_subscription_links
        return 0
      fi
      ;;
    *) die "未知的地址族补装请求：${requested}" ;;
  esac

  target_mode="$NETWORK_MODE_DUAL"
  printf '\n当前模式：%s\n' "$(network_mode_label "$old_mode")"
  printf '补装后模式：%s\n' "$(network_mode_label "$target_mode")"
  warn "请先为基础域名补齐缺少的 A/AAAA，并为缺少的 v4/v6 专用域名添加唯一的直连记录。"
  if [[ "$ACME_METHOD" == "$ACME_METHOD_HTTP" ]]; then
    warn "当前证书使用 HTTP-01；新增地址族还必须能从公网访问本机 TCP 80。"
  fi
  read -r -p "DNS 已准备好，继续执行可回滚补装？[y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  acquire_maintenance_lock
  load_state
  [[ "$NETWORK_MODE" == "$old_mode" ]] \
    || die "安装状态在操作期间发生变化，请重新打开面板。"

  NETWORK_MODE="$target_mode"
  assert_network_mode_kernel "$NETWORK_MODE"
  check_strict_stack_dns "$DOMAIN" "$NETWORK_MODE"
  assert_strict_addresses_local "$NETWORK_MODE"
  preflight_family_firewall_add "$NETWORK_MODE"
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] \
    || die "现有证书文件缺失；未开始补装。"
  if [[ "$ACME_METHOD" == "$ACME_METHOD_CLOUDFLARE" ]]; then
    assert_cloudflare_dns_token_file
  fi
  assert_family_source_trees

  if network_mode_has_ipv4 "$old_mode"; then
    new_ipv4_token="$(jq -r '.subscription.ipv4_token' "$NEKO_STATE")"
  else
    new_ipv4_token="$(random_urlsafe 24)"
  fi
  if network_mode_has_ipv6 "$old_mode"; then
    new_ipv6_token="$(jq -r '.subscription.ipv6_token' "$NEKO_STATE")"
  else
    new_ipv6_token="$(random_urlsafe 24)"
  fi
  new_ipv4_to_ipv6_token="$(random_urlsafe 24)"
  new_ipv6_to_ipv4_token="$(random_urlsafe 24)"

  # Allocate everything before the rollback transaction starts.  A random
  # source or port-allocation failure must leave the current services alone.
  # Existing listeners are reserved explicitly as well as discovered through
  # ss, covering temporarily stopped services and minimal test environments.
  initialize_port_reservations
  reserve_loaded_proxy_ports "$old_mode"
  reserve_random_range 128 cross_hy2_start cross_hy2_end
  reserve_random_port cross_tuic_port
  reserve_random_port cross_ss_port
  reserve_random_port cross_anytls_port
  reserve_random_port cross_trojan_port
  reserve_random_port cross_vision_port
  reserve_random_port cross_xhttp_port
  if [[ "$ANYREALITY_ENABLED" == "true" ]]; then
    reserve_random_port cross_anyreality_port
  fi

  [[ -d "$NEKO_PANEL_TMP_DIR" && -w "$NEKO_PANEL_TMP_DIR" ]] \
    || die "地址族补装临时目录不可写：${NEKO_PANEL_TMP_DIR}"
  FAMILY_BACKUP_DIR="$(
    mktemp -d "${NEKO_PANEL_TMP_DIR%/}/neko-family-backup.XXXXXX"
  )"
  if ! cp -a -- "$NEKO_ETC" "$FAMILY_BACKUP_DIR/etc" \
    || ! cp -a -- "$NEKO_VAR/lego" "$FAMILY_BACKUP_DIR/lego"; then
    cleanup_family_backup || true
    release_maintenance_lock
    die "无法完整备份当前配置与证书；未开始补装。"
  fi
  case "$(jq -r '.firewall.manager // "none"' "$NEKO_STATE")" in
    firewalld)
      if ! cp -a -- \
          "$FIREWALLD_SERVICE_FILE" "$FAMILY_BACKUP_DIR/firewall-profile"; then
        cleanup_family_backup || true
        release_maintenance_lock
        die "无法备份 firewalld 配置；未开始补装。"
      fi
      ;;
    ufw)
      if ! cp -a -- "$UFW_PROFILE_FILE" "$FAMILY_BACKUP_DIR/firewall-profile"; then
        cleanup_family_backup || true
        release_maintenance_lock
        die "无法备份 UFW 配置；未开始补装。"
      fi
      ;;
  esac
  FAMILY_FIREWALL_ADDED_ZONES=()
  FAMILY_TRANSACTION_ACTIVE=1
  trap finish_family_transaction EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  atomic_json_update \
    '.network.mode = "dual"
     | .subscription.ipv4_token = $ipv4_token
     | .subscription.ipv6_token = $ipv6_token
     | .subscription.ipv4_domain = $ipv4_domain
     | .subscription.ipv6_domain = $ipv6_domain
     | .subscription.ipv4_address = $ipv4_address
     | .subscription.ipv6_address = $ipv6_address
     | .subscription.ipv4_to_ipv6_token = $ipv4_to_ipv6_token
     | .subscription.ipv6_to_ipv4_token = $ipv6_to_ipv4_token
     | .ports.cross = {
         hysteria2_start: $cross_hy2_start,
         hysteria2_end: $cross_hy2_end,
         tuic: $cross_tuic_port,
         ss2022: $cross_ss_port,
         anytls: $cross_anytls_port,
         trojan: $cross_trojan_port,
         vless_reality_vision: $cross_vision_port,
         vless_reality_xhttp: $cross_xhttp_port
       }
     | if $anyreality_enabled then
         .experimental.anyreality.cross_port = $cross_anyreality_port
       else . end' \
    --arg ipv4_token "$new_ipv4_token" \
    --arg ipv6_token "$new_ipv6_token" \
    --arg ipv4_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
    --arg ipv6_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
    --arg ipv4_address "$SUBSCRIPTION_IPV4_ADDRESS" \
    --arg ipv6_address "$SUBSCRIPTION_IPV6_ADDRESS" \
    --arg ipv4_to_ipv6_token "$new_ipv4_to_ipv6_token" \
    --arg ipv6_to_ipv4_token "$new_ipv6_to_ipv4_token" \
    --argjson cross_hy2_start "$cross_hy2_start" \
    --argjson cross_hy2_end "$cross_hy2_end" \
    --argjson cross_tuic_port "$cross_tuic_port" \
    --argjson cross_ss_port "$cross_ss_port" \
    --argjson cross_anytls_port "$cross_anytls_port" \
    --argjson cross_trojan_port "$cross_trojan_port" \
    --argjson cross_vision_port "$cross_vision_port" \
    --argjson cross_xhttp_port "$cross_xhttp_port" \
    --argjson anyreality_enabled "$ANYREALITY_ENABLED" \
    --argjson cross_anyreality_port "$cross_anyreality_port"

  load_state
  render_all
  validate_runtime_configs
  systemctl restart neko-caddy.service
  systemctl is-active --quiet neko-caddy.service \
    || die "Caddy 未能为新增域名启动。"

  if ! certificate_has_active_domains "$CERT_FILE"; then
    domain_args=()
    while IFS= read -r certificate_domain; do
      domain_args+=(--domains "$certificate_domain")
    done < <(active_certificate_domains)
    info "正在把证书安全扩展到新增地址族域名……"
    run_lego_acme "$NEKO_LIBEXEC/lego" webroot run \
      --path "$NEKO_VAR/lego" \
      --email "$ACME_EMAIL" \
      "${domain_args[@]}" \
      --accept-tos \
      --key-type EC256 \
      --force-cert-domains \
      --renew-force \
      --no-random-sleep
  fi
  certificate_has_active_domains "$CERT_FILE" \
    || die "扩展后的证书没有覆盖全部已安装域名。"
  openssl x509 -in "$CERT_FILE" -noout -checkend 604800 >/dev/null \
    || die "扩展后的证书有效期不足 7 天。"
  set_runtime_certificate_permissions

  sync_firewall_for_family_add
  render_all
  validate_runtime_configs
  restart_runtime_services || die "新增地址族后服务未保持运行。"
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    systemctl is-active --quiet "${service}.service" \
      || die "${service} 在补装后未保持运行。"
  done

  FAMILY_TRANSACTION_ACTIVE=0
  trap - EXIT INT TERM
  cleanup_family_backup \
    || warn "补装已成功，但临时备份无法清理：${FAMILY_BACKUP_DIR}"
  release_maintenance_lock
  ok "缺少的地址族已经补装完成；当前为 IPv4 + IPv6 双栈。"
  show_subscription_links
}

manage_address_families() {
  local choice
  load_state
  printf '当前安装状态：\n'
  if network_mode_has_ipv4; then
    printf '  IPv4：已安装\n'
  else
    printf '  IPv4：未安装\n'
  fi
  if network_mode_has_ipv6; then
    printf '  IPv6：已安装\n'
  else
    printf '  IPv6：未安装\n'
  fi
  printf '\n1. 添加 IPv4\n'
  printf '2. 添加 IPv6\n'
  printf '3. 添加 IPv4 与 IPv6\n'
  printf '0. 返回\n'
  read -r -p "请选择 [0-3]：" choice
  case "$choice" in
    0|"") return 0 ;;
    1) add_missing_address_family ipv4 ;;
    2) add_missing_address_family ipv6 ;;
    3) add_missing_address_family both ;;
    *) warn "请输入 0 到 3。" ;;
  esac
}

subscription_qr_menu() {
  local choice index route client route_label client_label url
  local -a qr_routes=() qr_clients=() qr_labels=()

  while true; do
    load_state
    qr_routes=()
    qr_clients=()
    qr_labels=()
    for route in ipv4 ipv6 ipv4-to-ipv6 ipv6-to-ipv4; do
      case "$route" in
        ipv4)
          network_mode_has_ipv4 || continue
          route_label='IPv4 → IPv4'
          ;;
        ipv6)
          network_mode_has_ipv6 || continue
          route_label='IPv6 → IPv6'
          ;;
        ipv4-to-ipv6)
          network_mode_has_cross_routes || continue
          route_label='IPv4 → IPv6'
          ;;
        ipv6-to-ipv4)
          network_mode_has_cross_routes || continue
          route_label='IPv6 → IPv4'
          ;;
      esac
      for client in mihomo stash shadowrocket sing-box; do
        client_label="$(subscription_client_label "$client")"
        qr_routes+=("$route")
        qr_clients+=("$client")
        qr_labels+=("${client_label} ${route_label}（严格）")
      done
    done

    clear 2>/dev/null || true
    printf '当前严格订阅链接\n'
    printf '================\n'
    show_subscription_links
    printf '订阅二维码（每次显示一个）：\n'
    for index in "${!qr_labels[@]}"; do
      printf '%d. %s\n' "$((index + 1))" "${qr_labels[$index]}"
    done
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-${#qr_labels[@]}]：" choice

    [[ -n "$choice" ]] || return 0
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      warn "请输入菜单中已有的数字。"
      sleep 1
      continue
    fi
    index=$((10#$choice))
    (( index != 0 )) || return 0
    if (( index < 1 || index > ${#qr_labels[@]} )); then
      warn "请输入 0 到 ${#qr_labels[@]}。"
      sleep 1
      continue
    fi
    index=$((index - 1))
    route="${qr_routes[$index]}"
    client="${qr_clients[$index]}"
    url="$(subscription_url "$route" "$client")" \
      || die "无法读取所选订阅链接；安装状态可能不完整。"

    clear 2>/dev/null || true
    printf '%s\n' "${qr_labels[$index]}"
    printf '%s\n' "$url"
    show_terminal_qr "$url"
    printf '\n可在 iPad 上截图后，用“照片”识别二维码；也可以直接复制上方链接。\n'
    read -r -p "按 Enter 返回订阅菜单……" _
  done
}

load_third_party_manifest() {
  local manifest="${NEKO_LIBEXEC}/versions.env"
  [[ -r "$manifest" ]] || {
    warn "缺少第三方入口版本清单：${manifest}"
    return 1
  }
  # Installed by Neko as a root-owned, non-writable release manifest.
  # shellcheck source=versions.env
  source "$manifest"
  [[ "${GOECS_SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ \
    && "${GOECS_SHA256:-}" =~ ^[0-9a-f]{64}$ \
    && "${NODEQUALITY_SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ \
    && "${NODEQUALITY_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
    warn "第三方入口版本清单格式无效；未下载或执行。"
    return 1
  }
}

prepare_third_party_entry() {
  local label="$1" source_url="$2" commit="$3" expected_sha="$4"
  local confirmation="$5" script="$6" transitive_boundary="$7"
  local actual_sha answer="" command_name

  for command_name in curl sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
      warn "${label} 入口缺少校验命令：${command_name}"
      return 1
    }
  done
  if ! curl --fail --location --silent --show-error \
      --retry 4 --connect-timeout 20 \
      "$source_url" --output "$script"; then
    warn "${label} 固定入口脚本下载失败。"
    return 1
  fi
  if ! chmod 0600 "$script"; then
    warn "${label} 固定入口临时文件权限设置失败；已拒绝执行。"
    return 1
  fi
  if ! actual_sha="$(sha256sum "$script")"; then
    warn "${label} 固定入口 SHA-256 计算失败；已拒绝执行。"
    return 1
  fi
  actual_sha="${actual_sha%% *}"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    warn "${label} 固定入口 SHA-256 不匹配；已拒绝执行。"
    return 1
  fi

  printf '\n%s 第三方 root 脚本\n' "$label"
  printf '来源：%s\n' "$source_url"
  printf '提交：%s\n' "$commit"
  printf '入口 SHA-256（已验证）：%s\n' "$actual_sha"
  warn "入口脚本已固定并校验，但其运行期间仍会${transitive_boundary}。"
  warn "第三方代码可能安装依赖、修改系统、发起公网请求、跑满 CPU/磁盘或上传测试结果。"
  read -r -p "输入 ${confirmation} 才以 root 执行（直接 Enter 取消）：" answer \
    || answer=""
  if [[ "$answer" != "$confirmation" ]]; then
    warn "已取消 ${label}；固定入口临时文件将被删除，未执行第三方代码。"
    return 1
  fi
}

run_goecs() {
  local script source_url
  load_third_party_manifest || return 1
  source_url="https://raw.githubusercontent.com/oneclickvirt/ecs/${GOECS_SOURCE_COMMIT}/goecs.sh"
  script="$(mktemp "${NEKO_PANEL_TMP_DIR%/}/neko-goecs.XXXXXX.sh")"
  if ! prepare_third_party_entry \
      "GOECS" "$source_url" "$GOECS_SOURCE_COMMIT" "$GOECS_SHA256" \
      "RUN-GOECS" "$script" \
      "查询 releases/latest，并从 GitHub Release 或第三方镜像下载未由 Neko 校验的 goecs 二进制"; then
    rm -f -- "$script"
    return 1
  fi
  if ! noninteractive=true bash "$script" install; then
    rm -f -- "$script"
    warn "GOECS 安装或更新失败。"
    return 1
  fi
  rm -f -- "$script"
  command -v goecs >/dev/null 2>&1 || {
    warn "GOECS 安装完成后没有找到 goecs 命令。"
    return 1
  }
  goecs
}

run_nodequality() {
  local script source_url rc=0
  load_third_party_manifest || return 1
  source_url="https://raw.githubusercontent.com/LloydAsp/NodeQuality/${NODEQUALITY_SOURCE_COMMIT}/NodeQuality.sh"
  script="$(mktemp "${NEKO_PANEL_TMP_DIR%/}/neko-nodequality.XXXXXX.sh")"
  if ! prepare_third_party_entry \
      "NodeQuality" "$source_url" "$NODEQUALITY_SOURCE_COMMIT" \
      "$NODEQUALITY_SHA256" "RUN-NODEQUALITY" "$script" \
      "从 main、Check.Place 等地址下载可变脚本/测试环境，并可能上传测试结果"; then
    rm -f -- "$script"
    return 1
  fi
  bash "$script" || rc=$?
  rm -f -- "$script"
  return "$rc"
}

open_third_party_checks() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '第三方 VPS 体检 & Neko 自带体检\n'
    printf '================================\n\n'
    printf '1. GOECS 融合怪（固定入口，执行前确认）\n'
    printf '2. NodeQuality 综合测试（固定入口，执行前确认）\n'
    printf '3. Neko 三网线路检测\n'
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-3]：" choice
    case "$choice" in
      0|"") return 0 ;;
      1) run_goecs || true ;;
      2) run_nodequality || true ;;
      3)
        if [[ -x "${NEKO_LIBEXEC}/route-diagnostics.sh" ]]; then
          "${NEKO_LIBEXEC}/route-diagnostics.sh" || true
        else
          warn "Neko 三网线路检测组件不可用；代理服务不受影响。"
        fi
        ;;
      *)
        warn "请输入 0 到 3。"
        sleep 1
        continue
        ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回 VPS 体检菜单……" _ || true
  done
}

manage_akdns() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf 'AKDNS 智能 DNS 解锁（第三方、可选）\n'
    printf '===================================\n\n'
    printf 'AKDNS 会接管整台 VPS 的系统 DNS，不是只影响某一个代理协议。\n'
    printf 'Neko 只运行固定上游提交并校验 SHA-256；切换失败会自动恢复。\n'
    printf '上游菜单里的流媒体检测还会运行其选择的另一份第三方脚本。\n'
    printf '需要还原时请退出上游界面，回到这里选择 2，不要在上游选 7。\n\n'
    printf '1. 打开已固定并校验的 AKDNS 官方菜单\n'
    printf '2. 紧急恢复 Neko 保存的 AKDNS 启用前状态\n'
    printf '3. 查看 AKDNS 状态\n'
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-3]：" choice
    case "$choice" in
      0|"") return 0 ;;
      1) "${NEKO_LIBEXEC}/akdns.sh" --run || true ;;
      2) "${NEKO_LIBEXEC}/akdns.sh" --restore || true ;;
      3) "${NEKO_LIBEXEC}/akdns.sh" --status || true ;;
      *)
        warn "请输入 0 到 3。"
        sleep 1
        continue
        ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回 AKDNS 菜单……" _ || true
  done
}

generate_anyreality_pair() {
  local output private_key public_key
  output="$("$NEKO_LIBEXEC/sing-box" generate reality-keypair)"
  private_key="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<< "$output")"
  public_key="$(awk -F': ' '/^PublicKey:/ {print $2}' <<< "$output")"
  [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  [[ "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  printf '%s %s\n' "$private_key" "$public_key"
}
show_route_recommendation() {
  local client_choice client blocked sent recommended backup
  local recommended_label backup_label recommended_url backup_url

  load_state
  if ! network_mode_has_cross_routes; then
    printf '\n当前安装不是 IPv4 + IPv6 双栈，不能生成四种线路组合。\n'
    printf '功能 8 只适用于同时拥有可用 IPv4 和 IPv6 的 VPS。\n'
    read -r -p "按 Enter 返回菜单……" _ || true
    return 0
  fi

  printf '\n选择所需的订阅链接：\n\n'
  printf '1. Shadowrocket\n'
  printf '2. Stash\n'
  printf '3. Mihomo\n'
  printf '4. sing-box\n'
  printf '0. 退出\n\n'
  read -r -p "请选择 [0-4]：" client_choice
  case "$client_choice" in
    0|"") return 0 ;;
    1) client=shadowrocket ;;
    2) client=stash ;;
    3) client=mihomo ;;
    4) client=sing-box ;;
    *) warn "请输入 0 到 4。"; return 0 ;;
  esac

  printf '\n哪个入口 IP 被墙？\n\n1. IPv4\n2. IPv6\n0. 退出\n\n'
  read -r -p "请选择 [0-2]：" blocked
  case "$blocked" in
    0|"") return 0 ;;
    1) blocked=ipv4 ;;
    2) blocked=ipv6 ;;
    *) warn "请输入 0 到 2。"; return 0 ;;
  esac

  printf '\n哪个出口 IP 被“送中”？\n\n1. IPv4\n2. IPv6\n0. 退出\n\n'
  read -r -p "请选择 [0-2]：" sent
  case "$sent" in
    0|"") return 0 ;;
    1) sent=ipv4 ;;
    2) sent=ipv6 ;;
    *) warn "请输入 0 到 2。"; return 0 ;;
  esac

  case "${blocked}:${sent}" in
    ipv4:ipv4) recommended=ipv6; backup=ipv6-to-ipv4 ;;
    ipv4:ipv6) recommended=ipv6-to-ipv4; backup=ipv6 ;;
    ipv6:ipv4) recommended=ipv4-to-ipv6; backup=ipv4 ;;
    ipv6:ipv6) recommended=ipv4; backup=ipv4-to-ipv6 ;;
    *) die "内部线路组合无效。" ;;
  esac
  case "$recommended" in
    ipv4) recommended_label='IPv4→IPv4' ;;
    ipv6) recommended_label='IPv6→IPv6' ;;
    ipv4-to-ipv6) recommended_label='IPv4→IPv6' ;;
    ipv6-to-ipv4) recommended_label='IPv6→IPv4' ;;
  esac
  case "$backup" in
    ipv4) backup_label='IPv4→IPv4' ;;
    ipv6) backup_label='IPv6→IPv6' ;;
    ipv4-to-ipv6) backup_label='IPv4→IPv6' ;;
    ipv6-to-ipv4) backup_label='IPv6→IPv4' ;;
  esac
  recommended_url="$(subscription_url "$recommended" "$client")" \
    || die "无法读取推荐订阅链接。"
  backup_url="$(subscription_url "$backup" "$client")" \
    || die "无法读取备用订阅链接。"

  printf '\n推荐：%s\n' "$recommended_label"
  printf '原因：通过未被墙的入口进入 VPS，再使用未被“送中”的出口。\n'
  printf '%s\n' "$recommended_url"
  show_terminal_qr "$recommended_url"
  printf '\n备用：%s\n' "$backup_label"
  printf '说明：这个出口被“送中”，但不代表完全不可以使用。\n'
  printf '%s\n' "$backup_url"
  show_terminal_qr "$backup_url"
  printf '\n'
  read -r -p "按 Enter 返回菜单……" _ || true
}

show_route_guide() {
  clear 2>/dev/null || true
  cat <<'EOF'
什么是 IP 被墙、IP“送中”，以及如何解决？
===========================================

前提：VPS 同时拥有 IPv4 和 IPv6，并且你的网络环境支持 IPv6。

先说明一个容易误会的情况：有些网站（包括但不限于 x.com）本身不支持 IPv6。
如果你选择 IPv6 出站后无法访问这类网站，并不是 Neko 的问题，应改用 IPv4 出站。

入站：你的设备到 VPS。出站：VPS 到要访问的网站。
例如 IPv4→IPv6，代表你的设备通过 IPv4 进入 VPS，VPS 再通过 IPv6 访问网站。

检测 IP 是否被墙：可在浏览器打开 itdog.cn。检测 IPv4 时选择在线 Ping（IPv4），
检测 IPv6 时选择在线 Ping（IPv6）。如果中国大陆地区全部超时，而海外地区正常，
这个 IP 很可能被墙；如果大陆和海外都超时，也可能是 VPS 服务商迁移机房或网络故障。

IP 被墙表示对应 IPv4 或 IPv6 地址的入口被阻断，不代表另一个地址也被阻断，
也不代表一定会永久被封锁。为降低风险，可优先考虑基于 TCP 的协议，例如
VLESS + REALITY + Vision 或 AnyTLS/AnyReality，但任何协议都不能保证百分之百不被墙。

解决 IP 被墙的方法是更换入口：IPv4 被墙就使用 IPv6 入站；IPv6 被墙就使用
IPv4 入站。

检测 IP“送中”：用对应出口打开 Google，随便搜索内容并滑到页面底部。如果 Google
根据互联网地址把位置显示为中国大陆，可以认为该出口可能被“送中”。“送中”表示
Google 等服务把出口 IP 识别为中国大陆，不等于这个出口完全无法使用。视频和很多
普通网站通常仍可正常工作，但 Gemini 等部分服务可能受影响。

解决 IP“送中”的方法是更换出口：IPv4 出口被“送中”就改用 IPv6 出站；IPv6
出口被“送中”就改用 IPv4 出站。

如果 IPv4/IPv6 同时被墙或同时被“送中”，不在本功能的自动推荐范围内。

请先记住一句话：被墙换左边，送中换右边。

一、IPv4 被墙：更换入口

如果你的设备通过 IPv4 无法连接 VPS，但本地网络和 VPS 的 IPv6 都能正常使用，
可以尝试：

IPv4→IPv4
切换为
IPv6→IPv4

左边代表你的设备怎样连接 VPS。切换以后，你的设备通过 IPv6 进入 VPS，
但 VPS 仍然使用 IPv4 访问网站，因此网站兼容性基本不变。

前提是本地网络支持 IPv6、VPS 拥有可用的公网 IPv6，并且 VPS 的 IPv6 没有同时
被阻断。

二、IPv4 被“送中”：更换出口

“送中”通常是指 VPS 的 IPv4 出口被 Google 或其他网站错误识别为中国大陆，
或者因为 IPv4 的地区、信誉和风控记录而受到限制。

如果当前使用 IPv4 入站，可以把 IPv4→IPv4 切换为 IPv4→IPv6。
如果当前使用 IPv6 入站，可以把 IPv6→IPv4 切换为 IPv6→IPv6。

右边代表 VPS 使用哪个地址访问目标网站。切换以后，网站看到的是 VPS 的 IPv6，
而不是原来的 IPv4。

需要注意：IPv6 出站只能直接访问支持 IPv6 的网站，而且网站判断还可能受到账号地区、
Cookie、设备位置和自身风控政策影响，因此切换 IPv6 不能保证解决所有地区限制。

三、IPv4 入口被墙，同时 IPv4 出口又被“送中”

如果本地、VPS 和目标网站都支持 IPv6，可以尝试 IPv6→IPv6。

总结：

IPv4 入口有问题，就更换箭头左边。
IPv4 出口有问题，就更换箭头右边。

下面是完整的线路说明。

你好，很荣幸为你介绍 Neko 中入站、出站以及四种线路的区别。

如果你刚才看到一长串订阅链接，又看到 IPv4→IPv6、IPv6→IPv4 这样的名称，
感觉有点蒙，这是很正常的。

其实它们并没有看起来那么复杂。

Neko 的双栈模式只有 4 种线路方向。由于每种线路分别提供 Mihomo、Stash、
Shadowrocket 和 sing-box 四种客户端格式，所以最终会显示：

4 种线路方向 × 4 种客户端格式 = 16 条订阅链接

你不需要把 16 条链接全部导入。

只需要先找到自己正在使用的客户端，再从对应的四种线路中选择一条即可。需要测试
其他线路时，再导入相应的订阅链接。

一、什么是入站和出站？

为了方便理解，请记住：

箭头左边代表入站。
箭头右边代表出站。

入站：你的设备 → VPS
出站：VPS → 目标网站或服务

例如，你想访问一个网站：

你的设备 → VPS，这一段叫作入站。
VPS → 目标网站，这一段叫作出站。

因此，IPv6→IPv4 的完整意思是：

你的设备通过 IPv6 连接 VPS，然后 VPS 再通过 IPv4 访问目标网站。

可以把它理解为：

你的设备 → IPv6 入站 → VPS → IPv4 出站 → 目标网站

这里并不是把 IPv6“转换”成 IPv4，而是把整条连接分成前后两段，并让这两段分别
选择使用 IPv4 或 IPv6。

二、四种线路分别是什么？

IPv4→IPv4

你的设备通过 IPv4 连接 VPS，VPS 再通过 IPv4 访问网站。

这是默认推荐的线路，兼容性最好，适合绝大多数日常使用场景。

IPv6→IPv4

你的设备通过 IPv6 连接 VPS，VPS 再通过 IPv4 访问网站。

适合 IPv6 入站速度更好、IPv4 入站无法连接，或者 VPS 的 IPv4 地址被墙时使用。
由于出站仍然是 IPv4，因此网站兼容性通常较好。

IPv4→IPv6

你的设备通过 IPv4 连接 VPS，VPS 再通过 IPv6 访问网站。

适合 IPv4 入站表现更好，但希望使用 VPS 的 IPv6 地址作为出口时使用。

IPv6→IPv6

你的设备通过 IPv6 连接 VPS，VPS 再通过 IPv6 访问网站。

适合本地网络、VPS 和目标网站都能正常使用 IPv6，并且希望同时使用 IPv6 入站和
IPv6 出站的情况。

三、完全不知道怎么选怎么办？

如果你完全不知道应该选择哪一种，建议先使用：

IPv4→IPv4

这是日常使用中兼容性最好、最稳妥的默认选择。

因为目前并不是所有网站和服务都支持 IPv6。如果使用严格 IPv6 出站访问一个只支持
IPv4 的网站，访问失败属于正常现象。

四、IPv4 入站和 IPv6 入站怎么比较？

如果你想知道自己的网络使用 IPv4 入站还是 IPv6 入站更好，可以测试：

IPv4→IPv4
IPv6→IPv4

这两条线路的出站都是 IPv4，唯一的区别是你的设备通过 IPv4 还是 IPv6 连接 VPS。

请尽量在相同时间、相同网络和相同测试目标下进行比较。

哪一条延迟更低、丢包更少、连接更稳定，就选择哪一条。

如果 IPv4 入站表现更好，选择 IPv4→IPv4。
如果 IPv6 入站表现更好，选择 IPv6→IPv4。

不要直接使用 IPv4→IPv4 和 IPv6→IPv6 比较入站质量，因为这样入站和出站同时
发生了变化，测试结果不容易准确判断。

五、VPS 的 IPv4 被墙后，IPv6 为什么可能还能使用？

大家常说“VPS 的 IPv4 被墙了”，通常是指：

从受到防火墙影响的网络，通过 IPv4 无法正常连接这台 VPS。

这并不一定代表整台 VPS 已经无法使用，也不一定代表这台 VPS 的 IPv6 同时被封锁。

同一台 VPS 的 IPv4 和 IPv6 是两个不同的公网地址。

例如：

IPv4 地址：1.2.3.4
IPv6 地址：2001:db8::1

它们虽然属于同一台 VPS，但在网络中是两个不同的连接目标。因此，IPv4 地址或对应
连接被阻断时，IPv6 地址不一定也已经被阻断。

如果满足下面这些条件：

你的本地网络可以正常使用 IPv6；
VPS 拥有可以正常使用的公网 IPv6；
Neko 的 IPv6 入站正在正常工作；
VPS 的 IPv6 还没有被阻断。

那么就可以尝试：

IPv6→IPv4

此时连接过程是：

你的设备通过 IPv6 连接同一台 VPS，然后 VPS 继续通过 IPv4 访问目标网站。

也就是说，虽然原来的 IPv4 入口无法连接，但你仍然有机会通过 IPv6 入口继续使用
这台 VPS，而网站兼容性较好的 IPv4 出站仍然可以保留。

这正是 Neko 四种线路设计的重要优势之一：

IPv4 入口出现问题时，不一定需要立刻更换 VPS，也不一定需要马上重新修改传输方式
或者套用 CDN。只要 IPv6 入口仍然可用，就可以先尝试通过 IPv6→IPv4 继续使用原来
的服务器。

不过需要注意：

这并不代表 IPv6 永远不会被墙，也不代表所有封锁都能通过切换 IPv6 解决。

如果本地没有 IPv6、VPS 没有可用的公网 IPv6、IPv6 地址也被阻断，或者封锁方式
同时影响相关协议和连接特征，那么 IPv6 入站也可能无法使用。

因此，IPv6 入站更准确的定位是：

在 IPv4 入口出现问题时，为同一台 VPS 多保留一条可以尝试的入口。

六、IPv4 被“送中”后，IPv6 为什么可能正常？

大家所说的“送中”，通常是指 VPS 的出口 IP 被 Google 或其他网站错误识别为中国
大陆地区，或者因为 IP 信誉、风控数据库等原因受到限制。

这里需要注意：

网站识别的是你访问它时所使用的出口公网 IP。

如果你使用 IPv4 出站，网站看到的是 VPS 的 IPv4 地址。
如果你使用 IPv6 出站，网站看到的是 VPS 的 IPv6 地址。

同一台 VPS 的 IPv4 和 IPv6 是两个不同的公网地址。不同网站和不同 IP 数据库对这
两个地址的地理位置、用途和信誉记录可能并不相同。

因此，可能出现下面这种情况：

VPS 的 IPv4 被识别为中国大陆；
但同一台 VPS 的 IPv6 仍被识别为服务器的实际所在地区。

如果当前使用 IPv4 入站，可以尝试：

IPv4→IPv4 切换为 IPv4→IPv6

这样只更换出站，入站仍然保持 IPv4。

如果当前使用 IPv6 入站，可以尝试：

IPv6→IPv4 切换为 IPv6→IPv6

这样入站仍然保持 IPv6，只把出站从 IPv4 更换为 IPv6。

切换以后，目标网站看到的不再是原来的 IPv4 地址，而是这台 VPS 的 IPv6 地址。

如果问题确实来自 IPv4 的地理位置记录或 IP 信誉，而 IPv6 的记录正常，那么切换
IPv6 出站就可能恢复部分网站或服务的正常使用。

这也是 Neko 四种线路设计的另一个重要优势：

当 IPv4 出口的地理位置或 IP 信誉出现问题时，不需要立刻放弃整台 VPS，可以先尝试
使用同一台 VPS 的 IPv6 作为另一条出口。

你可以在 Google 浏览器中随便搜索一个内容，然后滑到页面最底部，查看 Google 显示
的位置。

如果页面明确显示该位置是“根据您的互联网地址”判断出来的，并且被识别为中国大陆，
那么说明 Google 当前可能对这个出口 IP 的位置判断有误。

不过，这个结果只能作为参考，不能作为唯一判断标准。

Gemini 或其他服务能否使用，还可能受到账号地区、浏览器记录、Cookie、设备位置和
服务自身政策等因素影响。因此，切换 IPv6 出站可能解决问题，但不能保证百分之百
有效。

另外，IPv6 出站只能直接访问支持 IPv6 的网站。如果目标网站没有提供 IPv6 服务，
那么使用严格 IPv6 出站时，该网站可能无法访问。

七、Neko 四种线路真正解决了什么？

Neko 的优势并不只是“同时支持 IPv4 和 IPv6”。

更重要的是，它把入站和出站拆开，让你可以分别选择。

入口出现问题，就更换箭头左边。
出口出现问题，就更换箭头右边。

例如：

VPS 的 IPv4 入站被墙：

IPv4→IPv4
切换为
IPv6→IPv4

这样更换的是入口，网站兼容性较好的 IPv4 出站保持不变。

VPS 的 IPv4 出站被“送中”：

IPv4→IPv4
切换为
IPv4→IPv6

这样入口保持不变，只更换网站能够看到的出口地址。

如果 IPv4 入站被墙，同时 IPv4 出站又被“送中”，并且目标网站支持 IPv6，可以
尝试：

IPv6→IPv6

这样入口和出口都会切换到 IPv6。

这就是四种线路存在的意义：

让入站和出站可以自由组合，为同一台 VPS 保留更多可以继续使用的可能。

八、最后应该怎么选？

如果你还是不知道怎么选：

默认先使用 IPv4→IPv4。

如果 IPv6 入站测试结果更好，使用 IPv6→IPv4。

如果 VPS 的 IPv4 被墙，但 IPv6 仍能连接，使用 IPv6→IPv4。

如果 IPv4 出站被错误识别地区或受到 IP 信誉限制，可以根据当前入站选择 IPv4→IPv6
或 IPv6→IPv6。

如果 IPv6 出站无法访问某些网站，请切换回 IPv4 出站。

最后记住一句话：

左边决定你怎么连接 VPS，右边决定 VPS 怎么连接网站。

IPv4 入口出现问题，就尝试更换左边。
IPv4 出口出现问题，就尝试更换右边。
EOF
  show_route_recommendation
}

uninstall_neko() {
  local answer created_user service
  if [[ -d "$NEKO_VAR/akdns/pre-akdns" ]]; then
    die "Neko 仍保存着 AKDNS 启用前快照；请先从功能 9 紧急恢复，再卸载。"
  fi
  printf '\n这会删除全部协议、证书、订阅和本工具创建的防火墙规则。\n'
  read -r -p "请输入 UNINSTALL 确认：" answer
  [[ "$answer" == "UNINSTALL" ]] || return 0

  acquire_maintenance_lock
  created_user="$(jq -r '.system_user_created // false' "$NEKO_STATE" 2>/dev/null || printf false)"
  systemctl disable --now neko-renew.timer >/dev/null 2>&1 || true
  systemctl stop neko-renew.service >/dev/null 2>&1 || true
  systemctl disable --now \
    neko-hysteria.service neko-xray.service neko-sing-box.service neko-caddy.service \
    >/dev/null 2>&1 || true
  systemctl stop \
    neko-hysteria.service neko-xray.service neko-sing-box.service neko-caddy.service \
    >/dev/null 2>&1 || true
  for service in neko-renew neko-hysteria neko-xray neko-sing-box neko-caddy; do
    if systemctl is-active --quiet "${service}.service"; then
      die "${service} 未能停止；为避免残留进程和端口跳跃规则，暂不删除文件。"
    fi
  done
  remove_firewall
  restore_bbr

  remove_uninstall_files
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  if [[ "$created_user" == "true" ]] && id neko-proxy >/dev/null 2>&1; then
    userdel neko-proxy >/dev/null 2>&1 || true
    if getent group neko-proxy >/dev/null 2>&1; then
      groupdel neko-proxy >/dev/null 2>&1 || true
    fi
  fi

  printf '\n[完成] 已卸载 Neko 创建的全部服务与数据。\n'
  exit 0
}

draw_menu() {
  load_state
  clear 2>/dev/null || true
  printf 'Neko 终端控制面板\n'
  printf '=================\n'
  printf '当前网络：%s\n\n' "$(network_mode_label)"
  printf '0. 退出\n'
  printf '1. 查看当前严格订阅链接与二维码\n'
  printf '2. 开启 BBRv1\n'
  printf '3. 订阅与节点访问管理\n'
  printf '4. 刷新已安装地址族端点\n'
  printf '5. IPv4/IPv6 安装管理\n'
  printf '6. 卸载全部协议\n'
  printf '7. 第三方 VPS 体检 & Neko 自带体检\n'
  printf '8. 双栈线路怎么选？（同时拥有 IPv4 和 IPv6 时查看）\n'
  printf '9. AKDNS 智能 DNS 解锁（第三方、可选）\n'
  printf '\n'
}

main() {
  if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -- "$0" "$@"
    fi
    die "neko 控制面板需要 root 权限。"
  fi
  [[ -r "$NEKO_STATE" ]] || die "Neko 尚未完整安装。"
  while true; do
    draw_menu
    read -r -p "请选择 [0-9]：" choice
    case "$choice" in
      0) exit 0 ;;
      1)
        subscription_qr_menu
        continue
        ;;
      2) enable_bbr ;;
      3) manage_subscription_access ;;
      4) refresh_subscription_endpoints ;;
      5) manage_address_families ;;
      6) uninstall_neko ;;
      7)
        open_third_party_checks
        continue
        ;;
      8)
        show_route_guide
        continue
        ;;
      9)
        manage_akdns
        continue
        ;;
      *) warn "请输入 0 到 9。" ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回菜单……" _
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
