#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "$ROOT/tests/panel-route-guide.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

cp -a -- "$ROOT/tests/fixtures/state.json" "$WORK/state.json"
state_before="$(sha256sum "$WORK/state.json")"

panel_output="$(
  printf '\n' \
    | NEKO_ETC="$WORK" \
      NEKO_STATE="$WORK/state.json" \
      NEKO_LIBEXEC="$ROOT" \
      TERM=dumb \
      bash -c 'source "$1"; draw_menu; show_route_guide; draw_menu' \
        _ "$ROOT/runtime/panel.sh" 2>&1
)"

[[ "$panel_output" == *'8. 订阅链接太多不知道怎么选？小白建议先看'* ]]
[[ "$panel_output" == *'入站是“你的设备到 VPS”这一段'* ]]
[[ "$panel_output" == *'IPv6→IPv4 = 你的设备通过 IPv6 连接 VPS'* ]]
[[ "$panel_output" == *'IPv4→IPv4  改为  IPv6→IPv4'* ]]
[[ "$panel_output" == *'IPv4→IPv4  改为  IPv4→IPv6'* ]]
[[ "$panel_output" == *'左边决定怎么连接 VPS，右边决定 VPS 怎么连接网站'* ]]
[[ "$(sha256sum "$WORK/state.json")" == "$state_before" ]]

eof_output="$(
  NEKO_LIBEXEC="$ROOT" TERM=dumb \
    bash -c 'source "$1"; show_route_guide </dev/null; printf "guide-returned\n"' \
      _ "$ROOT/runtime/panel.sh" 2>&1
)"
[[ "$eof_output" == *'guide-returned'* ]]

grep -Fq 'read -r -p "请选择 [0-8]：" choice' "$ROOT/runtime/panel.sh"
grep -Fq '*) warn "请输入 0 到 8。" ;;' "$ROOT/runtime/panel.sh"
grep -A2 -F '8)' "$ROOT/runtime/panel.sh" | grep -Fq 'show_route_guide'
grep -Fq '在 `neko` 面板选择 `8`' "$ROOT/README.md"

printf '面板第 8 项：入站、出站与四种线路说明测试通过。\n'
