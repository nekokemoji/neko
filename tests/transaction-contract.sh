#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-transaction-contract.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

run_case() {
  local name="$1"
  shift
  mkdir -p "$WORK/$name"
  NEKO_TRANSACTION_TEST_DIR="$WORK/$name" \
    bash -Eeuo pipefail -c "$*" _ "$ROOT/lib/transaction.sh"
}

run_case commit '
  source "$1"
  rollback_case() { printf "rollback\n" >> "$NEKO_TRANSACTION_TEST_DIR/log"; }
  neko_transaction_begin --owner commit-case --rollback rollback_case
  neko_transaction_snapshot --owner commit-case
  ! neko_transaction_commit --owner commit-case
  neko_transaction_validate --owner commit-case
  neko_transaction_commit --owner commit-case
  [[ -z "$(trap -p EXIT)" && -z "$(trap -p INT)" && -z "$(trap -p TERM)" ]]
  [[ ! -e "$NEKO_TRANSACTION_TEST_DIR/log" ]]
'

run_case nested '
  source "$1"
  rollback_case() { :; }
  neko_transaction_begin --owner first --rollback rollback_case
  ! neko_transaction_begin --owner second --rollback rollback_case
  [[ "$NEKO_TRANSACTION_OWNER" == first ]]
  neko_transaction_snapshot --owner first
  neko_transaction_cancel --owner first
'

run_case existing-trap '
  source "$1"
  rollback_case() { :; }
  trap : EXIT
  before="$(trap -p EXIT)"
  ! neko_transaction_begin --owner guarded --rollback rollback_case
  [[ "$(trap -p EXIT)" == "$before" ]]
  trap - EXIT
'

run_case manual-rollback '
  source "$1"
  rollback_case() { printf "rollback\n" >> "$NEKO_TRANSACTION_TEST_DIR/log"; }
  neko_transaction_begin --owner manual --rollback rollback_case
  neko_transaction_snapshot --owner manual
  neko_transaction_rollback --owner manual
  [[ "$(<"$NEKO_TRANSACTION_TEST_DIR/log")" == rollback ]]
  [[ "$NEKO_TRANSACTION_PHASE" == idle && -z "$NEKO_TRANSACTION_OWNER" ]]
'

run_case rollback-failure '
  source "$1"
  mkdir "$NEKO_TRANSACTION_TEST_DIR/snapshot"
  rollback_case() { return 1; }
  neko_transaction_begin --owner retained --rollback rollback_case
  neko_transaction_snapshot --owner retained
  set +e
  neko_transaction_rollback --owner retained
  rc=$?
  set -e
  (( rc == 1 ))
  [[ -d "$NEKO_TRANSACTION_TEST_DIR/snapshot" ]]
  [[ "$NEKO_TRANSACTION_PHASE" == idle && -z "$NEKO_TRANSACTION_OWNER" ]]
'

mkdir -p "$WORK/exit"
set +e
NEKO_TRANSACTION_TEST_DIR="$WORK/exit" bash -Eeuo pipefail -c '
  source "$1"
  rollback_case() { printf "rollback\n" >> "$NEKO_TRANSACTION_TEST_DIR/log"; }
  neko_transaction_begin --owner exit-case --rollback rollback_case
  neko_transaction_snapshot --owner exit-case
  exit 42
' _ "$ROOT/lib/transaction.sh"
exit_rc=$?
set -e
(( exit_rc == 42 ))
[[ "$(<"$WORK/exit/log")" == rollback ]]

for signal_case in INT TERM; do
  mkdir -p "$WORK/signal-$signal_case"
  set +e
  NEKO_TRANSACTION_TEST_DIR="$WORK/signal-$signal_case" \
    bash -Eeuo pipefail -c '
      source "$1"
      rollback_case() {
        printf "rollback\n" >> "$NEKO_TRANSACTION_TEST_DIR/log"
      }
      neko_transaction_begin --owner signal-case --rollback rollback_case
      neko_transaction_snapshot --owner signal-case
      kill -"$2" "$$"
    ' _ "$ROOT/lib/transaction.sh" "$signal_case"
  signal_rc=$?
  set -e
  if [[ "$signal_case" == INT ]]; then
    (( signal_rc == 130 ))
  else
    (( signal_rc == 143 ))
  fi
  [[ "$(<"$WORK/signal-$signal_case/log")" == rollback ]]
done

printf '统一事务 owner、阶段、trap、提交与回滚失败保留契约测试通过。\n'
