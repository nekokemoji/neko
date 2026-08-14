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
grep -Fq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$ROOT/systemd/neko-sing-box.service"
grep -Fq 'AmbientCapabilities=CAP_NET_ADMIN' "$ROOT/systemd/neko-hysteria.service"
grep -Fq 'ExecStart=/usr/local/libexec/neko/hysteria-dual.sh' "$ROOT/systemd/neko-hysteria.service"
grep -Fq 'wait -n "${pids[@]}"' "$ROOT/runtime/hysteria-dual.sh"
grep -Fq 'ReadWritePaths=/var/lib/neko' "$ROOT/systemd/neko-renew.service"
grep -Fq 'systemctl stop neko-renew.service' "$ROOT/runtime/panel.sh"
grep -Fq 'restart_runtime_services' "$ROOT/runtime/panel.sh"
bash "$ROOT/tests/maintenance-lock.sh"
bash "$ROOT/tests/panel-refresh.sh"
bash "$ROOT/tests/panel-credentials.sh"

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

mode_gate_line="$(grep -n 'collect_network_mode' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
domain_gate_line="$(grep -n 'collect_identity' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
dependency_line="$(grep -n 'install_dependencies' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
lock_line="$(grep -n 'exec 9>/run/lock/neko-install.lock' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
(( mode_gate_line < dependency_line
  && dependency_line < domain_gate_line
  && domain_gate_line < lock_line ))

printf '[9/10] IPv4-only、IPv6-only 与面板地址族事务……\n'
bash "$ROOT/tests/render-golden.sh"
bash "$ROOT/tests/family-modes.sh"
