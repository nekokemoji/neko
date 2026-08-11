#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
XRAY="${XRAY_BIN:-$TOOLS/xray}"
SING_BOX="${SING_BOX_BIN:-$TOOLS/sing-box}"
HYSTERIA="${HYSTERIA_BIN:-$TOOLS/hysteria}"
CADDY="${CADDY_BIN:-$TOOLS/caddy}"
LEGO="${LEGO_BIN:-$TOOLS/lego}"
MIHOMO="${MIHOMO_BIN:-$TOOLS/mihomo}"
QRC="${QRC_BIN:-$TOOLS/qrc}"
NEXTTRACE="${NEXTTRACE_BIN:-$TOOLS/nexttrace-tiny}"

for binary in \
  "$XRAY" "$SING_BOX" "$HYSTERIA" "$CADDY" "$LEGO" "$MIHOMO" \
  "$QRC" "$NEXTTRACE"; do
  [[ -x "$binary" ]] || {
    printf '缺少测试工具 %s；先运行 tests/fetch-pinned-tools.sh。\n' "$binary" >&2
    exit 1
  }
done

source "$ROOT/versions.env"

printf '[1/9] Bash 语法、ShellCheck 与 Python YAML……\n'
mapfile -t shell_files <<< "$(find "$ROOT" -type f -name '*.sh' -print | sort)"
bash -n "${shell_files[@]}"
command -v shellcheck >/dev/null 2>&1 \
  || { printf '缺少必需测试工具 shellcheck。\n' >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 \
  || { printf '缺少必需 Python 模块 PyYAML。\n' >&2; exit 1; }
command -v zbarimg >/dev/null 2>&1 \
  || { printf '缺少必需测试工具 zbarimg。\n' >&2; exit 1; }
# Dynamic library sourcing and cross-file globals are intentional.
shellcheck -x -e SC1090,SC1091,SC2016,SC2034 "${shell_files[@]}"

printf '[2/9] 发行版、架构、DNS 与防火墙区域逻辑……\n'
bash "$ROOT/tests/platform-matrix.sh"
bash -c '
  set -Eeuo pipefail
  source "$1"
  calls=0
  apt-get() {
    ((calls += 1))
    if [[ "$1" == install ]]; then
      [[ " $* " == *" bind9-dnsutils "* ]]
      [[ " $* " == *" iputils-ping "* ]]
    fi
  }
  OS_FAMILY=debian install_dependencies >/dev/null
  [[ "$calls" == 2 ]]
' _ "$ROOT/lib/common.sh"
bash -c '
  set -Eeuo pipefail
  source "$1"
  calls=0
  microdnf() {
    ((calls += 1))
    [[ "$1" == "-y" && "$2" == "install" ]]
    [[ " $* " == *" bind-utils "* ]]
    [[ " $* " == *" iputils "* ]]
  }
  OS_FAMILY=rhel install_dependencies >/dev/null
  [[ "$calls" == 1 ]]
' _ "$ROOT/lib/common.sh"
bash -c '
  set -Eeuo pipefail
  source "$1"
  resolved_ipv4_addresses() {
    case "$1" in
      example.com|v4.example.com) printf "192.0.2.44\n" ;;
    esac
  }
  resolved_ipv6_addresses() {
    case "$1" in
      example.com|v6.example.com) printf "2001:db8::44\n" ;;
    esac
  }
  check_strict_dual_stack_dns example.com >/dev/null 2>&1
  [[ "$SUBSCRIPTION_DOMAIN_IPV4" == "v4.example.com" ]]
  [[ "$SUBSCRIPTION_DOMAIN_IPV6" == "v6.example.com" ]]
  [[ "$SUBSCRIPTION_IPV4_ADDRESS" == "192.0.2.44" ]]
  [[ "$SUBSCRIPTION_IPV6_ADDRESS" == "2001:db8::44" ]]
  is_safe_ip_literal 203.0.113.9
  is_safe_ip_literal 2001:db8::9
  ! is_safe_ip_literal 999.0.0.1
  ! is_safe_ip_literal "example.com"
  valid_ipv6=(
    "::"
    "::1"
    "2001:db8::"
    "2001:db8::9"
    "2001:0DB8:0000:0000:0000:0000:0000:0009"
    "1:2:3:4:5:6:7::"
  )
  invalid_ipv6=(
    ""
    ":"
    ":::"
    ":1:2:3:4:5:6:7"
    "1:2:3:4:5:6:7:"
    "1:2:3:4:5:6:7"
    "1:2:3:4:5:6:7:8:9"
    "1:2:3:4:5:6:7:8::"
    "1::2::3"
    "2001:db8::gg"
    "2001:db8::192.0.2.1"
  )
  for address in "${valid_ipv6[@]}"; do
    is_ipv6_literal "$address"
  done
  for address in "${invalid_ipv6[@]}"; do
    ! is_ipv6_literal "$address"
  done
' _ "$ROOT/lib/common.sh"
bash -c '
  set -Eeuo pipefail
  source "$1"
  SUBSCRIPTION_IPV4_ADDRESS=192.0.2.44
  SUBSCRIPTION_IPV6_ADDRESS=2001:db8::44
  ip() {
    case "$1:$2:$3:$4" in
      -4:route:get:192.0.2.44) printf "local 192.0.2.44 dev lo src 192.0.2.44\n" ;;
      -6:route:get:2001:db8::44) printf "local 2001:db8::44 dev lo src 2001:db8::44\n" ;;
    esac
  }
  assert_strict_addresses_local
' _ "$ROOT/lib/common.sh"
if bash -c '
  set -Eeuo pipefail
  source "$1"
  SUBSCRIPTION_IPV4_ADDRESS=192.0.2.44
  SUBSCRIPTION_IPV6_ADDRESS=2001:db8::44
  ip() {
    case "$1:$2:$3:$4" in
      -4:route:get:192.0.2.44) printf "192.0.2.44 via 192.0.2.1 dev eth0 src 192.0.2.10\n" ;;
      -6:route:get:2001:db8::44) printf "local 2001:db8::44 dev lo src 2001:db8::44\n" ;;
    esac
  }
  assert_strict_addresses_local
' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
  printf '严格 IPv4 地址不属于本机时没有被拒绝。\n' >&2
  exit 1
fi
if bash -c '
  set -Eeuo pipefail
  source "$1"
  resolved_ipv4_addresses() {
    case "$1" in example.com|v4.example.com) printf "192.0.2.44\n" ;; esac
  }
  resolved_ipv6_addresses() {
    case "$1" in
      example.com|v6.example.com) printf "2001:db8::44\n" ;;
      v4.example.com) printf "2001:db8::99\n" ;;
    esac
  }
  check_strict_dual_stack_dns example.com
' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
  printf '严格 IPv4 域名带 AAAA 时没有被拒绝。\n' >&2
  exit 1
fi
if bash -c '
  set -Eeuo pipefail
  source "$1"
  resolved_ipv4_addresses() {
    case "$1" in
      example.com|v4.example.com) printf "192.0.2.44\n" ;;
      v6.example.com) printf "192.0.2.99\n" ;;
    esac
  }
  resolved_ipv6_addresses() {
    case "$1" in example.com|v6.example.com) printf "2001:db8::44\n" ;; esac
  }
  check_strict_dual_stack_dns example.com
' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
  printf '严格 IPv6 域名带 A 时没有被拒绝。\n' >&2
  exit 1
fi
bash -c '
  set -Eeuo pipefail
  source "$1"
  source "$2"
  firewall-cmd() {
    case "$1" in
      --get-default-zone) printf "public\n" ;;
      --get-zone-of-interface=eth0) printf "public\n" ;;
      --get-zone-of-interface=eth1) printf "public6\n" ;;
      *) return 1 ;;
    esac
  }
  ip() {
    case "$1:$2:$3:$4" in
      -4:route:show:default) printf "default via 192.0.2.1 dev eth0\n" ;;
      -6:route:show:default) printf "default via 2001:db8::1 dev eth1\n" ;;
    esac
  }
  zones="$(firewalld_target_zones)"
  [[ "$zones" == $'"'"'public\npublic6'"'"' ]]
' _ "$ROOT/lib/common.sh" "$ROOT/lib/firewall.sh"

DNS_TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-dns-test.XXXXXX")"
mkdir -p "$DNS_TEST_WORK/bin"
cat > "$DNS_TEST_WORK/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${@: -2:1}"
record_type="${@: -1}"
printf '%s %s\n' "$record_type" "$name" >> "$NEKO_DNS_QUERY_LOG"
printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
case "${record_type}:${name}" in
  A:example.com.|A:v4.example.com.)
    printf '%s 60 IN A 192.0.2.44\n' "$name"
    ;;
  AAAA:example.com.|AAAA:v6.example.com.)
    printf '%s 60 IN AAAA 2001:db8::44\n' "$name"
    ;;
  *)
    if [[ "$name" != *. ]]; then
      printf '%s 60 IN A 13.248.169.48\n' "$name"
    fi
    ;;
esac
EOF
chmod 0755 "$DNS_TEST_WORK/bin/dig"
if ! NEKO_DNS_QUERY_LOG="$DNS_TEST_WORK/queries" \
  PATH="$DNS_TEST_WORK/bin:$PATH" LOCALDOMAIN=com bash -c '
    set -Eeuo pipefail
    source "$1"
    check_strict_dual_stack_dns example.com >/dev/null 2>&1
    while read -r record_type query_name; do
      [[ -n "$record_type" && "$query_name" == *. ]]
    done < "$NEKO_DNS_QUERY_LOG"
  ' _ "$ROOT/lib/common.sh"; then
  rm -rf -- "$DNS_TEST_WORK"
  printf '严格 DNS 查询仍会受到系统 search 后缀污染。\n' >&2
  exit 1
fi
rm -rf -- "$DNS_TEST_WORK"

FIREWALL_TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-firewall-test.XXXXXX")"
if ! NEKO_FIREWALL_CALLS="$FIREWALL_TEST_WORK/firewalld-calls" bash -c '
  set -Eeuo pipefail
  source "$1"
  source "$2"
  firewalld_is_active() { return 0; }
  ufw_is_active() { return 1; }
  firewalld_target_zones() { printf "public\npublic6\n"; }
  declare -A opened_ports=()
  firewall-cmd() {
    local argument zone="" action=""
    printf "%s\n" "$*" >> "$NEKO_FIREWALL_CALLS"
    for argument in "$@"; do
      case "$argument" in
        --zone=*) zone="${argument#--zone=}" ;;
        --add-port=80/tcp) action=add ;;
        --query-port=80/tcp) action=query ;;
        --remove-port=80/tcp) action=remove ;;
      esac
    done
    case "$action" in
      add) opened_ports["$zone"]=1 ;;
      query) [[ -n "${opened_ports[$zone]:-}" ]] ;;
      remove) unset "opened_ports[$zone]" ;;
    esac
  }
  open_temporary_http_challenge_port >/dev/null
  [[ "$TEMP_HTTP_FIREWALL_MANAGER" == firewalld ]]
  [[ "${TEMP_HTTP_FIREWALL_ZONES[*]}" == "public public6" ]]
  close_temporary_http_challenge_port
  [[ "$TEMP_HTTP_FIREWALL_MANAGER" == none ]]
  grep -Fq -- "--zone=public --add-port=80/tcp --timeout=10m" "$NEKO_FIREWALL_CALLS"
  grep -Fq -- "--zone=public6 --add-port=80/tcp --timeout=10m" "$NEKO_FIREWALL_CALLS"
  grep -Fq -- "--zone=public --remove-port=80/tcp" "$NEKO_FIREWALL_CALLS"
  grep -Fq -- "--zone=public6 --remove-port=80/tcp" "$NEKO_FIREWALL_CALLS"
' _ "$ROOT/lib/common.sh" "$ROOT/lib/firewall.sh"; then
  rm -rf -- "$FIREWALL_TEST_WORK"
  printf 'firewalld 的 HTTP-01 临时规则没有正确创建和清理。\n' >&2
  exit 1
fi
if ! NEKO_UFW_CALLS="$FIREWALL_TEST_WORK/ufw-calls" \
  NEKO_UFW_PROFILE="$FIREWALL_TEST_WORK/neko-acme-temporary" bash -c '
    set -Eeuo pipefail
    source "$1"
    TEMP_HTTP_UFW_PROFILE_FILE="$NEKO_UFW_PROFILE"
    source "$2"
    firewalld_is_active() { return 1; }
    ufw_is_active() { return 0; }
    ufw() {
      printf "%s\n" "$*" >> "$NEKO_UFW_CALLS"
      if [[ "$1" == status ]]; then
        printf "NekoACMETemporary ALLOW Anywhere\n"
      fi
    }
    open_temporary_http_challenge_port >/dev/null
    [[ "$TEMP_HTTP_FIREWALL_MANAGER" == ufw ]]
    [[ -f "$TEMP_HTTP_UFW_PROFILE_FILE" ]]
    close_temporary_http_challenge_port
    [[ "$TEMP_HTTP_FIREWALL_MANAGER" == none ]]
    [[ ! -e "$TEMP_HTTP_UFW_PROFILE_FILE" ]]
    grep -Fq "allow NekoACMETemporary" "$NEKO_UFW_CALLS"
    grep -Fq -- "--force delete allow NekoACMETemporary" "$NEKO_UFW_CALLS"
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/firewall.sh"; then
  rm -rf -- "$FIREWALL_TEST_WORK"
  printf 'UFW 的 HTTP-01 临时规则没有正确创建和清理。\n' >&2
  exit 1
fi
mkdir -p "$FIREWALL_TEST_WORK/etc"
jq '.firewall = {manager: "ufw", zone: "", zones: []}' \
  "$ROOT/tests/fixtures/state.json" \
  > "$FIREWALL_TEST_WORK/etc/state.json"
printf '%s\n' '[NekoProxy]' 'ports=443/tcp' \
  > "$FIREWALL_TEST_WORK/neko-proxy"
if ! NEKO_ETC="$FIREWALL_TEST_WORK/etc" \
  NEKO_VAR="$FIREWALL_TEST_WORK/var" \
  NEKO_STATE="$FIREWALL_TEST_WORK/etc/state.json" \
  NEKO_USER=root \
  UFW_PROFILE_FILE="$FIREWALL_TEST_WORK/neko-proxy" \
  NEKO_UFW_CALLS="$FIREWALL_TEST_WORK/ufw-sync-calls" bash -c '
    set -Eeuo pipefail
    source "$1"
    source "$2"
    ufw_is_active() { return 0; }
    ufw() {
      printf "%s\n" "$*" >> "$NEKO_UFW_CALLS"
      [[ "$1" != status ]] || printf "Status: active\nNekoProxy ALLOW Anywhere\n"
    }
    sync_managed_firewall_profile
    grep -Fq "24500" "$UFW_PROFILE_FILE"
    grep -Fq "31000" "$UFW_PROFILE_FILE"
    grep -Fq "27000:27127" "$UFW_PROFILE_FILE"
    grep -Fxq "app update NekoProxy" "$NEKO_UFW_CALLS"
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/firewall.sh"; then
  rm -rf -- "$FIREWALL_TEST_WORK"
  printf '升级时没有正确更新 Neko 的 UFW 应用规则。\n' >&2
  exit 1
fi
rm -rf -- "$FIREWALL_TEST_WORK"

printf '[3/9] 冻结版本身份与 lego v5 CLI……\n'
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
if grep -R "releases/latest\|/latest/download" \
    "$ROOT/install.sh" "$ROOT/upgrade.sh" \
    "$ROOT/tests/fetch-pinned-tools.sh" \
    "$ROOT/tests/fetch-pinned-qrc.sh" \
    "$ROOT/tests/fetch-pinned-nexttrace.sh"; then
  printf '发现未冻结的 latest 下载地址。\n' >&2
  exit 1
fi
grep -Fq 'NEKO_WORK_BASE=/var/tmp' "$ROOT/install.sh"
grep -Fq 'minimum_kib=$((768 * 1024))' "$ROOT/install.sh"
grep -Fq 'mktemp -d "${NEKO_WORK_BASE}/neko-install.XXXXXX"' "$ROOT/install.sh"
grep -Eq '^NEKO_SOURCE_COMMIT="[0-9a-f]{40}"$' "$ROOT/bootstrap.sh"
grep -Fq 'NEKO_RELEASE="1.11.1"' "$ROOT/versions.env"
grep -Fq 'runtime/route-diagnostics.sh' "$ROOT/bootstrap.sh"
grep -Fq 'runtime/route-diagnostics.sh' "$ROOT/install.sh"
if grep -Fq 'runtime/diagnostics.sh' "$ROOT/bootstrap.sh" \
    || grep -Fq 'runtime/diagnostics.sh' "$ROOT/install.sh"; then
  printf '新安装不应包含旧版完整自研体检。\n' >&2
  exit 1
fi
grep -Fq -- '--force-cert-domains' "$ROOT/runtime/renew.sh"
grep -Fq -- '--renew-force' "$ROOT/upgrade.sh"
grep -Fq -- '--cloudflare-token-file' "$ROOT/install.sh"
grep -Fq -- '--dns cloudflare' "$ROOT/lib/common.sh"
if grep -Eq '\|[[:space:]]*head([[:space:]]|$)' "$ROOT/install.sh"; then
  printf '安装器包含可能在 pipefail 下触发 SIGPIPE 的 head 管道。\n' >&2
  exit 1
fi

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

ACME_WORK="$(mktemp -d "$ROOT/tests/acme.XXXXXX")"
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

printf '[4/9] 渲染服务端配置与客户端订阅……\n'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-tests.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/etc" "$WORK/var/lego/certificates" "$WORK/var/acme"
cp "$ROOT/tests/fixtures/state.json" "$WORK/etc/state.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=example.com \
  -addext 'subjectAltName=DNS:example.com,DNS:v4.example.com,DNS:v6.example.com' \
  -keyout "$WORK/var/lego/certificates/example.com.key" \
  -out "$WORK/var/lego/certificates/example.com.crt" >/dev/null 2>&1

root_dir_name="${ROOT##*/}"
(
  cd "$ROOT"
  find . \
    -path './.git' -prune -o \
    -path './tests/.tools' -prune -o \
    \( -type f -o -type l \) -print0
) | tar --null --no-recursion \
  --transform="s#^\\./#${root_dir_name}/#" \
  -czf "$WORK/bootstrap-source.tar.gz" -C "$ROOT" --files-from=-
mkdir -p "$WORK/bootstrap-work"
NEKO_BOOTSTRAP_ARCHIVE="$WORK/bootstrap-source.tar.gz" \
  NEKO_BOOTSTRAP_WORK_BASE="$WORK/bootstrap-work" NEKO_BOOTSTRAP_TEST_MODE=1 \
  bash "$ROOT/bootstrap.sh" > "$WORK/bootstrap.log"
grep -Fq '[测试] Bootstrap 已成功校验固定安装包。' "$WORK/bootstrap.log"
if find "$WORK/bootstrap-work" -mindepth 1 -maxdepth 1 -name 'neko-bootstrap.*' | grep -q .; then
  printf 'Bootstrap 没有清理临时源码目录。\n' >&2
  exit 1
fi

mkdir -p "$WORK/bootstrap-minimal/bin" "$WORK/bootstrap-minimal/work"
for command_name in bash mktemp mkdir grep rm cp; do
  ln -s "$(command -v "$command_name")" "$WORK/bootstrap-minimal/bin/$command_name"
done
cat > "$WORK/bootstrap-minimal/bin/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" > "$NEKO_BOOTSTRAP_PM_LOG"
bin_dir="${BASH_SOURCE[0]%/*}"
"$NEKO_TEST_REAL_LN" -s "$NEKO_TEST_REAL_TAR" "$bin_dir/tar"
"$NEKO_TEST_REAL_LN" -s "$NEKO_TEST_REAL_GZIP" "$bin_dir/gzip"
EOF
chmod 0755 "$WORK/bootstrap-minimal/bin/dnf"
real_ln="$(command -v ln)"
real_tar="$(command -v tar)"
real_gzip="$(command -v gzip)"
PATH="$WORK/bootstrap-minimal/bin" \
  NEKO_TEST_REAL_LN="$real_ln" \
  NEKO_TEST_REAL_TAR="$real_tar" \
  NEKO_TEST_REAL_GZIP="$real_gzip" \
  NEKO_BOOTSTRAP_PM_LOG="$WORK/bootstrap-minimal/package-manager.log" \
  NEKO_BOOTSTRAP_ARCHIVE="$WORK/bootstrap-source.tar.gz" \
  NEKO_BOOTSTRAP_WORK_BASE="$WORK/bootstrap-minimal/work" \
  NEKO_BOOTSTRAP_TEST_MODE=1 \
  /usr/bin/bash "$ROOT/bootstrap.sh" > "$WORK/bootstrap-minimal/bootstrap.log"
grep -Fq 'tar gzip' "$WORK/bootstrap-minimal/bootstrap.log"
grep -Fxq -- '-y install ca-certificates tar gzip' \
  "$WORK/bootstrap-minimal/package-manager.log"
if grep -Eq 'coreutils|curl|gawk|glibc-common' \
  "$WORK/bootstrap-minimal/package-manager.log"; then
  printf 'Bootstrap 安装了并未缺少的软件包，可能与最小系统替代包冲突。\n' >&2
  exit 1
fi
grep -Fq '[测试] Bootstrap 已成功校验固定安装包。' \
  "$WORK/bootstrap-minimal/bootstrap.log"
if find "$WORK/bootstrap-minimal/work" -mindepth 1 -maxdepth 1 -name 'neko-bootstrap.*' | grep -q .; then
  printf '缺少 tar/gzip 的 Bootstrap 测试没有清理临时源码目录。\n' >&2
  exit 1
fi

NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
  bash -c 'source "$1"; source "$2"; render_all' \
  _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

printf '[5/9] 用真实冻结核心校验配置……\n'
"$SING_BOX" check -c "$WORK/etc/config/sing-box.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v4.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v6.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v4-to-v6.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v6-to-v4.json"
"$XRAY" run -test -c "$WORK/etc/config/xray.json"
"$CADDY" validate --config "$WORK/etc/config/Caddyfile" --adapter caddyfile >/dev/null
mkdir -p \
  "$WORK/mihomo-v4" "$WORK/mihomo-v6" \
  "$WORK/mihomo-v4-to-v6" "$WORK/mihomo-v6-to-v4"
"$MIHOMO" -d "$WORK/mihomo-v4" -t -f "$WORK/etc/subscriptions/mihomo-v4.yaml"
"$MIHOMO" -d "$WORK/mihomo-v6" -t -f "$WORK/etc/subscriptions/mihomo-v6.yaml"
"$MIHOMO" -d "$WORK/mihomo-v4-to-v6" -t \
  -f "$WORK/etc/subscriptions/mihomo-v4-to-v6.yaml"
"$MIHOMO" -d "$WORK/mihomo-v6-to-v4" -t \
  -f "$WORK/etc/subscriptions/mihomo-v6-to-v4.yaml"
for family in v4 v6 v4-to-v6 v6-to-v4; do
  set +e
  PATH=/nonexistent "$HYSTERIA" server --disable-update-check \
    --config "$WORK/etc/config/hysteria-${family}.yaml" \
    >"$WORK/hysteria-${family}-check.log" 2>&1
  hysteria_rc=$?
  set -e
  (( hysteria_rc != 0 ))
  grep -Fq 'executable file not found' "$WORK/hysteria-${family}-check.log"
done

printf '[6/9] 校验严格订阅、出口策略、端口和 REALITY 目标……\n'
bash -c '
  set -Eeuo pipefail
  source "$1"
  for ((round = 0; round < 50; round++)); do
    initialize_port_reservations
    reserve_random_range 128 range_start range_end
    reserve_random_port tuic
    reserve_random_port ss
    reserve_random_port anytls
    reserve_random_port trojan
    reserve_random_port vision
    reserve_random_port xhttp
    declare -A seen=()
    for ((port = range_start; port <= range_end; port++)); do seen[$port]=1; done
    for port in "$tuic" "$ss" "$anytls" "$trojan" "$vision" "$xhttp"; do
      [[ -z "${seen[$port]+x}" ]]
      seen[$port]=1
    done
  done
' _ "$ROOT/lib/common.sh"
python3 - "$WORK" <<'PY'
import base64
import json
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
state = json.loads((root / "etc/state.json").read_text())
assert state["acme"]["method"] == "http-01"
xray = json.loads((root / "etc/config/xray.json").read_text())
sing = json.loads((root / "etc/config/sing-box.json").read_text())
hysteria_v4 = yaml.safe_load((root / "etc/config/hysteria-v4.yaml").read_text())
hysteria_v6 = yaml.safe_load((root / "etc/config/hysteria-v6.yaml").read_text())
hysteria_v4_to_v6 = yaml.safe_load(
    (root / "etc/config/hysteria-v4-to-v6.yaml").read_text()
)
hysteria_v6_to_v4 = yaml.safe_load(
    (root / "etc/config/hysteria-v6-to-v4.yaml").read_text()
)
caddy = (root / "etc/config/Caddyfile").read_text()

expected_subscription_files = {
    f"{client}-{route}.{extension}"
    for client, extension in (
        ("mihomo", "yaml"), ("stash", "yaml"),
        ("shadowrocket", "txt"), ("sing-box", "json"),
    )
    for route in ("v4", "v6", "v4-to-v6", "v6-to-v4")
}
assert {p.name for p in (root / "etc/subscriptions").iterdir()} == expected_subscription_files

for family, address, ip_version, route_ports, expected_dns_strategy, expected_dns_server, rejected_ip_version in (
    ("v4", state["subscription"]["ipv4_address"], "ipv4", state["ports"],
     "ipv4_only", "1.1.1.1", 6),
    ("v6", state["subscription"]["ipv6_address"], "ipv6", state["ports"],
     "ipv6_only", "2606:4700:4700::1111", 4),
    ("v4-to-v6", state["subscription"]["ipv4_address"], "ipv4", state["ports"]["cross"],
     "ipv6_only", "2606:4700:4700::1111", 4),
    ("v6-to-v4", state["subscription"]["ipv6_address"], "ipv6", state["ports"]["cross"],
     "ipv4_only", "1.1.1.1", 6),
):
    mihomo = yaml.safe_load((root / f"etc/subscriptions/mihomo-{family}.yaml").read_text())
    stash = yaml.safe_load((root / f"etc/subscriptions/stash-{family}.yaml").read_text())
    shadow = yaml.safe_load((root / f"etc/subscriptions/shadowrocket-{family}.txt").read_text())
    sing_client = json.loads(
        (root / f"etc/subscriptions/sing-box-{family}.json").read_text()
    )

    assert len(mihomo["proxies"]) == 7
    assert all(p["server"] == address for p in mihomo["proxies"])
    assert all(p["ip-version"] == ip_version for p in mihomo["proxies"])
    mihomo_tuic = next(p for p in mihomo["proxies"] if p["type"] == "tuic")
    assert mihomo_tuic["sni"] == "example.com"
    assert mihomo_tuic["disable-sni"] is False
    mihomo_trojan = next(p for p in mihomo["proxies"] if p["type"] == "trojan")
    assert mihomo_trojan == {
        "name": "Trojan-TLS",
        "type": "trojan",
        "server": address,
        "ip-version": ip_version,
        "port": route_ports["trojan"],
        "password": state["credentials"]["trojan_password"],
        "sni": "example.com",
        "udp": True,
        "skip-cert-verify": False,
    }
    assert len(stash["proxies"]) == 6
    assert all(p["server"] == address for p in stash["proxies"])
    assert all(p["network"] != "xhttp" for p in stash["proxies"] if p["type"] == "vless")
    stash_hy2 = next(p for p in stash["proxies"] if p["type"] == "hysteria2")
    stash_tuic = next(p for p in stash["proxies"] if p["type"] == "tuic")
    stash_trojan = next(p for p in stash["proxies"] if p["type"] == "trojan")
    stash_vision = next(p for p in stash["proxies"] if p["type"] == "vless")
    assert stash_hy2["auth"] == "test-hy2-password" and "password" not in stash_hy2
    assert stash_tuic["version"] == 5
    assert stash_trojan["port"] == route_ports["trojan"]
    assert stash_trojan["password"] == state["credentials"]["trojan_password"]
    assert stash_trojan["sni"] == "example.com"
    assert stash_trojan["skip-cert-verify"] is False
    assert stash_vision["sni"] == "example.com" and "servername" not in stash_vision

    shadow_proxies = shadow["proxies"]
    assert [p["type"] for p in shadow_proxies] == [
        "hysteria2", "tuic", "ss", "anytls", "trojan", "vless", "vless"
    ]
    assert all(p["server"] == address for p in shadow_proxies)
    shadow_hy2, shadow_tuic, _, _, shadow_trojan, shadow_vision, shadow_xhttp = shadow_proxies
    route_hy2_range = f'{route_ports["hysteria2_start"]}-{route_ports["hysteria2_end"]}'
    assert shadow_hy2["port-range"] == route_hy2_range
    assert shadow_hy2["ports"] == route_hy2_range
    assert shadow_tuic["version"] == 5
    assert shadow_trojan["port"] == route_ports["trojan"]
    assert shadow_trojan["password"] == state["credentials"]["trojan_password"]
    assert shadow_trojan["sni"] == "example.com"
    assert shadow_trojan["skip-cert-verify"] is False
    assert shadow_vision["network"] == "tcp"
    assert shadow_vision["reality-opts"]["public-key"] == state["reality"]["vision_public_key"]
    assert shadow_xhttp["network"] == "xhttp"
    assert shadow_xhttp["xhttp-opts"]["mode"] == "stream-one"
    assert shadow_xhttp["xhttp-opts"]["path"] == state["reality"]["xhttp_path"]

    expected_selector = [
        "HY2", "TUIC-v5", "SS2022", "AnyTLS", "Trojan-TLS",
        "VLESS-Reality-Vision"
    ]
    client_outbounds = {outbound["tag"]: outbound for outbound in sing_client["outbounds"]}
    assert set(client_outbounds) == {"PROXY", *expected_selector}
    assert client_outbounds["PROXY"] == {
        "type": "selector",
        "tag": "PROXY",
        "outbounds": expected_selector,
        "default": "HY2",
    }
    assert all(
        outbound["server"] == address
        for tag, outbound in client_outbounds.items()
        if tag != "PROXY"
    )
    assert all(outbound["type"] != "direct" for outbound in sing_client["outbounds"])
    assert client_outbounds["HY2"]["server_ports"] == [
        f'{route_ports["hysteria2_start"]}:{route_ports["hysteria2_end"]}'
    ]
    assert client_outbounds["HY2"]["hop_interval"] == "30s"
    assert client_outbounds["TUIC-v5"]["udp_relay_mode"] == "native"
    assert client_outbounds["SS2022"]["method"] == "2022-blake3-aes-128-gcm"
    assert client_outbounds["VLESS-Reality-Vision"]["flow"] == "xtls-rprx-vision"
    assert client_outbounds["VLESS-Reality-Vision"]["network"] == "tcp"
    assert client_outbounds["VLESS-Reality-Vision"]["tls"]["reality"] == {
        "enabled": True,
        "public_key": state["reality"]["vision_public_key"],
        "short_id": state["reality"]["vision_short_id"],
    }
    for tag in ("HY2", "TUIC-v5", "AnyTLS", "Trojan-TLS", "VLESS-Reality-Vision"):
        assert client_outbounds[tag]["tls"]["server_name"] == "example.com"
        assert client_outbounds[tag]["tls"]["insecure"] is False
    assert client_outbounds["Trojan-TLS"] == {
        "type": "trojan",
        "tag": "Trojan-TLS",
        "server": address,
        "server_port": route_ports["trojan"],
        "password": state["credentials"]["trojan_password"],
        "tls": {
            "enabled": True,
            "server_name": "example.com",
            "insecure": False,
        },
    }
    assert sing_client["dns"] == {
        "servers": [{
            "type": "https",
            "tag": "strict-doh",
            "server": expected_dns_server,
            "server_port": 443,
            "path": "/dns-query",
            "tls": {
                "enabled": True,
                "server_name": "cloudflare-dns.com",
                "insecure": False,
            },
            "detour": "PROXY",
        }],
        "final": "strict-doh",
        "strategy": expected_dns_strategy,
    }
    assert sing_client["inbounds"] == [{
        "type": "tun",
        "tag": "tun-in",
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        "auto_route": True,
        "strict_route": True,
        "stack": "mixed",
    }]
    assert sing_client["route"] == {
        "rules": [
            {"protocol": "dns", "action": "hijack-dns"},
            {"ip_version": rejected_ip_version, "action": "reject"},
        ],
        "final": "PROXY",
        "auto_detect_interface": True,
    }
    assert sing_client["experimental"] == {"cache_file": {"enabled": True}}

ports = state["ports"]
cross_ports = ports["cross"]
all_used_ports = set()
for port_set in (ports, cross_ports):
    singles = [
        port_set[k] for k in (
        "tuic", "ss2022", "anytls", "trojan",
        "vless_reality_vision", "vless_reality_xhttp",
        )
    ]
    port_range = set(range(port_set["hysteria2_start"], port_set["hysteria2_end"] + 1))
    assert len(port_range) == 128
    assert len(set(singles)) == len(singles)
    assert not port_range.intersection(singles)
    assert not all_used_ports.intersection(port_range | set(singles))
    all_used_ports |= port_range | set(singles)

v4_address = state["subscription"]["ipv4_address"]
v6_address = state["subscription"]["ipv6_address"]

assert len(sing["inbounds"]) == 16
sing_inbounds = {inbound["tag"]: inbound for inbound in sing["inbounds"]}
sing_protocol_ports = {
    "tuic": "tuic", "ss2022": "ss2022", "anytls": "anytls", "trojan": "trojan"
}
for suffix, address, route_ports in (
    ("v4", v4_address, ports),
    ("v6", v6_address, ports),
    ("v4-to-v6", v4_address, cross_ports),
    ("v6-to-v4", v6_address, cross_ports),
):
    for protocol, port_key in sing_protocol_ports.items():
        inbound = sing_inbounds[f"{protocol}-{suffix}-in"]
        assert inbound["listen"] == address
        assert inbound["listen_port"] == route_ports[port_key]

assert len(xray["inbounds"]) == 8
xray_inbounds = {inbound["tag"]: inbound for inbound in xray["inbounds"]}
for suffix, address, route_ports in (
    ("v4", v4_address, ports),
    ("v6", v6_address, ports),
    ("v4-to-v6", v4_address, cross_ports),
    ("v6-to-v4", v6_address, cross_ports),
):
    vision = xray_inbounds[f"vless-reality-vision-{suffix}-in"]
    xhttp = xray_inbounds[f"vless-reality-xhttp-{suffix}-in"]
    assert vision["listen"] == address and vision["port"] == route_ports["vless_reality_vision"]
    assert xhttp["listen"] == address and xhttp["port"] == route_ports["vless_reality_xhttp"]
for inbound in xray["inbounds"]:
    reality = inbound["streamSettings"]["realitySettings"]
    assert reality["target"] == "127.0.0.1:8443"
    assert reality["serverNames"] == ["example.com"]
cert_path = str(root / "var/lego/certificates/example.com.crt")
key_path = str(root / "var/lego/certificates/example.com.key")
for suffix, address, route_ports in (
    ("v4", v4_address, ports),
    ("v6", v6_address, ports),
    ("v4-to-v6", v4_address, cross_ports),
    ("v6-to-v4", v6_address, cross_ports),
):
    trojan = sing_inbounds[f"trojan-{suffix}-in"]
    assert trojan["listen"] == address
    assert trojan["listen_port"] == route_ports["trojan"]
    assert trojan["users"] == [
        {"password": state["credentials"]["trojan_password"]}
    ]
    assert trojan["tls"] == {
        "enabled": True,
        "server_name": "example.com",
        "certificate_path": cert_path,
        "key_path": key_path,
    }
tls_inbounds = [i for i in sing["inbounds"] if "tls" in i]
assert all(i["tls"]["certificate_path"] == cert_path for i in tls_inbounds)
assert all(i["tls"]["key_path"] == key_path for i in tls_inbounds)
v4_egress_tags = [
    "tuic-v4-in", "ss2022-v4-in", "anytls-v4-in", "trojan-v4-in",
    "tuic-v6-to-v4-in", "ss2022-v6-to-v4-in",
    "anytls-v6-to-v4-in", "trojan-v6-to-v4-in",
]
v6_egress_tags = [
    "tuic-v6-in", "ss2022-v6-in", "anytls-v6-in", "trojan-v6-in",
    "tuic-v4-to-v6-in", "ss2022-v4-to-v6-in",
    "anytls-v4-to-v6-in", "trojan-v4-to-v6-in",
]
assert sing["route"]["rules"][0] == {"network": "tcp", "port": 25, "action": "reject"}
assert sing["route"]["rules"][1] == {
    "inbound": v4_egress_tags,
    "action": "resolve",
    "server": "local",
    "strategy": "ipv4_only",
}
assert sing["route"]["rules"][2] == {
    "inbound": v6_egress_tags,
    "action": "resolve",
    "server": "local",
    "strategy": "ipv6_only",
}
assert sing["route"]["rules"][3] == {"ip_is_private": True, "action": "reject"}
assert sing["route"]["rules"][4] == {
    "inbound": v4_egress_tags,
    "ip_version": 6,
    "action": "reject",
}
assert sing["route"]["rules"][5] == {
    "inbound": v6_egress_tags,
    "ip_version": 4,
    "action": "reject",
}
assert sing["route"]["rules"][6] == {
    "inbound": v4_egress_tags,
    "action": "route",
    "outbound": "direct-v4",
}
assert sing["route"]["rules"][7] == {
    "inbound": v6_egress_tags,
    "action": "route",
    "outbound": "direct-v6",
}
sing_outbounds = {outbound["tag"]: outbound for outbound in sing["outbounds"]}
assert sing_outbounds == {
    "direct-v4": {
        "type": "direct",
        "tag": "direct-v4",
        "inet4_bind_address": v4_address,
        "domain_resolver": {"server": "local", "strategy": "ipv4_only"},
    },
    "direct-v6": {
        "type": "direct",
        "tag": "direct-v6",
        "inet6_bind_address": v6_address,
        "domain_resolver": {"server": "local", "strategy": "ipv6_only"},
    },
}
assert sing["dns"] == {
    "servers": [{"type": "local", "tag": "local", "prefer_go": True}]
}
assert {o["tag"]: o["protocol"] for o in xray["outbounds"]} == {
    "direct-v4": "freedom", "direct-v6": "freedom", "blocked": "blackhole"
}
xray_outbounds = {outbound["tag"]: outbound for outbound in xray["outbounds"]}
assert xray_outbounds["direct-v4"]["sendThrough"] == v4_address
assert xray_outbounds["direct-v4"]["targetStrategy"] == "ForceIPv4"
assert xray_outbounds["direct-v4"]["settings"]["domainStrategy"] == "ForceIPv4"
assert xray_outbounds["direct-v6"]["sendThrough"] == v6_address
assert xray_outbounds["direct-v6"]["targetStrategy"] == "ForceIPv6"
assert xray_outbounds["direct-v6"]["settings"]["domainStrategy"] == "ForceIPv6"
assert xray["routing"]["domainStrategy"] == "IPIfNonMatch"
assert xray["routing"]["rules"][0]["outboundTag"] == "blocked"
assert "169.254.0.0/16" in xray["routing"]["rules"][0]["ip"]
assert "fc00::/7" in xray["routing"]["rules"][0]["ip"]
assert xray["routing"]["rules"][1] == {
    "type": "field", "network": "tcp", "port": 25, "outboundTag": "blocked"
}
assert xray["routing"]["rules"][2] == {
    "type": "field",
    "inboundTag": [
        "vless-reality-vision-v4-in", "vless-reality-xhttp-v4-in",
        "vless-reality-vision-v6-to-v4-in", "vless-reality-xhttp-v6-to-v4-in",
    ],
    "outboundTag": "direct-v4",
}
assert xray["routing"]["rules"][3] == {
    "type": "field",
    "inboundTag": [
        "vless-reality-vision-v6-in", "vless-reality-xhttp-v6-in",
        "vless-reality-vision-v4-to-v6-in", "vless-reality-xhttp-v4-to-v6-in",
    ],
    "outboundTag": "direct-v6",
}

for family, hysteria, address, mode, bind_field, listen in (
    ("v4", hysteria_v4, v4_address, 4, "bindIPv4", f"{v4_address}:21000-21127"),
    ("v6", hysteria_v6, v6_address, 6, "bindIPv6", f"[{v6_address}]:21000-21127"),
    ("v4-to-v6", hysteria_v4_to_v6, v6_address, 6, "bindIPv6",
     f'{v4_address}:{cross_ports["hysteria2_start"]}-{cross_ports["hysteria2_end"]}'),
    ("v6-to-v4", hysteria_v6_to_v4, v4_address, 4, "bindIPv4",
     f'[{v6_address}]:{cross_ports["hysteria2_start"]}-{cross_ports["hysteria2_end"]}'),
):
    assert hysteria["listen"] == listen
    assert hysteria["tls"] == {"cert": cert_path, "key": key_path}
    assert hysteria["auth"]["password"] == "test-hy2-password"
    assert hysteria["obfs"]["salamander"]["password"] == "test-hy2-obfs-password"
    assert hysteria["outbounds"] == [{
        "name": "direct",
        "type": "direct",
        "direct": {"mode": mode, bind_field: address},
    }]
    assert "reject(169.254.0.0/16)" in hysteria["acl"]["inline"]
    assert "reject(fc00::/7)" in hysteria["acl"]["inline"]
    assert "reject(all, tcp/25)" in hysteria["acl"]["inline"]
    assert hysteria["acl"]["inline"][-1] == "direct(all)"
assert not (root / "etc/config/hysteria.yaml").exists()
assert caddy.count(f"tls {cert_path} {key_path}") == 4
assert "protocols h1 h2" in caddy
assert "mihomo-v4.yaml" in caddy and "mihomo-v6.yaml" in caddy
assert "sing-box-v4.json" in caddy and "sing-box-v6.json" in caddy
assert "sing-box-v4-to-v6.json" in caddy and "sing-box-v6-to-v4.json" in caddy
assert "https://v4.example.com" in caddy and "https://v6.example.com" in caddy
assert "handle /test-subscription-token/v4/mihomo.yaml" in caddy
assert "handle /test-subscription-token/v6/mihomo.yaml" in caddy
assert "handle /test-v4-to-v6-token/v4-to-v6/mihomo.yaml" in caddy
assert "handle /test-v6-to-v4-token/v6-to-v4/mihomo.yaml" in caddy
assert caddy.count("handle /test-subscription-token/mihomo.yaml") == 2
assert (
    "handle /test-subscription-token/v4/mihomo.yaml {\n"
    "\t\trewrite * /mihomo-v4.yaml"
) in caddy
assert (
    "handle /test-subscription-token/v6/mihomo.yaml {\n"
    "\t\trewrite * /mihomo-v6.yaml"
) in caddy
assert 'header Content-Type "text/yaml; charset=utf-8"' in caddy
assert caddy.count('header Content-Type "application/json; charset=utf-8"') == 6
PY

links="$(
  NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
    bash -c 'source "$1"; show_subscription_links' _ "$ROOT/lib/common.sh"
)"
[[ "$links" == *'https://example.com/test-subscription-token/v4/mihomo.yaml'* ]]
[[ "$links" == *'https://example.com/test-subscription-token/v6/mihomo.yaml'* ]]
[[ "$links" == *'https://example.com/test-subscription-token/v4/sing-box.json'* ]]
[[ "$links" == *'https://example.com/test-subscription-token/v6/sing-box.json'* ]]
[[ "$links" == *'https://example.com/test-v4-to-v6-token/v4-to-v6/mihomo.yaml'* ]]
[[ "$links" == *'https://example.com/test-v6-to-v4-token/v6-to-v4/sing-box.json'* ]]
[[ "$(grep -c '（严格）' <<< "$links")" == 16 ]]

qr_url='https://example.com/test-subscription-token/v4/mihomo.yaml'
printf '%s' "$qr_url" \
  | "$QRC" --output-format unicode --invert \
    --ec-level M --scale 1 --border 4 > "$WORK/subscription-qr.unicode"
python3 "$ROOT/tests/unicode-qr-to-pbm.py" \
  < "$WORK/subscription-qr.unicode" > "$WORK/subscription-qr.pbm"
decoded_qr="$(
  zbarimg --quiet --raw "$WORK/subscription-qr.pbm" 2>/dev/null
)"
[[ "$decoded_qr" == "$qr_url" ]]
bash "$ROOT/tests/panel-qrcode.sh"
bash "$ROOT/tests/panel-route-guide.sh"
bash "$ROOT/tests/panel-third-party.sh"
bash "$ROOT/tests/route-diagnostics.sh"
SING_BOX_BIN="$SING_BOX" XRAY_BIN="$XRAY" \
  bash "$ROOT/tests/default-anyreality-install.sh"
SING_BOX_BIN="$SING_BOX" bash "$ROOT/tests/experimental-anyreality.sh"

printf '[7/9] 模拟订阅令牌轮换，并检查 systemd 安全关键项……\n'
jq '.subscription.ipv4_token = "replacement-ipv4-token"' \
  "$WORK/etc/state.json" > "$WORK/etc/state.new"
mv "$WORK/etc/state.new" "$WORK/etc/state.json"
NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
  bash -c 'source "$1"; source "$2"; render_all' \
  _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
grep -Fq '/replacement-ipv4-token/mihomo.yaml' "$WORK/etc/config/Caddyfile"
grep -Fq '/replacement-ipv4-token/sing-box.json' "$WORK/etc/config/Caddyfile"
grep -Fq '/replacement-ipv4-token/v4/mihomo.yaml' \
  "$WORK/etc/config/Caddyfile"
grep -Fq '/replacement-ipv4-token/v4/sing-box.json' \
  "$WORK/etc/config/Caddyfile"
[[ "$(grep -Fc '/test-subscription-token/' "$WORK/etc/config/Caddyfile")" == 8 ]]
if grep -Fq '/test-subscription-token/v4/' \
    "$WORK/etc/config/Caddyfile"; then
  printf 'IPv4 的旧订阅令牌仍出现在通用 Caddy 下载入口中。\n' >&2
  exit 1
fi
grep -Fq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$ROOT/systemd/neko-sing-box.service"
grep -Fq 'AmbientCapabilities=CAP_NET_ADMIN' "$ROOT/systemd/neko-hysteria.service"
grep -Fq 'ExecStart=/usr/local/libexec/neko/hysteria-dual.sh' "$ROOT/systemd/neko-hysteria.service"
grep -Fq 'wait -n "${pids[@]}"' "$ROOT/runtime/hysteria-dual.sh"
grep -Fq 'ReadWritePaths=/var/lib/neko' "$ROOT/systemd/neko-renew.service"
grep -Fq 'systemctl stop neko-renew.service' "$ROOT/runtime/panel.sh"
grep -Fq 'restart_runtime_services' "$ROOT/runtime/panel.sh"
bash "$ROOT/tests/panel-refresh.sh"
bash "$ROOT/tests/panel-credentials.sh"

SUPERVISOR_WORK="$WORK/hysteria-supervisor"
mkdir -p "$SUPERVISOR_WORK/config"
printf 'listen: test-v4\n' > "$SUPERVISOR_WORK/config/hysteria-v4.yaml"
printf 'listen: test-v6\n' > "$SUPERVISOR_WORK/config/hysteria-v6.yaml"
printf 'listen: test-v4-to-v6\n' \
  > "$SUPERVISOR_WORK/config/hysteria-v4-to-v6.yaml"
printf 'listen: test-v6-to-v4\n' \
  > "$SUPERVISOR_WORK/config/hysteria-v6-to-v4.yaml"
cat > "$SUPERVISOR_WORK/fake-hysteria" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
config=""
while (( $# )); do
  case "$1" in
    --config)
      config="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
case "$config" in
  *hysteria-v4.yaml)
    : > "$NEKO_SUPERVISOR_TEST_DIR/v4.started"
    sleep 0.5
    exit 0
    ;;
  *hysteria-v6.yaml)
    printf '%s\n' "$$" > "$NEKO_SUPERVISOR_TEST_DIR/v6.pid"
    : > "$NEKO_SUPERVISOR_TEST_DIR/v6.started"
    trap ': > "$NEKO_SUPERVISOR_TEST_DIR/v6.terminated"; exit 0' TERM INT
    while :; do sleep 0.1; done
    ;;
  *hysteria-v4-to-v6.yaml)
    printf '%s\n' "$$" > "$NEKO_SUPERVISOR_TEST_DIR/v4-to-v6.pid"
    : > "$NEKO_SUPERVISOR_TEST_DIR/v4-to-v6.started"
    trap ': > "$NEKO_SUPERVISOR_TEST_DIR/v4-to-v6.terminated"; exit 0' TERM INT
    while :; do sleep 0.1; done
    ;;
  *hysteria-v6-to-v4.yaml)
    printf '%s\n' "$$" > "$NEKO_SUPERVISOR_TEST_DIR/v6-to-v4.pid"
    : > "$NEKO_SUPERVISOR_TEST_DIR/v6-to-v4.started"
    trap ': > "$NEKO_SUPERVISOR_TEST_DIR/v6-to-v4.terminated"; exit 0' TERM INT
    while :; do sleep 0.1; done
    ;;
  *) exit 64 ;;
esac
EOF
chmod 0755 "$SUPERVISOR_WORK/fake-hysteria"
set +e
NEKO_HYSTERIA_BINARY="$SUPERVISOR_WORK/fake-hysteria" \
  NEKO_CONFIG_DIR="$SUPERVISOR_WORK/config" \
  NEKO_SUPERVISOR_TEST_DIR="$SUPERVISOR_WORK" \
  "$ROOT/runtime/hysteria-dual.sh"
supervisor_rc=$?
set -e
(( supervisor_rc != 0 ))
[[ -e "$SUPERVISOR_WORK/v4.started" ]]
[[ -e "$SUPERVISOR_WORK/v6.started" ]]
[[ -e "$SUPERVISOR_WORK/v6.terminated" ]]
for child in v6 v4-to-v6 v6-to-v4; do
  [[ -e "$SUPERVISOR_WORK/${child}.started" ]]
  [[ -e "$SUPERVISOR_WORK/${child}.terminated" ]]
  child_pid="$(<"$SUPERVISOR_WORK/${child}.pid")"
  if kill -0 "$child_pid" 2>/dev/null; then
    printf 'Hysteria 监管脚本留下了 %s 子进程。\n' "$child" >&2
    exit 1
  fi
done

mode_gate_line="$(grep -n 'collect_network_mode' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
domain_gate_line="$(grep -n 'collect_identity' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
dependency_line="$(grep -n 'install_dependencies' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
lock_line="$(grep -n 'exec 9>/run/lock/neko-install.lock' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
(( mode_gate_line < dependency_line
  && dependency_line < domain_gate_line
  && domain_gate_line < lock_line ))

printf '[8/9] IPv4-only、IPv6-only 与面板地址族事务……\n'
bash "$ROOT/tests/family-modes.sh"

printf '[9/9] 模拟旧版本原地升级成功与失败回滚……\n'
prepare_upgrade_install() {
  local target="$1" schema="${2:-1}" source_release="${3:-}"
  local source_mode="${4:-dual}"
  local source_has_trojan="${5:-false}" state_tmp
  mkdir -p \
    "$target/etc/config" "$target/etc/subscriptions" \
    "$target/var/acme" "$target/libexec/lib" "$target/systemd" "$target/tmp" \
    "$target/firewall"
  cp -a -- "$WORK/etc/config/." "$target/etc/config/"
  if [[ "$source_release" == "1.2.3-test" ]]; then
    cp -a -- \
      "$WORK/etc/subscriptions/mihomo-v4.yaml" \
      "$WORK/etc/subscriptions/mihomo-v6.yaml" \
      "$WORK/etc/subscriptions/stash-v4.yaml" \
      "$WORK/etc/subscriptions/stash-v6.yaml" \
      "$WORK/etc/subscriptions/shadowrocket-v4.txt" \
      "$WORK/etc/subscriptions/shadowrocket-v6.txt" \
      "$target/etc/subscriptions/"
  else
    cp -a -- "$WORK/etc/subscriptions/mihomo-v4.yaml" \
      "$target/etc/subscriptions/mihomo.yaml"
    cp -a -- "$WORK/etc/subscriptions/stash-v4.yaml" \
      "$target/etc/subscriptions/stash.yaml"
    cp -a -- "$WORK/etc/subscriptions/shadowrocket-v4.txt" \
      "$target/etc/subscriptions/shadowrocket.txt"
  fi
  if [[ "$schema" == 1 ]]; then
    jq '
      .schema = 1
      | .release = "1.0.4-test"
      | del(.acme)
      | del(.network)
      | del(.ports.cross)
      | .subscription = {
          token: .subscription.ipv4_token,
          shadowrocket_server: .subscription.ipv4_address
        }
      | .firewall = {manager: "none", zone: ""}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  elif [[ "$schema" == 2 ]]; then
    jq --arg release "${source_release:-1.1.1-test}" '
      .schema = 2
      | .release = $release
      | .acme = {method: "http-01"}
      | .network = {listen_address: "::"}
      | .subscription.token = .subscription.ipv4_token
      | del(
          .subscription.ipv4_token,
          .subscription.ipv6_token,
          .subscription.ipv4_to_ipv6_token,
          .subscription.ipv6_to_ipv4_token,
          .ports.cross
        )
      | .firewall = {manager: "none", zone: "", zones: []}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  elif [[ "$schema" == 3 ]]; then
    jq \
      --arg release "${source_release:-1.2.4-test}" \
      --arg mode "$source_mode" '
      .schema = 3
      | .release = $release
      | .network = {mode: $mode}
      | .subscription.ipv4_to_ipv6_token = null
      | .subscription.ipv6_to_ipv4_token = null
      | .ports.cross = null
      | if $mode == "ipv4-only" then
          .subscription.ipv6_token = null
          | .subscription.ipv6_domain = null
          | .subscription.ipv6_address = null
        elif $mode == "ipv6-only" then
          .subscription.ipv4_token = null
          | .subscription.ipv4_domain = null
          | .subscription.ipv4_address = null
        else . end
      | .firewall = {manager: "none", zone: "", zones: []}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  else
    jq \
      --arg release "${source_release:-1.9.0-test}" \
      --arg mode "$source_mode" '
      .schema = 4
      | .release = $release
      | .network = {mode: $mode}
      | if $mode == "ipv4-only" then
          .subscription.ipv6_token = null
          | .subscription.ipv4_to_ipv6_token = null
          | .subscription.ipv6_to_ipv4_token = null
          | .subscription.ipv6_domain = null
          | .subscription.ipv6_address = null
          | .ports.cross = null
        elif $mode == "ipv6-only" then
          .subscription.ipv4_token = null
          | .subscription.ipv4_to_ipv6_token = null
          | .subscription.ipv6_to_ipv4_token = null
          | .subscription.ipv4_domain = null
          | .subscription.ipv4_address = null
          | .ports.cross = null
        else . end
      | .firewall = {manager: "none", zone: "", zones: []}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  fi
  if [[ "$source_has_trojan" != true ]]; then
    state_tmp="$(mktemp "$target/etc/state.json.tmp.XXXXXX")"
    jq 'del(.ports.trojan, .credentials.trojan_password)' \
      "$target/etc/state.json" > "$state_tmp"
    mv -f -- "$state_tmp" "$target/etc/state.json"
  fi
  cp -a -- "$WORK/var/lego" "$target/var/lego"
  cp -a -- "$ROOT/lib/." "$target/libexec/lib/"
  cp -a -- "$ROOT/versions.env" "$target/libexec/versions.env"
  cp -a -- "$ROOT/runtime/panel.sh" "$ROOT/runtime/renew.sh" "$target/libexec/"
  cp -a -- \
    "$ROOT/tests/fixtures/neko-hysteria-legacy.service" \
    "$target/systemd/neko-hysteria.service"
  ln -s "$SING_BOX" "$target/libexec/sing-box"
  ln -s "$XRAY" "$target/libexec/xray"
  ln -s "$HYSTERIA" "$target/libexec/hysteria"
  ln -s "$CADDY" "$target/libexec/caddy"
  ln -s "$LEGO" "$target/libexec/lego"
}

run_upgrade() {
  local target="$1"
  shift
  env PATH="$ROOT/tests/helpers:$PATH" \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_LIBEXEC="$target/libexec" NEKO_SYSTEMD="$target/systemd" \
    NEKO_STATE="$target/etc/state.json" \
    NEKO_USER=root NEKO_UPDATE_TMP_DIR="$target/tmp" \
    NEKO_UPDATE_LOCK_FILE="$target/upgrade.lock" \
    FIREWALLD_SERVICE_FILE="$target/firewall/neko-proxy.xml" \
    UFW_PROFILE_FILE="$target/firewall/neko-proxy.ufw" \
    NEKO_TEST_FIREWALL_LOG="$target/firewall/commands.log" \
    NEKO_UPDATE_TEST_MODE=1 NEKO_UPDATE_SKIP_ACME=1 \
    NEKO_UPDATE_QRC_BINARY="$QRC" \
    NEKO_UPDATE_NEXTTRACE_BINARY="$NEXTTRACE" \
    NEKO_UPDATE_IPV4_OVERRIDE=192.0.2.10 \
    NEKO_UPDATE_IPV6_OVERRIDE=2001:db8::10 \
    "$@" bash "$ROOT/upgrade.sh"
}

assert_trojan_migrated() {
  local target="$1" trojan_port expected_inbounds=1
  trojan_port="$(jq -r '.ports.trojan' "$target/etc/state.json")"
  [[ "$trojan_port" =~ ^[0-9]+$ ]]
  (( trojan_port >= 10000 && trojan_port <= 60000 ))
  jq -e '
    (.credentials.trojan_password | test("^[A-Za-z0-9_-]{16,128}$"))
    and ([.ports.hysteria2_start, .ports.hysteria2_end] as $range
      | (.ports.trojan < $range[0] or .ports.trojan > $range[1]))
    and ([.ports.tuic, .ports.ss2022, .ports.anytls,
          .ports.trojan, .ports.vless_reality_vision,
          .ports.vless_reality_xhttp] | length == (unique | length))
  ' "$target/etc/state.json" >/dev/null
  [[ "$(jq -r '.network.mode' "$target/etc/state.json")" != dual ]] \
    || expected_inbounds=4
  jq -e --argjson expected "$expected_inbounds" '
    [.inbounds[] | select(.type == "trojan")] | length == $expected
  ' "$target/etc/config/sing-box.json" >/dev/null
}

assert_cross_routes_migrated() {
  local target="$1"
  jq -e '
    .network.mode == "dual"
    and (.ports.cross | type == "object")
    and (.ports.cross.hysteria2_end - .ports.cross.hysteria2_start == 127)
    and (.subscription.ipv4_to_ipv6_token
      | test("^[A-Za-z0-9_-]{16,128}$"))
    and (.subscription.ipv6_to_ipv4_token
      | test("^[A-Za-z0-9_-]{16,128}$"))
  ' "$target/etc/state.json" >/dev/null
  NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    bash -c 'source "$1"; load_state' \
      _ "$target/libexec/lib/common.sh"
  [[ -s "$target/etc/config/hysteria-v4-to-v6.yaml" ]]
  [[ -s "$target/etc/config/hysteria-v6-to-v4.yaml" ]]
  [[ -s "$target/etc/subscriptions/sing-box-v4-to-v6.json" ]]
  [[ -s "$target/etc/subscriptions/sing-box-v6-to-v4.json" ]]
}

assert_anyreality_migrated() {
  local target="$1" expected_inbounds=1 profile=v4
  [[ "$(jq -r '.network.mode' "$target/etc/state.json")" != dual ]] \
    || expected_inbounds=4
  [[ "$(jq -r '.network.mode' "$target/etc/state.json")" != ipv6-only ]] \
    || profile=v6
  jq -e '
    .experimental.anyreality.enabled == true
    and (.experimental.anyreality.port | type == "number")
    and (.experimental.anyreality.password | test("^[A-Za-z0-9_-]{16,128}$"))
    and (.experimental.anyreality.private_key | test("^[A-Za-z0-9_-]{43}$"))
    and (.experimental.anyreality.public_key | test("^[A-Za-z0-9_-]{43}$"))
    and (.experimental.anyreality.short_id | test("^[0-9a-f]{16}$"))
  ' "$target/etc/state.json" >/dev/null
  [[ "$(jq '[.inbounds[] | select(.tag | startswith("anyreality-"))] | length' \
    "$target/etc/config/sing-box.json")" == "$expected_inbounds" ]]
  grep -Fq 'name: "AnyReality"' \
    "$target/etc/subscriptions/shadowrocket-${profile}.txt"
}

UPGRADE_OK="$WORK/upgrade-ok"
prepare_upgrade_install "$UPGRADE_OK"
upgrade_identity_before="$(jq -cS '{ports, credentials, reality, token: .subscription.token}' \
  "$UPGRADE_OK/etc/state.json")"
run_upgrade "$UPGRADE_OK" > "$UPGRADE_OK/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_OK/etc/state.json")" == 4 ]]
[[ "$(jq -r '.release' "$UPGRADE_OK/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(jq -r '.network.mode' "$UPGRADE_OK/etc/state.json")" == dual ]]
[[ "$(jq -r '.subscription.ipv4_domain' "$UPGRADE_OK/etc/state.json")" == v4.example.com ]]
[[ "$(jq -r '.subscription.ipv6_domain' "$UPGRADE_OK/etc/state.json")" == v6.example.com ]]
[[ "$(jq -r '.subscription.shadowrocket_server // empty' "$UPGRADE_OK/etc/state.json")" == "" ]]
[[ "$(jq -r '.acme.method' "$UPGRADE_OK/etc/state.json")" == http-01 ]]
[[ "$(jq -cS '{
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality,
    token: .subscription.ipv4_token
  }' \
  "$UPGRADE_OK/etc/state.json")" == "$upgrade_identity_before" ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_OK/etc/state.json")" \
  == "$(jq -r '.token' <<< "$upgrade_identity_before")" ]]
[[ "$(find "$UPGRADE_OK/etc/subscriptions" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 16 ]]
[[ -x "$UPGRADE_OK/libexec/hysteria-dual.sh" ]]
[[ -x "$UPGRADE_OK/libexec/route-diagnostics.sh" ]]
[[ ! -e "$UPGRADE_OK/libexec/diagnostics.sh" ]]
cmp -s -- "$QRC" "$UPGRADE_OK/libexec/qrc"
cmp -s -- "$NEXTTRACE" "$UPGRADE_OK/libexec/nexttrace-tiny"
grep -Fq 'ExecStart=/usr/local/libexec/neko/hysteria-dual.sh' \
  "$UPGRADE_OK/systemd/neko-hysteria.service"
[[ -s "$UPGRADE_OK/etc/config/hysteria-v4.yaml" ]]
[[ -s "$UPGRADE_OK/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_OK/etc/config/hysteria.yaml" ]]
assert_trojan_migrated "$UPGRADE_OK"
assert_cross_routes_migrated "$UPGRADE_OK"
assert_anyreality_migrated "$UPGRADE_OK"
if find "$UPGRADE_OK/tmp" -maxdepth 1 \
    \( -name 'neko-upgrade-backup.*' -o -name 'neko-qrc-stage.*' -o -name 'neko-nexttrace-stage.*' \) \
    | grep -q .; then
  printf '升级成功后没有清理备份目录。\n' >&2
  exit 1
fi

UPGRADE_SCHEMA2="$WORK/upgrade-schema2"
prepare_upgrade_install "$UPGRADE_SCHEMA2" 2
schema2_identity_before="$(jq -cS '{ports, credentials, reality, token: .subscription.token}' \
  "$UPGRADE_SCHEMA2/etc/state.json")"
run_upgrade "$UPGRADE_SCHEMA2" > "$UPGRADE_SCHEMA2/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_SCHEMA2/etc/state.json")" == 4 ]]
[[ "$(jq -r '.release' "$UPGRADE_SCHEMA2/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(jq -cS '{
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality,
    token: .subscription.ipv4_token
  }' \
  "$UPGRADE_SCHEMA2/etc/state.json")" == "$schema2_identity_before" ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_SCHEMA2/etc/state.json")" \
  == "$(jq -r '.token' <<< "$schema2_identity_before")" ]]
[[ -x "$UPGRADE_SCHEMA2/libexec/hysteria-dual.sh" ]]
[[ ! -e "$UPGRADE_SCHEMA2/libexec/diagnostics.sh" ]]
[[ -s "$UPGRADE_SCHEMA2/etc/config/hysteria-v4.yaml" ]]
[[ -s "$UPGRADE_SCHEMA2/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_SCHEMA2/etc/config/hysteria.yaml" ]]
assert_trojan_migrated "$UPGRADE_SCHEMA2"
assert_cross_routes_migrated "$UPGRADE_SCHEMA2"
assert_anyreality_migrated "$UPGRADE_SCHEMA2"

UPGRADE_123="$WORK/upgrade-1.2.3"
prepare_upgrade_install "$UPGRADE_123" 2 1.2.3-test
release_123_identity_before="$(jq -cS '{ports, credentials, reality, token: .subscription.token}' \
  "$UPGRADE_123/etc/state.json")"
[[ "$(find "$UPGRADE_123/etc/subscriptions" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 6 ]]
run_upgrade "$UPGRADE_123" > "$UPGRADE_123/upgrade.log"
[[ "$(jq -r '.release' "$UPGRADE_123/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(jq -cS '{
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality,
    token: .subscription.ipv4_token
  }' \
  "$UPGRADE_123/etc/state.json")" == "$release_123_identity_before" ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_123/etc/state.json")" \
  == "$(jq -r '.token' <<< "$release_123_identity_before")" ]]
[[ "$(find "$UPGRADE_123/etc/subscriptions" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 16 ]]
[[ -s "$UPGRADE_123/etc/subscriptions/sing-box-v4.json" ]]
[[ -s "$UPGRADE_123/etc/subscriptions/sing-box-v6.json" ]]
assert_trojan_migrated "$UPGRADE_123"
assert_cross_routes_migrated "$UPGRADE_123"
assert_anyreality_migrated "$UPGRADE_123"

UPGRADE_CURRENT="$WORK/upgrade-current"
prepare_upgrade_install "$UPGRADE_CURRENT" 3 1.7.0-test dual true
current_trojan_before="$(
  jq -cS '{port: .ports.trojan, password: .credentials.trojan_password}' \
    "$UPGRADE_CURRENT/etc/state.json"
)"
run_upgrade "$UPGRADE_CURRENT" > "$UPGRADE_CURRENT/upgrade.log"
[[ "$(jq -cS '{port: .ports.trojan, password: .credentials.trojan_password}' \
  "$UPGRADE_CURRENT/etc/state.json")" == "$current_trojan_before" ]]
assert_trojan_migrated "$UPGRADE_CURRENT"
assert_cross_routes_migrated "$UPGRADE_CURRENT"
assert_anyreality_migrated "$UPGRADE_CURRENT"

UPGRADE_SCHEMA4="$WORK/upgrade-schema4"
prepare_upgrade_install "$UPGRADE_SCHEMA4" 4 1.9.0-test dual true
jq '
  .experimental.anyreality = {
    enabled: true,
    port: 34000,
    cross_port: 35000,
    password: "preserved-anyreality-password",
    private_key: .reality.vision_private_key,
    public_key: .reality.vision_public_key,
    short_id: "2122232425262728"
  }
' "$UPGRADE_SCHEMA4/etc/state.json" > "$UPGRADE_SCHEMA4/etc/state.anyreality.json"
mv -f -- "$UPGRADE_SCHEMA4/etc/state.anyreality.json" \
  "$UPGRADE_SCHEMA4/etc/state.json"
schema4_identity_before="$(jq -cS '{
  ports,
  credentials,
  reality,
  experimental,
  tokens: {
    ipv4: .subscription.ipv4_token,
    ipv6: .subscription.ipv6_token,
    ipv4_to_ipv6: .subscription.ipv4_to_ipv6_token,
    ipv6_to_ipv4: .subscription.ipv6_to_ipv4_token
  }
}' "$UPGRADE_SCHEMA4/etc/state.json")"
run_upgrade "$UPGRADE_SCHEMA4" \
  NEKO_TEST_LISTENING_PORTS="34000,35000" \
  > "$UPGRADE_SCHEMA4/upgrade.log"
[[ "$(jq -cS '{
  ports,
  credentials,
  reality,
  experimental,
  tokens: {
    ipv4: .subscription.ipv4_token,
    ipv6: .subscription.ipv6_token,
    ipv4_to_ipv6: .subscription.ipv4_to_ipv6_token,
    ipv6_to_ipv4: .subscription.ipv6_to_ipv4_token
  }
}' "$UPGRADE_SCHEMA4/etc/state.json")" == "$schema4_identity_before" ]]
assert_trojan_migrated "$UPGRADE_SCHEMA4"
assert_cross_routes_migrated "$UPGRADE_SCHEMA4"
assert_anyreality_migrated "$UPGRADE_SCHEMA4"

UPGRADE_SCHEMA4_CONFLICT="$WORK/upgrade-schema4-conflict"
prepare_upgrade_install "$UPGRADE_SCHEMA4_CONFLICT" 4 1.10.0-test dual true
jq '
  .experimental.anyreality = {
    enabled: true,
    port: .ports.anytls,
    cross_port: .ports.cross.anytls,
    password: "conflicting-anyreality-password",
    private_key: .reality.vision_private_key,
    public_key: .reality.vision_public_key,
    short_id: "3132333435363738"
  }
' "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json" \
  > "$UPGRADE_SCHEMA4_CONFLICT/etc/state.anyreality.json"
mv -f -- "$UPGRADE_SCHEMA4_CONFLICT/etc/state.anyreality.json" \
  "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json"
schema4_conflict_before="$(
  sha256sum "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json" | awk '{print $1}'
)"
set +e
run_upgrade "$UPGRADE_SCHEMA4_CONFLICT" \
  > "$UPGRADE_SCHEMA4_CONFLICT/upgrade.log" 2>&1
schema4_conflict_rc=$?
set -e
(( schema4_conflict_rc != 0 ))
grep -Fq 'AnyReality 端口' "$UPGRADE_SCHEMA4_CONFLICT/upgrade.log"
grep -Fq '与 AnyTLS 冲突' "$UPGRADE_SCHEMA4_CONFLICT/upgrade.log"
[[ "$(sha256sum "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json" | awk '{print $1}')" \
  == "$schema4_conflict_before" ]]

UPGRADE_FIREWALL="$WORK/upgrade-firewall"
prepare_upgrade_install "$UPGRADE_FIREWALL" 3 1.6.1-test dual false
printf '%s\n' '<service><port protocol="tcp" port="23000"/></service>' \
  > "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
jq '
  .firewall = {manager: "firewalld", zone: "public", zones: ["public"]}
' "$UPGRADE_FIREWALL/etc/state.json" \
  > "$UPGRADE_FIREWALL/etc/state.firewall.json"
mv -f -- \
  "$UPGRADE_FIREWALL/etc/state.firewall.json" \
  "$UPGRADE_FIREWALL/etc/state.json"
run_upgrade "$UPGRADE_FIREWALL" > "$UPGRADE_FIREWALL/upgrade.log"
firewall_trojan_port="$(
  jq -r '.ports.trojan' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_cross_trojan_port="$(
  jq -r '.ports.cross.trojan' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_anyreality_port="$(
  jq -r '.experimental.anyreality.port' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_cross_anyreality_port="$(
  jq -r '.experimental.anyreality.cross_port' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_cross_hy2_range="$(
  jq -r '.ports.cross | "\(.hysteria2_start)-\(.hysteria2_end)"' \
    "$UPGRADE_FIREWALL/etc/state.json"
)"
grep -Fq "protocol=\"tcp\" port=\"${firewall_trojan_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"tcp\" port=\"${firewall_cross_trojan_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"tcp\" port=\"${firewall_anyreality_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"tcp\" port=\"${firewall_cross_anyreality_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"udp\" port=\"${firewall_cross_hy2_range}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fxq -- '--reload' "$UPGRADE_FIREWALL/firewall/commands.log"
grep -Fxq -- '--zone=public --query-service=neko-proxy' \
  "$UPGRADE_FIREWALL/firewall/commands.log"
assert_trojan_migrated "$UPGRADE_FIREWALL"
assert_cross_routes_migrated "$UPGRADE_FIREWALL"
assert_anyreality_migrated "$UPGRADE_FIREWALL"

UPGRADE_FIREWALL_INACTIVE="$WORK/upgrade-firewall-inactive"
prepare_upgrade_install "$UPGRADE_FIREWALL_INACTIVE" 3 1.6.1-test dual false
printf '%s\n' '<service><port protocol="tcp" port="23000"/></service>' \
  > "$UPGRADE_FIREWALL_INACTIVE/firewall/neko-proxy.xml"
jq '
  .firewall = {manager: "firewalld", zone: "public", zones: ["public"]}
' "$UPGRADE_FIREWALL_INACTIVE/etc/state.json" \
  > "$UPGRADE_FIREWALL_INACTIVE/etc/state.firewall.json"
mv -f -- \
  "$UPGRADE_FIREWALL_INACTIVE/etc/state.firewall.json" \
  "$UPGRADE_FIREWALL_INACTIVE/etc/state.json"
inactive_state_before="$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/etc/state.json" | awk '{print $1}'
)"
inactive_profile_before="$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/firewall/neko-proxy.xml" \
    | awk '{print $1}'
)"
set +e
run_upgrade "$UPGRADE_FIREWALL_INACTIVE" \
  NEKO_TEST_FIREWALL_INACTIVE=1 \
  > "$UPGRADE_FIREWALL_INACTIVE/upgrade.log" 2>&1
inactive_upgrade_rc=$?
set -e
(( inactive_upgrade_rc != 0 ))
[[ "$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/etc/state.json" | awk '{print $1}'
)" == "$inactive_state_before" ]]
[[ "$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/firewall/neko-proxy.xml" \
    | awk '{print $1}'
)" == "$inactive_profile_before" ]]
grep -Fq 'firewalld 当前未运行；未开始升级' \
  "$UPGRADE_FIREWALL_INACTIVE/upgrade.log"

UPGRADE_V4="$WORK/upgrade-v4-only"
prepare_upgrade_install "$UPGRADE_V4" 3 1.2.4-test ipv4-only
v4_token_before="$(jq -r '.subscription.ipv4_token' "$UPGRADE_V4/etc/state.json")"
run_upgrade "$UPGRADE_V4" > "$UPGRADE_V4/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_V4/etc/state.json")" == 4 ]]
[[ "$(jq -r '.network.mode' "$UPGRADE_V4/etc/state.json")" == ipv4-only ]]
[[ "$(jq -r '.subscription.ipv4_token' "$UPGRADE_V4/etc/state.json")" \
  == "$v4_token_before" ]]
[[ "$(jq -r '.subscription.ipv6_token // empty' "$UPGRADE_V4/etc/state.json")" == "" ]]
[[ "$(jq -r '.subscription.ipv4_to_ipv6_token // empty' \
  "$UPGRADE_V4/etc/state.json")" == "" ]]
[[ "$(jq -r '.ports.cross // empty' "$UPGRADE_V4/etc/state.json")" == "" ]]
[[ "$(find "$UPGRADE_V4/etc/subscriptions" -maxdepth 1 -type f \
  | wc -l | tr -d ' ')" == 4 ]]
[[ -s "$UPGRADE_V4/etc/config/hysteria-v4.yaml" ]]
[[ ! -e "$UPGRADE_V4/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_V4/etc/config/hysteria-v4-to-v6.yaml" ]]
[[ ! -e "$UPGRADE_V4/etc/config/hysteria-v6-to-v4.yaml" ]]
assert_trojan_migrated "$UPGRADE_V4"
assert_anyreality_migrated "$UPGRADE_V4"

UPGRADE_V6="$WORK/upgrade-v6-only"
prepare_upgrade_install "$UPGRADE_V6" 3 1.2.4-test ipv6-only
v6_token_before="$(jq -r '.subscription.ipv6_token' "$UPGRADE_V6/etc/state.json")"
run_upgrade "$UPGRADE_V6" > "$UPGRADE_V6/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_V6/etc/state.json")" == 4 ]]
[[ "$(jq -r '.network.mode' "$UPGRADE_V6/etc/state.json")" == ipv6-only ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_V6/etc/state.json")" \
  == "$v6_token_before" ]]
[[ "$(jq -r '.subscription.ipv4_token // empty' "$UPGRADE_V6/etc/state.json")" == "" ]]
[[ "$(jq -r '.subscription.ipv6_to_ipv4_token // empty' \
  "$UPGRADE_V6/etc/state.json")" == "" ]]
[[ "$(jq -r '.ports.cross // empty' "$UPGRADE_V6/etc/state.json")" == "" ]]
[[ "$(find "$UPGRADE_V6/etc/subscriptions" -maxdepth 1 -type f \
  | wc -l | tr -d ' ')" == 4 ]]
[[ ! -e "$UPGRADE_V6/etc/config/hysteria-v4.yaml" ]]
[[ -s "$UPGRADE_V6/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_V6/etc/config/hysteria-v4-to-v6.yaml" ]]
[[ ! -e "$UPGRADE_V6/etc/config/hysteria-v6-to-v4.yaml" ]]
assert_trojan_migrated "$UPGRADE_V6"
assert_anyreality_migrated "$UPGRADE_V6"

UPGRADE_FAIL="$WORK/upgrade-fail"
prepare_upgrade_install "$UPGRADE_FAIL"
printf '%s\n' '<service><port protocol="tcp" port="23000"/></service>' \
  > "$UPGRADE_FAIL/firewall/neko-proxy.xml"
jq '
  .firewall = {manager: "firewalld", zone: "public", zones: ["public"]}
' "$UPGRADE_FAIL/etc/state.json" > "$UPGRADE_FAIL/etc/state.firewall.json"
mv -f -- \
  "$UPGRADE_FAIL/etc/state.firewall.json" "$UPGRADE_FAIL/etc/state.json"
cp -a -- "$ROOT/tests/helpers/systemctl" "$UPGRADE_FAIL/libexec/qrc"
cp -a -- "$ROOT/tests/helpers/systemctl" "$UPGRADE_FAIL/libexec/nexttrace-tiny"
qrc_before="$(sha256sum "$UPGRADE_FAIL/libexec/qrc" | awk '{print $1}')"
nexttrace_before="$(
  sha256sum "$UPGRADE_FAIL/libexec/nexttrace-tiny" | awk '{print $1}'
)"
state_before="$(sha256sum "$UPGRADE_FAIL/etc/state.json" | awk '{print $1}')"
config_before="$(sha256sum "$UPGRADE_FAIL/etc/config/Caddyfile" | awk '{print $1}')"
unit_before="$(sha256sum "$UPGRADE_FAIL/systemd/neko-hysteria.service" | awk '{print $1}')"
firewall_before="$(
  sha256sum "$UPGRADE_FAIL/firewall/neko-proxy.xml" | awk '{print $1}'
)"
subscriptions_before="$(
  find "$UPGRADE_FAIL/etc/subscriptions" -maxdepth 1 -type f -printf '%f\n' \
    | sort | sha256sum | awk '{print $1}'
)"
set +e
run_upgrade "$UPGRADE_FAIL" \
  NEKO_TEST_SYSTEMCTL_FAIL_PATTERN='neko-sing-box.service' \
  NEKO_TEST_SYSTEMCTL_FAIL_ONCE_FILE="$UPGRADE_FAIL/systemctl-failed-once" \
  > "$UPGRADE_FAIL/upgrade.log" 2>&1
upgrade_rc=$?
set -e
(( upgrade_rc != 0 ))
[[ "$(sha256sum "$UPGRADE_FAIL/etc/state.json" | awk '{print $1}')" == "$state_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/etc/config/Caddyfile" | awk '{print $1}')" == "$config_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/systemd/neko-hysteria.service" | awk '{print $1}')" == "$unit_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/firewall/neko-proxy.xml" | awk '{print $1}')" \
  == "$firewall_before" ]]
grep -Fxq -- '--reload' "$UPGRADE_FAIL/firewall/commands.log"
[[ "$(sha256sum "$UPGRADE_FAIL/libexec/qrc" | awk '{print $1}')" == "$qrc_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/libexec/nexttrace-tiny" | awk '{print $1}')" \
  == "$nexttrace_before" ]]
[[ "$(
  find "$UPGRADE_FAIL/etc/subscriptions" -maxdepth 1 -type f -printf '%f\n' \
    | sort | sha256sum | awk '{print $1}'
)" == "$subscriptions_before" ]]
[[ ! -e "$UPGRADE_FAIL/libexec/hysteria-dual.sh" ]]
[[ ! -e "$UPGRADE_FAIL/libexec/diagnostics.sh" ]]
grep -Fq '正在恢复升级前的状态' "$UPGRADE_FAIL/upgrade.log"
if find "$UPGRADE_FAIL/tmp" -maxdepth 1 \
    \( -name 'neko-upgrade-backup.*' -o -name 'neko-qrc-stage.*' -o -name 'neko-nexttrace-stage.*' \) \
    | grep -q .; then
  printf '升级回滚后没有清理备份目录。\n' >&2
  exit 1
fi

printf '全部测试通过。\n'
