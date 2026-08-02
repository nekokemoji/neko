#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-panel-credentials.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

credential_keys=(
  hysteria2_password
  hysteria2_obfs_password
  tuic_uuid
  tuic_password
  ss2022_password
  anytls_password
  trojan_password
  vision_uuid
  xhttp_uuid
)

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
  local name="$1" mode="$2" target
  target="$WORK/$name"
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
  cp -a -- "$target/etc/state.json" "$target/state.before.json"
  cp -a -- "$target/etc/config" "$target/config.before"
  cp -a -- "$target/etc/subscriptions" "$target/subscriptions.before"
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

      acquire_maintenance_lock() {
        printf "lock\n" >> "$CASE_DIR/calls"
      }
      release_maintenance_lock() {
        printf "unlock\n" >> "$CASE_DIR/calls"
      }
      next_counter() {
        local counter_file="$1" count=0
        [[ ! -s "$counter_file" ]] || count="$(<"$counter_file")"
        count=$((count + 1))
        printf "%s\n" "$count" > "$counter_file"
        printf "%s" "$count"
      }
      random_urlsafe() {
        local count
        count="$(next_counter "$CASE_DIR/urlsafe.count")"
        if [[ "$CASE_MODE" == same-random && "$count" == 1 ]]; then
          jq -r ".credentials.hysteria2_password" "$NEKO_STATE"
          return 0
        fi
        case "$count" in
          1) printf "new-hy2-password-value-01" ;;
          2) printf "new-hy2-obfs-value-02" ;;
          3) printf "new-tuic-password-value-03" ;;
          4) printf "new-anytls-password-value-04" ;;
          5) printf "new-trojan-password-value-05" ;;
          6) printf "new-ipv4-subscription-token-06" ;;
          7) printf "new-ipv6-subscription-token-07" ;;
          8) printf "new-ipv4-to-ipv6-token-08" ;;
          9) printf "new-ipv6-to-ipv4-token-09" ;;
          *) return 70 ;;
        esac
      }
      new_uuid() {
        local count
        count="$(next_counter "$CASE_DIR/uuid.count")"
        case "$count" in
          1) printf "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" ;;
          2) printf "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" ;;
          3) printf "cccccccc-cccc-4ccc-8ccc-cccccccccccc" ;;
          *) return 70 ;;
        esac
      }
      random_base64() {
        printf "base64\n" >> "$CASE_DIR/calls"
        printf "YWJjZGVmZ2hpamtsbW5vcA=="
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
      }
      validate_runtime_configs() {
        local count
        printf "validate\n" >> "$CASE_DIR/calls"
        count="$(grep -c "^validate$" "$CASE_DIR/calls")"
        if [[ "$CASE_MODE" == unexpected-exit && "$count" == 1 ]]; then
          exit 75
        fi
        return 0
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

      manage_subscription_access <<< "$CASE_INPUT"
    ' _ "$ROOT/runtime/panel.sh" > "$target/output" 2>&1
  printf '%s\n' "$?" > "$target/rc"
  set -e
}

call_count() {
  local name="$1" call="$2"
  grep -c "^${call}$" "$WORK/$name/calls" 2>/dev/null || true
}

assert_credentials_changed() {
  local name="$1" key before after
  for key in "${credential_keys[@]}"; do
    before="$(jq -r --arg key "$key" '.credentials[$key]' \
      "$WORK/$name/state.before.json")"
    after="$(jq -r --arg key "$key" '.credentials[$key]' \
      "$WORK/$name/etc/state.json")"
    if [[ "$before" == "$after" ]]; then
      printf '节点凭据字段没有换新：%s\n' "$key" >&2
      exit 1
    fi
  done
}

assert_protocol_secrets_not_printed() {
  local name="$1" key value
  for key in "${credential_keys[@]}"; do
    value="$(jq -r --arg key "$key" '.credentials[$key]' \
      "$WORK/$name/state.before.json")"
    if grep -Fq -- "$value" "$WORK/$name/output"; then
      printf '旧节点凭据泄露到终端输出：%s\n' "$key" >&2
      exit 1
    fi
    value="$(jq -r --arg key "$key" '.credentials[$key]' \
      "$WORK/$name/etc/state.json")"
    if grep -Fq -- "$value" "$WORK/$name/output"; then
      printf '新节点凭据泄露到终端输出：%s\n' "$key" >&2
      exit 1
    fi
  done
}

assert_old_credentials_absent_from_runtime() {
  local name="$1" key value
  for key in "${credential_keys[@]}"; do
    value="$(jq -r --arg key "$key" '.credentials[$key]' \
      "$WORK/$name/state.before.json")"
    if grep -FRq -- "$value" \
      "$WORK/$name/etc/config" "$WORK/$name/etc/subscriptions"; then
      printf '旧节点凭据仍出现在生成配置中：%s\n' "$key" >&2
      exit 1
    fi
  done
}

assert_new_credentials_rendered() {
  local name="$1" key value
  for key in "${credential_keys[@]}"; do
    value="$(jq -r --arg key "$key" '.credentials[$key]' \
      "$WORK/$name/etc/state.json")"
    if ! grep -FRq -- "$value" \
      "$WORK/$name/etc/config" "$WORK/$name/etc/subscriptions"; then
      printf '新节点凭据没有写入任何生成配置：%s\n' "$key" >&2
      exit 1
    fi
  done
}

assert_no_access_backup() {
  local name="$1"
  if find "$WORK/$name/tmp" -mindepth 1 -maxdepth 1 \
    -name "neko-access-backup.*" | grep -q .; then
    printf '维护成功或成功回滚后留下了访问凭据备份：%s\n' "$name" >&2
    exit 1
  fi
}

printf '[面板凭据] 仅重置全部节点凭据，保留订阅 URL……\n'
prepare_case credentials-only dual
run_case credentials-only $'2\nROTATE'
[[ "$(<"$WORK/credentials-only/rc")" == 0 ]]
assert_credentials_changed credentials-only
jq -e '
  .credentials == {
    hysteria2_password: "new-hy2-password-value-01",
    hysteria2_obfs_password: "new-hy2-obfs-value-02",
    tuic_uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    tuic_password: "new-tuic-password-value-03",
    ss2022_password: "YWJjZGVmZ2hpamtsbW5vcA==",
    anytls_password: "new-anytls-password-value-04",
    trojan_password: "new-trojan-password-value-05",
    vision_uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    xhttp_uuid: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  }
' "$WORK/credentials-only/etc/state.json" >/dev/null
jq -cS 'del(.credentials)' "$WORK/credentials-only/state.before.json" \
  > "$WORK/credentials-only/before.public"
jq -cS 'del(.credentials)' "$WORK/credentials-only/etc/state.json" \
  > "$WORK/credentials-only/after.public"
cmp -s \
  "$WORK/credentials-only/before.public" "$WORK/credentials-only/after.public"
[[ "$(<"$WORK/credentials-only/urlsafe.count")" == 5 ]]
[[ "$(<"$WORK/credentials-only/uuid.count")" == 3 ]]
[[ "$(call_count credentials-only base64)" == 1 ]]
[[ "$(call_count credentials-only render)" == 1 ]]
[[ "$(call_count credentials-only validate)" == 1 ]]
[[ "$(call_count credentials-only restart)" == 1 ]]
[[ "$(call_count credentials-only links)" == 1 ]]
grep -Fq '订阅 URL 保持不变' "$WORK/credentials-only/output"
assert_old_credentials_absent_from_runtime credentials-only
assert_new_credentials_rendered credentials-only
assert_protocol_secrets_not_printed credentials-only
assert_no_access_backup credentials-only

printf '[面板凭据] 双栈紧急全部换新同时替换两族 URL……\n'
prepare_case emergency-dual dual
run_case emergency-dual $'3\nREVOKE'
[[ "$(<"$WORK/emergency-dual/rc")" == 0 ]]
assert_credentials_changed emergency-dual
old_ipv4_token="$(jq -r '.subscription.ipv4_token' \
  "$WORK/emergency-dual/state.before.json")"
old_ipv6_token="$(jq -r '.subscription.ipv6_token' \
  "$WORK/emergency-dual/state.before.json")"
old_ipv4_to_ipv6_token="$(jq -r '.subscription.ipv4_to_ipv6_token' \
  "$WORK/emergency-dual/state.before.json")"
old_ipv6_to_ipv4_token="$(jq -r '.subscription.ipv6_to_ipv4_token' \
  "$WORK/emergency-dual/state.before.json")"
new_ipv4_token="$(jq -r '.subscription.ipv4_token' \
  "$WORK/emergency-dual/etc/state.json")"
new_ipv6_token="$(jq -r '.subscription.ipv6_token' \
  "$WORK/emergency-dual/etc/state.json")"
new_ipv4_to_ipv6_token="$(jq -r '.subscription.ipv4_to_ipv6_token' \
  "$WORK/emergency-dual/etc/state.json")"
new_ipv6_to_ipv4_token="$(jq -r '.subscription.ipv6_to_ipv4_token' \
  "$WORK/emergency-dual/etc/state.json")"
[[ "$new_ipv4_token" != "$old_ipv4_token" ]]
[[ "$new_ipv6_token" != "$old_ipv6_token" ]]
[[ "$new_ipv4_token" != "$new_ipv6_token" ]]
[[ "$new_ipv4_to_ipv6_token" != "$old_ipv4_to_ipv6_token" ]]
[[ "$new_ipv6_to_ipv4_token" != "$old_ipv6_to_ipv4_token" ]]
[[ "$(<"$WORK/emergency-dual/urlsafe.count")" == 9 ]]
jq -cS '
  del(
    .credentials,
    .subscription.ipv4_token,
    .subscription.ipv6_token,
    .subscription.ipv4_to_ipv6_token,
    .subscription.ipv6_to_ipv4_token
  )
' "$WORK/emergency-dual/state.before.json" \
  > "$WORK/emergency-dual/before.public"
jq -cS '
  del(
    .credentials,
    .subscription.ipv4_token,
    .subscription.ipv6_token,
    .subscription.ipv4_to_ipv6_token,
    .subscription.ipv6_to_ipv4_token
  )
' "$WORK/emergency-dual/etc/state.json" \
  > "$WORK/emergency-dual/after.public"
cmp -s "$WORK/emergency-dual/before.public" "$WORK/emergency-dual/after.public"
if grep -FRq -- "$old_ipv4_token" "$WORK/emergency-dual/etc"; then
  printf '紧急换新后旧订阅令牌仍出现在配置目录中。\n' >&2
  exit 1
fi
grep -Fq "$new_ipv4_token" "$WORK/emergency-dual/etc/config/Caddyfile"
grep -Fq "$new_ipv6_token" "$WORK/emergency-dual/etc/config/Caddyfile"
grep -Fq "$new_ipv4_to_ipv6_token" "$WORK/emergency-dual/etc/config/Caddyfile"
grep -Fq "$new_ipv6_to_ipv4_token" "$WORK/emergency-dual/etc/config/Caddyfile"
grep -Fq '旧订阅 URL 与旧节点凭据已全部失效' \
  "$WORK/emergency-dual/output"
assert_old_credentials_absent_from_runtime emergency-dual
assert_new_credentials_rendered emergency-dual
assert_protocol_secrets_not_printed emergency-dual
assert_no_access_backup emergency-dual

printf '[面板凭据] 紧急模式只轮换已安装地址族的 URL……\n'
for mode in ipv4-only ipv6-only; do
  name="emergency-${mode}"
  prepare_case "$name" "$mode"
  run_case "$name" $'3\nREVOKE'
  [[ "$(<"$WORK/$name/rc")" == 0 ]]
  assert_credentials_changed "$name"
  case "$mode" in
    ipv4-only)
      [[ "$(jq -r '.subscription.ipv4_token' "$WORK/$name/etc/state.json")" \
        != "$(jq -r '.subscription.ipv4_token' "$WORK/$name/state.before.json")" ]]
      [[ "$(jq -r '.subscription.ipv6_token // empty' \
        "$WORK/$name/etc/state.json")" == "" ]]
      ;;
    ipv6-only)
      [[ "$(jq -r '.subscription.ipv6_token' "$WORK/$name/etc/state.json")" \
        != "$(jq -r '.subscription.ipv6_token' "$WORK/$name/state.before.json")" ]]
      [[ "$(jq -r '.subscription.ipv4_token // empty' \
        "$WORK/$name/etc/state.json")" == "" ]]
      ;;
  esac
  [[ "$(<"$WORK/$name/urlsafe.count")" == 6 ]]
  assert_old_credentials_absent_from_runtime "$name"
  assert_new_credentials_rendered "$name"
  assert_no_access_backup "$name"
done

printf '[面板凭据] 未输入确认词时保持完全不变……\n'
prepare_case cancelled dual
cancelled_hash="$(sha256sum "$WORK/cancelled/etc/state.json" | awk '{print $1}')"
run_case cancelled $'2\nno'
[[ "$(<"$WORK/cancelled/rc")" == 0 ]]
[[ "$(sha256sum "$WORK/cancelled/etc/state.json" | awk '{print $1}')" \
  == "$cancelled_hash" ]]
[[ ! -e "$WORK/cancelled/calls" ]]
assert_no_access_backup cancelled

printf '[面板凭据] 随机值意外重复时在写入前安全停止……\n'
prepare_case same-random dual
same_random_hash="$(
  sha256sum "$WORK/same-random/etc/state.json" | awk '{print $1}'
)"
run_case same-random $'2\nROTATE' same-random
[[ "$(<"$WORK/same-random/rc")" != 0 ]]
[[ "$(sha256sum "$WORK/same-random/etc/state.json" | awk '{print $1}')" \
  == "$same_random_hash" ]]
[[ "$(call_count same-random lock)" == 1 ]]
[[ "$(call_count same-random unlock)" == 1 ]]
[[ "$(call_count same-random render)" == 0 ]]
grep -Fq '随机生成的新值与旧值意外相同' "$WORK/same-random/output"
assert_no_access_backup same-random

printf '[面板凭据] 服务失败时恢复旧状态与全部生成配置……\n'
prepare_case rollback dual
run_case rollback $'2\nROTATE' rollback
[[ "$(<"$WORK/rollback/rc")" != 0 ]]
cmp -s "$WORK/rollback/state.before.json" "$WORK/rollback/etc/state.json"
diff -ru "$WORK/rollback/config.before" "$WORK/rollback/etc/config"
diff -ru \
  "$WORK/rollback/subscriptions.before" "$WORK/rollback/etc/subscriptions"
[[ "$(call_count rollback render)" == 1 ]]
[[ "$(call_count rollback validate)" == 2 ]]
[[ "$(call_count rollback restart)" == 2 ]]
grep -Fq '已恢复原订阅、原节点和服务' "$WORK/rollback/output"
assert_no_access_backup rollback

printf '[面板凭据] 意外退出由 EXIT 事务自动恢复……\n'
prepare_case unexpected-exit dual
run_case unexpected-exit $'2\nROTATE' unexpected-exit
[[ "$(<"$WORK/unexpected-exit/rc")" == 75 ]]
cmp -s \
  "$WORK/unexpected-exit/state.before.json" \
  "$WORK/unexpected-exit/etc/state.json"
diff -ru \
  "$WORK/unexpected-exit/config.before" \
  "$WORK/unexpected-exit/etc/config"
diff -ru \
  "$WORK/unexpected-exit/subscriptions.before" \
  "$WORK/unexpected-exit/etc/subscriptions"
[[ "$(call_count unexpected-exit render)" == 1 ]]
[[ "$(call_count unexpected-exit validate)" == 2 ]]
[[ "$(call_count unexpected-exit restart)" == 1 ]]
grep -Fq '已恢复原来的订阅、节点凭据、配置和服务' \
  "$WORK/unexpected-exit/output"
assert_no_access_backup unexpected-exit

printf '[面板凭据] 回滚服务仍失败时保留 root-only 备份……\n'
prepare_case rollback-fail dual
run_case rollback-fail $'3\nREVOKE' rollback-fail
[[ "$(<"$WORK/rollback-fail/rc")" != 0 ]]
cmp -s \
  "$WORK/rollback-fail/state.before.json" \
  "$WORK/rollback-fail/etc/state.json"
backup_path="$(
  find "$WORK/rollback-fail/tmp" -mindepth 1 -maxdepth 1 \
    -type d -name "neko-access-backup.*" -print -quit
)"
[[ -n "$backup_path" ]]
[[ "$(stat -c '%a' "$backup_path")" == 700 ]]
[[ "$(stat -c '%a' "$backup_path/etc/state.json")" == 600 ]]
grep -Fq '自动恢复未完全成功' "$WORK/rollback-fail/output"

if NEKO_ETC=/ NEKO_VAR=/var NEKO_LIBEXEC="$ROOT" \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    assert_access_source_tree
  ' _ "$ROOT/runtime/panel.sh" >/dev/null 2>&1; then
  printf '访问凭据事务错误接受了根目录作为配置目录。\n' >&2
  exit 1
fi

printf '控制面板节点凭据与紧急撤销事务测试通过。\n'
