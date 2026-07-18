#!/usr/bin/env bash

# Temporarily keep the existing Shadowrocket subscription format and replace
# only each proxy server address with the domain's direct IP.  This isolates
# client-side DNS/bootstrap problems without changing protocol parameters.

set -Eeuo pipefail
umask 0077

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_SUB_DIR="${NEKO_SUB_DIR:-${NEKO_ETC}/subscriptions}"
SUB_FILE="${NEKO_SUB_DIR}/shadowrocket.txt"
BACKUP_FILE="${NEKO_SUB_DIR}/shadowrocket.txt.before-all-protocol-diagnostic"
SS2022_BACKUP_FILE="${NEKO_SUB_DIR}/shadowrocket.txt.before-ss2022-diagnostic"
CAPTURE_FILE="${NEKO_CAPTURE_FILE:-/root/neko-shadowrocket-all-diagnostic.log}"

die_diag() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

require_ready_install() {
  if (( EUID != 0 )) && [[ "${NEKO_DIAG_TEST_MODE:-0}" != 1 ]]; then
    die_diag "请使用 root 运行。"
  fi
  command -v jq >/dev/null 2>&1 || die_diag "系统缺少 jq。"
  command -v getent >/dev/null 2>&1 || die_diag "系统缺少 getent。"
  [[ -s "$NEKO_STATE" ]] || die_diag "找不到 ${NEKO_STATE}。"
  [[ -s "$SUB_FILE" ]] || die_diag "找不到 ${SUB_FILE}。"
}

first_domain_ipv4() {
  { getent ahostsv4 "$1" 2>/dev/null || true; } \
    | awk '$1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && !found { value=$1; found=1 } END { if (found) print value }'
}

first_domain_ipv6() {
  { getent ahostsv6 "$1" 2>/dev/null || true; } \
    | awk '$1 ~ /:/ && $1 ~ /^[0-9A-Fa-f:]+$/ && !found { value=$1; found=1 } END { if (found) print value }'
}

select_endpoint() {
  local domain="$1" endpoint="${NEKO_DIAG_ENDPOINT_OVERRIDE:-}"
  if [[ -z "$endpoint" ]]; then
    endpoint="$(first_domain_ipv4 "$domain")"
  fi
  if [[ -z "$endpoint" ]]; then
    endpoint="$(first_domain_ipv6 "$domain")"
  fi
  [[ -n "$endpoint" ]] || die_diag "域名 ${domain} 没有可用的直连 A/AAAA 地址。"
  [[ "$endpoint" =~ ^[0-9A-Fa-f:.]+$ ]] \
    || die_diag "解析得到的地址格式异常。"
  printf '%s\n' "$endpoint"
}

state_number() {
  local expression="$1" description="$2"
  jq -er "${expression} | select(type == \"number\")" "$NEKO_STATE" \
    || die_diag "state.json 缺少 ${description}。"
}

restore_subscription() {
  require_ready_install
  [[ -s "$BACKUP_FILE" ]] || die_diag "没有找到本轮诊断前的订阅备份，无需恢复。"
  cp -a -- "$BACKUP_FILE" "$SUB_FILE"
  rm -f -- "$BACKUP_FILE"
  printf '[完成] 已恢复六协议诊断前的 Shadowrocket 订阅文件。\n'
  printf '请在 Shadowrocket 中删除带 diag=all-ip 的临时订阅。\n'
}

install_diagnostic_subscription() {
  local domain token endpoint source_file tmp_file replacement_count timestamp
  local hy2_start hy2_end tuic_port ss_port anytls_port vision_port xhttp_port
  local capture_filter

  require_ready_install
  domain="$(jq -er '.domain | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die_diag "state.json 缺少域名。"
  token="$(jq -er '.subscription.token | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die_diag "state.json 缺少订阅令牌。"
  endpoint="$(select_endpoint "$domain")"

  # If the SS2022 Base64 diagnostic is still installed, use its saved original
  # structured feed as the source.  This avoids asking the user to restore it
  # manually first and preserves that backup untouched.
  source_file="$SUB_FILE"
  if ! grep -Eq '^[[:space:]]*proxies:[[:space:]]*$' "$source_file"; then
    if [[ -s "$SS2022_BACKUP_FILE" ]] \
      && grep -Eq '^[[:space:]]*proxies:[[:space:]]*$' "$SS2022_BACKUP_FILE"; then
      source_file="$SS2022_BACKUP_FILE"
    else
      die_diag "当前订阅不是六协议结构化配置，也没有找到 SS2022 诊断前备份。"
    fi
  fi

  replacement_count="$(grep -Ec '^[[:space:]]+server:[[:space:]]*' "$source_file" || true)"
  [[ "$replacement_count" == 6 ]] \
    || die_diag "预期找到 6 个节点地址，实际为 ${replacement_count}；为防止误改已停止。"

  if [[ ! -e "$BACKUP_FILE" ]]; then
    cp -a -- "$source_file" "$BACKUP_FILE"
  fi

  tmp_file="$(mktemp "${SUB_FILE}.tmp.XXXXXX")"
  if ! awk -v endpoint="$endpoint" '
    /^[[:space:]]+server:[[:space:]]*/ {
      sub(/server:.*/, "server: \"" endpoint "\"")
      replaced++
    }
    { print }
    END { if (replaced != 6) exit 42 }
  ' "$source_file" > "$tmp_file"; then
    rm -f -- "$tmp_file"
    die_diag "替换节点地址失败，原订阅未变。"
  fi
  chmod --reference="$source_file" "$tmp_file" 2>/dev/null || chmod 0640 "$tmp_file"
  chown --reference="$source_file" "$tmp_file" 2>/dev/null || true
  mv -f -- "$tmp_file" "$SUB_FILE"

  [[ "$(grep -Ec "^[[:space:]]+server:[[:space:]]*\"${endpoint//./\\.}\"[[:space:]]*$" "$SUB_FILE" || true)" == 6 ]] \
    || die_diag "生成后的直连地址自检失败。"

  hy2_start="$(state_number '.ports.hysteria2_start' 'Hysteria2 起始端口')"
  hy2_end="$(state_number '.ports.hysteria2_end' 'Hysteria2 结束端口')"
  tuic_port="$(state_number '.ports.tuic' 'TUIC 端口')"
  ss_port="$(state_number '.ports.ss2022' 'SS2022 端口')"
  anytls_port="$(state_number '.ports.anytls' 'AnyTLS 端口')"
  vision_port="$(state_number '.ports.vless_reality_vision' 'Vision 端口')"
  xhttp_port="$(state_number '.ports.vless_reality_xhttp' 'XHTTP 端口')"

  capture_filter="udp portrange ${hy2_start}-${hy2_end} or udp port ${tuic_port} or tcp port ${ss_port} or udp port ${ss_port} or tcp port ${anytls_port} or tcp port ${vision_port} or tcp port ${xhttp_port}"
  if [[ "${NEKO_DIAG_NO_CAPTURE:-0}" != 1 ]] && command -v tcpdump >/dev/null 2>&1; then
    install -m 0600 /dev/null "$CAPTURE_FILE"
    nohup timeout 600 tcpdump -nn -l -tttt -i any -s 96 "$capture_filter" \
      > "$CAPTURE_FILE" 2>&1 </dev/null &
    printf '[信息] 已后台抓取六协议端口 600 秒，记录：%s\n' "$CAPTURE_FILE"
  else
    printf '[注意] 未启动抓包；这不影响节点测试。\n'
  fi

  timestamp="$(date +%s)"
  printf '\n[完成] 临时订阅只改了 6 个节点的连接地址：%s\n' "$endpoint"
  printf '证书校验、SNI、REALITY serverName 和 XHTTP Host 仍使用：%s\n' "$domain"
  printf '请把下面 URL 作为“新订阅”加入 Shadowrocket：\n\n'
  printf 'https://%s/%s/shadowrocket.txt?diag=all-ip-%s\n\n' \
    "$domain" "$token" "$timestamp"
  printf '依次测试 HY2、TUIC-v5、SS2022、AnyTLS、Vision、XHTTP，并截图结果。\n'
  printf '不要发送订阅 URL、节点二维码或配置详情页。\n'
  printf '测试后恢复命令：bash diagnose-shadowrocket-all.sh --restore\n'
}

case "${1:-}" in
  --restore)
    restore_subscription
    ;;
  ''|--install)
    install_diagnostic_subscription
    ;;
  *)
    die_diag "用法：bash diagnose-shadowrocket-all.sh [--install|--restore]"
    ;;
esac
