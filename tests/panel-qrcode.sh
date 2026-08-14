#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-panel-qr.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/etc" "$WORK/libexec/lib"
cp -a -- "$ROOT/tests/fixtures/state.json" "$WORK/etc/state.json"
cp -a -- "$ROOT/lib/common.sh" "$ROOT/lib/state.sh" "$ROOT/lib/render.sh" \
  "$ROOT/lib/firewall.sh" "$WORK/libexec/lib/"
cp -a -- "$ROOT/runtime/panel.sh" "$WORK/libexec/panel.sh"

cat > "$WORK/fake-qrc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" > "$NEKO_QR_ARGS_LOG"
cat > "$NEKO_QR_STDIN_LOG"
printf '%s\n' \
  '    █▀▀▀▀▀█    ' \
  '    █ ███ █    ' \
  '    █ ▀▀▀ █    ' \
  '    ▀▀▀▀▀▀▀    '
EOF
chmod 0755 "$WORK/fake-qrc"

panel_output="$(
  printf '1\n\n0\n' \
    | NEKO_ETC="$WORK/etc" \
      NEKO_STATE="$WORK/etc/state.json" \
      NEKO_LIBEXEC="$WORK/libexec" \
      NEKO_QRC_BINARY="$WORK/fake-qrc" \
      NEKO_QR_ARGS_LOG="$WORK/qrc.args" \
      NEKO_QR_STDIN_LOG="$WORK/qrc.stdin" \
      NEKO_QR_TEST_MODE=1 COLUMNS=120 TERM=xterm \
      bash -c 'source "$1"; draw_menu; subscription_qr_menu' \
        _ "$WORK/libexec/panel.sh" 2>&1
)"
expected_url='https://example.com/test-subscription-token/v4/mihomo.yaml'
[[ "$(< "$WORK/qrc.stdin")" == "$expected_url" ]]
grep -Fxq -- '--output-format' "$WORK/qrc.args"
grep -Fxq -- 'unicode' "$WORK/qrc.args"
grep -Fxq -- '--invert' "$WORK/qrc.args"
grep -Fxq -- '--ec-level' "$WORK/qrc.args"
grep -Fxq -- 'M' "$WORK/qrc.args"
grep -Fxq -- '--scale' "$WORK/qrc.args"
grep -Fxq -- '1' "$WORK/qrc.args"
grep -Fxq -- '--border' "$WORK/qrc.args"
grep -Fxq -- '4' "$WORK/qrc.args"
if grep -Fq 'https://' "$WORK/qrc.args"; then
  printf '订阅链接被放进了 qrc 命令参数。\n' >&2
  exit 1
fi
[[ "$panel_output" == *'查看当前严格订阅链接与二维码'* ]]
[[ "$panel_output" == *'16. sing-box IPv6 → IPv4（严格）'* ]]
[[ "$panel_output" == *"$expected_url"* ]]
[[ "$panel_output" == *'二维码等同于订阅密码'* ]]

for mode in ipv4-only ipv6-only; do
  if [[ "$mode" == ipv4-only ]]; then
    installed_family=IPv4
    missing_family=IPv6
  else
    installed_family=IPv6
    missing_family=IPv4
  fi
  jq --arg mode "$mode" '
    .network.mode = $mode
    | if $mode == "ipv4-only" then
        .subscription.ipv6_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv6_domain = null
        | .subscription.ipv6_address = null
        | .ports.cross = null
      else
        .subscription.ipv4_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv4_domain = null
        | .subscription.ipv4_address = null
        | .ports.cross = null
      end
  ' "$ROOT/tests/fixtures/state.json" > "$WORK/etc/state-${mode}.json"
  single_output="$(
    printf '0\n' \
      | NEKO_ETC="$WORK/etc" \
        NEKO_STATE="$WORK/etc/state-${mode}.json" \
        NEKO_LIBEXEC="$WORK/libexec" \
        NEKO_QRC_BINARY="$WORK/fake-qrc" \
        NEKO_QR_TEST_MODE=1 COLUMNS=120 TERM=xterm \
        bash -c 'source "$1"; subscription_qr_menu' \
          _ "$WORK/libexec/panel.sh" 2>&1
  )"
  [[ "$single_output" == *"4. sing-box ${installed_family} → ${installed_family}（严格）"* ]]
  [[ "$single_output" != *"Mihomo ${missing_family} → ${missing_family}（严格）"* ]]
done

missing_output="$(
  NEKO_LIBEXEC="$WORK/libexec" \
    NEKO_QRC_BINARY="$WORK/not-installed" \
    NEKO_QR_TEST_MODE=1 COLUMNS=120 \
    bash -c 'source "$1"; show_terminal_qr "$2"; printf "continued\n"' \
    _ "$ROOT/lib/common.sh" "$expected_url" 2>&1
)"
[[ "$missing_output" == *'二维码组件不可用'* ]]
[[ "$missing_output" == *'continued'* ]]

cat > "$WORK/failing-qrc" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 9
EOF
chmod 0755 "$WORK/failing-qrc"
failure_output="$(
  NEKO_LIBEXEC="$WORK/libexec" \
    NEKO_QRC_BINARY="$WORK/failing-qrc" \
    NEKO_QR_TEST_MODE=1 COLUMNS=120 \
    bash -c 'source "$1"; show_terminal_qr "$2"; printf "continued\n"' \
    _ "$ROOT/lib/common.sh" "$expected_url" 2>&1
)"
[[ "$failure_output" == *'二维码生成失败'* ]]
[[ "$failure_output" == *'continued'* ]]

cat > "$WORK/wide-qrc" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
for ((column = 0; column < 100; column++)); do
  printf '█'
done
printf '\n'
EOF
chmod 0755 "$WORK/wide-qrc"
width_output="$(
  NEKO_LIBEXEC="$WORK/libexec" \
    NEKO_QRC_BINARY="$WORK/wide-qrc" \
    NEKO_QR_TEST_MODE=1 COLUMNS=20 \
    bash -c 'source "$1"; show_terminal_qr "$2"; printf "continued\n"' \
    _ "$ROOT/lib/common.sh" "$expected_url" 2>&1
)"
[[ "$width_output" == *'二维码需要 100 列'* ]]
[[ "$width_output" == *'continued'* ]]

non_tty_output="$(
  NEKO_LIBEXEC="$WORK/libexec" \
    NEKO_QRC_BINARY="$WORK/fake-qrc" TERM=xterm \
    bash -c 'source "$1"; show_terminal_qr "$2"; printf "continued\n"' \
    _ "$ROOT/lib/common.sh" "$expected_url" 2>&1
)"
[[ "$non_tty_output" == *'当前输出不是可显示二维码的交互终端'* ]]
[[ "$non_tty_output" == *'continued'* ]]

qr_width="$(
  LC_ALL=C bash -c 'source "$1"; unicode_qr_width "$2"' \
    _ "$ROOT/lib/common.sh" '█▀▄  '
)"
[[ "$qr_width" == 5 ]]
