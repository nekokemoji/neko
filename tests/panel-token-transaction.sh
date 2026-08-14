#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-panel-token.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

render_case() {
  local target="$1"
  NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      source "$2"
      render_all
    ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
}

prepare_case() {
  local name="$1" mode="$2" target="$WORK/$1"
  mkdir -p "$target/etc" "$target/var" "$target/tmp"
  case "$mode" in
    dual)
      cp -a -- "$ROOT/tests/fixtures/state.json" "$target/etc/state.json"
      ;;
    ipv4-only)
      jq '
        .network.mode = "ipv4-only"
        | .subscription.ipv6_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv6_domain = null
        | .subscription.ipv6_address = null
        | .ports.cross = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    ipv6-only)
      jq '
        .network.mode = "ipv6-only"
        | .subscription.ipv4_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv4_domain = null
        | .subscription.ipv4_address = null
        | .ports.cross = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    *) return 64 ;;
  esac
  chmod 0600 "$target/etc/state.json"
  render_case "$target"
  cp -a -- "$target/etc" "$target/etc.before"
  : > "$target/calls"
}

run_case() {
  local name="$1" input="$2" case_mode="${3:-success}" target="$WORK/$1"
  set +e
  env \
    CASE_DIR="$target" CASE_INPUT="$input" CASE_MODE="$case_mode" \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    NEKO_LIBEXEC="$ROOT" NEKO_PANEL_TMP_DIR="$target/tmp" \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      eval "$(
        declare -f atomic_json_update \
          | sed "1s/^atomic_json_update /real_atomic_json_update /"
      )"

      acquire_maintenance_lock() {
        printf "lock\n" >> "$CASE_DIR/calls"
      }
      release_maintenance_lock() {
        printf "unlock\n" >> "$CASE_DIR/calls"
      }
      random_urlsafe() {
        local count=0
        [[ ! -s "$CASE_DIR/random.count" ]] \
          || count="$(<"$CASE_DIR/random.count")"
        count=$((count + 1))
        printf "%s\n" "$count" > "$CASE_DIR/random.count"
        if [[ "$CASE_MODE" == same-old && "$count" == 1 ]]; then
          jq -r ".subscription.ipv4_token" "$NEKO_STATE"
        elif [[ "$CASE_MODE" == duplicate-new ]]; then
          printf "duplicate-new-subscription-token"
        else
          printf "new-subscription-token-%02d-abcdefghijk" "$count"
        fi
      }
      atomic_json_update() {
        printf "commit\n" >> "$CASE_DIR/calls"
        real_atomic_json_update "$@"
        [[ "$CASE_MODE" != commit-fail ]]
      }
      render_all() {
        printf "render\n" >> "$CASE_DIR/calls"
        NEKO_ETC="$NEKO_ETC" NEKO_VAR="$NEKO_VAR" \
          NEKO_STATE="$NEKO_STATE" NEKO_USER=root \
          bash -c "
            set -Eeuo pipefail
            source \"$NEKO_LIBEXEC/lib/common.sh\"
            source \"$NEKO_LIBEXEC/lib/render.sh\"
            render_all
          "
        [[ "$CASE_MODE" != render-fail ]]
      }
      validate_runtime_configs() {
        local count
        printf "validate\n" >> "$CASE_DIR/calls"
        count="$(grep -c "^validate$" "$CASE_DIR/calls")"
        if [[ "$CASE_MODE" == unexpected-exit && "$count" == 1 ]]; then
          exit 75
        fi
        [[ "$CASE_MODE" != validate-fail || "$count" != 1 ]]
      }
      restart_runtime_services() {
        local count
        printf "restart\n" >> "$CASE_DIR/calls"
        count="$(grep -c "^restart$" "$CASE_DIR/calls")"
        case "$CASE_MODE" in
          restart-fail) (( count >= 2 )) ;;
          rollback-fail) return 1 ;;
          *) return 0 ;;
        esac
      }
      show_subscription_links() {
        printf "links\n" >> "$CASE_DIR/calls"
      }

      rotate_subscription <<< "$CASE_INPUT"
    ' _ "$ROOT/runtime/panel.sh" > "$target/output" 2>&1
  printf '%s\n' "$?" > "$target/rc"
  set -e
}

call_count() {
  local name="$1" call="$2"
  grep -c "^${call}$" "$WORK/$name/calls" 2>/dev/null || true
}

token() {
  local file="$1" key="$2"
  jq -r --arg key "$key" '.subscription[$key] // empty' "$file"
}

assert_changed() {
  local name="$1" key="$2"
  [[ "$(token "$WORK/$name/etc.before/state.json" "$key")" \
    != "$(token "$WORK/$name/etc/state.json" "$key")" ]]
}

assert_unchanged() {
  local name="$1" key="$2"
  [[ "$(token "$WORK/$name/etc.before/state.json" "$key")" \
    == "$(token "$WORK/$name/etc/state.json" "$key")" ]]
}

assert_only_token_keys_changed() {
  local name="$1"
  shift
  local jq_delete='.' key
  for key in "$@"; do
    jq_delete+=" | del(.subscription.${key})"
  done
  jq -cS "$jq_delete" "$WORK/$name/etc.before/state.json" \
    > "$WORK/$name/state.before.public"
  jq -cS "$jq_delete" "$WORK/$name/etc/state.json" \
    > "$WORK/$name/state.after.public"
  cmp -s "$WORK/$name/state.before.public" "$WORK/$name/state.after.public"
}

assert_four_client_routes() {
  local name="$1" token_value="$2" route="$3" client file
  for client in mihomo stash shadowrocket sing-box; do
    file="$(
      NEKO_LIBEXEC="$ROOT" bash -c '
        source "$1/lib/common.sh"
        subscription_client_filename "$2"
      ' _ "$ROOT" "$client"
    )"
    grep -Fq "/${token_value}/${route}/${file}" \
      "$WORK/$name/etc/config/Caddyfile"
  done
}

assert_four_client_files() {
  local name="$1" profile="$2"
  [[ -s "$WORK/$name/etc/subscriptions/mihomo-${profile}.yaml" ]]
  [[ -s "$WORK/$name/etc/subscriptions/stash-${profile}.yaml" ]]
  [[ -s "$WORK/$name/etc/subscriptions/shadowrocket-${profile}.txt" ]]
  jq -e . "$WORK/$name/etc/subscriptions/sing-box-${profile}.json" >/dev/null
}

assert_no_backup() {
  local name="$1"
  if find "$WORK/$name/tmp" -mindepth 1 -maxdepth 1 \
    -name 'neko-access-backup.*' | grep -q .; then
    printf '订阅事务成功或成功回滚后留下了维护备份：%s\n' "$name" >&2
    exit 1
  fi
}

assert_restored() {
  local name="$1"
  diff -ru "$WORK/$name/etc.before" "$WORK/$name/etc"
  assert_no_backup "$name"
}

printf '[面板订阅] 双栈只轮换 IPv4 入口与同向跨栈入口……\n'
prepare_case dual-ipv4 dual
run_case dual-ipv4 $'1\ny'
[[ "$(<"$WORK/dual-ipv4/rc")" == 0 ]]
assert_changed dual-ipv4 ipv4_token
assert_changed dual-ipv4 ipv4_to_ipv6_token
assert_unchanged dual-ipv4 ipv6_token
assert_unchanged dual-ipv4 ipv6_to_ipv4_token
assert_only_token_keys_changed dual-ipv4 ipv4_token ipv4_to_ipv6_token
new_ipv4="$(token "$WORK/dual-ipv4/etc/state.json" ipv4_token)"
new_ipv4_to_ipv6="$(
  token "$WORK/dual-ipv4/etc/state.json" ipv4_to_ipv6_token
)"
assert_four_client_routes dual-ipv4 "$new_ipv4" v4
assert_four_client_routes dual-ipv4 "$new_ipv4_to_ipv6" v4-to-v6
assert_four_client_files dual-ipv4 v4
assert_four_client_files dual-ipv4 v4-to-v6
[[ "$(call_count dual-ipv4 commit)" == 1 ]]
[[ "$(call_count dual-ipv4 render)" == 1 ]]
[[ "$(call_count dual-ipv4 validate)" == 1 ]]
[[ "$(call_count dual-ipv4 restart)" == 1 ]]
[[ "$(call_count dual-ipv4 links)" == 1 ]]
assert_no_backup dual-ipv4

printf '[面板订阅] 双栈只轮换 IPv6 入口与同向跨栈入口……\n'
prepare_case dual-ipv6 dual
run_case dual-ipv6 $'2\ny'
[[ "$(<"$WORK/dual-ipv6/rc")" == 0 ]]
assert_unchanged dual-ipv6 ipv4_token
assert_unchanged dual-ipv6 ipv4_to_ipv6_token
assert_changed dual-ipv6 ipv6_token
assert_changed dual-ipv6 ipv6_to_ipv4_token
assert_only_token_keys_changed dual-ipv6 ipv6_token ipv6_to_ipv4_token
new_ipv6="$(token "$WORK/dual-ipv6/etc/state.json" ipv6_token)"
new_ipv6_to_ipv4="$(
  token "$WORK/dual-ipv6/etc/state.json" ipv6_to_ipv4_token
)"
assert_four_client_routes dual-ipv6 "$new_ipv6" v6
assert_four_client_routes dual-ipv6 "$new_ipv6_to_ipv4" v6-to-v4
assert_four_client_files dual-ipv6 v6
assert_four_client_files dual-ipv6 v6-to-v4
assert_no_backup dual-ipv6

printf '[面板订阅] 双栈全部轮换四个入口且新令牌互不重复……\n'
prepare_case dual-all dual
run_case dual-all $'3\ny'
[[ "$(<"$WORK/dual-all/rc")" == 0 ]]
for token_key in \
  ipv4_token ipv6_token ipv4_to_ipv6_token ipv6_to_ipv4_token; do
  assert_changed dual-all "$token_key"
done
[[ "$(
  jq -r '
    .subscription
    | [.ipv4_token, .ipv6_token, .ipv4_to_ipv6_token, .ipv6_to_ipv4_token]
    | unique | length
  ' "$WORK/dual-all/etc/state.json"
)" == 4 ]]
assert_only_token_keys_changed dual-all \
  ipv4_token ipv6_token ipv4_to_ipv6_token ipv6_to_ipv4_token
assert_no_backup dual-all

printf '[面板订阅] 单栈的全部选项只轮换已安装入口……\n'
for mode in ipv4-only ipv6-only; do
  name="single-${mode}"
  prepare_case "$name" "$mode"
  run_case "$name" $'3\ny\ny'
  [[ "$(<"$WORK/$name/rc")" == 0 ]]
  case "$mode" in
    ipv4-only)
      assert_changed "$name" ipv4_token
      assert_unchanged "$name" ipv6_token
      assert_only_token_keys_changed "$name" ipv4_token
      assert_four_client_routes \
        "$name" "$(token "$WORK/$name/etc/state.json" ipv4_token)" v4
      assert_four_client_files "$name" v4
      ;;
    ipv6-only)
      assert_changed "$name" ipv6_token
      assert_unchanged "$name" ipv4_token
      assert_only_token_keys_changed "$name" ipv6_token
      assert_four_client_routes \
        "$name" "$(token "$WORK/$name/etc/state.json" ipv6_token)" v6
      assert_four_client_files "$name" v6
      ;;
  esac
  [[ "$(<"$WORK/$name/random.count")" == 1 ]]
  assert_no_backup "$name"
done

printf '[面板订阅] 取消确认时不加锁也不修改配置……\n'
prepare_case cancelled dual
run_case cancelled $'1\nn'
[[ "$(<"$WORK/cancelled/rc")" == 0 ]]
diff -ru "$WORK/cancelled/etc.before" "$WORK/cancelled/etc"
[[ "$(call_count cancelled lock)" == 0 ]]
[[ "$(call_count cancelled commit)" == 0 ]]
assert_no_backup cancelled

printf '[面板订阅] 随机值与旧令牌或同批新令牌重复时不写入……\n'
for case_mode in same-old duplicate-new; do
  name="collision-${case_mode}"
  prepare_case "$name" dual
  run_case "$name" $'3\ny' "$case_mode"
  [[ "$(<"$WORK/$name/rc")" != 0 ]]
  diff -ru "$WORK/$name/etc.before" "$WORK/$name/etc"
  [[ "$(call_count "$name" commit)" == 0 ]]
  [[ "$(call_count "$name" unlock)" == 1 ]]
  assert_no_backup "$name"
done

printf '[面板订阅] 各提交阶段失败都恢复完整配置树与服务……\n'
for case_mode in commit-fail render-fail validate-fail restart-fail; do
  name="failure-${case_mode}"
  prepare_case "$name" dual
  run_case "$name" $'3\ny' "$case_mode"
  [[ "$(<"$WORK/$name/rc")" != 0 ]]
  assert_restored "$name"
  [[ "$(call_count "$name" commit)" == 1 ]]
  [[ "$(call_count "$name" validate)" -ge 1 ]]
  [[ "$(call_count "$name" restart)" -ge 1 ]]
done
[[ "$(call_count failure-commit-fail render)" == 0 ]]
[[ "$(call_count failure-render-fail render)" == 1 ]]
[[ "$(call_count failure-validate-fail validate)" == 2 ]]
[[ "$(call_count failure-restart-fail restart)" == 2 ]]

printf '[面板订阅] 意外退出由 EXIT 陷阱恢复完整配置树……\n'
prepare_case unexpected-exit dual
run_case unexpected-exit $'3\ny' unexpected-exit
[[ "$(<"$WORK/unexpected-exit/rc")" == 75 ]]
assert_restored unexpected-exit
[[ "$(call_count unexpected-exit validate)" == 2 ]]
[[ "$(call_count unexpected-exit restart)" == 1 ]]

printf '[面板订阅] 回滚服务失败时保留 root-only 完整备份……\n'
prepare_case rollback-fail dual
run_case rollback-fail $'3\ny' rollback-fail
[[ "$(<"$WORK/rollback-fail/rc")" != 0 ]]
diff -ru "$WORK/rollback-fail/etc.before" "$WORK/rollback-fail/etc"
backup_path="$(
  find "$WORK/rollback-fail/tmp" -mindepth 1 -maxdepth 1 \
    -type d -name 'neko-access-backup.*' -print -quit
)"
[[ -n "$backup_path" ]]
[[ "$(stat -c '%a' "$backup_path")" == 700 ]]
[[ "$(stat -c '%a' "$backup_path/etc/state.json")" == 600 ]]
diff -ru "$WORK/rollback-fail/etc.before" "$backup_path/etc"
grep -Fq '自动恢复未完全成功' "$WORK/rollback-fail/output"

printf '控制面板订阅令牌全量事务测试通过。\n'
