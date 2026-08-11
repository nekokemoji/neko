#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-route-diagnostics.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

bash -n "$ROOT/runtime/route-diagnostics.sh"
help_output="$(NEKO_LIBEXEC="$ROOT" bash "$ROOT/runtime/route-diagnostics.sh" --help)"
[[ "$help_output" == *'gd|sh|bj|sc|hb|ln|all'* ]]

mapping="$(
  NEKO_LIBEXEC="$ROOT" bash -c '
    source "$1"
    for value in 1 2 3 4 5 6 7; do
      printf "%s:%s\\n" "$value" "$(normalize_route_region "$value")"
    done
  ' _ "$ROOT/runtime/route-diagnostics.sh"
)"
[[ "$mapping" == $'1:gd\n2:sh\n3:bj\n4:sc\n5:hb\n6:ln\n7:all' ]]

menu_output="$(
  printf '5\nROUTE\n\n0\n' \
    | NEKO_LIBEXEC="$ROOT" TERM=dumb ROUTE_LOG="$WORK/routes.log" \
      bash -c '
        source "$1"
        show_route_report() { printf "%s\\n" "$1" >> "$ROUTE_LOG"; }
        run_route_menu
      ' _ "$ROOT/runtime/route-diagnostics.sh" 2>&1
)"
[[ "$menu_output" == *'1. 广东'* ]]
[[ "$menu_output" == *'5. 湖北'* ]]
[[ "$menu_output" == *'6. 辽宁'* ]]
[[ "$menu_output" == *'7. 全部地区（六地）'* ]]
grep -Fxq 'hb' "$WORK/routes.log"

grep -Fq 'NEKO_DIAG_PACKET_LOSS_COUNT=100' "$ROOT/runtime/route-diagnostics.sh"
grep -Fq 'NEKO_DIAG_TCP_CONNECT_COUNT=100' "$ROOT/runtime/route-diagnostics.sh"
grep -Fq 'P95' "$ROOT/runtime/route-diagnostics.sh"
grep -Fq 'ASN 路径' "$ROOT/runtime/route-diagnostics.sh"
grep -Fq 'TCP 显示的是连接成功率，不冒充网络层丢包率' \
  "$ROOT/runtime/route-diagnostics.sh"
if grep -Eq 'show_system_report|show_ip_quality|show_routing_registration|run_cpu_benchmark|run_disk_benchmark' \
    "$ROOT/runtime/route-diagnostics.sh"; then
  printf '精简线路组件不应包含旧版硬件、IP 质量或基准测试。\n' >&2
  exit 1
fi

printf '六地顺序、三网线路、100 次 ICMP/TCP 降级与精简边界测试通过。\n'
