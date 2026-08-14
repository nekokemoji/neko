#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-maintenance-lock.XXXXXX")"
LOCK_FILE="$WORK/neko-maintenance.lock"
READY_FILE="$WORK/holder-ready"
RELEASE_FILE="$WORK/release-holder"
RM_LOG="$WORK/remove.log"
HOLDER_PID=""

cleanup() {
  if [[ -n "$HOLDER_PID" ]] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT

for command_name in flock kill sleep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '维护锁并发测试缺少命令：%s\n' "$command_name" >&2
    exit 1
  }
done

NEKO_LIBEXEC="$ROOT" \
NEKO_MAINTENANCE_LOCK_FILE="$LOCK_FILE" \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    acquire_maintenance_lock
    : > "$2"
    while [[ ! -e "$3" ]]; do sleep 0.01; done
    release_maintenance_lock
  ' _ "$ROOT/runtime/panel.sh" "$READY_FILE" "$RELEASE_FILE" &
HOLDER_PID=$!

for ((attempt = 0; attempt < 500; attempt++)); do
  [[ ! -e "$READY_FILE" ]] || break
  kill -0 "$HOLDER_PID" 2>/dev/null || {
    printf '第一个维护进程在持锁前意外退出。\n' >&2
    exit 1
  }
  sleep 0.01
done
[[ -e "$READY_FILE" && -e "$LOCK_FILE" ]]

# Exercise the exact uninstall removal list with a guarded rm. A regression
# targeting either the configured or hard-coded maintenance lock removes only
# this temporary lock, never host paths, and makes the contender enter.
NEKO_TEST_RM_LOG="$RM_LOG" \
NEKO_LIBEXEC="$ROOT" \
NEKO_MAINTENANCE_LOCK_FILE="$LOCK_FILE" \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    rm() {
      printf "%s\n" "$*" >> "$NEKO_TEST_RM_LOG"
      if [[ " $* " == *" neko-maintenance.lock "* \
        || " $* " == *"/neko-maintenance.lock"* ]]; then
        command rm -f -- "$NEKO_MAINTENANCE_LOCK_FILE"
      fi
    }
    remove_uninstall_files
  ' _ "$ROOT/runtime/panel.sh"

[[ -e "$LOCK_FILE" ]]
if NEKO_LIBEXEC="$ROOT" \
    NEKO_MAINTENANCE_LOCK_FILE="$LOCK_FILE" \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      acquire_maintenance_lock
      release_maintenance_lock
    ' _ "$ROOT/runtime/panel.sh" >"$WORK/contender.log" 2>&1; then
  printf '第二个维护进程在卸载锁持有期间错误进入。\n' >&2
  exit 1
fi
grep -Fq '另一个 Neko 维护任务正在运行' "$WORK/contender.log"

: > "$RELEASE_FILE"
wait "$HOLDER_PID"
HOLDER_PID=""

NEKO_LIBEXEC="$ROOT" \
NEKO_MAINTENANCE_LOCK_FILE="$LOCK_FILE" \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    acquire_maintenance_lock
    release_maintenance_lock
  ' _ "$ROOT/runtime/panel.sh"
[[ -e "$LOCK_FILE" ]]

printf '卸载保留共享锁 inode，维护并发互斥测试通过。\n'
