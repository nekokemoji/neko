#!/usr/bin/env bash

# Panel mutation, systemd, and family transaction contracts.
# This file is sourced by tests/run.sh so the suites keep one shared fixture.
# shellcheck disable=SC2154
[[ "${NEKO_TEST_SUITE_CONTEXT:-}" == 1 ]] || {
  printf '请通过 tests/run.sh 运行测试套件。\n' >&2
  exit 1
}

printf '[8/10] 模拟订阅令牌轮换，并检查 systemd 安全关键项……\n'
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
# Unit sandbox/capability declarations are static security boundaries enforced
# by systemd itself. Keep these narrow scans in addition to VM unit parsing.
grep -Fq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$ROOT/systemd/neko-sing-box.service"
grep -Fq 'AmbientCapabilities=CAP_NET_ADMIN' "$ROOT/systemd/neko-hysteria.service"
grep -Fq 'ExecStart=/usr/local/libexec/neko/hysteria-dual.sh' "$ROOT/systemd/neko-hysteria.service"
grep -Fq 'ReadWritePaths=/var/lib/neko' "$ROOT/systemd/neko-renew.service"
bash "$ROOT/tests/maintenance-lock.sh"
bash "$ROOT/tests/panel-refresh.sh"
bash "$ROOT/tests/panel-credentials.sh"

PREFLIGHT_LOG="$WORK/install-preflight.log"
set +e
NEKO_TEST_PREFLIGHT_LOG="$PREFLIGHT_LOG" bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  parse_args() { :; }
  require_root() { :; }
  detect_platform() { :; }
  require_systemd() { :; }
  collect_network_mode() { printf "network\n" >> "$NEKO_TEST_PREFLIGHT_LOG"; }
  install_dependencies() { printf "dependencies\n" >> "$NEKO_TEST_PREFLIGHT_LOG"; }
  require_commands() { :; }
  collect_identity() {
    printf "identity\n" >> "$NEKO_TEST_PREFLIGHT_LOG"
    return 73
  }
  main
' _ "$ROOT/install.sh" >/dev/null 2>&1
preflight_rc=$?
set -e
(( preflight_rc == 73 ))
[[ "$(<"$PREFLIGHT_LOG")" == $'network\ndependencies\nidentity' ]]

UNINSTALL_WORK="$WORK/panel-uninstall"
mkdir -p "$UNINSTALL_WORK/var"
jq '.system_user_created = false' "$ROOT/tests/fixtures/state.json" \
  > "$UNINSTALL_WORK/state.json"
: > "$UNINSTALL_WORK/actions.log"
printf 'UNINSTALL\n' \
  | NEKO_ETC="$UNINSTALL_WORK" NEKO_VAR="$UNINSTALL_WORK/var" \
    NEKO_STATE="$UNINSTALL_WORK/state.json" NEKO_LIBEXEC="$ROOT" \
    NEKO_TEST_UNINSTALL_LOG="$UNINSTALL_WORK/actions.log" \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      acquire_maintenance_lock() { printf "lock\n" >> "$NEKO_TEST_UNINSTALL_LOG"; }
      systemctl() {
        printf "systemctl:%s\n" "$*" >> "$NEKO_TEST_UNINSTALL_LOG"
        [[ "${1:-}" != is-active ]]
      }
      remove_firewall() { printf "remove-firewall\n" >> "$NEKO_TEST_UNINSTALL_LOG"; }
      restore_bbr() { printf "restore-bbr\n" >> "$NEKO_TEST_UNINSTALL_LOG"; }
      remove_uninstall_files() { printf "remove-files\n" >> "$NEKO_TEST_UNINSTALL_LOG"; }
      uninstall_neko
    ' _ "$ROOT/runtime/panel.sh" >/dev/null
mapfile -t uninstall_actions < "$UNINSTALL_WORK/actions.log"
[[ "${uninstall_actions[0]}" == lock ]]
[[ "${uninstall_actions[1]}" \
  == 'systemctl:disable --now neko-renew.timer' ]]
[[ "${uninstall_actions[2]}" == 'systemctl:stop neko-renew.service' ]]
[[ " ${uninstall_actions[*]} " \
  == *' systemctl:stop neko-hysteria.service neko-xray.service neko-sing-box.service neko-caddy.service '* ]]
[[ " ${uninstall_actions[*]} " == *' remove-firewall restore-bbr remove-files '* ]]

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

printf '[9/10] IPv4-only、IPv6-only 与面板地址族事务……\n'
bash "$ROOT/tests/render-golden.sh"
bash "$ROOT/tests/family-modes.sh"
