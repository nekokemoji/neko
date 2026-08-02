#!/usr/bin/env bash

set -Eeuo pipefail

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
NEKO_PANEL_TMP_DIR="${NEKO_PANEL_TMP_DIR:-/var/tmp}"
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

source "${NEKO_LIBEXEC}/lib/common.sh"
source "${NEKO_LIBEXEC}/lib/render.sh"
source "${NEKO_LIBEXEC}/lib/firewall.sh"

SYSCTL_FILE="/etc/sysctl.d/99-neko-bbr.conf"
FAMILY_BACKUP_DIR=""
FAMILY_TRANSACTION_ACTIVE=0
declare -a FAMILY_FIREWALL_ADDED_ZONES=()
ACCESS_BACKUP_DIR=""
ACCESS_TRANSACTION_ACTIVE=0

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
  exec {MAINTENANCE_LOCK_FD}>/run/lock/neko-maintenance.lock
  flock -n "$MAINTENANCE_LOCK_FD" \
    || die "另一个 Neko 维护任务正在运行，请稍后重试。"
}

release_maintenance_lock() {
  flock -u "$MAINTENANCE_LOCK_FD" 2>/dev/null || true
  exec {MAINTENANCE_LOCK_FD}>&-
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
  "$NEKO_LIBEXEC/sing-box" check -c "${NEKO_CONFIG_DIR}/sing-box.json" >/dev/null
  if network_mode_has_ipv4; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v4.json" >/dev/null
  fi
  if network_mode_has_ipv6; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v6.json" >/dev/null
  fi
  if network_mode_has_cross_routes; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v4-to-v6.json" >/dev/null
    "$NEKO_LIBEXEC/sing-box" check \
      -c "${NEKO_SUB_DIR}/sing-box-v6-to-v4.json" >/dev/null
  fi
  "$NEKO_LIBEXEC/xray" run -test -c "${NEKO_CONFIG_DIR}/xray.json" >/dev/null
  "$NEKO_LIBEXEC/caddy" validate \
    --config "${NEKO_CONFIG_DIR}/Caddyfile" --adapter caddyfile >/dev/null
}

restart_runtime_services() {
  local service
  systemctl restart \
    neko-caddy.service neko-sing-box.service neko-xray.service neko-hysteria.service
  sleep 1
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    systemctl is-active --quiet "${service}.service" || return 1
  done
}

enable_bbr() {
  local previous_qdisc previous_cc managed available_cc
  managed="$(jq -r '.bbr.managed // false' "$NEKO_STATE")"

  if [[ "$managed" != "true" && -e "$SYSCTL_FILE" ]]; then
    die "${SYSCTL_FILE} 已存在但不是本工具创建的，拒绝覆盖。"
  fi

  previous_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  previous_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  modprobe sch_fq 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || die "当前内核没有可用的 tcp_bbr 模块。"

  available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<< "$available_cc"; then
    die "当前内核没有公布 bbr 拥塞控制算法。"
  fi

  if [[ "$managed" != "true" ]]; then
    atomic_json_update \
      '.bbr = {managed: true, previous_qdisc: $qdisc, previous_congestion_control: $cc}' \
      --arg qdisc "$previous_qdisc" --arg cc "$previous_cc"
  fi

  local tmp
  tmp="$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")"
  cat > "$tmp" <<'EOF'
# Managed by Neko. Removed, and previous live values restored, on uninstall.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE"

  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
    || die "BBR 配置写入后未生效。"
  ok "已启用内核 tcp_bbr（通常称 BBRv1；具体实现由发行版内核决定）。"
}

restore_bbr() {
  [[ -r "$NEKO_STATE" ]] || return 0
  local managed previous_qdisc previous_cc
  managed="$(jq -r '.bbr.managed // false' "$NEKO_STATE")"
  [[ "$managed" == "true" ]] || return 0
  previous_qdisc="$(jq -r '.bbr.previous_qdisc // empty' "$NEKO_STATE")"
  previous_cc="$(jq -r '.bbr.previous_congestion_control // empty' "$NEKO_STATE")"
  rm -f -- "$SYSCTL_FILE"
  [[ -z "$previous_qdisc" ]] || sysctl -w "net.core.default_qdisc=${previous_qdisc}" >/dev/null 2>&1 || true
  [[ -z "$previous_cc" ]] || sysctl -w "net.ipv4.tcp_congestion_control=${previous_cc}" >/dev/null 2>&1 || true
}

rotate_subscription() {
  local answer choice backup new_ipv4_token="" new_ipv6_token=""
  local new_ipv4_to_ipv6_token="" new_ipv6_to_ipv4_token=""
  local rotate_ipv4=0 rotate_ipv6=0
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
  (( rotate_ipv4 == 0 )) || new_ipv4_token="$(random_urlsafe 24)"
  (( rotate_ipv6 == 0 )) || new_ipv6_token="$(random_urlsafe 24)"
  if network_mode_has_cross_routes; then
    (( rotate_ipv4 == 0 )) \
      || new_ipv4_to_ipv6_token="$(random_urlsafe 24)"
    (( rotate_ipv6 == 0 )) \
      || new_ipv6_to_ipv4_token="$(random_urlsafe 24)"
  fi
  backup="$(mktemp "${NEKO_STATE}.backup.XXXXXX")"
  if ! cp -a -- "$NEKO_STATE" "$backup"; then
    rm -f -- "$backup"
    release_maintenance_lock
    die "无法备份安装状态；没有重置任何订阅 URL。"
  fi

  if atomic_json_update \
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
      --argjson has_cross "$(network_mode_has_cross_routes && printf true || printf false)" \
      --arg ipv4_token "$new_ipv4_token" \
      --arg ipv6_token "$new_ipv6_token" \
      --arg ipv4_to_ipv6_token "$new_ipv4_to_ipv6_token" \
      --arg ipv6_to_ipv4_token "$new_ipv6_to_ipv4_token" \
    && render_all \
    && validate_runtime_configs \
    && systemctl restart neko-caddy.service \
    && systemctl is-active --quiet neko-caddy.service; then
    rm -f -- "$backup"
    release_maintenance_lock
    ok "所选订阅 URL 已重置；对应旧 URL 不可再访问。"
    show_subscription_links
  else
    cp -a -- "$backup" "$NEKO_STATE"
    rm -f -- "$backup"
    render_all || true
    systemctl restart neko-caddy.service >/dev/null 2>&1 || true
    release_maintenance_lock
    die "订阅重置失败，已恢复旧链接。"
  fi
}

rotate_node_credentials() {
  local rotate_urls="${1:-false}" confirmation
  local has_ipv4=false has_ipv6=false has_cross=false
  local new_hy2_password new_hy2_obfs_password
  local new_tuic_uuid new_tuic_password new_ss_password
  local new_anytls_password new_trojan_password new_vision_uuid new_xhttp_uuid
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
    warn "此操作会重置七种协议的全部节点凭据，并短暂重启代理服务。"
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

  new_hy2_password="$(random_urlsafe 24)"
  new_hy2_obfs_password="$(random_urlsafe 24)"
  new_tuic_uuid="$(new_uuid)"
  new_tuic_password="$(random_urlsafe 24)"
  new_ss_password="$(random_base64 16)"
  new_anytls_password="$(random_urlsafe 24)"
  new_trojan_password="$(random_urlsafe 24)"
  new_vision_uuid="$(new_uuid)"
  new_xhttp_uuid="$(new_uuid)"
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
      ok "七种协议的全部节点凭据已换新；订阅 URL 保持不变。"
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
  chown -R root:root "$NEKO_VAR/lego"
  find "$NEKO_VAR/lego" -type d -exec chmod 0700 {} +
  find "$NEKO_VAR/lego" -type f -exec chmod 0600 {} +
  chown "root:${NEKO_USER}" "$NEKO_VAR/lego"
  chmod 0750 "$NEKO_VAR/lego"
  chown -R "root:${NEKO_USER}" "$NEKO_VAR/lego/certificates"
  find "$NEKO_VAR/lego/certificates" -type d -exec chmod 0750 {} +
  find "$NEKO_VAR/lego/certificates" -type f -exec chmod 0640 {} +
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
       }' \
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
    --argjson cross_xhttp_port "$cross_xhttp_port"

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

open_diagnostics() {
  local diagnostics="${NEKO_LIBEXEC}/diagnostics.sh"
  if [[ ! -x "$diagnostics" ]]; then
    warn "VPS 体检组件缺失；代理服务没有受到影响。请运行当前版本升级脚本修复。"
    return 0
  fi
  if ! "$diagnostics"; then
    warn "本次体检被中断或有检查未完成；它没有修改 Neko 配置或服务。"
  fi
}

uninstall_neko() {
  local answer created_user service
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

  rm -f -- \
    /etc/systemd/system/neko-caddy.service \
    /etc/systemd/system/neko-sing-box.service \
    /etc/systemd/system/neko-xray.service \
    /etc/systemd/system/neko-hysteria.service \
    /etc/systemd/system/neko-renew.service \
    /etc/systemd/system/neko-renew.timer \
    /usr/local/bin/neko \
    /run/lock/neko-install.lock \
    /run/lock/neko-maintenance.lock
  rm -rf -- /etc/neko /var/lib/neko /usr/local/libexec/neko
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
  printf '7. VPS 硬件、IP 与网络体检\n\n'
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
    read -r -p "请选择 [0-7]：" choice
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
        open_diagnostics
        continue
        ;;
      *) warn "请输入 0 到 7。" ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回菜单……" _
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
