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

diagnostic_output="$(
  NEKO_LIBEXEC="$ROOT" NEKO_DIAG_TEST_WORK="$WORK" bash -c '
    set -Eeuo pipefail
    source "$1"
    [[ "$NEKO_DIAG_PACKET_LOSS_COUNT" == 100 ]]
    [[ "$NEKO_DIAG_TCP_CONNECT_COUNT" == 100 ]]

    packet_file="$NEKO_DIAG_TEST_WORK/packet-loss.log"
    for ((sample = 1; sample <= 95; sample++)); do
      printf "64 bytes from target: icmp_seq=%d ttl=48 time=%d.0 ms\n" \
        "$sample" "$sample" >> "$packet_file"
    done
    printf "100 packets transmitted, 95 received, 5%% packet loss\n" \
      >> "$packet_file"
    [[ "$(packet_loss_sample "$packet_file")" \
      == $'"'"'complete\t5%（95/100）'"'"' ]]
    [[ "$(packet_latency_metrics "$packet_file")" \
      == $'"'"'1.00\t48.00\t48.00\t91.00\t95.00\t27.42\t95'"'"' ]]

    tcp_file="$NEKO_DIAG_TEST_WORK/tcp.log"
    for ((sample = 1; sample <= 90; sample++)); do
      printf "ok\t%d.0\n" "$sample" >> "$tcp_file"
    done
    for ((sample = 1; sample <= 10; sample++)); do
      printf "fail\t28\n" >> "$tcp_file"
    done
    [[ "$(tcp_connection_sample "$tcp_file")" \
      == $'"'"'complete\t90%（90/100）'"'"' ]]
    [[ "$(tcp_latency_metrics "$tcp_file")" == $'"'"'45.50\t86.00\t90'"'"' ]]

    cat > "$NEKO_DIAG_TEST_WORK/trace.json" <<'"'"'JSON'"'"'
{"Hops":[
  [{"Success":true,"Geo":{"asnumber":"AS4809"}}],
  [{"Success":true,"Geo":{"asnumber":"4134"}}],
  [{"Success":true,"Geo":{"asnumber":"AS4809"}}]
]}
JSON
    printf "target.example\ticmp\t0\t1\t1\n" \
      > "$NEKO_DIAG_TEST_WORK/selection.log"
    show_carrier_route_result gd ipv4 ct 电信 \
      "$NEKO_DIAG_TEST_WORK/trace.json" "$packet_file" "$tcp_file" \
      "$NEKO_DIAG_TEST_WORK/selection.log"
    show_route_report_summary
  ' _ "$ROOT/runtime/route-diagnostics.sh"
)"
[[ "$diagnostic_output" == *'P95 延迟：91.00 ms'* ]]
[[ "$diagnostic_output" == *'ASN 路径：AS4809 → AS4134'* ]]
[[ "$diagnostic_output" == *'ICMP 每组固定发送 100 包；不回应 ICMP 时改测 100 次 TCP 连接。'* ]]
[[ "$diagnostic_output" == *'TCP 显示的是连接成功率，不冒充网络层丢包率。'* ]]

# Retired broad diagnostics are a negative safety boundary: merely hiding them
# from the menu would still ship mutating benchmark/IP-quality code. Keep this
# narrow source scan until a sandbox can prove the payload is absent.
if grep -Eq 'show_system_report|show_ip_quality|show_routing_registration|run_cpu_benchmark|run_disk_benchmark' \
    "$ROOT/runtime/route-diagnostics.sh"; then
  printf '精简线路组件不应包含旧版硬件、IP 质量或基准测试。\n' >&2
  exit 1
fi

printf '六地顺序、三网线路、100 次 ICMP/TCP 降级与精简边界测试通过。\n'
