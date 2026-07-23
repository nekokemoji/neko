#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/neko-panel-refresh.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

prepare_case() {
  local name="$1" target="$WORK/$1"
  mkdir -p "$target/etc"
  cp -a -- "$ROOT/tests/fixtures/state.json" "$target/etc/state.json"
}

run_case() {
  local name="$1" target="$WORK/$1"
  shift
  set +e
  env \
    CASE_MODE="$name" CASE_DIR="$target" \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_LIBEXEC="$ROOT" NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    bash -c '
      set -Eeuo pipefail
      source "$1"

      acquire_maintenance_lock() {
        printf "lock\n" >> "$CASE_DIR/calls"
      }
      release_maintenance_lock() {
        printf "unlock\n" >> "$CASE_DIR/calls"
      }
      load_state() {
        DOMAIN="$(jq -r ".domain" "$NEKO_STATE")"
        SUBSCRIPTION_DOMAIN_IPV4="$(jq -r ".subscription.ipv4_domain" "$NEKO_STATE")"
        SUBSCRIPTION_DOMAIN_IPV6="$(jq -r ".subscription.ipv6_domain" "$NEKO_STATE")"
        SUBSCRIPTION_IPV4_ADDRESS="$(jq -r ".subscription.ipv4_address" "$NEKO_STATE")"
        SUBSCRIPTION_IPV6_ADDRESS="$(jq -r ".subscription.ipv6_address" "$NEKO_STATE")"
      }
      assert_dual_stack_kernel() {
        printf "dual-stack\n" >> "$CASE_DIR/calls"
      }
      check_strict_dual_stack_dns() {
        printf "dns\n" >> "$CASE_DIR/calls"
        SUBSCRIPTION_DOMAIN_IPV4="v4.example.com"
        SUBSCRIPTION_DOMAIN_IPV6="v6.example.com"
        case "$CASE_MODE" in
          no-change)
            SUBSCRIPTION_IPV4_ADDRESS="127.0.0.1"
            SUBSCRIPTION_IPV6_ADDRESS="::1"
            ;;
          *)
            SUBSCRIPTION_IPV4_ADDRESS="192.0.2.44"
            SUBSCRIPTION_IPV6_ADDRESS="2001:db8::44"
            ;;
        esac
      }
      assert_strict_addresses_local() {
        printf "local-addresses\n" >> "$CASE_DIR/calls"
      }
      render_all() {
        printf "render\n" >> "$CASE_DIR/calls"
        jq -c ".subscription" "$NEKO_STATE" >> "$CASE_DIR/rendered-states"
      }
      validate_runtime_configs() {
        printf "validate\n" >> "$CASE_DIR/calls"
      }
      restart_runtime_services() {
        local count
        printf "restart\n" >> "$CASE_DIR/calls"
        count="$(grep -c "^restart$" "$CASE_DIR/calls")"
        case "$CASE_MODE" in
          rollback) (( count >= 2 )) ;;
          rollback-fail) return 1 ;;
          *) return 0 ;;
        esac
      }
      show_subscription_links() {
        printf "links\n" >> "$CASE_DIR/calls"
      }

      refresh_subscription_endpoints <<< "y"
    ' _ "$ROOT/runtime/panel.sh" "$@" > "$target/output" 2>&1
  printf '%s\n' "$?" > "$target/rc"
  set -e
}

call_count() {
  local name="$1" call="$2"
  grep -c "^${call}$" "$WORK/$name/calls" 2>/dev/null || true
}

for case_name in no-change success rollback rollback-fail; do
  prepare_case "$case_name"
  run_case "$case_name"
done

[[ "$(<"$WORK/no-change/rc")" == 0 ]]
grep -Fq "端点没有变化" "$WORK/no-change/output"
[[ "$(call_count no-change dual-stack)" == 1 ]]
[[ "$(call_count no-change dns)" == 1 ]]
[[ "$(call_count no-change local-addresses)" == 1 ]]
[[ "$(call_count no-change render)" == 0 ]]
[[ "$(call_count no-change restart)" == 0 ]]
[[ "$(jq -r ".subscription.ipv4_address" "$WORK/no-change/etc/state.json")" == 127.0.0.1 ]]
[[ "$(jq -r ".subscription.ipv6_address" "$WORK/no-change/etc/state.json")" == ::1 ]]
if find "$WORK/no-change/etc" -maxdepth 1 -name "state.json.backup.*" | grep -q .; then
  printf '端点未变化时留下了不应存在的状态备份。\n' >&2
  exit 1
fi

[[ "$(<"$WORK/success/rc")" == 0 ]]
grep -Fq "端点与八份订阅已刷新" "$WORK/success/output"
[[ "$(call_count success render)" == 1 ]]
[[ "$(call_count success validate)" == 1 ]]
[[ "$(call_count success restart)" == 1 ]]
[[ "$(call_count success links)" == 1 ]]
[[ "$(jq -r ".subscription.ipv4_address" "$WORK/success/etc/state.json")" == 192.0.2.44 ]]
[[ "$(jq -r ".subscription.ipv6_address" "$WORK/success/etc/state.json")" == 2001:db8::44 ]]
if find "$WORK/success/etc" -maxdepth 1 -name "state.json.backup.*" | grep -q .; then
  printf '端点刷新成功后没有清理状态备份。\n' >&2
  exit 1
fi

[[ "$(<"$WORK/rollback/rc")" != 0 ]]
grep -Fq "已恢复原地址和订阅" "$WORK/rollback/output"
[[ "$(call_count rollback render)" == 2 ]]
[[ "$(call_count rollback validate)" == 2 ]]
[[ "$(call_count rollback restart)" == 2 ]]
[[ "$(jq -r ".subscription.ipv4_address" "$WORK/rollback/etc/state.json")" == 127.0.0.1 ]]
[[ "$(jq -r ".subscription.ipv6_address" "$WORK/rollback/etc/state.json")" == ::1 ]]
if find "$WORK/rollback/etc" -maxdepth 1 -name "state.json.backup.*" | grep -q .; then
  printf '端点刷新成功回滚后没有清理状态备份。\n' >&2
  exit 1
fi

[[ "$(<"$WORK/rollback-fail/rc")" != 0 ]]
grep -Fq "自动恢复未完全成功" "$WORK/rollback-fail/output"
[[ "$(call_count rollback-fail render)" == 2 ]]
[[ "$(call_count rollback-fail validate)" == 2 ]]
[[ "$(call_count rollback-fail restart)" == 2 ]]
[[ "$(jq -r ".subscription.ipv4_address" "$WORK/rollback-fail/etc/state.json")" == 127.0.0.1 ]]
[[ "$(jq -r ".subscription.ipv6_address" "$WORK/rollback-fail/etc/state.json")" == ::1 ]]
[[ "$(find "$WORK/rollback-fail/etc" -maxdepth 1 -name "state.json.backup.*" | wc -l | tr -d " ")" == 1 ]]

printf '控制面板端点刷新事务测试通过。\n'
