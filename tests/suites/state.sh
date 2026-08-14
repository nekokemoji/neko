#!/usr/bin/env bash

# Platform, state, firewall, DNS, and AKDNS contracts.
# This file is sourced by tests/run.sh so the suites keep one shared fixture.
# shellcheck disable=SC2154
[[ "${NEKO_TEST_SUITE_CONTEXT:-}" == 1 ]] || {
  printf '请通过 tests/run.sh 运行测试套件。\n' >&2
  exit 1
}

printf '[2/10] 发行版、架构、DNS 与防火墙区域逻辑……\n'
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

printf '[3/10] AKDNS 固定来源、事务恢复与失败回滚……\n'
bash "$ROOT/tests/akdns-transaction.sh"
