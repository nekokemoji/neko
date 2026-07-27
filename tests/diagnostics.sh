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
  '.release = "1.4.0-test"
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
case "$*" in
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

chmod 0755 "$WORK/bin/systemctl" "$WORK/bin/ip" "$WORK/bin/dig" "$WORK/bin/curl"

common_env=(
  "PATH=$WORK/bin:$PATH"
  "NEKO_ETC=$WORK/etc"
  "NEKO_VAR=$WORK/var"
  "NEKO_LIBEXEC=$WORK/libexec"
  "NEKO_STATE=$WORK/etc/state.json"
  "NEKO_DIAG_RESOLV_CONF=$WORK/resolv.conf"
  "NEKO_DIAG_DNS_TIMEOUT=3"
  "NEKO_DIAG_NETWORK_TIMEOUT=2"
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
grep -Fq '“原生 IP”没有统一、权威的公开字段' <<< "$network_output"

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
grep -Fq '体检小结' <<< "$failed_output"

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

printf 'VPS 体检：离线信息、服务证书、双栈出口、RIPEstat、降级与轻量测试通过。\n'
