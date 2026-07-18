#!/usr/bin/env bash

# Build a temporary Shadowrocket subscription containing several SS2022 URI
# encodings.  This isolates URI parsing and DNS from the running proxy server.

set -Eeuo pipefail
umask 0077

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_SUB_DIR="${NEKO_SUB_DIR:-${NEKO_ETC}/subscriptions}"
NEKO_TMP_DIR="${NEKO_TMP_DIR:-/var/tmp}"
SUB_FILE="${NEKO_SUB_DIR}/shadowrocket.txt"
BACKUP_FILE="${NEKO_SUB_DIR}/shadowrocket.txt.before-ss2022-diagnostic"
CAPTURE_FILE="${NEKO_CAPTURE_FILE:-/root/neko-shadowrocket-ss2022-diagnostic.log}"
RAW_FILE=""

die_diag() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$RAW_FILE" && "$RAW_FILE" == "${NEKO_TMP_DIR}"/neko-ss2022-uri.* ]]; then
    rm -f -- "$RAW_FILE"
  fi
}

trap cleanup EXIT

require_ready_install() {
  if (( EUID != 0 )) && [[ "${NEKO_DIAG_TEST_MODE:-0}" != 1 ]]; then
    die_diag "请使用 root 运行。"
  fi
  command -v jq >/dev/null 2>&1 || die_diag "系统缺少 jq。"
  command -v base64 >/dev/null 2>&1 || die_diag "系统缺少 base64。"
  [[ -s "$NEKO_STATE" ]] || die_diag "找不到 ${NEKO_STATE}。"
  [[ -s "$SUB_FILE" ]] || die_diag "找不到 ${SUB_FILE}。"
}

base64_standard() {
  base64 | tr -d '\r\n'
}

base64url_no_pad() {
  base64_standard | tr '+/' '-_' | tr -d '='
}

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

first_domain_ipv4() {
  { getent ahostsv4 "$1" 2>/dev/null || true; } \
    | awk '$1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && !found { value=$1; found=1 } END { if (found) print value }'
}

append_uri_variants() {
  local host="$1" label="$2"
  local plain_userinfo raw_userinfo b64url_userinfo b64_userinfo legacy_authority

  plain_userinfo="${METHOD}:$(urlencode "$SS_PASSWORD")"
  raw_userinfo="${METHOD}:${SS_PASSWORD}"
  b64url_userinfo="$(printf '%s' "${METHOD}:${SS_PASSWORD}" | base64url_no_pad)"
  b64_userinfo="$(printf '%s' "${METHOD}:${SS_PASSWORD}" | base64_standard)"
  legacy_authority="$(printf '%s' "${METHOD}:${SS_PASSWORD}@${host}:${SS_PORT}" | base64url_no_pad)"

  {
    printf 'ss://%s@%s:%s#A-SIP002-Plain-%s\n' \
      "$plain_userinfo" "$host" "$SS_PORT" "$label"
    printf 'ss://%s@%s:%s#B-Userinfo-B64URL-%s\n' \
      "$b64url_userinfo" "$host" "$SS_PORT" "$label"
    printf 'ss://%s@%s:%s#C-Userinfo-StdB64-%s\n' \
      "$b64_userinfo" "$host" "$SS_PORT" "$label"
    printf 'ss://%s@%s:%s#D-Plain-Unescaped-%s\n' \
      "$raw_userinfo" "$host" "$SS_PORT" "$label"
    printf 'ss://%s#E-Legacy-FullB64-%s\n' \
      "$legacy_authority" "$label"
  } >> "$RAW_FILE"
}

restore_subscription() {
  require_ready_install
  [[ -s "$BACKUP_FILE" ]] || die_diag "没有找到诊断前的订阅备份，无需恢复。"
  cp -a -- "$BACKUP_FILE" "$SUB_FILE"
  rm -f -- "$BACKUP_FILE"
  printf '[完成] 已恢复诊断前的 Shadowrocket 订阅文件。\n'
  printf '请在 Shadowrocket 中删除诊断订阅；原订阅 URL 没有改变。\n'
}

install_diagnostic_subscription() {
  local domain token ipv4 tmp_file uri_count timestamp

  require_ready_install
  domain="$(jq -er '.domain | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die_diag "state.json 缺少域名。"
  token="$(jq -er '.subscription.token | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die_diag "state.json 缺少订阅令牌。"
  SS_PORT="$(jq -er '.ports.ss2022 | select(type == "number")' "$NEKO_STATE")" \
    || die_diag "state.json 缺少 SS2022 端口。"
  SS_PASSWORD="$(jq -er '.credentials.ss2022_password | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die_diag "state.json 缺少 SS2022 密码。"
  METHOD='2022-blake3-aes-128-gcm'
  export SS_PORT SS_PASSWORD METHOD

  if [[ ! -e "$BACKUP_FILE" ]]; then
    cp -a -- "$SUB_FILE" "$BACKUP_FILE"
  fi

  [[ -d "$NEKO_TMP_DIR" && -w "$NEKO_TMP_DIR" ]] \
    || die_diag "临时目录不可写：${NEKO_TMP_DIR}"
  RAW_FILE="$(mktemp "${NEKO_TMP_DIR}/neko-ss2022-uri.XXXXXX")"
  : > "$RAW_FILE"
  append_uri_variants "$domain" Domain

  ipv4="$(first_domain_ipv4 "$domain")"
  if [[ -n "$ipv4" ]]; then
    append_uri_variants "$ipv4" IPv4
  fi

  uri_count="$(wc -l < "$RAW_FILE" | tr -d ' ')"
  [[ "$uri_count" == 5 || "$uri_count" == 10 ]] \
    || die_diag "内部错误：生成了异常数量的诊断节点。"

  tmp_file="$(mktemp "${SUB_FILE}.tmp.XXXXXX")"
  { base64_standard < "$RAW_FILE"; printf '\n'; } > "$tmp_file"
  chmod --reference="$SUB_FILE" "$tmp_file" 2>/dev/null || chmod 0640 "$tmp_file"
  chown --reference="$SUB_FILE" "$tmp_file" 2>/dev/null || true
  mv -f -- "$tmp_file" "$SUB_FILE"

  # Verify that the outer subscription is valid Base64 without printing secrets.
  [[ "$(base64 -d < "$SUB_FILE" 2>/dev/null | wc -l | tr -d ' ')" == "$uri_count" ]] \
    || die_diag "生成后的 Base64 自检失败。"

  if [[ "${NEKO_DIAG_NO_CAPTURE:-0}" != 1 ]] && command -v tcpdump >/dev/null 2>&1; then
    install -m 0600 /dev/null "$CAPTURE_FILE"
    nohup timeout 300 tcpdump -nn -l -tttt -i any -s 96 \
      "tcp port ${SS_PORT} or udp port ${SS_PORT}" \
      > "$CAPTURE_FILE" 2>&1 </dev/null &
    printf '[信息] 已后台抓包 300 秒，记录：%s\n' "$CAPTURE_FILE"
  else
    printf '[注意] 未启动抓包；这不影响节点测试。\n'
  fi

  timestamp="$(date +%s)"
  printf '\n[完成] 已生成 %s 个临时 SS2022 诊断节点。\n' "$uri_count"
  printf '请把下面这个新 URL 作为“新订阅”加入 Shadowrocket：\n\n'
  printf 'https://%s/%s/shadowrocket.txt?diag=ss2022-%s\n\n' \
    "$domain" "$token" "$timestamp"
  printf '逐个测试 A/B/C/D/E；如果同时有 Domain 和 IPv4，先测 IPv4。\n'
  printf '不要把订阅 URL、密码或节点二维码发给任何人。\n'
  printf '测试结束后执行：bash diagnose-shadowrocket-ss2022.sh --restore\n'
}

case "${1:-}" in
  --restore)
    restore_subscription
    ;;
  ''|--install)
    install_diagnostic_subscription
    ;;
  *)
    die_diag "用法：bash diagnose-shadowrocket-ss2022.sh [--install|--restore]"
    ;;
esac
