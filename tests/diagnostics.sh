#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "$ROOT/tests/diagnostics.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p \
  "$WORK/bin" \
  "$WORK/etc" \
  "$WORK/var/lego/certificates" \
  "$WORK/libexec/lib" \
  "$WORK/bench"
cp -a -- "$ROOT/lib/common.sh" "$WORK/libexec/lib/common.sh"
jq \
  '.release = "1.6.0-test"
   | .subscription.ipv4_address = "192.0.2.44"
   | .subscription.ipv6_address = "2001:db8::44"' \
  "$ROOT/tests/fixtures/state.json" > "$WORK/etc/state.json"
chmod 0600 "$WORK/etc/state.json"
printf 'nameserver 192.0.2.53\nnameserver 2001:db8::53\n' \
  > "$WORK/resolv.conf"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj '/CN=example.com' \
  -addext 'subjectAltName=DNS:example.com,DNS:v4.example.com,DNS:v6.example.com' \
  -keyout "$WORK/var/lego/certificates/example.com.key" \
  -out "$WORK/var/lego/certificates/example.com.crt" \
  >/dev/null 2>&1

cat > "$WORK/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == is-active ]]; then
  printf 'active\n'
  exit 0
fi
exit 1
EOF

cat > "$WORK/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  '-4 route show default')
    printf 'default via 192.0.2.1 dev eth0\n'
    ;;
  '-6 route show default')
    printf 'default via 2001:db8::1 dev eth1\n'
    ;;
  '-4 -o address show to 192.0.2.44/32')
    printf '2: eth0 inet 192.0.2.44/24 scope global eth0\n'
    ;;
  '-6 -o address show to 2001:db8::44/128')
    printf '3: eth1 inet6 2001:db8::44/64 scope global\n'
    ;;
  '-4 route get 1.1.1.1 from 192.0.2.44')
    printf '1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.44\n'
    ;;
  '-6 route get 2606:4700:4700::1111 from 2001:db8::44')
    printf '2606:4700:4700::1111 via 2001:db8::1 dev eth1 src 2001:db8::44\n'
    ;;
  '-o link show dev eth0')
    printf '2: eth0: <UP> mtu 1500 qdisc fq state UP mode DEFAULT\n'
    ;;
  '-o link show dev eth1')
    printf '3: eth1: <UP> mtu 1500 qdisc fq state UP mode DEFAULT\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat > "$WORK/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ " $* " == *' -x '* ]]; then
  printf 'ptr.example.net.\n'
  exit 0
fi
name="${@: -2:1}"
record_type="${@: -1}"
printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
case "${record_type}:${name}" in
  A:example.com.|A:v4.example.com.)
    printf '%s 60 IN A 192.0.2.44\n' "$name"
    ;;
  AAAA:example.com.|AAAA:v6.example.com.)
    printf '%s 60 IN AAAA 2001:db8::44\n' "$name"
    ;;
esac
EOF

cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${NEKO_DIAG_CURL_FAIL:-0}" != 1 ]] || exit 28
family=ipv4
[[ " $* " == *' --ipv6 '* ]] && family=ipv6
if [[ -n "${NEKO_DIAG_CURL_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$NEKO_DIAG_CURL_ARGS_LOG"
fi
case "$*" in
  *'api.ipapi.is'*)
    if [[ "$family" == ipv4 ]]; then
      printf '%s\n' \
        '{"ip":"192.0.2.44","is_datacenter":true,"is_proxy":false,"is_vpn":false,"is_tor":false,"is_abuser":false,"company":{"type":"hosting","name":"TEST-HOST-V4"},"asn":{"asn":64500,"org":"TEST-AS-V4"},"location":{"country_code":"HK","city":"Hong Kong"}}'
    else
      printf '%s\n' \
        '{"ip":"2001:db8::44","is_datacenter":true,"is_proxy":false,"is_vpn":false,"is_tor":false,"is_abuser":false,"company":{"type":"hosting","name":"TEST-HOST-V6"},"asn":{"asn":64501,"org":"TEST-AS-V6"},"location":{"country_code":"HK","city":"Hong Kong"}}'
    fi
    ;;
  *'proxycheck.io/v3/'*)
    [[ "${NEKO_DIAG_QUALITY_PARTIAL:-0}" != 1 ]] || exit 28
    if [[ "$family" == ipv4 ]]; then
      printf '%s\n' \
        '{"status":"ok","192.0.2.44":{"network":{"asn":"AS64500","organisation":"TEST-PROXYCHECK-V4","type":"Hosting"},"location":{"country_code":"HK","city_name":"Hong Kong"},"detections":{"proxy":false,"vpn":false,"tor":false,"compromised":false,"scraper":false,"hosting":true,"anonymous":false,"risk":10}}}'
    else
      printf '%s\n' \
        '{"status":"ok","2001:db8::44":{"network":{"asn":"AS64501","organisation":"TEST-PROXYCHECK-V6","type":"Hosting"},"location":{"country_code":"HK","city_name":"Hong Kong"},"detections":{"proxy":false,"vpn":false,"tor":false,"compromised":false,"scraper":false,"hosting":true,"anonymous":false,"risk":10}}}'
    fi
    ;;
  *'ipwho.is/'*)
    if [[ "$family" == ipv4 ]]; then
      printf '%s\n' \
        '{"success":true,"ip":"192.0.2.44","country_code":"HK","city":"Hong Kong","connection":{"asn":64500,"org":"TEST-IPWHO-V4"}}'
    else
      printf '%s\n' \
        '{"success":true,"ip":"2001:db8::44","country_code":"HK","city":"Hong Kong","connection":{"asn":64501,"org":"TEST-IPWHO-V6"}}'
    fi
    ;;
  *'api.ipquery.io/'*)
    if [[ "${NEKO_DIAG_IPQUERY_MALFORMED:-0}" == 1 ]]; then
      printf '%s\n' \
        '{"ip":"198.51.100.99","risk":{"is_datacenter":true}}'
    elif [[ "$family" == ipv4 ]]; then
      printf '%s\n' \
        '{"ip":"192.0.2.44","isp":{"asn":"AS64500","org":"TEST-IPQUERY-V4"},"location":{"country_code":"HK","city":"Hong Kong"},"risk":{"is_mobile":false,"is_vpn":false,"is_tor":false,"is_proxy":false,"is_datacenter":true,"risk_score":8}}'
    else
      printf '%s\n' \
        '{"ip":"2001:db8::44","isp":{"asn":"AS64501","org":"TEST-IPQUERY-V6"},"location":{"country_code":"HK","city":"Hong Kong"},"risk":{"is_mobile":false,"is_vpn":false,"is_tor":false,"is_proxy":false,"is_datacenter":true,"risk_score":8}}'
    fi
    ;;
  *'/network-info/data.json'*)
    if [[ "$family" == ipv4 ]]; then
      printf '{"status":"ok","data":{"prefix":"192.0.2.0/24","asns":[64500]}}\n'
    else
      printf '{"status":"ok","data":{"prefix":"2001:db8::/32","asns":[64501]}}\n'
    fi
    ;;
  *'/prefix-overview/data.json'*)
    if [[ "$family" == ipv4 ]]; then
      printf '{"status":"ok","data":{"announced":true,"asns":[{"asn":64500,"holder":"TEST-V4"}]}}\n'
    else
      printf '{"status":"ok","data":{"announced":true,"asns":[{"asn":64501,"holder":"TEST-V6"}]}}\n'
    fi
    ;;
  *'/rpki-validation/data.json'*)
    printf '{"status":"ok","data":{"status":"valid"}}\n'
    ;;
  *'/whois/data.json'*)
    [[ "${NEKO_DIAG_WHOIS_FAIL:-0}" != 1 ]] || exit 28
    if [[ "$family" == ipv4 ]]; then
      printf '%s\n' \
        '{"status":"ok","data":{"authorities":["test-rir"],"records":[[{"key":"netname","value":"TEST-NET-V4"},{"key":"country","value":"HK"},{"key":"source","value":"TEST-RIR"}]]}}'
    else
      printf '%s\n' \
        '{"status":"ok","data":{"authorities":["test-rir"],"records":[[{"key":"netname","value":"TEST-NET-V6"},{"key":"country","value":"HK"},{"key":"source","value":"TEST-RIR"}]]}}'
    fi
    ;;
  *'/cdn-cgi/trace'*)
    if [[ "$family" == ipv4 ]]; then
      printf 'ip=192.0.2.44\nloc=HK\ncolo=HKG\n'
    else
      printf 'ip=2001:db8::44\nloc=HK\ncolo=HKG\n'
    fi
    printf '__NEKO_CONNECT__=0.020\n__NEKO_FIRST_BYTE__=0.040\n'
    ;;
  *)
    exit 22
    ;;
esac
EOF

cat > "$WORK/libexec/nexttrace-tiny" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'NextTrace v1.7.1 test\n'
  exit 0
fi
[[ "${NEKO_DIAG_ROUTE_FAIL:-0}" != 1 ]] || exit 124
if [[ -n "${NEKO_DIAG_ROUTE_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$NEKO_DIAG_ROUTE_ARGS_LOG"
fi
asn=64500
case "${*: -1}" in
  *-ct-*) asn=4809 ;;
  *-cu-*) asn=9929 ;;
  *-cm-*) asn=58453 ;;
esac
printf '%s\n' \
  '{"Hops":[[{"Success":true,"Address":{"IP":"198.51.100.1"},"TTL":1,"RTT":20000000,"Geo":{"ip":"198.51.100.1","asnumber":"64500"}}],[{"Success":true,"Address":{"IP":"203.0.113.9"},"TTL":2,"RTT":30000000,"Geo":{"ip":"203.0.113.9","asnumber":"'"$asn"'"}}]]}'
EOF

chmod 0755 "$WORK/bin/systemctl" "$WORK/bin/ip" "$WORK/bin/dig" "$WORK/bin/curl"
chmod 0755 "$WORK/libexec/nexttrace-tiny"

common_env=(
  "PATH=$WORK/bin:$PATH"
  "NEKO_ETC=$WORK/etc"
  "NEKO_VAR=$WORK/var"
  "NEKO_LIBEXEC=$WORK/libexec"
  "NEKO_STATE=$WORK/etc/state.json"
  "NEKO_DIAG_RESOLV_CONF=$WORK/resolv.conf"
  "NEKO_DIAG_DNS_TIMEOUT=3"
  "NEKO_DIAG_NETWORK_TIMEOUT=2"
  "NEKO_DIAG_TMP_DIR=$WORK/bench"
  "NEKO_DIAG_CURL_ARGS_LOG=$WORK/curl-args.log"
  "NEKO_DIAG_ROUTE_ARGS_LOG=$WORK/route-args.log"
)

system_output="$(
  env "${common_env[@]}" bash "$ROOT/runtime/diagnostics.sh" --system
)"
grep -Fq '系统与硬件（只读）' <<< "$system_output"
grep -Fq 'CPU' <<< "$system_output"
grep -Fq '根文件系统' <<< "$system_output"

neko_output="$(
  env "${common_env[@]}" bash "$ROOT/runtime/diagnostics.sh" --neko
)"
grep -Fq 'Neko 版本' <<< "$neko_output"
grep -Fq 'neko-caddy 正在运行' <<< "$neko_output"
grep -Fq '证书覆盖全部已安装域名' <<< "$neko_output"

network_output="$(
  env "${common_env[@]}" bash "$ROOT/runtime/diagnostics.sh" --network
)"
grep -Fq '基础域名与已安装专用域名仍符合严格 DNS 规则' <<< "$network_output"
grep -Fq 'IPv4 公网出口：' <<< "$network_output"
grep -Fq '192.0.2.44' <<< "$network_output"
grep -Fq 'IPv6 公网出口：' <<< "$network_output"
grep -Fq '2001:db8::44' <<< "$network_output"
grep -Fq 'AS64500' <<< "$network_output"
grep -Fq 'AS64501' <<< "$network_output"
grep -Fq 'RPKI ROA 匹配' <<< "$network_output"
grep -Fq '小白结论 · 类型： 数据中心/托管 IP（3/3 个来源一致）' \
  <<< "$network_output"
grep -Fq '小白结论 · 位置： HK（4/4 个来源一致）' \
  <<< "$network_output"
grep -Fq '当前未见明显代理/VPN/Tor/滥用标签' <<< "$network_output"
grep -Fq '没有统一权威标准；不把单一数据库标签冒充原生结论' \
  <<< "$network_output"
grep -Fq 'ipquery.io：' <<< "$network_output"
grep -Fq 'IPv4 RIR 登记： TEST-RIR；国家/地区 HK；登记名称 TEST-NET-V4' \
  <<< "$network_output"
grep -Fq 'IPv6 RIR 登记： TEST-RIR；国家/地区 HK；登记名称 TEST-NET-V6' \
  <<< "$network_output"
grep -Fq 'RIR 登记国家/地区是地址注册资料，不等于 VPS 机房位置' \
  <<< "$network_output"
grep -Fq 'IPv4 BGP 注册（不是实际线路）' <<< "$network_output"
grep -Fq 'IPv6 BGP 注册（不是实际线路）' <<< "$network_output"
grep -Fq -- '--ipv4 --interface 192.0.2.44' "$WORK/curl-args.log"
grep -Fq -- '--ipv6 --interface 2001:db8::44' "$WORK/curl-args.log"
grep -Fq 'api.ipquery.io/192.0.2.44' "$WORK/curl-args.log"
grep -Fq 'api.ipquery.io/2001:db8::44' "$WORK/curl-args.log"

for secret in \
  test-subscription-token \
  test-hy2-password \
  test-tuic-password \
  test-anytls-password; do
  if grep -Fq "$secret" <<< "$network_output$neko_output"; then
    printf '体检输出泄露了测试秘密：%s\n' "$secret" >&2
    exit 1
  fi
done

failed_output="$(
  env "${common_env[@]}" NEKO_DIAG_CURL_FAIL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --network
)"
grep -Fq '无法在 2 秒内完成严格来源绑定的 HTTPS 检查' \
  <<< "$failed_output"
grep -Fq 'RIPEstat 路由注册信息暂时不可用' <<< "$failed_output"
grep -Fq '风控标签数据库暂时不可用' <<< "$failed_output"
grep -Fq 'ipquery.io 数据暂时不可用' <<< "$failed_output"
grep -Fq '体检小结' <<< "$failed_output"

partial_output="$(
  env "${common_env[@]}" NEKO_DIAG_QUALITY_PARTIAL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --network
)"
grep -Fq '数据中心/托管 IP（2/2 个来源一致）' <<< "$partial_output"
grep -Fq 'proxycheck.io 数据暂时不可用' <<< "$partial_output"
grep -Fq 'ipapi.is：' <<< "$partial_output"
grep -Fq 'ipwho.is：' <<< "$partial_output"
grep -Fq 'ipquery.io：' <<< "$partial_output"

malformed_output="$(
  env "${common_env[@]}" NEKO_DIAG_IPQUERY_MALFORMED=1 \
    bash "$ROOT/runtime/diagnostics.sh" --network
)"
grep -Fq 'ipquery.io 数据暂时不可用' <<< "$malformed_output"
grep -Fq '数据中心/托管 IP（2/2 个来源一致）' <<< "$malformed_output"
grep -Fq 'HK（3/3 个来源一致）' <<< "$malformed_output"
grep -Fq '体检小结' <<< "$malformed_output"

whois_failed_output="$(
  env "${common_env[@]}" NEKO_DIAG_WHOIS_FAIL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --network
)"
grep -Fq 'RIR 地址登记资料暂时不可用' <<< "$whois_failed_output"
grep -Fq 'BGP 前缀：' <<< "$whois_failed_output"
grep -Fq 'RPKI ROA 匹配' <<< "$whois_failed_output"
grep -Fq '体检小结' <<< "$whois_failed_output"

route_output="$(
  env "${common_env[@]}" bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '测试地区：广东' <<< "$route_output"
grep -Fq '测试方向：回程（这台 VPS → 国内三网参考目标）' \
  <<< "$route_output"
grep -Fq '去程状态：未测试' <<< "$route_output"
grep -Fq '【广东 · IPv4 回程】' <<< "$route_output"
grep -Fq 'CN2（AS4809）' <<< "$route_output"
grep -Fq '联通 9929/CUII（AS9929）' <<< "$route_output"
grep -Fq '中国移动国际 CMI（AS58453）' <<< "$route_output"
grep -Fq 'IPv4 电信：30.00 ms，CN2（AS4809）' <<< "$route_output"
grep -Fq 'IPv6 移动：30.00 ms，中国移动国际 CMI（AS58453）' \
  <<< "$route_output"
grep -Fq '已完成 6 条，未完成 0 条' <<< "$route_output"
if grep -Fq '【上海 ·' <<< "$route_output"; then
  printf '默认 --routes 不应自动测试全部地区。\n' >&2
  exit 1
fi
grep -Fq -- '--ipv4 --tcp --port 80 --source 192.0.2.44' \
  "$WORK/route-args.log"
grep -Fq -- '--ipv6 --tcp --port 80 --source 2001:db8::44' \
  "$WORK/route-args.log"

: > "$WORK/route-args.log"
all_regions_output="$(
  env "${common_env[@]}" bash "$ROOT/runtime/diagnostics.sh" --routes all
)"
for region_heading in \
  '【广东 · IPv4 回程】' \
  '【上海 · IPv4 回程】' \
  '【北京 · IPv4 回程】' \
  '【四川 · IPv4 回程】'; do
  grep -Fq "$region_heading" <<< "$all_regions_output"
done
for target in \
  gd-ct-v4.ip.zstaticcdn.com \
  sh-cu-v6.ip.zstaticcdn.com \
  bj-cm-v4.ip.zstaticcdn.com \
  sc-ct-v6.ip.zstaticcdn.com; do
  grep -Fq "$target" "$WORK/route-args.log"
done
[[ "$(wc -l < "$WORK/route-args.log")" -eq 24 ]]
grep -Fq '已完成 24 条，未完成 0 条' <<< "$all_regions_output"

classification_output="$(
  env "${common_env[@]}" bash -c '
    source "$1"
    classify_carrier_route ct "AS64500 → AS4134"
    printf "\n"
    classify_carrier_route cm "AS64500 → AS58807 → AS9808"
    printf "\n"
    classify_carrier_route ct "AS64500 → AS48090"
    printf "\n"
  ' _ "$ROOT/runtime/diagnostics.sh"
)"
grep -Fxq '电信 163（AS4134）' <<< "$classification_output"
grep -Fxq '移动 CMIN2（AS58807） → 移动 CMNET（AS9808）' \
  <<< "$classification_output"
grep -Fxq '未识别常见电信骨干' <<< "$classification_output"

jq '.network.mode = "ipv4-only"' \
  "$WORK/etc/state.json" > "$WORK/etc/state-ipv4.json"
ipv4_only_route_output="$(
  env "${common_env[@]}" NEKO_STATE="$WORK/etc/state-ipv4.json" \
    bash "$ROOT/runtime/diagnostics.sh" --routes sh
)"
grep -Fq '【上海 · IPv4 回程】' <<< "$ipv4_only_route_output"
grep -Fq '已完成 3 条，未完成 0 条' <<< "$ipv4_only_route_output"
if grep -Fq 'IPv6 回程' <<< "$ipv4_only_route_output"; then
  printf 'IPv4-only 线路测试不应运行 IPv6 探测。\n' >&2
  exit 1
fi

jq '.network.mode = "ipv6-only"' \
  "$WORK/etc/state.json" > "$WORK/etc/state-ipv6.json"
ipv6_only_route_output="$(
  env "${common_env[@]}" NEKO_STATE="$WORK/etc/state-ipv6.json" \
    bash "$ROOT/runtime/diagnostics.sh" --routes bj
)"
grep -Fq '【北京 · IPv6 回程】' <<< "$ipv6_only_route_output"
grep -Fq '已完成 3 条，未完成 0 条' <<< "$ipv6_only_route_output"
if grep -Fq 'IPv4 回程' <<< "$ipv6_only_route_output"; then
  printf 'IPv6-only 线路测试不应运行 IPv4 探测。\n' >&2
  exit 1
fi

if env "${common_env[@]}" \
    bash "$ROOT/runtime/diagnostics.sh" --routes invalid \
    > "$WORK/invalid-route.log" 2>&1; then
  printf '无效线路地区没有被拒绝。\n' >&2
  exit 1
fi
grep -Fq '线路地区只能是 gd、sh、bj、sc 或 all' \
  "$WORK/invalid-route.log"

route_failed_output="$(
  env "${common_env[@]}" NEKO_DIAG_ROUTE_FAIL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '未完成（超时、无响应或线路元数据不可用）' \
  <<< "$route_failed_output"
grep -Fq '线路测试小结' <<< "$route_failed_output"
grep -Fq '已完成 0 条，未完成 6 条' <<< "$route_failed_output"

route_missing_output="$(
  env "${common_env[@]}" NEKO_DIAG_NEXTTRACE="$WORK/missing-nexttrace" \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '可选 NextTrace 组件不可用' <<< "$route_missing_output"

if find "$WORK/bench" -mindepth 1 -maxdepth 1 \
  \( -name '.neko-ip-quality.*' -o -name '.neko-route.*' \) \
  | grep -q .; then
  printf 'IP 质量或线路测试没有清理临时目录。\n' >&2
  exit 1
fi

cpu_output="$(
  env "${common_env[@]}" NEKO_DIAG_CPU_SECONDS=1 \
    bash "$ROOT/runtime/diagnostics.sh" --benchmark-cpu
)"
grep -Fq 'CPU 轻量测试' <<< "$cpu_output"
grep -Fq 'CPU 轻量测试完成' <<< "$cpu_output"

disk_output="$(
  env "${common_env[@]}" \
    NEKO_DIAG_TMP_DIR="$WORK/bench" NEKO_DIAG_DISK_MIB=1 \
    bash "$ROOT/runtime/diagnostics.sh" --benchmark-disk
)"
grep -Fq '磁盘轻量写入测试' <<< "$disk_output"
grep -Fq '磁盘轻量写入测试完成' <<< "$disk_output"
if find "$WORK/bench" -mindepth 1 -maxdepth 1 \
  -name '.neko-disk-bench.*' | grep -q .; then
  printf '磁盘测试没有清理临时文件。\n' >&2
  exit 1
fi

grep -Fq '7. VPS 硬件、IP 与网络体检' "$ROOT/runtime/panel.sh"
grep -Fq 'open_diagnostics' "$ROOT/runtime/panel.sh"

printf 'VPS 体检：硬件、IP 质量、BGP、双栈三网线路、降级与轻量测试通过。\n'
