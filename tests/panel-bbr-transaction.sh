#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-panel-bbr.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

prepare_case() {
  local name="$1" target="$WORK/$1"
  mkdir -p \
    "$target/etc" "$target/var" "$target/tmp" "$target/sysctl.d" \
    "$target/kernel/modules"
  cp -a -- "$ROOT/tests/fixtures/state.json" "$target/etc/state.json"
  chmod 0600 "$target/etc/state.json"
  printf 'fq_codel\n' > "$target/kernel/qdisc"
  printf 'cubic\n' > "$target/kernel/cc"
  printf 'reno cubic\n' > "$target/kernel/available"
  cp -a -- "$target/etc/state.json" "$target/state.initial.json"
  : > "$target/calls"
}

render_case() {
  local name="$1" target="$WORK/$1"
  NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      source "$2"
      render_all
    ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
  cp -a -- "$target/etc/config" "$target/config.initial"
  cp -a -- "$target/etc/subscriptions" "$target/subscriptions.initial"
}

run_case() {
  local name="$1" operation="$2" case_mode="${3:-success}"
  local target="$WORK/$1"
  set +e
  env \
    CASE_DIR="$target" CASE_MODE="$case_mode" \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    NEKO_LIBEXEC="$ROOT" NEKO_PANEL_TMP_DIR="$target/tmp" \
    NEKO_BBR_SYSCTL_FILE="$target/sysctl.d/99-neko-bbr.conf" \
    bash -c '
      set -Eeuo pipefail
      source "$1"

      acquire_maintenance_lock() {
        printf "lock\n" >> "$CASE_DIR/calls"
      }
      release_maintenance_lock() {
        printf "unlock\n" >> "$CASE_DIR/calls"
      }
      bbr_current_qdisc() {
        printf "%s\n" "$(<"$CASE_DIR/kernel/qdisc")"
      }
      bbr_current_cc() {
        printf "%s\n" "$(<"$CASE_DIR/kernel/cc")"
      }
      bbr_available_cc() {
        printf "%s\n" "$(<"$CASE_DIR/kernel/available")"
      }
      bbr_module_is_loaded() {
        [[ -e "$CASE_DIR/kernel/modules/$1" ]]
      }
      modprobe() {
        local module
        printf "modprobe:%s\n" "$*" >> "$CASE_DIR/calls"
        if [[ "${1:-}" == -r ]]; then
          module="$2"
          if [[ "$CASE_MODE" == enable-rollback-module-fail \
            || "$CASE_MODE" == restore-module-fail ]]; then
            return 1
          fi
          command rm -f -- "$CASE_DIR/kernel/modules/$module"
          if [[ "$module" == tcp_bbr ]]; then
            printf "reno cubic\n" > "$CASE_DIR/kernel/available"
          fi
          return 0
        fi
        module="$1"
        if [[ "$module" == tcp_bbr \
          && ( "$CASE_MODE" == enable-module-load-fail \
            || "$CASE_MODE" == restore-module-load-fail ) ]]; then
          return 1
        fi
        : > "$CASE_DIR/kernel/modules/$module"
        if [[ "$module" == tcp_bbr \
          && "$CASE_MODE" != enable-availability-fail ]]; then
          printf "reno cubic bbr\n" > "$CASE_DIR/kernel/available"
        fi
      }
      bbr_apply_sysctl_files() {
        local count
        printf "apply\n" >> "$CASE_DIR/calls"
        count="$(grep -c "^apply$" "$CASE_DIR/calls")"
        case "$CASE_MODE" in
          enable-apply-fail)
            (( count != 1 )) || return 1
            ;;
          enable-rollback-apply-fail)
            return 1
            ;;
          restore-apply-fail)
            (( count != 1 )) || return 1
            ;;
        esac
        if [[ -f "$SYSCTL_FILE" ]]; then
          printf "fq\n" > "$CASE_DIR/kernel/qdisc"
          if [[ "$CASE_MODE" == enable-validate-fail && "$count" == 1 ]]; then
            printf "cubic\n" > "$CASE_DIR/kernel/cc"
          else
            printf "bbr\n" > "$CASE_DIR/kernel/cc"
          fi
        fi
        if [[ "$CASE_MODE" == enable-unexpected-exit && "$count" == 1 \
          || "$CASE_MODE" == restore-unexpected-exit && "$count" == 1 ]]; then
          exit 75
        fi
      }
      bbr_set_qdisc() {
        local count
        printf "set-qdisc:%s\n" "$1" >> "$CASE_DIR/calls"
        count="$(grep -c "^set-qdisc:" "$CASE_DIR/calls")"
        if [[ "$CASE_MODE" == restore-qdisc-fail && "$count" == 1 ]]; then
          return 1
        fi
        printf "%s\n" "$1" > "$CASE_DIR/kernel/qdisc"
      }
      bbr_set_cc() {
        local count
        printf "set-cc:%s\n" "$1" >> "$CASE_DIR/calls"
        count="$(grep -c "^set-cc:" "$CASE_DIR/calls")"
        if [[ "$CASE_MODE" == restore-cc-fail && "$count" == 1 \
          || "$CASE_MODE" == enable-rollback-cc-fail ]]; then
          return 1
        fi
        printf "%s\n" "$1" > "$CASE_DIR/kernel/cc"
      }
      bbr_remove_managed_sysctl_file() {
        printf "remove-sysctl\n" >> "$CASE_DIR/calls"
        [[ "$CASE_MODE" != restore-remove-fail ]] || return 1
        command rm -f -- "$SYSCTL_FILE"
      }
      mv() {
        local destination="${!#}"
        if [[ "$CASE_MODE" == enable-write-fail \
          && "$destination" == "$SYSCTL_FILE" \
          && "$*" == *".tmp."* ]]; then
          return 1
        fi
        if [[ "$CASE_MODE" == enable-rollback-file-fail \
          && "$destination" == "$SYSCTL_FILE" \
          && "$*" == *".restore."* ]]; then
          return 1
        fi
        if [[ ( "$CASE_MODE" == enable-rollback-state-fail \
            || "$CASE_MODE" == restore-rollback-state-fail ) \
          && "$destination" == "$NEKO_STATE" \
          && "$*" == *".bbr-restore."* ]]; then
          return 1
        fi
        command mv "$@"
      }
      rm() {
        local destination="${!#}"
        if [[ "$CASE_MODE" == enable-rollback-file-fail \
          && "$destination" == "$SYSCTL_FILE" ]]; then
          return 1
        fi
        command rm "$@"
      }
      atomic_json_update() {
        local filter="$1" tmp
        shift
        printf "commit\n" >> "$CASE_DIR/calls"
        tmp="$(mktemp "${NEKO_STATE}.tmp.XXXXXX")"
        jq "$@" "$filter" "$NEKO_STATE" > "$tmp"
        chmod 0600 "$tmp"
        command mv -f "$tmp" "$NEKO_STATE"
        case "$CASE_MODE" in
          enable-commit-fail|enable-rollback-file-fail|enable-rollback-state-fail|enable-rollback-cc-fail|enable-rollback-module-fail)
            return 1
            ;;
          restore-commit-fail|restore-rollback-state-fail)
            return 1
            ;;
        esac
      }
      if [[ "$CASE_MODE" == restore-validate-fail ]]; then
        bbr_recorded_state_matches() { return 1; }
      fi

      case "$2" in
        enable) enable_bbr ;;
        restore) restore_bbr ;;
        *) exit 64 ;;
      esac
    ' _ "$ROOT/runtime/panel.sh" "$operation" > "$target/output" 2>&1
  printf '%s\n' "$?" > "$target/rc"
  set -e
}

call_count() {
  local name="$1" pattern="$2"
  grep -c "^${pattern}" "$WORK/$name/calls" 2>/dev/null || true
}

assert_no_backup() {
  local name="$1"
  if find "$WORK/$name/tmp" -mindepth 1 -maxdepth 1 \
    -name 'neko-bbr-backup.*' | grep -q .; then
    printf 'BBR 成功或成功回滚后留下了备份：%s\n' "$name" >&2
    exit 1
  fi
}

snapshot_managed_case() {
  local name="$1" target="$WORK/$1"
  cp -a -- "$target/etc/state.json" "$target/managed.state.json"
  cp -a -- "$target/sysctl.d/99-neko-bbr.conf" "$target/managed.sysctl"
  cp -a -- "$target/kernel" "$target/managed.kernel"
  : > "$target/calls"
}

assert_initial_restored() {
  local name="$1" target="$WORK/$1"
  cmp -s "$target/state.initial.json" "$target/etc/state.json"
  [[ ! -e "$target/sysctl.d/99-neko-bbr.conf" ]]
  [[ "$(<"$target/kernel/qdisc")" == fq_codel ]]
  [[ "$(<"$target/kernel/cc")" == cubic ]]
  [[ "$(<"$target/kernel/available")" == 'reno cubic' ]]
  [[ ! -e "$target/kernel/modules/tcp_bbr" ]]
  [[ ! -e "$target/kernel/modules/sch_fq" ]]
  assert_no_backup "$name"
}

assert_managed_restored() {
  local name="$1" target="$WORK/$1"
  cmp -s "$target/managed.state.json" "$target/etc/state.json"
  cmp -s "$target/managed.sysctl" \
    "$target/sysctl.d/99-neko-bbr.conf"
  [[ "$(stat -c '%a' "$target/sysctl.d/99-neko-bbr.conf")" == 644 ]]
  [[ "$(stat -c '%a' "$target/etc/state.json")" == 600 ]]
  diff -ru "$target/managed.kernel" "$target/kernel"
  assert_no_backup "$name"
}

prepare_managed_case() {
  local name="$1"
  prepare_case "$name"
  run_case "$name" enable success
  [[ "$(<"$WORK/$name/rc")" == 0 ]]
  snapshot_managed_case "$name"
}

printf '[面板 BBR] 新启用记录原内核状态且不触碰订阅……\n'
prepare_case enable-success
render_case enable-success
run_case enable-success enable success
if [[ "$(<"$WORK/enable-success/rc")" != 0 ]]; then
  cat "$WORK/enable-success/output" >&2
  cat "$WORK/enable-success/calls" >&2
  find "$WORK/enable-success/kernel" -maxdepth 2 -type f \
    -printf '%P: ' -exec cat {} \; >&2
  exit 1
fi
jq -e '
  .bbr == {
    managed: true,
    previous_qdisc: "fq_codel",
    previous_congestion_control: "cubic",
    previous_available_congestion_control: "reno cubic",
    previous_tcp_bbr_loaded: false,
    previous_sch_fq_loaded: false
  }
' "$WORK/enable-success/etc/state.json" >/dev/null
jq -cS 'del(.bbr)' "$WORK/enable-success/state.initial.json" \
  > "$WORK/enable-success/state.initial.public"
jq -cS 'del(.bbr)' "$WORK/enable-success/etc/state.json" \
  > "$WORK/enable-success/state.after.public"
cmp -s \
  "$WORK/enable-success/state.initial.public" \
  "$WORK/enable-success/state.after.public"
diff -ru \
  "$WORK/enable-success/config.initial" "$WORK/enable-success/etc/config"
diff -ru \
  "$WORK/enable-success/subscriptions.initial" \
  "$WORK/enable-success/etc/subscriptions"
printf '%s\n' \
  '# Managed by Neko. Removed, and previous live values restored, on uninstall.' \
  'net.core.default_qdisc = fq' \
  'net.ipv4.tcp_congestion_control = bbr' \
  > "$WORK/expected-bbr-sysctl.conf"
cmp -s \
  "$WORK/expected-bbr-sysctl.conf" \
  "$WORK/enable-success/sysctl.d/99-neko-bbr.conf"
[[ "$(stat -c '%a' \
  "$WORK/enable-success/sysctl.d/99-neko-bbr.conf")" == 644 ]]
[[ "$(<"$WORK/enable-success/kernel/qdisc")" == fq ]]
[[ "$(<"$WORK/enable-success/kernel/cc")" == bbr ]]
[[ "$(<"$WORK/enable-success/kernel/available")" == 'reno cubic bbr' ]]
[[ -e "$WORK/enable-success/kernel/modules/tcp_bbr" ]]
[[ -e "$WORK/enable-success/kernel/modules/sch_fq" ]]
[[ "$(call_count enable-success commit)" == 1 ]]
[[ "$(call_count enable-success apply)" == 1 ]]
[[ "$(call_count enable-success unlock)" == 1 ]]
assert_no_backup enable-success

printf '[面板 BBR] 已由 Neko 管理且生效时保持幂等……\n'
: > "$WORK/enable-success/calls"
run_case enable-success enable success
[[ "$(<"$WORK/enable-success/rc")" == 0 ]]
[[ "$(call_count enable-success commit)" == 0 ]]
[[ "$(call_count enable-success apply)" == 0 ]]
grep -Fq '已由 Neko 管理并保持生效' "$WORK/enable-success/output"

printf '[面板 BBR] 系统原本已启用 BBR 时不接管……\n'
prepare_case preexisting
printf 'fq\n' > "$WORK/preexisting/kernel/qdisc"
printf 'bbr\n' > "$WORK/preexisting/kernel/cc"
printf 'reno cubic bbr\n' > "$WORK/preexisting/kernel/available"
: > "$WORK/preexisting/kernel/modules/tcp_bbr"
run_case preexisting enable success
[[ "$(<"$WORK/preexisting/rc")" == 0 ]]
cmp -s \
  "$WORK/preexisting/state.initial.json" "$WORK/preexisting/etc/state.json"
[[ ! -e "$WORK/preexisting/sysctl.d/99-neko-bbr.conf" ]]
[[ "$(call_count preexisting commit)" == 0 ]]
grep -Fq '系统原本已启用 BBR；Neko 不会接管' \
  "$WORK/preexisting/output"
assert_no_backup preexisting

printf '[面板 BBR] 用户原有同名文件绝不覆盖……\n'
prepare_case user-file
printf 'net.ipv4.tcp_congestion_control = cubic\n' \
  > "$WORK/user-file/sysctl.d/99-neko-bbr.conf"
cp -a -- \
  "$WORK/user-file/sysctl.d/99-neko-bbr.conf" "$WORK/user-file/user.sysctl"
run_case user-file enable success
[[ "$(<"$WORK/user-file/rc")" != 0 ]]
cmp -s \
  "$WORK/user-file/user.sysctl" \
  "$WORK/user-file/sysctl.d/99-neko-bbr.conf"
cmp -s "$WORK/user-file/state.initial.json" "$WORK/user-file/etc/state.json"
[[ "$(call_count user-file commit)" == 0 ]]

printf '[面板 BBR] 已加载算法不重复加载 tcp_bbr 并记录原模块……\n'
prepare_case available-before
printf 'reno cubic bbr\n' > "$WORK/available-before/kernel/available"
: > "$WORK/available-before/kernel/modules/tcp_bbr"
run_case available-before enable success
[[ "$(<"$WORK/available-before/rc")" == 0 ]]
jq -e '.bbr.previous_tcp_bbr_loaded == true' \
  "$WORK/available-before/etc/state.json" >/dev/null
[[ "$(call_count available-before 'modprobe:tcp_bbr')" == 0 ]]

printf '[面板 BBR] 启用的每个可变步骤失败都完整回滚……\n'
for case_mode in \
  enable-module-load-fail enable-availability-fail enable-write-fail \
  enable-apply-fail enable-validate-fail enable-commit-fail \
  enable-unexpected-exit; do
  name="failure-${case_mode}"
  prepare_case "$name"
  run_case "$name" enable "$case_mode"
  [[ "$(<"$WORK/$name/rc")" != 0 ]]
  assert_initial_restored "$name"
done
[[ "$(<"$WORK/failure-enable-unexpected-exit/rc")" == 75 ]]

printf '[面板 BBR] 启用回滚失败时保留 root-only 快照……\n'
for case_mode in \
  enable-rollback-file-fail enable-rollback-state-fail \
  enable-rollback-cc-fail enable-rollback-apply-fail \
  enable-rollback-module-fail; do
  name="rollback-${case_mode}"
  prepare_case "$name"
  run_case "$name" enable "$case_mode"
  [[ "$(<"$WORK/$name/rc")" != 0 ]]
  backup_path="$(
    find "$WORK/$name/tmp" -mindepth 1 -maxdepth 1 \
      -type d -name 'neko-bbr-backup.*' -print -quit
  )"
  [[ -n "$backup_path" ]]
  [[ "$(stat -c '%a' "$backup_path")" == 700 ]]
  [[ "$(stat -c '%a' "$backup_path/state.json")" == 600 ]]
  cmp -s "$WORK/$name/state.initial.json" "$backup_path/state.json"
  grep -Fq 'BBR 自动恢复未完全成功' "$WORK/$name/output"
done

printf '[面板 BBR] 成功恢复原值、模块、可用性、文件和状态……\n'
prepare_managed_case restore-success
run_case restore-success restore success
[[ "$(<"$WORK/restore-success/rc")" == 0 ]]
assert_initial_restored restore-success
[[ "$(call_count restore-success remove-sysctl)" == 1 ]]
[[ "$(call_count restore-success commit)" == 1 ]]

printf '[面板 BBR] 恢复的每个步骤失败都回到 Neko 管理状态……\n'
for case_mode in \
  restore-remove-fail restore-apply-fail restore-qdisc-fail \
  restore-cc-fail restore-module-fail restore-validate-fail \
  restore-commit-fail restore-unexpected-exit; do
  name="failure-${case_mode}"
  prepare_managed_case "$name"
  run_case "$name" restore "$case_mode"
  [[ "$(<"$WORK/$name/rc")" != 0 ]]
  assert_managed_restored "$name"
done
[[ "$(<"$WORK/failure-restore-unexpected-exit/rc")" == 75 ]]

printf '[面板 BBR] 恢复所需的原模块重新加载失败时回到调用前状态……\n'
prepare_case failure-restore-module-load-fail
printf 'reno cubic bbr\n' \
  > "$WORK/failure-restore-module-load-fail/kernel/available"
: > "$WORK/failure-restore-module-load-fail/kernel/modules/tcp_bbr"
run_case failure-restore-module-load-fail enable success
[[ "$(<"$WORK/failure-restore-module-load-fail/rc")" == 0 ]]
rm -f -- \
  "$WORK/failure-restore-module-load-fail/kernel/modules/tcp_bbr"
snapshot_managed_case failure-restore-module-load-fail
run_case \
  failure-restore-module-load-fail restore restore-module-load-fail
[[ "$(<"$WORK/failure-restore-module-load-fail/rc")" != 0 ]]
assert_managed_restored failure-restore-module-load-fail

printf '[面板 BBR] 恢复回滚失败同样保留 root-only 快照……\n'
prepare_managed_case restore-rollback-fail
run_case restore-rollback-fail restore restore-rollback-state-fail
[[ "$(<"$WORK/restore-rollback-fail/rc")" != 0 ]]
backup_path="$(
  find "$WORK/restore-rollback-fail/tmp" -mindepth 1 -maxdepth 1 \
    -type d -name 'neko-bbr-backup.*' -print -quit
)"
[[ -n "$backup_path" ]]
[[ "$(stat -c '%a' "$backup_path")" == 700 ]]
cmp -s \
  "$WORK/restore-rollback-fail/managed.state.json" \
  "$backup_path/state.json"

printf '[面板 BBR] 旧版 managed 状态缺少模块元数据时仍安全恢复……\n'
prepare_case legacy-managed
jq '
  .bbr = {
    managed: true,
    previous_qdisc: "fq_codel",
    previous_congestion_control: "cubic"
  }
' "$WORK/legacy-managed/etc/state.json" \
  > "$WORK/legacy-managed/etc/state.new"
mv "$WORK/legacy-managed/etc/state.new" \
  "$WORK/legacy-managed/etc/state.json"
chmod 0600 "$WORK/legacy-managed/etc/state.json"
printf '%s\n' \
  '# Managed by Neko. Removed, and previous live values restored, on uninstall.' \
  'net.core.default_qdisc = fq' \
  'net.ipv4.tcp_congestion_control = bbr' \
  > "$WORK/legacy-managed/sysctl.d/99-neko-bbr.conf"
chmod 0644 "$WORK/legacy-managed/sysctl.d/99-neko-bbr.conf"
printf 'fq\n' > "$WORK/legacy-managed/kernel/qdisc"
printf 'bbr\n' > "$WORK/legacy-managed/kernel/cc"
printf 'reno cubic bbr\n' > "$WORK/legacy-managed/kernel/available"
: > "$WORK/legacy-managed/kernel/modules/tcp_bbr"
: > "$WORK/legacy-managed/kernel/modules/sch_fq"
run_case legacy-managed restore success
[[ "$(<"$WORK/legacy-managed/rc")" == 0 ]]
jq -e '.bbr.managed == false' \
  "$WORK/legacy-managed/etc/state.json" >/dev/null
[[ "$(<"$WORK/legacy-managed/kernel/qdisc")" == fq_codel ]]
[[ "$(<"$WORK/legacy-managed/kernel/cc")" == cubic ]]
[[ -e "$WORK/legacy-managed/kernel/modules/tcp_bbr" ]]
[[ -e "$WORK/legacy-managed/kernel/modules/sch_fq" ]]
[[ ! -e "$WORK/legacy-managed/sysctl.d/99-neko-bbr.conf" ]]

printf '[面板 BBR] managed 文件被用户替换时恢复拒绝删除……\n'
prepare_managed_case restore-user-file
printf 'net.core.default_qdisc = fq_codel\n' \
  > "$WORK/restore-user-file/sysctl.d/99-neko-bbr.conf"
cp -a -- \
  "$WORK/restore-user-file/sysctl.d/99-neko-bbr.conf" \
  "$WORK/restore-user-file/user.sysctl"
run_case restore-user-file restore success
[[ "$(<"$WORK/restore-user-file/rc")" != 0 ]]
cmp -s \
  "$WORK/restore-user-file/user.sysctl" \
  "$WORK/restore-user-file/sysctl.d/99-neko-bbr.conf"
cmp -s \
  "$WORK/restore-user-file/managed.state.json" \
  "$WORK/restore-user-file/etc/state.json"
[[ "$(call_count restore-user-file remove-sysctl)" == 0 ]]

printf '控制面板 BBR 启用与恢复全量事务测试通过。\n'
