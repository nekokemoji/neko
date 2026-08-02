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

[[ "$panel_output" == *'8. 订阅链接怎么选？首次使用建议查看'* ]]
[[ "$panel_output" == *'4 种线路方向 × 4 种客户端格式 = 16 条订阅链接'* ]]
[[ "$panel_output" == *'你的设备 → VPS，这一段叫作入站。'* ]]
[[ "$panel_output" == *'这里并不是把 IPv6“转换”成 IPv4'* ]]
[[ "$panel_output" == *'IPv4→IPv4 切换为 IPv4→IPv6'* ]]
[[ "$panel_output" == *'左边决定你怎么连接 VPS，右边决定 VPS 怎么连接网站'* ]]
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
