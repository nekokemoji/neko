#!/usr/bin/env bash

# Small lifecycle guard for top-level Neko transactions. Snapshot creation,
# validation work, commit work, and rollback contents remain explicit in each
# caller; this library only owns phase ordering and process traps.

NEKO_TRANSACTION_OWNER=""
NEKO_TRANSACTION_ROLLBACK_HANDLER=""
NEKO_TRANSACTION_PHASE="idle"
NEKO_TRANSACTION_ACTIVE=0
NEKO_TRANSACTION_ROLLING_BACK=0

neko_transaction_fail() {
  printf '事务接口错误：%s\n' "$*" >&2
  return 64
}

neko_transaction_clear_traps() {
  trap - EXIT INT TERM
}

neko_transaction_clear_state() {
  NEKO_TRANSACTION_OWNER=""
  NEKO_TRANSACTION_ROLLBACK_HANDLER=""
  NEKO_TRANSACTION_PHASE="idle"
  NEKO_TRANSACTION_ACTIVE=0
  NEKO_TRANSACTION_ROLLING_BACK=0
}

neko_transaction_parse_owner() {
  (( $# == 2 )) && [[ "$1" == --owner && -n "$2" ]] \
    || neko_transaction_fail "必须只提供 --owner NAME。" || return
  [[ "$2" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || neko_transaction_fail "owner 名称无效。" || return
  printf '%s' "$2"
}

neko_transaction_assert_owner() {
  local owner="$1"
  if (( NEKO_TRANSACTION_ACTIVE != 1 \
      || NEKO_TRANSACTION_ROLLING_BACK != 0 )) \
    || [[ "$NEKO_TRANSACTION_OWNER" != "$owner" ]]; then
    neko_transaction_fail \
      "${owner} 不是当前活动的顶层事务 owner。"
    return
  fi
}

neko_transaction_begin() {
  local owner="" rollback_handler="" signal_name existing_trap
  while (( $# > 0 )); do
    case "$1" in
      --owner)
        (( $# >= 2 )) || neko_transaction_fail "--owner 缺少值。" || return
        owner="$2"
        shift 2
        ;;
      --rollback)
        (( $# >= 2 )) \
          || neko_transaction_fail "--rollback 缺少值。" || return
        rollback_handler="$2"
        shift 2
        ;;
      *) neko_transaction_fail "begin 未知选项：$1" || return ;;
    esac
  done
  [[ "$owner" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || neko_transaction_fail "owner 名称无效。" || return
  [[ "$rollback_handler" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    && declare -F "$rollback_handler" >/dev/null \
    || neko_transaction_fail "rollback handler 不存在或名称无效。" || return
  (( NEKO_TRANSACTION_ACTIVE == 0 \
    && NEKO_TRANSACTION_ROLLING_BACK == 0 )) \
    && [[ -z "$NEKO_TRANSACTION_OWNER" ]] \
    || neko_transaction_fail \
      "已有顶层事务 ${NEKO_TRANSACTION_OWNER:-unknown}，拒绝嵌套。" || return
  for signal_name in EXIT INT TERM; do
    existing_trap="$(trap -p "$signal_name")"
    [[ -z "$existing_trap" ]] \
      || neko_transaction_fail \
        "${signal_name} 已有 trap，拒绝覆盖。" || return
  done

  NEKO_TRANSACTION_OWNER="$owner"
  NEKO_TRANSACTION_ROLLBACK_HANDLER="$rollback_handler"
  NEKO_TRANSACTION_PHASE="begun"
  NEKO_TRANSACTION_ACTIVE=1
  trap 'neko_transaction_finish "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

neko_transaction_snapshot() {
  local owner
  owner="$(neko_transaction_parse_owner "$@")" || return
  neko_transaction_assert_owner "$owner" || return
  [[ "$NEKO_TRANSACTION_PHASE" == begun ]] \
    || neko_transaction_fail \
      "${owner} 只能在 begun 阶段确认 snapshot。" || return
  NEKO_TRANSACTION_PHASE="snapshotted"
}

neko_transaction_validate() {
  local owner
  owner="$(neko_transaction_parse_owner "$@")" || return
  neko_transaction_assert_owner "$owner" || return
  [[ "$NEKO_TRANSACTION_PHASE" == snapshotted ]] \
    || neko_transaction_fail \
      "${owner} 只能在 snapshotted 阶段确认 validate。" || return
  NEKO_TRANSACTION_PHASE="validated"
}

neko_transaction_disarm() {
  local owner="$1"
  neko_transaction_assert_owner "$owner" || return
  neko_transaction_clear_traps
  neko_transaction_clear_state
}

neko_transaction_commit() {
  local owner
  owner="$(neko_transaction_parse_owner "$@")" || return
  neko_transaction_assert_owner "$owner" || return
  [[ "$NEKO_TRANSACTION_PHASE" == validated ]] \
    || neko_transaction_fail \
      "${owner} 未完成 validate，拒绝 commit。" || return
  neko_transaction_disarm "$owner"
}

neko_transaction_cancel() {
  local owner
  owner="$(neko_transaction_parse_owner "$@")" || return
  neko_transaction_disarm "$owner"
}

neko_transaction_rollback() {
  local owner rollback_handler rollback_rc=0
  owner="$(neko_transaction_parse_owner "$@")" || return
  neko_transaction_assert_owner "$owner" || return
  rollback_handler="$NEKO_TRANSACTION_ROLLBACK_HANDLER"
  NEKO_TRANSACTION_ACTIVE=0
  NEKO_TRANSACTION_ROLLING_BACK=1
  neko_transaction_clear_traps
  "$rollback_handler" || rollback_rc=$?
  neko_transaction_clear_state
  return "$rollback_rc"
}

neko_transaction_finish() {
  local rc="${1:-1}" rollback_handler
  neko_transaction_clear_traps
  if (( NEKO_TRANSACTION_ACTIVE == 1 \
    && NEKO_TRANSACTION_ROLLING_BACK == 0 )); then
    rollback_handler="$NEKO_TRANSACTION_ROLLBACK_HANDLER"
    NEKO_TRANSACTION_ACTIVE=0
    NEKO_TRANSACTION_ROLLING_BACK=1
    "$rollback_handler" || true
    neko_transaction_clear_state
  fi
  exit "$rc"
}
