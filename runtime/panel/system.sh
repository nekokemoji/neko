#!/usr/bin/env bash

# Maintenance locking, runtime service checks, BBR, and uninstall operations.
# Loaded through runtime/panel.sh.

SYSCTL_FILE="${NEKO_BBR_SYSCTL_FILE:-/etc/sysctl.d/99-neko-bbr.conf}"
BBR_BACKUP_DIR=""
BBR_RELEASE_LOCK_ON_FINISH=0
BBR_SYSCTL_FILE_EXISTED=0
BBR_SYSCTL_TMP=""
BBR_SNAPSHOT_QDISC=""
BBR_SNAPSHOT_CC=""
BBR_SNAPSHOT_AVAILABLE_CC=""
BBR_SNAPSHOT_TCP_BBR_LOADED=false
BBR_SNAPSHOT_SCH_FQ_LOADED=false

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
  if ! neko_transaction_begin \
      --owner panel-bbr --rollback rollback_bbr_transaction \
    || ! neko_transaction_snapshot --owner panel-bbr; then
    neko_transaction_cancel --owner panel-bbr 2>/dev/null || true
    cleanup_bbr_backup || true
    return 1
  fi
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

abort_bbr_transaction() {
  local restored_message="$1" failed_message="$2"
  if neko_transaction_rollback --owner panel-bbr; then
    die "$restored_message"
  fi
  die "$failed_message"
}

complete_bbr_transaction() {
  neko_transaction_validate --owner panel-bbr
  neko_transaction_commit --owner panel-bbr
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
