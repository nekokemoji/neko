#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-panel-route-guide.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

cp -a -- "$ROOT/tests/fixtures/state.json" "$WORK/state.json"
state_before="$(sha256sum "$WORK/state.json")"

run_case() {
  local blocked="$1" sent="$2"
  printf '1\n%s\n%s\n\n' "$blocked" "$sent" \
    | NEKO_ETC="$WORK" \
      NEKO_STATE="$WORK/state.json" \
      NEKO_LIBEXEC="$ROOT" \
      TERM=dumb \
      bash -c '
        source "$1"
        show_terminal_qr() { printf "QR:%s\\n" "$1"; }
        show_route_guide
      ' _ "$ROOT/runtime/panel.sh" 2>&1
}

panel_output="$(run_case 1 1)"
[[ "$panel_output" == *'什么是 IP 被墙、IP“送中”，以及如何解决？'* ]]
[[ "$panel_output" == *'itdog.cn'* ]]
[[ "$panel_output" == *'被墙换左边，送中换右边。'* ]]
[[ "$panel_output" == *'1. Shadowrocket'* ]]
[[ "$panel_output" == *'哪个入口 IP 被墙？'* ]]
[[ "$panel_output" == *'哪个出口 IP 被“送中”？'* ]]
[[ "$panel_output" == *'推荐：IPv6→IPv6'* ]]
[[ "$panel_output" == *'备用：IPv6→IPv4'* ]]
[[ "$panel_output" == *'送中”，但不代表完全不可以使用'* ]]
[[ "$panel_output" == *'https://example.com/test-subscription-token/v6/shadowrocket.txt'* ]]
[[ "$panel_output" == *'https://example.com/test-v6-to-v4-token/v6-to-v4/shadowrocket.txt'* ]]
[[ "$(grep -c '^QR:https://' <<< "$panel_output")" == 2 ]]
[[ "$(sha256sum "$WORK/state.json")" == "$state_before" ]]

for spec in \
  '1 2 推荐：IPv6→IPv4 备用：IPv6→IPv6' \
  '2 1 推荐：IPv4→IPv6 备用：IPv4→IPv4' \
  '2 2 推荐：IPv4→IPv4 备用：IPv4→IPv6'; do
  read -r blocked sent recommended backup <<< "$spec"
  output="$(run_case "$blocked" "$sent")"
  [[ "$output" == *"$recommended"* ]]
  [[ "$output" == *"$backup"* ]]
  [[ "$(grep -c '^QR:https://' <<< "$output")" == 2 ]]
done

menu_output="$(
  NEKO_ETC="$WORK" NEKO_STATE="$WORK/state.json" NEKO_LIBEXEC="$ROOT" TERM=dumb \
    bash -c 'source "$1"; draw_menu' _ "$ROOT/runtime/panel.sh" 2>&1
)"
[[ "$menu_output" == *'8. 双栈线路怎么选？（同时拥有 IPv4 和 IPv6 时查看）'* ]]
[[ "$menu_output" == *'9. AKDNS 智能 DNS 解锁（第三方、可选）'* ]]

run_main_menu_case() {
  local input="$1" action_log="$WORK/menu-action.log"
  local -a privilege=()
  : > "$action_log"
  chmod 0666 "$action_log"
  if (( EUID != 0 )); then
    privilege=(sudo)
  fi
  printf '%s' "$input" \
    | "${privilege[@]}" env \
      NEKO_ETC="$WORK" NEKO_STATE="$WORK/state.json" \
      NEKO_LIBEXEC="$ROOT" NEKO_TEST_PANEL_ACTION_LOG="$action_log" \
      TERM=dumb bash -c '
        set -Eeuo pipefail
        source "$1"
        draw_menu() { :; }
        show_route_guide() { printf "route-guide\n" >> "$NEKO_TEST_PANEL_ACTION_LOG"; }
        manage_akdns() { printf "akdns\n" >> "$NEKO_TEST_PANEL_ACTION_LOG"; }
        warn() { printf "warn:%s\n" "$*" >> "$NEKO_TEST_PANEL_ACTION_LOG"; }
        main
      ' _ "$ROOT/runtime/panel.sh" >/dev/null
  cat "$action_log"
}

[[ "$(run_main_menu_case $'8\n0\n')" == route-guide ]]
[[ "$(run_main_menu_case $'9\n0\n')" == akdns ]]
[[ "$(run_main_menu_case $'invalid\n\n0\n')" == 'warn:请输入 0 到 9。' ]]

printf '面板第 8 项文案、四种推荐映射、真实链接与双二维码测试通过。\n'
