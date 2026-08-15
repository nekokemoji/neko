#!/usr/bin/env bash

# Subscription URL, label, terminal QR, and required-port presentation helpers.
# Loaded through lib/common.sh.

urlencode_path() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//\//%2F}"
  value="${value// /%20}"
  printf '%s' "$value"
}

subscription_client_label() {
  case "$1" in
    mihomo) printf 'Mihomo' ;;
    stash) printf 'Stash' ;;
    shadowrocket) printf 'Shadowrocket' ;;
    sing-box) printf 'sing-box' ;;
    *) return 1 ;;
  esac
}

subscription_client_filename() {
  case "$1" in
    mihomo) printf 'mihomo.yaml' ;;
    stash) printf 'stash.yaml' ;;
    shadowrocket) printf 'shadowrocket.txt' ;;
    sing-box) printf 'sing-box.json' ;;
    *) return 1 ;;
  esac
}

subscription_url() {
  local route="$1" client="$2" route_path token filename
  filename="$(subscription_client_filename "$client")" || return 1
  case "$route" in
    ipv4)
      network_mode_has_ipv4 || return 1
      token="$SUB_TOKEN_IPV4"
      route_path=v4
      ;;
    ipv6)
      network_mode_has_ipv6 || return 1
      token="$SUB_TOKEN_IPV6"
      route_path=v6
      ;;
    ipv4-to-ipv6)
      network_mode_has_cross_routes || return 1
      token="$SUB_TOKEN_IPV4_TO_IPV6"
      route_path=v4-to-v6
      ;;
    ipv6-to-ipv4)
      network_mode_has_cross_routes || return 1
      token="$SUB_TOKEN_IPV6_TO_IPV4"
      route_path=v6-to-v4
      ;;
    *)
      return 1
      ;;
  esac
  [[ -n "$DOMAIN" && -n "$token" ]] || return 1
  printf 'https://%s/%s/%s/%s' \
    "$DOMAIN" "$token" "$route_path" "$filename"
}

show_subscription_links() {
  local route client route_label client_label url
  load_state
  printf '\n当前模式：%s\n' "$(network_mode_label)"
  printf '下载入口：基础域名（只负责取回配置；节点入口与出口按箭头严格固定）\n'
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
      url="$(subscription_url "$route" "$client")"
      printf '\n%s %s（严格）：\n%s\n' \
        "$client_label" "$route_label" "$url"
    done
  done
  printf '\n'
}

terminal_columns() {
  local size rows columns
  if [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] && (( COLUMNS > 0 )); then
    printf '%s' "$COLUMNS"
    return 0
  fi
  if command -v stty >/dev/null 2>&1; then
    size="$(stty size 2>/dev/null < /dev/tty || true)"
    rows="${size%% *}"
    columns="${size##* }"
    if [[ "$rows" =~ ^[0-9]+$ && "$columns" =~ ^[0-9]+$ ]] \
      && (( rows > 0 && columns > 0 )); then
      printf '%s' "$columns"
      return 0
    fi
  fi
  printf '80'
}

unicode_qr_width() {
  local output="$1" line normalized line_width width=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # sed replaces each three-byte block glyph with one ASCII byte, so the
    # result is correct even when a minimal image starts Bash in LC_ALL=C.
    normalized="$(
      printf '%s' "$line" \
        | sed 's/▀/#/g; s/▄/#/g; s/█/#/g'
    )"
    line_width="${#normalized}"
    if (( line_width > width )); then
      width="$line_width"
    fi
  done <<< "$output"
  printf '%s' "$width"
}

show_terminal_qr() {
  local url="$1" qrc_binary qr_output qr_width columns
  local -a qrc_command
  qrc_binary="${NEKO_QRC_BINARY:-${NEKO_LIBEXEC}/qrc}"

  if [[ ! -x "$qrc_binary" ]]; then
    warn "二维码组件不可用；上面的文字订阅链接仍可正常使用。"
    return 0
  fi
  if [[ "${NEKO_QR_TEST_MODE:-0}" != "1" ]] \
    && { [[ ! -t 1 ]] || [[ "${TERM:-dumb}" == dumb ]]; }; then
    warn "当前输出不是可显示二维码的交互终端；请直接使用上面的文字链接。"
    return 0
  fi

  qrc_command=(
    "$qrc_binary"
    --output-format unicode
    --invert
    --ec-level M
    --scale 1
    --border 4
  )
  if command -v timeout >/dev/null 2>&1; then
    qrc_command=(timeout 5 "${qrc_command[@]}")
  fi
  if ! qr_output="$(
      printf '%s' "$url" | "${qrc_command[@]}" 2>/dev/null
    )" || [[ -z "$qr_output" ]]; then
    warn "二维码生成失败；上面的文字订阅链接仍可正常使用。"
    return 0
  fi

  qr_width="$(unicode_qr_width "$qr_output")"
  columns="$(terminal_columns)"
  if [[ "$qr_width" =~ ^[0-9]+$ && "$columns" =~ ^[0-9]+$ ]] \
    && (( qr_width > columns )); then
    warn "当前终端约 ${columns} 列，二维码需要 ${qr_width} 列。请横屏或缩小终端字体后重试；文字链接不受影响。"
    return 0
  fi

  # qrc's compact Unicode mode packs two modules into one row. Explicit
  # foreground/background colors keep the code readable on both light and
  # dark terminal themes; the URL itself is only supplied over stdin.
  printf '\n\033[30;47m%s\033[0m\n' "$qr_output"
  warn "二维码等同于订阅密码；请勿分享二维码、截图或上方完整链接。"
}

show_required_ports() {
  load_state
  local family_label
  family_label="$(network_mode_label)"
  if [[ "$ACME_METHOD" == "$ACME_METHOD_HTTP" ]]; then
    printf '%s 云防火墙 TCP：80, 443, %s, %s, %s, %s, %s\n' "$family_label" \
      "$SS_PORT" "$ANYTLS_PORT" "$TROJAN_PORT" "$VISION_PORT" "$XHTTP_PORT"
  else
    printf '%s 云防火墙 TCP：443, %s, %s, %s, %s, %s\n' "$family_label" \
      "$SS_PORT" "$ANYTLS_PORT" "$TROJAN_PORT" "$VISION_PORT" "$XHTTP_PORT"
    printf 'TCP 80：DNS-01 模式无需公网放行（Caddy 仍会在本机监听 HTTP 跳转）。\n'
  fi
  printf '%s 云防火墙 UDP：%s-%s, %s, %s\n' \
    "$family_label" "$HY2_START" "$HY2_END" "$TUIC_PORT" "$SS_PORT"
  if network_mode_has_cross_routes; then
    printf '双栈跨族线路 TCP：%s, %s, %s, %s, %s\n' \
      "$CROSS_SS_PORT" "$CROSS_ANYTLS_PORT" "$CROSS_TROJAN_PORT" \
      "$CROSS_VISION_PORT" "$CROSS_XHTTP_PORT"
    printf '双栈跨族线路 UDP：%s-%s, %s, %s\n' \
      "$CROSS_HY2_START" "$CROSS_HY2_END" "$CROSS_TUIC_PORT" "$CROSS_SS_PORT"
  fi
  if [[ "$ANYREALITY_ENABLED" == "true" ]]; then
    printf 'AnyReality TCP：%s\n' "$ANYREALITY_PORT"
    if network_mode_has_cross_routes; then
      printf '双栈跨族 AnyReality TCP：%s\n' "$CROSS_ANYREALITY_PORT"
    fi
  fi
  printf '仅回环 TCP：8443（不要对公网放行）\n'
}
