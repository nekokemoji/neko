#!/usr/bin/env bash

# Pinned tool identity and ACME transaction contracts.
# This file is sourced by tests/run.sh so the suites keep one shared fixture.
# shellcheck disable=SC2154
[[ "${NEKO_TEST_SUITE_CONTEXT:-}" == 1 ]] || {
  printf '请通过 tests/run.sh 运行测试套件。\n' >&2
  exit 1
}

printf '[4/10] 冻结版本、lego v5 CLI 与证书续期事务……\n'
[[ "$("$XRAY" version)" == *"$XRAY_VERSION"* ]]
[[ "$("$SING_BOX" version)" == *"$SING_BOX_VERSION"* ]]
[[ "$("$HYSTERIA" version 2>&1)" == *"v${HYSTERIA_VERSION}"* ]]
[[ "$("$CADDY" version)" == *"v${CADDY_VERSION}"* ]]
[[ "$("$LEGO" --version)" == *"$LEGO_VERSION"* ]]
[[ "$("$MIHOMO" -v)" == *"${MIHOMO_VERSION}"* ]]
[[ "$("$QRC" --help 2>&1)" == *'--output-format=<auto|ansi|sixel|unicode>'* ]]
[[ "$(NO_COLOR=1 "$NEXTTRACE" --version 2>&1)" == *"NextTrace v${NEXTTRACE_VERSION}"* ]]
[[ "$("$LEGO" run --help 2>&1)" == *"--http.webroot"* ]]
[[ "$("$LEGO" run --help 2>&1)" == *"--dns"* ]]
bash "$ROOT/tests/renew-transaction.sh"

# These scans are deliberate supply-chain and pipefail safety boundaries. A
# download advertised as "latest", or an early-exiting head in the installer,
# cannot be exercised deterministically without performing the unsafe action.
if grep -R "releases/latest\|/latest/download" \
    "$ROOT/install.sh" "$ROOT/upgrade.sh" \
    "$ROOT/tests/fetch-pinned-tools.sh" \
    "$ROOT/tests/fetch-pinned-qrc.sh" \
    "$ROOT/tests/fetch-pinned-nexttrace.sh"; then
  printf '发现未冻结的 latest 下载地址。\n' >&2
  exit 1
fi
if grep -Eq '\|[[:space:]]*head([[:space:]]|$)' "$ROOT/install.sh"; then
  printf '安装器包含可能在 pipefail 下触发 SIGPIPE 的 head 管道。\n' >&2
  exit 1
fi

ACME_WORK="$(mktemp -d "$ROOT/tests/acme.XXXXXX")"

default_work_base="$(bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  printf "%s" "$NEKO_WORK_BASE"
' _ "$ROOT/install.sh")"
[[ "$default_work_base" == /var/tmp ]]

bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  NEKO_WORK_BASE="$2"
  df() {
    printf "%s\n" \
      "Filesystem 1024-blocks Used Available Capacity Mounted on" \
      "testfs 1000000 1 900000 1% $NEKO_WORK_BASE"
  }
  assert_work_space
' _ "$ROOT/install.sh" "$ACME_WORK"
set +e
workspace_error="$(bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  NEKO_WORK_BASE="$2"
  df() {
    printf "%s\n" \
      "Filesystem 1024-blocks Used Available Capacity Mounted on" \
      "testfs 1000000 1 786431 1% $NEKO_WORK_BASE"
  }
  assert_work_space
' _ "$ROOT/install.sh" "$ACME_WORK" 2>&1)"
workspace_rc=$?
set -e
(( workspace_rc != 0 ))
[[ "$workspace_error" == *'至少需要 768 MiB'* ]]

bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  parse_args --cloudflare-token-file "$2"
  [[ "$CLOUDFLARE_TOKEN_SOURCE_FILE" == "$2" ]]
' _ "$ROOT/install.sh" "$ACME_WORK/cloudflare-token"

PAYLOAD_WORK="$ACME_WORK/install-payload"
mkdir -p \
  "$PAYLOAD_WORK/work/bin" "$PAYLOAD_WORK/libexec/lib" \
  "$PAYLOAD_WORK/systemd"
for binary_name in xray sing-box hysteria caddy lego; do
  install -m 0755 /usr/bin/true "$PAYLOAD_WORK/work/bin/$binary_name"
done
NEKO_TEST_PAYLOAD_ROOT="$PAYLOAD_WORK" bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  WORKDIR="$NEKO_TEST_PAYLOAD_ROOT/work"
  NEKO_LIBEXEC="$NEKO_TEST_PAYLOAD_ROOT/libexec"
  NEKO_SYSTEMD="$NEKO_TEST_PAYLOAD_ROOT/systemd"
  ln() { printf "%s\n" "$*" > "$NEKO_TEST_PAYLOAD_ROOT/link.log"; }
  install_payload
' _ "$ROOT/install.sh"
for installed_runtime in \
  panel.sh akdns.sh route-diagnostics.sh renew.sh hysteria-dual.sh; do
  [[ -x "$PAYLOAD_WORK/libexec/$installed_runtime" ]]
done
for installed_library in \
  common.sh state.sh render.sh firewall.sh transaction.sh; do
  [[ -r "$PAYLOAD_WORK/libexec/lib/$installed_library" ]]
done
[[ ! -e "$PAYLOAD_WORK/libexec/diagnostics.sh" ]]
[[ "$(<"$PAYLOAD_WORK/link.log")" \
  == "-s $PAYLOAD_WORK/libexec/panel.sh /usr/local/bin/neko" ]]

OPTIONAL_DOWNLOAD_WORK="$(mktemp -d "$ROOT/tests/optional-download.XXXXXX")"
if ! bash -c '
    set -Eeuo pipefail
    source "$1"
    curl() { return 22; }
    output="$2/qrc.tar.gz"
    printf stale > "$output"
    if download_optional_verified \
        "qrc test" "https://example.invalid/qrc.tar.gz" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "$output"; then
      exit 1
    fi
    [[ ! -e "$output" ]]
    printf continued
  ' _ "$ROOT/lib/common.sh" "$OPTIONAL_DOWNLOAD_WORK" \
  | grep -Fq continued; then
  rm -rf -- "$OPTIONAL_DOWNLOAD_WORK"
  printf '可选二维码下载失败时没有安全降级。\n' >&2
  exit 1
fi
rm -rf -- "$OPTIONAL_DOWNLOAD_WORK"

mkdir -p "$ACME_WORK/bin"
cat > "$ACME_WORK/bin/lego-fake" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ -z "${CF_API_EMAIL:-}" ]]
[[ -z "${CF_API_KEY:-}" ]]
[[ -z "${CF_DNS_API_TOKEN:-}" ]]
[[ -z "${CF_ZONE_API_TOKEN:-}" ]]
[[ -z "${CF_API_EMAIL_FILE:-}" ]]
[[ -z "${CF_API_KEY_FILE:-}" ]]
[[ -z "${CF_ZONE_API_TOKEN_FILE:-}" ]]
[[ -z "${CF_BASE_URL:-}" ]]
[[ -z "${CF_BASE_URL_FILE:-}" ]]
[[ -z "${CLOUDFLARE_API_KEY:-}" ]]
[[ -z "${CLOUDFLARE_DNS_API_TOKEN:-}" ]]
[[ -z "${CLOUDFLARE_EMAIL:-}" ]]
[[ -z "${CLOUDFLARE_ZONE_API_TOKEN:-}" ]]
[[ -z "${CLOUDFLARE_BASE_URL:-}" ]]
[[ -z "${CLOUDFLARE_API_KEY_FILE:-}" ]]
[[ -z "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]]
[[ -z "${CLOUDFLARE_EMAIL_FILE:-}" ]]
[[ -z "${CLOUDFLARE_ZONE_API_TOKEN_FILE:-}" ]]
[[ -z "${CLOUDFLARE_BASE_URL_FILE:-}" ]]
printf '%s\n' "$@" > "$NEKO_TEST_ARGS_LOG"
printf '%s\n' "${CF_DNS_API_TOKEN_FILE:-}" > "$NEKO_TEST_ENV_LOG"
EOF
chmod 0755 "$ACME_WORK/bin/lego-fake"
printf '%s\n' 'test_Cloudflare-token_1234567890' > "$ACME_WORK/input-token"
chmod 0600 "$ACME_WORK/input-token"
NEKO_INSTALL_TEST_TOKEN_FILE="$ACME_WORK/input-token" bash -c '
  set -Eeuo pipefail
  unset CF_DNS_API_TOKEN CF_DNS_API_TOKEN_FILE \
    CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN_FILE
  source "$1"
  ACME_METHOD_INPUT=""
  CLOUDFLARE_TOKEN_SOURCE_FILE="$NEKO_INSTALL_TEST_TOKEN_FILE"
  collect_acme_settings
  [[ "$ACME_METHOD" == cloudflare-dns-01 ]]
  [[ "$CLOUDFLARE_DNS_TOKEN_INPUT" == test_Cloudflare-token_1234567890 ]]
' _ "$ROOT/install.sh"
if NEKO_INSTALL_TEST_TOKEN_FILE="$ACME_WORK/input-token" bash -c '
  set -Eeuo pipefail
  unset CF_DNS_API_TOKEN CF_DNS_API_TOKEN_FILE \
    CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN_FILE
  source "$1"
  ACME_METHOD_INPUT=http-01
  CLOUDFLARE_TOKEN_SOURCE_FILE="$NEKO_INSTALL_TEST_TOKEN_FILE"
  collect_acme_settings
' _ "$ROOT/install.sh" >/dev/null 2>&1; then
  printf 'HTTP-01 接受了不应使用的 Cloudflare Token。\n' >&2
  exit 1
fi
if bash -c '
  set -Eeuo pipefail
  unset CF_DNS_API_TOKEN CF_DNS_API_TOKEN_FILE \
    CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN_FILE
  source "$1"
  ACME_METHOD_INPUT=""
  CLOUDFLARE_TOKEN_SOURCE_FILE=""
  collect_acme_settings
' _ "$ROOT/install.sh" </dev/null >/dev/null 2>&1; then
  printf '非交互安装没有显式选择 ACME 方式时仍然继续。\n' >&2
  exit 1
fi
printf '%s\n' \
  'During secondary validation: Fetching http://v6.example.com/: Network unreachable' \
  > "$ACME_WORK/http-route-error"
http_failure_message="$(bash -c '
  set -Eeuo pipefail
  source "$1"
  explain_http01_failure "$2"
' _ "$ROOT/install.sh" "$ACME_WORK/http-route-error" 2>&1)"
[[ "$http_failure_message" == *"IPv6 路由不完整"* ]]
cat > "$ACME_WORK/bin/lego" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'lego\n' >> "$NEKO_TEST_HTTP_SEQUENCE"
printf 'During secondary validation: Fetching http://v6.example.com/: Network unreachable\n'
exit 42
EOF
chmod 0755 "$ACME_WORK/bin/lego"
NEKO_TEST_HTTP_ROOT="$ACME_WORK" bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  NEKO_VAR="$NEKO_TEST_HTTP_ROOT/http-var"
  WORKDIR="$NEKO_TEST_HTTP_ROOT"
  DOMAIN=example.com
  SUBSCRIPTION_DOMAIN_IPV4=v4.example.com
  SUBSCRIPTION_DOMAIN_IPV6=v6.example.com
  ACME_EMAIL=admin@example.com
  ACME_METHOD=http-01
  export NEKO_TEST_HTTP_SEQUENCE="$NEKO_TEST_HTTP_ROOT/http-sequence"
  open_temporary_http_challenge_port() {
    printf "open\n" >> "$NEKO_TEST_HTTP_SEQUENCE"
  }
  close_temporary_http_challenge_port() {
    printf "close\n" >> "$NEKO_TEST_HTTP_SEQUENCE"
  }
  issue_rc=0
  issue_initial_certificate >/dev/null 2>&1 || issue_rc=$?
  ROLLBACK_NEEDED=0
  (( issue_rc == 42 ))
  [[ "$(<"$NEKO_TEST_HTTP_SEQUENCE")" == $'"'"'open\nlego\nclose'"'"' ]]
' _ "$ROOT/install.sh"
NEKO_VAR="$ACME_WORK/var" NEKO_TEST_MODE=1 \
  ACME_TEST_ROOT="$ACME_WORK" bash -c '
    set -Eeuo pipefail
    source "$1"
    token="test_Cloudflare-token_1234567890"
    validate_cloudflare_dns_token "$token"
    ! validate_cloudflare_dns_token short
    write_cloudflare_dns_token "$token"
    [[ "$(stat -c %a "$(dirname "$CLOUDFLARE_DNS_TOKEN_FILE")")" == 700 ]]
    [[ "$(stat -c %a "$CLOUDFLARE_DNS_TOKEN_FILE")" == 600 ]]
    chmod 0644 "$CLOUDFLARE_DNS_TOKEN_FILE"
    if (assert_cloudflare_dns_token_file >/dev/null 2>&1); then
      printf "权限过宽的 Cloudflare Token 文件未被拒绝。\n" >&2
      exit 1
    fi
    chmod 0600 "$CLOUDFLARE_DNS_TOKEN_FILE"
    assert_cloudflare_dns_token_file

    export NEKO_TEST_ARGS_LOG="$ACME_TEST_ROOT/dns-args"
    export NEKO_TEST_ENV_LOG="$ACME_TEST_ROOT/dns-env"
    ACME_METHOD=cloudflare-dns-01
    CF_DNS_API_TOKEN="must-not-leak"
    CF_ZONE_API_TOKEN_FILE="/must/not/leak"
    CLOUDFLARE_DNS_API_TOKEN_FILE="/must/not/leak-either"
    CLOUDFLARE_BASE_URL="https://attacker.invalid/"
    export CF_DNS_API_TOKEN CF_ZONE_API_TOKEN_FILE \
      CLOUDFLARE_DNS_API_TOKEN_FILE CLOUDFLARE_BASE_URL
    run_lego_acme "$ACME_TEST_ROOT/bin/lego-fake" standalone \
      run --domains example.com
    grep -Fxq -- "--dns" "$NEKO_TEST_ARGS_LOG"
    grep -Fxq cloudflare "$NEKO_TEST_ARGS_LOG"
    [[ "$(<"$NEKO_TEST_ENV_LOG")" == "$CLOUDFLARE_DNS_TOKEN_FILE" ]]
    ! grep -Eq "must-not-leak|$token" \
      "$NEKO_TEST_ARGS_LOG" "$NEKO_TEST_ENV_LOG"

    export NEKO_TEST_ARGS_LOG="$ACME_TEST_ROOT/http-args"
    export NEKO_TEST_ENV_LOG="$ACME_TEST_ROOT/http-env"
    ACME_METHOD=http-01
    unset CF_DNS_API_TOKEN CF_ZONE_API_TOKEN_FILE \
      CLOUDFLARE_DNS_API_TOKEN_FILE CLOUDFLARE_BASE_URL
    run_lego_acme "$ACME_TEST_ROOT/bin/lego-fake" webroot \
      run --domains example.com
    grep -Fxq -- "--http" "$NEKO_TEST_ARGS_LOG"
    grep -Fxq -- "--http.webroot" "$NEKO_TEST_ARGS_LOG"
    grep -Fxq "$NEKO_VAR/acme" "$NEKO_TEST_ARGS_LOG"
    [[ "$(<"$NEKO_TEST_ENV_LOG")" == "" ]]
  ' _ "$ROOT/lib/common.sh"

fast_failure_output="$(
  NEKO_TEST_MODE=1 NEKO_ACME_TIMEOUT_SECONDS=20 \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      for ((attempt = 0; attempt < 1000; attempt++)); do
        output=""
        rc=0
        output="$(run_acme_command_guarded "$2" 2>&1)" || rc=$?
        (( rc == 42 ))
        [[ "$output" == *"9109: Invalid access token"* ]]
        [[ "$output" == *"Cloudflare 拒绝了 DNS API Token"* ]]
        [[ "$output" != *"Bad file descriptor"* ]]
      done
      printf "%s\n" "$output"
    ' _ "$ROOT/lib/common.sh" \
      "$ROOT/tests/fixtures/lego-fast-failure.sh"
)"
grep -Fq 'Zone / Zone / Read' <<< "$fast_failure_output"
grep -Fq 'Zone / DNS / Edit' <<< "$fast_failure_output"

rate_limit_started=$SECONDS
set +e
rate_limit_output="$(
  NEKO_TEST_MODE=1 NEKO_ACME_TIMEOUT_SECONDS=20 \
    NEKO_TEST_ACME_FINISHED="$ACME_WORK/rate-limit-finished" \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      ACME_METHOD=http-01
      run_lego_acme "$2" standalone run --domains example.com
    ' _ "$ROOT/lib/common.sh" \
      "$ROOT/tests/fixtures/lego-rate-limited.sh" 2>&1
)"
rate_limit_rc=$?
set -e
rate_limit_elapsed=$((SECONDS - rate_limit_started))
(( rate_limit_rc == 75 ))
(( rate_limit_elapsed < 5 ))
[[ ! -e "$ACME_WORK/rate-limit-finished" ]]
grep -Fq '脚本已停止长时间等待' <<< "$rate_limit_output"
grep -Fq '2026-07-29 03:47:06 UTC' <<< "$rate_limit_output"

set +e
acme_timeout_output="$(
  NEKO_TEST_MODE=1 NEKO_ACME_TIMEOUT_SECONDS=1 \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      ACME_METHOD=http-01
      run_lego_acme "$2" standalone run --domains example.com
    ' _ "$ROOT/lib/common.sh" "$ROOT/tests/fixtures/lego-timeout.sh" 2>&1
)"
acme_timeout_rc=$?
set -e
(( acme_timeout_rc == 124 ))
grep -Fq '证书申请超过 1 秒' <<< "$acme_timeout_output"
rm -rf -- "$ACME_WORK"
