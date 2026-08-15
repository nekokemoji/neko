#!/usr/bin/env bash

# ACME validation, credential-file, issuance, and certificate-domain helpers.
# Loaded through lib/common.sh.

CLOUDFLARE_DNS_TOKEN_FILE="${NEKO_VAR}/credentials/cloudflare-dns-api-token"
ACME_METHOD_HTTP="http-01"
ACME_METHOD_CLOUDFLARE="cloudflare-dns-01"
ACME_RATE_LIMIT_EXIT=75
ACME_TIMEOUT_EXIT=124
ACME_DEFAULT_TIMEOUT_SECONDS=600

validate_domain() {
  local domain="${1,,}"
  [[ -n "$domain" ]] || return 1
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. ]] || return 1
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] || return 1
  # An IPv4 literal such as 1.2.3.4 is not a bound domain name.
  [[ "${domain##*.}" =~ [a-z] ]] || return 1

  local label
  IFS='.' read -r -a _domain_labels <<< "$domain"
  for label in "${_domain_labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

normalize_acme_method() {
  case "${1,,}" in
    http|http-01)
      printf '%s' "$ACME_METHOD_HTTP"
      ;;
    cloudflare|dns|dns-01|cloudflare-dns|cloudflare-dns-01)
      printf '%s' "$ACME_METHOD_CLOUDFLARE"
      ;;
    *)
      return 1
      ;;
  esac
}

validate_cloudflare_dns_token() {
  local token="$1"
  [[ ${#token} -ge 20 && ${#token} -le 256 ]] || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]]
}

write_cloudflare_dns_token() {
  local token="$1" credentials_dir tmp
  validate_cloudflare_dns_token "$token" \
    || die "Cloudflare API Token 格式无效；应为 20 到 256 位且只包含字母、数字、下划线或连字符。"

  credentials_dir="$(dirname -- "$CLOUDFLARE_DNS_TOKEN_FILE")"
  install -d -m 0700 "$credentials_dir"
  tmp="$(mktemp "${credentials_dir}/.cloudflare-dns-token.XXXXXX")"
  printf '%s\n' "$token" > "$tmp"
  chmod 0600 "$tmp"
  if (( EUID == 0 )); then
    chown root:root "$credentials_dir" "$tmp"
  fi
  mv -f -- "$tmp" "$CLOUDFLARE_DNS_TOKEN_FILE"
}

assert_cloudflare_dns_token_file() {
  local credentials_dir token owner_uid mode dir_owner_uid dir_mode expected_uid
  credentials_dir="$(dirname -- "$CLOUDFLARE_DNS_TOKEN_FILE")"
  [[ -d "$credentials_dir" && ! -L "$credentials_dir" ]] \
    || die "Cloudflare 凭据目录缺失或不安全：${credentials_dir}"
  [[ -f "$CLOUDFLARE_DNS_TOKEN_FILE" && ! -L "$CLOUDFLARE_DNS_TOKEN_FILE" \
    && -r "$CLOUDFLARE_DNS_TOKEN_FILE" ]] \
    || die "Cloudflare DNS API Token 文件缺失或不安全：${CLOUDFLARE_DNS_TOKEN_FILE}"

  dir_owner_uid="$(stat -c '%u' "$credentials_dir")"
  dir_mode="$(stat -c '%a' "$credentials_dir")"
  owner_uid="$(stat -c '%u' "$CLOUDFLARE_DNS_TOKEN_FILE")"
  mode="$(stat -c '%a' "$CLOUDFLARE_DNS_TOKEN_FILE")"
  if [[ "${NEKO_TEST_MODE:-0}" == "1" || "${NEKO_UPDATE_TEST_MODE:-0}" == "1" ]]; then
    expected_uid="$(id -u)"
  else
    expected_uid=0
  fi
  [[ "$dir_owner_uid" == "$expected_uid" && "$dir_mode" == "700" ]] \
    || die "Cloudflare 凭据目录必须由 root 持有且权限为 0700。"
  [[ "$owner_uid" == "$expected_uid" && "$mode" == "600" ]] \
    || die "Cloudflare DNS API Token 必须由 root 持有且权限为 0600。"

  token="$(<"$CLOUDFLARE_DNS_TOKEN_FILE")"
  validate_cloudflare_dns_token "$token" \
    || die "Cloudflare DNS API Token 文件内容无效。"
}

stop_acme_guard_process() {
  local guard_pid="$1" child
  local -a children=()

  [[ "$guard_pid" =~ ^[0-9]+$ ]] || return 0
  if [[ -r "/proc/${guard_pid}/task/${guard_pid}/children" ]]; then
    read -r -a children \
      < "/proc/${guard_pid}/task/${guard_pid}/children" || true
  fi

  for child in "${children[@]}"; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$child" 2>/dev/null || true
  done
  kill -TERM "$guard_pid" 2>/dev/null || true
}

run_acme_command_guarded() (
  local timeout_seconds="${NEKO_ACME_TIMEOUT_SECONDS:-$ACME_DEFAULT_TIMEOUT_SECONDS}"
  local guard_pid output_fd line retry_after="" acme_rc=0
  local rate_limited=0 exact_set_limited=0 cloudflare_invalid_token=0

  command -v timeout >/dev/null 2>&1 \
    || die "系统缺少证书申请超时保护命令：timeout"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
    || die "证书申请超时必须是正整数秒。"
  (( timeout_seconds <= 3600 )) \
    || die "证书申请超时不能超过 3600 秒。"

  # Keep the read descriptor under this subshell's ownership. Bash may reap a
  # short-lived coproc and close its generated descriptors before the first
  # read, which can hide the useful ACME error behind "Bad file descriptor".
  exec {output_fd}< <(
    exec timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" \
      "$@" 2>&1
  )
  guard_pid=$!

  trap 'stop_acme_guard_process "$guard_pid"; exit 130' INT
  trap 'stop_acme_guard_process "$guard_pid"; exit 143' TERM

  while IFS= read -r line <&"$output_fd"; do
    printf '%s\n' "$line"
    if (( rate_limited == 0 )) \
      && [[ "$line" == *"urn:ietf:params:acme:error:rateLimited"* ]]; then
      rate_limited=1
      [[ "$line" != *"exact set of identifiers"* ]] || exact_set_limited=1
      if [[ "$line" =~ retry[[:space:]]after[[:space:]]([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]UTC) ]]; then
        retry_after="${BASH_REMATCH[1]}"
      fi
      stop_acme_guard_process "$guard_pid"
    fi
    if [[ "$line" == *"9109: Invalid access token"* ]]; then
      cloudflare_invalid_token=1
    fi
  done
  exec {output_fd}<&-

  if wait "$guard_pid"; then
    acme_rc=0
  else
    acme_rc=$?
  fi
  trap - INT TERM

  if (( rate_limited == 1 )); then
    if (( exact_set_limited == 1 )); then
      warn "Let’s Encrypt 已限制这组完全相同的域名；脚本已停止长时间等待。"
    else
      warn "Let’s Encrypt 已触发证书签发额度；脚本已停止长时间等待。"
    fi
    if [[ -n "$retry_after" ]]; then
      warn "官方允许再次尝试的时间：${retry_after}。"
    fi
    warn "请到恢复时间后再运行；不要连续重装或反复申请证书。"
    return "$ACME_RATE_LIMIT_EXIT"
  fi

  if (( acme_rc == ACME_TIMEOUT_EXIT )); then
    warn "证书申请超过 ${timeout_seconds} 秒，已主动停止；不会继续无限等待。"
    warn "请检查上方 ACME 输出和网络/DNS 后再试。"
  fi
  if (( cloudflare_invalid_token == 1 && acme_rc != 0 )); then
    warn "Cloudflare 拒绝了 DNS API Token（错误 9109：Invalid access token）。"
    warn "请使用仍然有效的 API Token；不要使用 Global API Key、Origin CA Key 或已撤销的 Token。"
    warn "Token 需要 Zone / Zone / Read 与 Zone / DNS / Edit，并把 Zone Resources 限定到当前域名所在 Zone。"
  fi
  return "$acme_rc"
)

run_lego_acme() {
  local lego_binary="$1" http_mode="$2"
  local -a lego_command=()
  shift 2
  [[ -x "$lego_binary" ]] || die "lego 不可执行：${lego_binary}"

  case "${ACME_METHOD:-$ACME_METHOD_HTTP}" in
    "$ACME_METHOD_HTTP")
      case "$http_mode" in
        standalone)
          lego_command=("$lego_binary" "$@" --http)
          ;;
        webroot)
          lego_command=(
            "$lego_binary" "$@" --http --http.webroot "$NEKO_VAR/acme"
          )
          ;;
        *)
          die "未知的 HTTP-01 运行模式：${http_mode}"
          ;;
      esac
      ;;
    "$ACME_METHOD_CLOUDFLARE")
      assert_cloudflare_dns_token_file
      lego_command=(env \
        -u CF_API_EMAIL \
        -u CF_API_KEY \
        -u CF_DNS_API_TOKEN \
        -u CF_ZONE_API_TOKEN \
        -u CF_API_EMAIL_FILE \
        -u CF_API_KEY_FILE \
        -u CF_DNS_API_TOKEN_FILE \
        -u CF_ZONE_API_TOKEN_FILE \
        -u CF_BASE_URL \
        -u CF_BASE_URL_FILE \
        -u CLOUDFLARE_API_KEY \
        -u CLOUDFLARE_DNS_API_TOKEN \
        -u CLOUDFLARE_EMAIL \
        -u CLOUDFLARE_ZONE_API_TOKEN \
        -u CLOUDFLARE_BASE_URL \
        -u CLOUDFLARE_API_KEY_FILE \
        -u CLOUDFLARE_DNS_API_TOKEN_FILE \
        -u CLOUDFLARE_EMAIL_FILE \
        -u CLOUDFLARE_ZONE_API_TOKEN_FILE \
        -u CLOUDFLARE_BASE_URL_FILE \
        CF_DNS_API_TOKEN_FILE="$CLOUDFLARE_DNS_TOKEN_FILE" \
        "$lego_binary" "$@" --dns cloudflare)
      ;;
    *)
      die "不支持的 ACME 验证方式：${ACME_METHOD:-empty}"
      ;;
  esac

  run_acme_command_guarded "${lego_command[@]}"
}

# DOMAIN and subscription-domain globals come from the validated state contract.
# shellcheck disable=SC2153
active_certificate_domains() {
  printf '%s\n' "$DOMAIN"
  if network_mode_has_ipv4; then
    printf '%s\n' "$SUBSCRIPTION_DOMAIN_IPV4"
  fi
  if network_mode_has_ipv6; then
    printf '%s\n' "$SUBSCRIPTION_DOMAIN_IPV6"
  fi
}

certificate_has_active_domains() {
  local certificate_file="$1" certificate_domain
  [[ -s "$certificate_file" ]] || return 1
  while IFS= read -r certificate_domain; do
    openssl x509 -in "$certificate_file" -noout -checkhost "$certificate_domain" \
      >/dev/null 2>&1 || return 1
  done < <(active_certificate_domains)
}
