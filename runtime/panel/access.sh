#!/usr/bin/env bash

# Subscription Token, node credential, endpoint refresh, and QR operations.
# Loaded through runtime/panel.sh.

ACCESS_BACKUP_DIR=""

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

begin_access_transaction() {
  if ! neko_transaction_begin \
      --owner panel-access --rollback rollback_access_transaction \
    || ! neko_transaction_snapshot --owner panel-access; then
    neko_transaction_cancel --owner panel-access 2>/dev/null || true
    return 1
  fi
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
  warn "订阅或节点凭据更新未完成，正在恢复原来的配置和服务……"

  if access_backup_path_is_safe; then
    cp -a -- "$ACCESS_BACKUP_DIR/etc/." "$NEKO_ETC/" || rollback_ok=0
  else
    rollback_ok=0
  fi
  validate_runtime_configs || rollback_ok=0
  restart_runtime_services || rollback_ok=0

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

  if ! begin_access_transaction; then
    cleanup_access_backup || true
    release_maintenance_lock
    die "无法启动订阅 URL 顶层事务；没有修改任何内容。"
  fi

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
    if neko_transaction_rollback --owner panel-access; then
      die "订阅令牌写入失败，已恢复原订阅、原配置和服务。"
    fi
    die "订阅令牌写入失败，且自动恢复未完全成功；请保留上方备份并停止继续操作。"
  fi

  if render_all \
    && validate_runtime_configs \
    && restart_runtime_services \
    && neko_transaction_validate --owner panel-access \
    && neko_transaction_commit --owner panel-access; then
    cleanup_access_backup \
      || warn "订阅 URL 已重置，但临时备份无法清理：${ACCESS_BACKUP_DIR}"
    release_maintenance_lock
    ok "所选订阅 URL 已重置；对应旧 URL 不可再访问。"
    show_subscription_links
    return 0
  fi

  if neko_transaction_rollback --owner panel-access; then
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

  if ! begin_access_transaction; then
    cleanup_access_backup || true
    release_maintenance_lock
    die "无法启动节点凭据顶层事务；没有修改任何内容。"
  fi

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
    neko_transaction_cancel --owner panel-access
    cleanup_access_backup || true
    release_maintenance_lock
    die "无法写入新节点凭据；原状态和运行服务均未修改。"
  fi

  if render_all \
    && validate_runtime_configs \
    && restart_runtime_services \
    && neko_transaction_validate --owner panel-access \
    && neko_transaction_commit --owner panel-access; then
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

  if neko_transaction_rollback --owner panel-access; then
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
