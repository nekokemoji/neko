#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-diagnostics-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p \
  "$WORK/bin" \
  "$WORK/etc" \
  "$WORK/var/lego/certificates" \
  "$WORK/libexec/lib" \
  "$WORK/bench"
cp -a -- "$ROOT/lib/common.sh" "$WORK/libexec/lib/common.sh"
jq \
  '.release = "1.7.1-test"
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
case "${*: -1}" in
  http://*.ip.zstaticcdn.com:*|https://*.ip.zstaticcdn.com:*|\
  http://*noicmp.example:*|https://*noicmp.example:*|\
  http://backup-v4.example:*|https://backup-v4.example:*)
    if [[ "${NEKO_DIAG_TCP_ALL_FAIL:-0}" == 1 ]] \
      || { [[ "${NEKO_DIAG_TCP_443_FAIL:-0}" == 1 ]] \
        && [[ "${*: -1}" == https://*:443/ ]]; }; then
      printf '0.010000\t0.000000\n'
      exit 28
    fi
    if [[ "${NEKO_DIAG_TCP_MALFORMED:-0}" == 1 ]]; then
      printf 'not-a-time\n'
      exit 0
    fi
    printf '0.010000\t0.130000\n'
    exit 0
    ;;
esac
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

cat > "$WORK/bin/ping" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -n "${NEKO_DIAG_PING_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$NEKO_DIAG_PING_ARGS_LOG"
fi
[[ "${NEKO_DIAG_PING_FAIL:-0}" != 1 ]] || exit 2
target="${*: -1}"
count=100
previous=""
for argument in "$@"; do
  if [[ "$previous" == -c ]]; then
    count="$argument"
    break
  fi
  previous="$argument"
done
transmitted="$count"
received="$count"
if [[ " $* " == *' -w '* ]]; then
  transmitted=129
  received=102
elif (( count == 100 )) && [[ "${NEKO_DIAG_PING_MALFORMED:-0}" == 1 ]]; then
  printf '100 packets transmitted, 101 received, invalid packet loss\n'
  exit 0
elif (( count == 100 )) && [[ "${NEKO_DIAG_PING_INCOMPLETE:-0}" == 1 ]]; then
  transmitted=80
  received=75
elif [[ "${NEKO_DIAG_PING_NO_REPLY:-0}" == 1 ]]; then
  received=0
elif (( count == 3 )) && [[ "$target" == *primary-noicmp* \
  || "$target" == 198.51.100.10 ]]; then
  received=0
else
  if (( count == 100 )); then
    case "$target" in
      *-cu-*) received=98 ;;
      *-cm-*) received=93 ;;
    esac
  fi
fi
loss=$((transmitted - received))
printf 'PING %s (%s) 56(84) bytes of data.\n' "$target" "$target"
base=20
[[ "$target" == *-v6* || "$target" == *:* ]] && base=45
for ((sequence = 1; sequence <= received; sequence++)); do
  latency=$((base + (sequence - 1) % 5))
  printf '64 bytes from %s: icmp_seq=%d ttl=50 time=%d.00 ms\n' \
    "$target" "$sequence" "$latency"
done
printf '%d packets transmitted, %d received, %d%% packet loss, time 20000ms\n' \
  "$transmitted" "$received" "$loss"
(( received > 0 )) || exit 1
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
  '{"Hops":[[{"Success":true,"Address":{"IP":"198.51.100.1"},"TTL":1,"RTT":20000000,"Geo":{"ip":"198.51.100.1","asnumber":"2497","owner":"Internet Initiative Japan Inc."}}],[{"Success":true,"Address":{"IP":"203.0.113.9"},"TTL":2,"RTT":30000000,"Geo":{"ip":"203.0.113.9","asnumber":"'"$asn"'"}}]]}'
EOF

chmod 0755 \
  "$WORK/bin/systemctl" "$WORK/bin/ip" "$WORK/bin/dig" "$WORK/bin/curl" \
  "$WORK/bin/ping"
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
  "NEKO_DIAG_PING_ARGS_LOG=$WORK/ping-args.log"
  "NEKO_DIAG_TCP_INTERVAL=0"
  "NEKO_DIAG_TCP_PORTS=80"
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
grep -Fq '【广东 · IPv4 回程】' <<< "$route_output"
grep -Fq '先发 3 包 ICMP 预检；通过后固定发送 100 包' \
  <<< "$route_output"
grep -Fq 'ICMP 不回应时改测 100 次独立连接' <<< "$route_output"
grep -Fq 'CN2（AS4809）' <<< "$route_output"
grep -Fq '联通 9929/CUII（AS9929）' <<< "$route_output"
grep -Fq '中国移动国际 CMI（AS58453）' <<< "$route_output"
grep -Fq '线路判断：IIJ（AS2497） → CN2（AS4809）' \
  <<< "$route_output"
grep -Fq 'ASN 路径：AS2497 → AS4809（2 跳响应）' <<< "$route_output"
grep -Fq '平均延迟：22.00 ms｜P95 延迟：24.00 ms' \
  <<< "$route_output"
grep -Fq 'ICMP 丢包率：0%（100/100）' \
  <<< "$route_output"
grep -Fq 'ICMP 丢包率：2%（98/100）' \
  <<< "$route_output"
grep -Fq 'ICMP 丢包率：7%（93/100）' \
  <<< "$route_output"
grep -Fq '平均延迟：47.00 ms｜P95 延迟：49.00 ms' \
  <<< "$route_output"
grep -Fq '线路判断：IIJ（AS2497） → 中国移动国际 CMI（AS58453）' \
  <<< "$route_output"
grep -Fq 'ASN 路径：有效 6 条，未测 0 条' \
  <<< "$route_output"
grep -Fq '质量样本：ICMP 6 组，TCP 0 组，未测/异常 0 组' \
  <<< "$route_output"
grep -Fq 'TCP 显示的是连接成功率，不冒充网络层丢包率' \
  <<< "$route_output"
for removed_text in \
  'IPv4 / IPv6 回程对比' \
  '末跳' \
  '网络识别：' \
  'P50' \
  '本地实测 IPv4→IPv4'; do
  if grep -Fq "$removed_text" <<< "$route_output"; then
    printf '小白线路报告不应再显示：%s\n' "$removed_text" >&2
    exit 1
  fi
done
if grep -Fq '【上海 ·' <<< "$route_output"; then
  printf '默认 --routes 不应自动测试全部地区。\n' >&2
  exit 1
fi
grep -Fq -- '--ipv4 --tcp --port 80 --source 192.0.2.44' \
  "$WORK/route-args.log"
grep -Fq -- '--ipv6 --tcp --port 80 --source 2001:db8::44' \
  "$WORK/route-args.log"
grep -Fq -- '-4 -n -q -I 192.0.2.44 -c 3 -i 0.2 -W 1 --' \
  "$WORK/ping-args.log"
grep -Fq -- '-6 -n -q -I 2001:db8::44 -c 3 -i 0.2 -W 1 --' \
  "$WORK/ping-args.log"
grep -Fq -- '-4 -n -I 192.0.2.44 -c 100 -i 0.2 -W 1 --' \
  "$WORK/ping-args.log"
grep -Fq -- '-6 -n -I 2001:db8::44 -c 100 -i 0.2 -W 1 --' \
  "$WORK/ping-args.log"
if grep -Eq -- '(^|[[:space:]])-w([[:space:]]|$)' "$WORK/ping-args.log"; then
  printf '固定 100 包检测不应再向 ping 传递 deadline。\n' >&2
  exit 1
fi
[[ "$(wc -l < "$WORK/ping-args.log")" -eq 12 ]]

: > "$WORK/route-args.log"
: > "$WORK/ping-args.log"
all_regions_output="$(
  env "${common_env[@]}" bash "$ROOT/runtime/diagnostics.sh" --routes 5
)"
grep -Fq '测试地区：广东、上海、北京、四川、湖北、辽宁' \
  <<< "$all_regions_output"
for region_heading in \
  '【广东 · IPv4 回程】' \
  '【上海 · IPv4 回程】' \
  '【北京 · IPv4 回程】' \
  '【四川 · IPv4 回程】' \
  '【湖北 · IPv4 回程】' \
  '【辽宁 · IPv4 回程】'; do
  grep -Fq "$region_heading" <<< "$all_regions_output"
done
for target in \
  gd-ct-v4.ip.zstaticcdn.com \
  sh-cu-v6.ip.zstaticcdn.com \
  bj-cm-v4.ip.zstaticcdn.com \
  sc-ct-v6.ip.zstaticcdn.com \
  hb-ct-v4.ip.zstaticcdn.com \
  hb-cu-v4.ip.zstaticcdn.com \
  hb-cm-v4.ip.zstaticcdn.com \
  hb-ct-v6.ip.zstaticcdn.com \
  hb-cu-v6.ip.zstaticcdn.com \
  hb-cm-v6.ip.zstaticcdn.com \
  ln-ct-v4.ip.zstaticcdn.com \
  ln-cu-v4.ip.zstaticcdn.com \
  ln-cm-v4.ip.zstaticcdn.com \
  ln-ct-v6.ip.zstaticcdn.com \
  ln-cu-v6.ip.zstaticcdn.com \
  ln-cm-v6.ip.zstaticcdn.com; do
  grep -Fq "$target" "$WORK/route-args.log"
done
[[ "$(wc -l < "$WORK/route-args.log")" -eq 36 ]]
[[ "$(wc -l < "$WORK/ping-args.log")" -eq 72 ]]
grep -Fq 'ASN 路径：有效 36 条，未测 0 条' <<< "$all_regions_output"
grep -Fq '质量样本：ICMP 36 组，TCP 0 组，未测/异常 0 组' \
  <<< "$all_regions_output"

region_number_output="$(
  env "${common_env[@]}" bash -c '
    source "$1"
    printf "%s\n" \
      "$(normalize_route_region 5)" \
      "$(normalize_route_region 6)" \
      "$(normalize_route_region 7)"
  ' _ "$ROOT/runtime/diagnostics.sh"
)"
[[ "$region_number_output" == $'all\nhb\nln' ]]

classification_output="$(
  env "${common_env[@]}" bash -c '
    source "$1"
    classify_carrier_route ct "AS64500 → AS4134"
    printf "\n"
    classify_carrier_route cm "AS64500 → AS58807 → AS9808"
    printf "\n"
    classify_carrier_route ct "AS64500 → AS48090"
    printf "\n"
    classify_carrier_route ct "AS2497 → AS23764 → AS4134"
    printf "\n"
    classify_major_networks "AS174 → AS1299 → AS2497 → AS2516 → AS2914 → AS3356 → AS3491 → AS6453 → AS6939 → AS9304"
    printf "\n"
    classify_major_networks "AS12956 → AS17676 → AS176760"
    printf "\n"
    classify_major_networks "AS1239"
    printf "\n"
  ' _ "$ROOT/runtime/diagnostics.sh"
)"
grep -Fxq '电信 163（AS4134）' <<< "$classification_output"
grep -Fxq '移动 CMIN2（AS58807） → 移动 CMNET（AS9808）' \
  <<< "$classification_output"
grep -Fxq '未识别常见电信骨干' <<< "$classification_output"
grep -Fxq '中国电信国际 CTGNet（AS23764） → 电信 163（AS4134）' \
  <<< "$classification_output"
grep -Fxq 'Cogent（AS174） → Arelion（AS1299） → IIJ（AS2497） → KDDI（AS2516） → NTT（AS2914） → Level 3（AS3356） → PCCW Global（AS3491） → Tata Communications（AS6453） → …' \
  <<< "$classification_output"
grep -Fxq 'Telxius（AS12956） → SoftBank（AS17676）' \
  <<< "$classification_output"
grep -Fxq 'SprintLink（AS1239）' <<< "$classification_output"
if grep -Fq 'IIJ（AS24970）' <<< "$classification_output"; then
  printf '相似但不同的 ASN 不应被识别为 IIJ。\n' >&2
  exit 1
fi

jq '.network.mode = "ipv4-only"' \
  "$WORK/etc/state.json" > "$WORK/etc/state-ipv4.json"
ipv4_only_route_output="$(
  env "${common_env[@]}" NEKO_STATE="$WORK/etc/state-ipv4.json" \
    bash "$ROOT/runtime/diagnostics.sh" --routes hb
)"
grep -Fq '【湖北 · IPv4 回程】' <<< "$ipv4_only_route_output"
grep -Fq 'ASN 路径：有效 3 条，未测 0 条' <<< "$ipv4_only_route_output"
if grep -Fq 'IPv6 回程' <<< "$ipv4_only_route_output"; then
  printf 'IPv4-only 线路测试不应运行 IPv6 探测。\n' >&2
  exit 1
fi

jq '.network.mode = "ipv6-only"' \
  "$WORK/etc/state.json" > "$WORK/etc/state-ipv6.json"
ipv6_only_route_output="$(
  env "${common_env[@]}" NEKO_STATE="$WORK/etc/state-ipv6.json" \
    bash "$ROOT/runtime/diagnostics.sh" --routes ln
)"
grep -Fq '【辽宁 · IPv6 回程】' <<< "$ipv6_only_route_output"
grep -Fq 'ASN 路径：有效 3 条，未测 0 条' <<< "$ipv6_only_route_output"
grep -Fq '当前 Neko 安装未配置可用 IPv4；只测试 IPv6，不会报错退出' \
  <<< "$ipv6_only_route_output"
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
grep -Fq '线路地区只能是 gd、sh、bj、sc、hb、ln 或 all' \
  "$WORK/invalid-route.log"

route_failed_output="$(
  env "${common_env[@]}" NEKO_DIAG_ROUTE_FAIL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq 'ASN 路径：未测（超时、无响应或线路元数据不可用）' \
  <<< "$route_failed_output"
grep -Fq '线路测试小结' <<< "$route_failed_output"
grep -Fq 'ASN 路径：有效 0 条，未测 6 条' <<< "$route_failed_output"
grep -Fq '质量样本：ICMP 6 组，TCP 0 组，未测/异常 0 组' \
  <<< "$route_failed_output"

: > "$WORK/curl-args.log"
ping_no_reply_output="$(
  env "${common_env[@]}" NEKO_DIAG_PING_NO_REPLY=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '平均握手延迟：120.00 ms｜P95 握手延迟：120.00 ms' \
  <<< "$ping_no_reply_output"
grep -Fq 'TCP 连接成功率：100%（100/100）（端口 80）' \
  <<< "$ping_no_reply_output"
grep -Fq '质量样本：ICMP 0 组，TCP 6 组，未测/异常 0 组' \
  <<< "$ping_no_reply_output"
[[ "$(grep -c '.ip.zstaticcdn.com:80/' "$WORK/curl-args.log")" -eq 618 ]]
grep -Fq -- '--ipv4 --interface 192.0.2.44' "$WORK/curl-args.log"
grep -Fq -- '--ipv6 --interface 2001:db8::44' "$WORK/curl-args.log"

ping_failed_output="$(
  env "${common_env[@]}" NEKO_DIAG_PING_FAIL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq 'TCP 连接成功率：100%（100/100）（端口 80）' \
  <<< "$ping_failed_output"
grep -Fq '质量样本：ICMP 0 组，TCP 6 组，未测/异常 0 组' \
  <<< "$ping_failed_output"

ping_malformed_output="$(
  env "${common_env[@]}" NEKO_DIAG_PING_MALFORMED=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '质量样本：未测（测试异常（无法读取可靠统计））' \
  <<< "$ping_malformed_output"
grep -Fq '质量样本：ICMP 0 组，TCP 0 组，未测/异常 6 组' \
  <<< "$ping_malformed_output"

ping_incomplete_output="$(
  env "${common_env[@]}" NEKO_DIAG_PING_INCOMPLETE=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '质量样本：未测（测试异常（发包统计 80/100））' \
  <<< "$ping_incomplete_output"
grep -Fq '质量样本：ICMP 0 组，TCP 0 组，未测/异常 6 组' \
  <<< "$ping_incomplete_output"

printf '129 packets transmitted, 102 received, 20%% packet loss\n' \
  > "$WORK/ping-excess.txt"
ping_excess_sample="$(
  env "${common_env[@]}" bash -c '
    source "$1"
    packet_loss_sample "$2"
  ' _ "$ROOT/runtime/diagnostics.sh" "$WORK/ping-excess.txt"
)"
[[ "$ping_excess_sample" == \
  $'invalid\t测试异常（发包统计 129/100）' ]]

cat > "$WORK/ping-latency.txt" <<'EOF'
64 bytes from test: icmp_seq=1 ttl=50 time=10.00 ms
64 bytes from test: icmp_seq=2 ttl=50 time=20.00 ms
64 bytes from test: icmp_seq=3 ttl=50 time=30.00 ms
64 bytes from test: icmp_seq=4 ttl=50 time=40.00 ms
64 bytes from test: icmp_seq=5 ttl=50 time=100.00 ms
5 packets transmitted, 5 received, 0% packet loss, time 1000ms
EOF
latency_metrics="$(
  env "${common_env[@]}" bash -c '
    source "$1"
    packet_latency_metrics "$2"
  ' _ "$ROOT/runtime/diagnostics.sh" "$WORK/ping-latency.txt"
)"
[[ "$latency_metrics" == $'10.00\t40.00\t30.00\t100.00\t100.00\t31.62\t5' ]]

: > "$WORK/tcp-sample.txt"
for _ in $(seq 1 98); do
  printf 'ok\t120.00\n' >> "$WORK/tcp-sample.txt"
done
printf 'fail\t28\nfail\t7\n' >> "$WORK/tcp-sample.txt"
tcp_sample="$(
  env "${common_env[@]}" bash -c '
    source "$1"
    tcp_connection_sample "$2"
  ' _ "$ROOT/runtime/diagnostics.sh" "$WORK/tcp-sample.txt"
)"
[[ "$tcp_sample" == $'complete\t98%（98/100）' ]]
tcp_metrics="$(
  env "${common_env[@]}" bash -c '
    source "$1"
    tcp_latency_metrics "$2"
  ' _ "$ROOT/runtime/diagnostics.sh" "$WORK/tcp-sample.txt"
)"
[[ "$tcp_metrics" == $'120.00\t120.00\t98' ]]

: > "$WORK/route-args.log"
: > "$WORK/ping-args.log"
backup_target_output="$(
  env "${common_env[@]}" \
    NEKO_DIAG_ROUTE_GD_V4_CT=primary-noicmp.example \
    NEKO_DIAG_ROUTE_GD_V4_CT_BACKUP=backup-v4.example \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq 'backup-v4.example' "$WORK/route-args.log"
grep -Fq -- '-4 -n -q -I 192.0.2.44 -c 3 -i 0.2 -W 1 -- primary-noicmp.example' \
  "$WORK/ping-args.log"
grep -Fq -- '-4 -n -I 192.0.2.44 -c 100 -i 0.2 -W 1 -- backup-v4.example' \
  "$WORK/ping-args.log"
if grep -Fq '目标保护' <<< "$backup_target_output"; then
  printf '小白报告不应展示内部候选切换细节。\n' >&2
  exit 1
fi

: > "$WORK/curl-args.log"
tcp_port_fallback_output="$(
  env "${common_env[@]}" \
    NEKO_STATE="$WORK/etc/state-ipv4.json" \
    NEKO_DIAG_PING_NO_REPLY=1 \
    NEKO_DIAG_TCP_PORTS='443 80' \
    NEKO_DIAG_TCP_443_FAIL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq 'TCP 连接成功率：100%（100/100）（端口 80）' \
  <<< "$tcp_port_fallback_output"
grep -Fq 'https://gd-ct-v4.ip.zstaticcdn.com:443/' "$WORK/curl-args.log"
grep -Fq 'http://gd-ct-v4.ip.zstaticcdn.com:80/' "$WORK/curl-args.log"
grep -Fq -- '--ipv4 --tcp --port 80 --source 192.0.2.44' \
  "$WORK/route-args.log"

tcp_unavailable_output="$(
  env "${common_env[@]}" \
    NEKO_STATE="$WORK/etc/state-ipv4.json" \
    NEKO_DIAG_PING_NO_REPLY=1 \
    NEKO_DIAG_TCP_ALL_FAIL=1 \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '质量样本：未测（目标不响应 ICMP，TCP 端口也无法连接）' \
  <<< "$tcp_unavailable_output"
grep -Fq '质量样本：ICMP 0 组，TCP 0 组，未测/异常 3 组' \
  <<< "$tcp_unavailable_output"

ping_missing_output="$(
  env "${common_env[@]}" NEKO_DIAG_PING="$WORK/missing-ping" \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '系统缺少 ping；质量样本将尝试 TCP 连接测试' \
  <<< "$ping_missing_output"
grep -Fq 'TCP 连接成功率：100%（100/100）（端口 80）' \
  <<< "$ping_missing_output"
grep -Fq '质量样本：ICMP 0 组，TCP 6 组，未测/异常 0 组' \
  <<< "$ping_missing_output"

tcp_missing_output="$(
  env "${common_env[@]}" \
    NEKO_STATE="$WORK/etc/state-ipv4.json" \
    NEKO_DIAG_PING_NO_REPLY=1 \
    NEKO_DIAG_TCP_CURL="$WORK/missing-curl" \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '系统缺少 curl；ICMP 不回应时无法改测 TCP' \
  <<< "$tcp_missing_output"
grep -Fq '质量样本：未测（目标不响应 ICMP，系统缺少 TCP 测试工具）' \
  <<< "$tcp_missing_output"
grep -Fq '质量样本：ICMP 0 组，TCP 0 组，未测/异常 3 组' \
  <<< "$tcp_missing_output"

route_missing_output="$(
  env "${common_env[@]}" NEKO_DIAG_NEXTTRACE="$WORK/missing-nexttrace" \
    bash "$ROOT/runtime/diagnostics.sh" --routes
)"
grep -Fq '可选 NextTrace 组件不可用' <<< "$route_missing_output"
grep -Fq 'ASN 路径：有效 0 条，未测 6 条' <<< "$route_missing_output"
grep -Fq '质量样本：ICMP 6 组，TCP 0 组，未测/异常 0 组' \
  <<< "$route_missing_output"

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

printf 'VPS 体检：硬件、IP 质量、BGP、双栈三网 ASN、100 包 ICMP、100 次 TCP 降级与轻量测试通过。\n'
