#!/usr/bin/env bash

# Address-family add transaction, firewall synchronization, and family menu.
# Loaded through runtime/panel.sh.

FAMILY_BACKUP_DIR=""
declare -a FAMILY_FIREWALL_ADDED_ZONES=()

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
  if ! neko_transaction_begin \
      --owner panel-family --rollback rollback_family_transaction \
    || ! neko_transaction_snapshot --owner panel-family; then
    neko_transaction_cancel --owner panel-family 2>/dev/null || true
    cleanup_family_backup || true
    release_maintenance_lock
    die "无法启动地址族补装顶层事务；未修改现有安装。"
  fi

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

  neko_transaction_validate --owner panel-family
  neko_transaction_commit --owner panel-family
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
