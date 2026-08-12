#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-akdns-test.XXXXXX")"

cleanup() {
  [[ "$WORK" == "${TMPDIR:-/tmp}"/neko-akdns-test.* ]] && rm -rf -- "$WORK"
}
trap cleanup EXIT

setup_case() {
  local target="$1" service
  mkdir -p \
    "$target/system/etc" \
    "$target/system/run/systemd/resolve" \
    "$target/neko/libexec/lib" \
    "$target/neko/etc/subscriptions" \
    "$target/neko/var" \
    "$target/systemctl" \
    "$target/tmp"
  printf 'nameserver 127.0.0.53\noptions edns0 trust-ad\n' \
    > "$target/system/run/systemd/resolve/stub-resolv.conf"
  ln -s ../run/systemd/resolve/stub-resolv.conf \
    "$target/system/etc/resolv.conf"
  printf 'hosts: files resolve [!UNAVAIL=return] dns\n' \
    > "$target/system/etc/nsswitch.conf"
  cp -a -- "$ROOT/versions.env" "$target/neko/libexec/versions.env"
  cp -a -- "$ROOT/lib/common.sh" "$target/neko/libexec/lib/common.sh"
  cp -a -- "$ROOT/lib/render.sh" "$target/neko/libexec/lib/render.sh"
  printf 'public\n' > "$target/neko/etc/subscriptions/dns-mode"
  for service in \
    systemd-resolved.service \
    neko-caddy.service neko-sing-box.service neko-xray.service \
    neko-hysteria.service; do
    : > "$target/systemctl/${service}.active"
    printf 'enabled\n' > "$target/systemctl/${service}.enabled"
  done
}

run_wrapper() {
  local target="$1" action="$2"
  shift 2
  env -u NEKO_CONFIG_DIR -u NEKO_SUB_DIR \
    NEKO_ETC="$target/neko/etc" \
    NEKO_VAR="$target/neko/var" \
    NEKO_LIBEXEC="$target/neko/libexec" \
    NEKO_STATE="$target/neko/etc/state.json" \
    NEKO_AKDNS_TEST_MODE=1 \
    NEKO_AKDNS_SYSTEM_ROOT="$target/system" \
    NEKO_AKDNS_TMP_BASE="$target/tmp" \
    NEKO_AKDNS_LOCK_FILE="$target/akdns.lock" \
    NEKO_AKDNS_SYSTEMCTL="$ROOT/tests/fixtures/akdns-systemctl.sh" \
    NEKO_AKDNS_SYSTEMCTL_STATE_DIR="$target/systemctl" \
    NEKO_AKDNS_SYSTEMCTL_LOG="$target/systemctl.log" \
    NEKO_AKDNS_TEST_SCRIPT="$ROOT/tests/fixtures/akdns-mock.sh" \
    NEKO_AKDNS_TEST_ACTION="$action" \
    NEKO_AKDNS_TEST_VALIDATOR="$ROOT/tests/fixtures/akdns-validator.sh" \
    NEKO_AKDNS_TEST_HEALTH_CHECK="$ROOT/tests/fixtures/akdns-health.sh" \
    NEKO_AKDNS_TEST_RENDERER="$ROOT/tests/fixtures/akdns-renderer.sh" \
    NEKO_AKDNS_VALIDATOR_LOG="$target/validator.log" \
    NEKO_AKDNS_SERVICE_WAIT_SECONDS=0 \
    "$@" \
    bash "$ROOT/runtime/akdns.sh" --run
}

assert_original_state() {
  local target="$1"
  [[ -L "$target/system/etc/resolv.conf" ]]
  [[ "$(readlink "$target/system/etc/resolv.conf")" \
    == ../run/systemd/resolve/stub-resolv.conf ]]
  grep -Fxq 'hosts: files resolve [!UNAVAIL=return] dns' \
    "$target/system/etc/nsswitch.conf"
  [[ ! -e "$target/system/etc/nsswitch.conf.akdns.bak" ]]
  [[ ! -e "$target/system/etc/NetworkManager/conf.d/akdns-dns.conf" ]]
  [[ -f "$target/systemctl/systemd-resolved.service.active" ]]
  grep -Fxq enabled \
    "$target/systemctl/systemd-resolved.service.enabled"
}

SUCCESS="$WORK/success"
setup_case "$SUCCESS"
run_wrapper "$SUCCESS" apply > "$SUCCESS/apply.log"
[[ -f "$SUCCESS/system/etc/resolv.conf" \
  && ! -L "$SUCCESS/system/etc/resolv.conf" ]]
grep -Fxq 'nameserver 66.66.66.66' "$SUCCESS/system/etc/resolv.conf"
[[ -d "$SUCCESS/neko/var/akdns/pre-akdns" ]]
grep -Fxq 'version=3.0.0' "$SUCCESS/neko/var/akdns/status"
grep -Fq '订阅配置与服务均已验证' "$SUCCESS/apply.log"
grep -Fxq 'on 66.66.66.66' "$SUCCESS/neko/etc/subscriptions/dns-mode"
env \
  NEKO_ETC="$SUCCESS/neko/etc" \
  NEKO_VAR="$SUCCESS/neko/var" \
  NEKO_LIBEXEC="$SUCCESS/neko/libexec" \
  NEKO_STATE="$SUCCESS/neko/etc/state.json" \
  NEKO_AKDNS_TEST_MODE=1 \
  NEKO_AKDNS_SYSTEM_ROOT="$SUCCESS/system" \
  NEKO_AKDNS_TMP_BASE="$SUCCESS/tmp" \
  NEKO_AKDNS_LOCK_FILE="$SUCCESS/status.lock" \
  NEKO_AKDNS_SYSTEMCTL="$ROOT/tests/fixtures/akdns-systemctl.sh" \
  NEKO_AKDNS_SYSTEMCTL_STATE_DIR="$SUCCESS/systemctl" \
  bash "$ROOT/runtime/akdns.sh" --status > "$SUCCESS/status.log"
grep -Fq '当前系统 DNS：AKDNS（66.66.66.66）' "$SUCCESS/status.log"

env \
  NEKO_ETC="$SUCCESS/neko/etc" \
  NEKO_VAR="$SUCCESS/neko/var" \
  NEKO_LIBEXEC="$SUCCESS/neko/libexec" \
  NEKO_STATE="$SUCCESS/neko/etc/state.json" \
  NEKO_AKDNS_TEST_MODE=1 \
  NEKO_AKDNS_SYSTEM_ROOT="$SUCCESS/system" \
  NEKO_AKDNS_TMP_BASE="$SUCCESS/tmp" \
  NEKO_AKDNS_LOCK_FILE="$SUCCESS/restore.lock" \
  NEKO_AKDNS_SYSTEMCTL="$ROOT/tests/fixtures/akdns-systemctl.sh" \
  NEKO_AKDNS_SYSTEMCTL_STATE_DIR="$SUCCESS/systemctl" \
  NEKO_AKDNS_TEST_VALIDATOR="$ROOT/tests/fixtures/akdns-validator.sh" \
  NEKO_AKDNS_TEST_RENDERER="$ROOT/tests/fixtures/akdns-renderer.sh" \
  NEKO_AKDNS_SERVICE_WAIT_SECONDS=0 \
  bash "$ROOT/runtime/akdns.sh" --restore > "$SUCCESS/restore.log"
assert_original_state "$SUCCESS"
[[ ! -e "$SUCCESS/neko/var/akdns/pre-akdns" ]]
grep -Fq '启用前的精确 DNS' "$SUCCESS/restore.log"
grep -Fxq 'off' "$SUCCESS/neko/etc/subscriptions/dns-mode"

for action in fail invalid interrupt; do
  target="$WORK/$action"
  setup_case "$target"
  if run_wrapper "$target" "$action" > "$target/run.log" 2>&1; then
    printf 'AKDNS %s 场景没有失败。\n' "$action" >&2
    exit 1
  fi
  assert_original_state "$target"
  [[ ! -e "$target/neko/var/akdns/pre-akdns" ]]
  grep -Fq '正在恢复操作前的 DNS' "$target/run.log"
done

VALIDATION="$WORK/validation"
setup_case "$VALIDATION"
if run_wrapper "$VALIDATION" apply \
    NEKO_AKDNS_TEST_REJECT_ACTIVE=1 > "$VALIDATION/run.log" 2>&1; then
  printf 'AKDNS 验证失败场景没有回滚。\n' >&2
  exit 1
fi
assert_original_state "$VALIDATION"
grep -Fq '公网域名、配置或 Neko 服务验证失败' "$VALIDATION/run.log"
grep -Fxq 'public' "$VALIDATION/neko/etc/subscriptions/dns-mode"

HEALTH="$WORK/health"
setup_case "$HEALTH"
if run_wrapper "$HEALTH" apply \
    NEKO_AKDNS_TEST_REJECT_HEALTH=1 > "$HEALTH/run.log" 2>&1; then
  printf 'AKDNS 递归健康检查失败场景没有回滚。\n' >&2
  exit 1
fi
assert_original_state "$HEALTH"
grep -Fq '正在恢复操作前的 DNS' "$HEALTH/run.log"
grep -Fxq 'public' "$HEALTH/neko/etc/subscriptions/dns-mode"

NOCHANGE="$WORK/nochange"
setup_case "$NOCHANGE"
run_wrapper "$NOCHANGE" nochange > "$NOCHANGE/run.log"
assert_original_state "$NOCHANGE"
[[ ! -e "$NOCHANGE/neko/var/akdns/pre-akdns" ]]
grep -Fq '没有留下新的系统配置改动' "$NOCHANGE/run.log"

DNS_BYPASS="$WORK/dns-bypass"
mkdir -p "$DNS_BYPASS/var/akdns" "$DNS_BYPASS/etc"
printf 'resolver=66.66.66.66\n' > "$DNS_BYPASS/var/akdns/status"
printf 'nameserver 66.66.66.66\noptions use-vc\n' > "$DNS_BYPASS/etc/resolv.conf"
NEKO_VAR="$DNS_BYPASS/var" NEKO_RESOLV_CONF="$DNS_BYPASS/etc/resolv.conf" \
  DNS_BYPASS_LOG="$DNS_BYPASS/dig.log" bash -c '
    set -Eeuo pipefail
    source "$1"
    dig() {
      printf "%s\n" "$*" >> "$DNS_BYPASS_LOG"
      printf "%s\n" \
        ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1" \
        "v4.example.com. 60 IN A 192.0.2.44"
    }
    [[ "$(resolved_ipv4_addresses v4.example.com)" == 192.0.2.44 ]]
  ' _ "$ROOT/lib/common.sh"
grep -Fq '@1.1.1.1' "$DNS_BYPASS/dig.log"

grep -Fq \
  'AKDNS_SOURCE_COMMIT="d9a3f7caa08f528d55d799d73d37394026326a4d"' \
  "$ROOT/versions.env"
grep -Fq \
  'AKDNS_SHA256="430d0ec98d425ee9f59805b9cf2e6d42deaab2489382e4cd8129fb2d28bc9bfc"' \
  "$ROOT/versions.env"

printf 'AKDNS 固定来源、提交、精确恢复与失败回滚通过。\n'
