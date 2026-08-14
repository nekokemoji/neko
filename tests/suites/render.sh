#!/usr/bin/env bash

# Bootstrap, render, core, subscription, and read-only panel contracts.
# This file is sourced by tests/run.sh so the suites keep one shared fixture.
# shellcheck disable=SC2154
[[ "${NEKO_TEST_SUITE_CONTEXT:-}" == 1 ]] || {
  printf '请通过 tests/run.sh 运行测试套件。\n' >&2
  exit 1
}

printf '[5/10] 渲染服务端配置与客户端订阅……\n'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-tests.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/etc" "$WORK/var/lego/certificates" "$WORK/var/acme"
cp "$ROOT/tests/fixtures/state.json" "$WORK/etc/state.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=example.com \
  -addext 'subjectAltName=DNS:example.com,DNS:v4.example.com,DNS:v6.example.com' \
  -keyout "$WORK/var/lego/certificates/example.com.key" \
  -out "$WORK/var/lego/certificates/example.com.crt" >/dev/null 2>&1

root_dir_name="${ROOT##*/}"
(
  cd "$ROOT"
  find . \
    -path './.git' -prune -o \
    -path './tests/.tools' -prune -o \
    \( -type f -o -type l \) -print0
) | tar --null --no-recursion \
  --transform="s#^\\./#${root_dir_name}/#" \
  -czf "$WORK/bootstrap-source.tar.gz" -C "$ROOT" --files-from=-
mkdir -p "$WORK/bootstrap-work"
NEKO_BOOTSTRAP_ARCHIVE="$WORK/bootstrap-source.tar.gz" \
  NEKO_BOOTSTRAP_WORK_BASE="$WORK/bootstrap-work" NEKO_BOOTSTRAP_TEST_MODE=1 \
  bash "$ROOT/bootstrap.sh" > "$WORK/bootstrap.log"
grep -Fq '[测试] Bootstrap 已成功校验固定安装包。' "$WORK/bootstrap.log"
if find "$WORK/bootstrap-work" -mindepth 1 -maxdepth 1 -name 'neko-bootstrap.*' | grep -q .; then
  printf 'Bootstrap 没有清理临时源码目录。\n' >&2
  exit 1
fi

for required_runtime in runtime/akdns.sh runtime/route-diagnostics.sh; do
  missing_case="${required_runtime//\//-}"
  missing_root="$WORK/bootstrap-missing-$missing_case"
  mkdir -p "$missing_root/source" "$missing_root/work"
  tar -xzf "$WORK/bootstrap-source.tar.gz" -C "$missing_root/source"
  rm -f -- "$missing_root/source/$root_dir_name/$required_runtime"
  tar -czf "$missing_root/source.tar.gz" \
    -C "$missing_root/source" "$root_dir_name"
  set +e
  missing_output="$(
    NEKO_BOOTSTRAP_ARCHIVE="$missing_root/source.tar.gz" \
      NEKO_BOOTSTRAP_WORK_BASE="$missing_root/work" \
      NEKO_BOOTSTRAP_TEST_MODE=1 \
      bash "$ROOT/bootstrap.sh" 2>&1
  )"
  missing_rc=$?
  set -e
  (( missing_rc != 0 ))
  [[ "$missing_output" == *"缺少 ${required_runtime}"* ]]
done

mkdir -p "$WORK/bootstrap-minimal/bin" "$WORK/bootstrap-minimal/work"
for command_name in bash mktemp mkdir grep rm cp; do
  ln -s "$(command -v "$command_name")" "$WORK/bootstrap-minimal/bin/$command_name"
done
cat > "$WORK/bootstrap-minimal/bin/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" > "$NEKO_BOOTSTRAP_PM_LOG"
bin_dir="${BASH_SOURCE[0]%/*}"
"$NEKO_TEST_REAL_LN" -s "$NEKO_TEST_REAL_TAR" "$bin_dir/tar"
"$NEKO_TEST_REAL_LN" -s "$NEKO_TEST_REAL_GZIP" "$bin_dir/gzip"
EOF
chmod 0755 "$WORK/bootstrap-minimal/bin/dnf"
real_ln="$(command -v ln)"
real_tar="$(command -v tar)"
real_gzip="$(command -v gzip)"
PATH="$WORK/bootstrap-minimal/bin" \
  NEKO_TEST_REAL_LN="$real_ln" \
  NEKO_TEST_REAL_TAR="$real_tar" \
  NEKO_TEST_REAL_GZIP="$real_gzip" \
  NEKO_BOOTSTRAP_PM_LOG="$WORK/bootstrap-minimal/package-manager.log" \
  NEKO_BOOTSTRAP_ARCHIVE="$WORK/bootstrap-source.tar.gz" \
  NEKO_BOOTSTRAP_WORK_BASE="$WORK/bootstrap-minimal/work" \
  NEKO_BOOTSTRAP_TEST_MODE=1 \
  /usr/bin/bash "$ROOT/bootstrap.sh" > "$WORK/bootstrap-minimal/bootstrap.log"
grep -Fq 'tar gzip' "$WORK/bootstrap-minimal/bootstrap.log"
grep -Fxq -- '-y install ca-certificates tar gzip' \
  "$WORK/bootstrap-minimal/package-manager.log"
if grep -Eq 'coreutils|curl|gawk|glibc-common' \
  "$WORK/bootstrap-minimal/package-manager.log"; then
  printf 'Bootstrap 安装了并未缺少的软件包，可能与最小系统替代包冲突。\n' >&2
  exit 1
fi
grep -Fq '[测试] Bootstrap 已成功校验固定安装包。' \
  "$WORK/bootstrap-minimal/bootstrap.log"
if find "$WORK/bootstrap-minimal/work" -mindepth 1 -maxdepth 1 -name 'neko-bootstrap.*' | grep -q .; then
  printf '缺少 tar/gzip 的 Bootstrap 测试没有清理临时源码目录。\n' >&2
  exit 1
fi

NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
  bash -c 'source "$1"; source "$2"; render_all' \
  _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

printf '[6/10] 用真实冻结核心校验配置……\n'
"$SING_BOX" check -c "$WORK/etc/config/sing-box.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v4.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v6.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v4-to-v6.json"
"$SING_BOX" check -c "$WORK/etc/subscriptions/sing-box-v6-to-v4.json"
"$XRAY" run -test -c "$WORK/etc/config/xray.json"
"$CADDY" validate --config "$WORK/etc/config/Caddyfile" --adapter caddyfile >/dev/null
mkdir -p \
  "$WORK/mihomo-v4" "$WORK/mihomo-v6" \
  "$WORK/mihomo-v4-to-v6" "$WORK/mihomo-v6-to-v4"
"$MIHOMO" -d "$WORK/mihomo-v4" -t -f "$WORK/etc/subscriptions/mihomo-v4.yaml"
"$MIHOMO" -d "$WORK/mihomo-v6" -t -f "$WORK/etc/subscriptions/mihomo-v6.yaml"
"$MIHOMO" -d "$WORK/mihomo-v4-to-v6" -t \
  -f "$WORK/etc/subscriptions/mihomo-v4-to-v6.yaml"
"$MIHOMO" -d "$WORK/mihomo-v6-to-v4" -t \
  -f "$WORK/etc/subscriptions/mihomo-v6-to-v4.yaml"
for family in v4 v6 v4-to-v6 v6-to-v4; do
  set +e
  PATH=/nonexistent "$HYSTERIA" server --disable-update-check \
    --config "$WORK/etc/config/hysteria-${family}.yaml" \
    >"$WORK/hysteria-${family}-check.log" 2>&1
  hysteria_rc=$?
  set -e
  (( hysteria_rc != 0 ))
  grep -Fq 'executable file not found' "$WORK/hysteria-${family}-check.log"
done

printf '[7/10] 校验严格订阅、出口策略、端口和 REALITY 目标……\n'
bash -c '
  set -Eeuo pipefail
  source "$1"
  for ((round = 0; round < 50; round++)); do
    initialize_port_reservations
    reserve_random_range 128 range_start range_end
    reserve_random_port tuic
    reserve_random_port ss
    reserve_random_port anytls
    reserve_random_port trojan
    reserve_random_port vision
    reserve_random_port xhttp
    declare -A seen=()
    for ((port = range_start; port <= range_end; port++)); do seen[$port]=1; done
    for port in "$tuic" "$ss" "$anytls" "$trojan" "$vision" "$xhttp"; do
      [[ -z "${seen[$port]+x}" ]]
      seen[$port]=1
    done
  done
' _ "$ROOT/lib/common.sh"
python3 - "$WORK" <<'PY'
import base64
import json
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
state = json.loads((root / "etc/state.json").read_text())
assert state["acme"]["method"] == "http-01"
xray = json.loads((root / "etc/config/xray.json").read_text())
sing = json.loads((root / "etc/config/sing-box.json").read_text())
hysteria_v4 = yaml.safe_load((root / "etc/config/hysteria-v4.yaml").read_text())
hysteria_v6 = yaml.safe_load((root / "etc/config/hysteria-v6.yaml").read_text())
hysteria_v4_to_v6 = yaml.safe_load(
    (root / "etc/config/hysteria-v4-to-v6.yaml").read_text()
)
hysteria_v6_to_v4 = yaml.safe_load(
    (root / "etc/config/hysteria-v6-to-v4.yaml").read_text()
)
caddy = (root / "etc/config/Caddyfile").read_text()

expected_subscription_files = {
    f"{client}-{route}.{extension}"
    for client, extension in (
        ("mihomo", "yaml"), ("stash", "yaml"),
        ("shadowrocket", "txt"), ("sing-box", "json"),
    )
    for route in ("v4", "v6", "v4-to-v6", "v6-to-v4")
}
assert {p.name for p in (root / "etc/subscriptions").iterdir()} == expected_subscription_files

for family, address, ip_version, route_ports, expected_dns_strategy, expected_dns_server, rejected_ip_version in (
    ("v4", state["subscription"]["ipv4_address"], "ipv4", state["ports"],
     "ipv4_only", "1.1.1.1", 6),
    ("v6", state["subscription"]["ipv6_address"], "ipv6", state["ports"],
     "ipv6_only", "2606:4700:4700::1111", 4),
    ("v4-to-v6", state["subscription"]["ipv4_address"], "ipv4", state["ports"]["cross"],
     "ipv6_only", "2606:4700:4700::1111", 4),
    ("v6-to-v4", state["subscription"]["ipv6_address"], "ipv6", state["ports"]["cross"],
     "ipv4_only", "1.1.1.1", 6),
):
    mihomo = yaml.safe_load((root / f"etc/subscriptions/mihomo-{family}.yaml").read_text())
    stash = yaml.safe_load((root / f"etc/subscriptions/stash-{family}.yaml").read_text())
    shadow = yaml.safe_load((root / f"etc/subscriptions/shadowrocket-{family}.txt").read_text())
    sing_client = json.loads(
        (root / f"etc/subscriptions/sing-box-{family}.json").read_text()
    )

    assert len(mihomo["proxies"]) == 7
    assert all(p["server"] == address for p in mihomo["proxies"])
    assert all(p["ip-version"] == ip_version for p in mihomo["proxies"])
    mihomo_tuic = next(p for p in mihomo["proxies"] if p["type"] == "tuic")
    assert mihomo_tuic["sni"] == "example.com"
    assert mihomo_tuic["disable-sni"] is False
    mihomo_trojan = next(p for p in mihomo["proxies"] if p["type"] == "trojan")
    assert mihomo_trojan == {
        "name": "Trojan-TLS",
        "type": "trojan",
        "server": address,
        "ip-version": ip_version,
        "port": route_ports["trojan"],
        "password": state["credentials"]["trojan_password"],
        "sni": "example.com",
        "udp": True,
        "skip-cert-verify": False,
    }
    assert len(stash["proxies"]) == 6
    assert all(p["server"] == address for p in stash["proxies"])
    assert all(p["network"] != "xhttp" for p in stash["proxies"] if p["type"] == "vless")
    stash_hy2 = next(p for p in stash["proxies"] if p["type"] == "hysteria2")
    stash_tuic = next(p for p in stash["proxies"] if p["type"] == "tuic")
    stash_trojan = next(p for p in stash["proxies"] if p["type"] == "trojan")
    stash_vision = next(p for p in stash["proxies"] if p["type"] == "vless")
    assert stash_hy2["auth"] == "test-hy2-password" and "password" not in stash_hy2
    assert stash_tuic["version"] == 5
    assert stash_trojan["port"] == route_ports["trojan"]
    assert stash_trojan["password"] == state["credentials"]["trojan_password"]
    assert stash_trojan["sni"] == "example.com"
    assert stash_trojan["skip-cert-verify"] is False
    assert stash_vision["sni"] == "example.com" and "servername" not in stash_vision

    shadow_proxies = shadow["proxies"]
    assert [p["type"] for p in shadow_proxies] == [
        "hysteria2", "tuic", "ss", "anytls", "trojan", "vless", "vless"
    ]
    assert all(p["server"] == address for p in shadow_proxies)
    shadow_hy2, shadow_tuic, _, _, shadow_trojan, shadow_vision, shadow_xhttp = shadow_proxies
    route_hy2_range = f'{route_ports["hysteria2_start"]}-{route_ports["hysteria2_end"]}'
    assert shadow_hy2["port-range"] == route_hy2_range
    assert shadow_hy2["ports"] == route_hy2_range
    assert shadow_tuic["version"] == 5
    assert shadow_trojan["port"] == route_ports["trojan"]
    assert shadow_trojan["password"] == state["credentials"]["trojan_password"]
    assert shadow_trojan["sni"] == "example.com"
    assert shadow_trojan["skip-cert-verify"] is False
    assert shadow_vision["network"] == "tcp"
    assert shadow_vision["reality-opts"]["public-key"] == state["reality"]["vision_public_key"]
    assert shadow_xhttp["network"] == "xhttp"
    assert shadow_xhttp["xhttp-opts"]["mode"] == "stream-one"
    assert shadow_xhttp["xhttp-opts"]["path"] == state["reality"]["xhttp_path"]

    expected_selector = [
        "HY2", "TUIC-v5", "SS2022", "AnyTLS", "Trojan-TLS",
        "VLESS-Reality-Vision"
    ]
    client_outbounds = {outbound["tag"]: outbound for outbound in sing_client["outbounds"]}
    assert set(client_outbounds) == {"PROXY", *expected_selector}
    assert client_outbounds["PROXY"] == {
        "type": "selector",
        "tag": "PROXY",
        "outbounds": expected_selector,
        "default": "HY2",
    }
    assert all(
        outbound["server"] == address
        for tag, outbound in client_outbounds.items()
        if tag != "PROXY"
    )
    assert all(outbound["type"] != "direct" for outbound in sing_client["outbounds"])
    assert client_outbounds["HY2"]["server_ports"] == [
        f'{route_ports["hysteria2_start"]}:{route_ports["hysteria2_end"]}'
    ]
    assert client_outbounds["HY2"]["hop_interval"] == "30s"
    assert client_outbounds["TUIC-v5"]["udp_relay_mode"] == "native"
    assert client_outbounds["SS2022"]["method"] == "2022-blake3-aes-128-gcm"
    assert client_outbounds["VLESS-Reality-Vision"]["flow"] == "xtls-rprx-vision"
    assert client_outbounds["VLESS-Reality-Vision"]["network"] == "tcp"
    assert client_outbounds["VLESS-Reality-Vision"]["tls"]["reality"] == {
        "enabled": True,
        "public_key": state["reality"]["vision_public_key"],
        "short_id": state["reality"]["vision_short_id"],
    }
    for tag in ("HY2", "TUIC-v5", "AnyTLS", "Trojan-TLS", "VLESS-Reality-Vision"):
        assert client_outbounds[tag]["tls"]["server_name"] == "example.com"
        assert client_outbounds[tag]["tls"]["insecure"] is False
    assert client_outbounds["Trojan-TLS"] == {
        "type": "trojan",
        "tag": "Trojan-TLS",
        "server": address,
        "server_port": route_ports["trojan"],
        "password": state["credentials"]["trojan_password"],
        "tls": {
            "enabled": True,
            "server_name": "example.com",
            "insecure": False,
        },
    }
    assert sing_client["dns"] == {
        "servers": [{
            "type": "https",
            "tag": "strict-doh",
            "server": expected_dns_server,
            "server_port": 443,
            "path": "/dns-query",
            "tls": {
                "enabled": True,
                "server_name": "cloudflare-dns.com",
                "insecure": False,
            },
            "detour": "PROXY",
        }],
        "final": "strict-doh",
        "strategy": expected_dns_strategy,
    }
    assert sing_client["inbounds"] == [{
        "type": "tun",
        "tag": "tun-in",
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        "auto_route": True,
        "strict_route": True,
        "stack": "mixed",
    }]
    assert sing_client["route"] == {
        "rules": [
            {"protocol": "dns", "action": "hijack-dns"},
            {"ip_version": rejected_ip_version, "action": "reject"},
        ],
        "final": "PROXY",
        "auto_detect_interface": True,
    }
    assert sing_client["experimental"] == {"cache_file": {"enabled": True}}

ports = state["ports"]
cross_ports = ports["cross"]
all_used_ports = set()
for port_set in (ports, cross_ports):
    singles = [
        port_set[k] for k in (
        "tuic", "ss2022", "anytls", "trojan",
        "vless_reality_vision", "vless_reality_xhttp",
        )
    ]
    port_range = set(range(port_set["hysteria2_start"], port_set["hysteria2_end"] + 1))
    assert len(port_range) == 128
    assert len(set(singles)) == len(singles)
    assert not port_range.intersection(singles)
    assert not all_used_ports.intersection(port_range | set(singles))
    all_used_ports |= port_range | set(singles)

v4_address = state["subscription"]["ipv4_address"]
v6_address = state["subscription"]["ipv6_address"]

assert len(sing["inbounds"]) == 16
sing_inbounds = {inbound["tag"]: inbound for inbound in sing["inbounds"]}
sing_protocol_ports = {
    "tuic": "tuic", "ss2022": "ss2022", "anytls": "anytls", "trojan": "trojan"
}
for suffix, address, route_ports in (
    ("v4", v4_address, ports),
    ("v6", v6_address, ports),
    ("v4-to-v6", v4_address, cross_ports),
    ("v6-to-v4", v6_address, cross_ports),
):
    for protocol, port_key in sing_protocol_ports.items():
        inbound = sing_inbounds[f"{protocol}-{suffix}-in"]
        assert inbound["listen"] == address
        assert inbound["listen_port"] == route_ports[port_key]

assert len(xray["inbounds"]) == 8
xray_inbounds = {inbound["tag"]: inbound for inbound in xray["inbounds"]}
for suffix, address, route_ports in (
    ("v4", v4_address, ports),
    ("v6", v6_address, ports),
    ("v4-to-v6", v4_address, cross_ports),
    ("v6-to-v4", v6_address, cross_ports),
):
    vision = xray_inbounds[f"vless-reality-vision-{suffix}-in"]
    xhttp = xray_inbounds[f"vless-reality-xhttp-{suffix}-in"]
    assert vision["listen"] == address and vision["port"] == route_ports["vless_reality_vision"]
    assert xhttp["listen"] == address and xhttp["port"] == route_ports["vless_reality_xhttp"]
for inbound in xray["inbounds"]:
    reality = inbound["streamSettings"]["realitySettings"]
    assert reality["target"] == "127.0.0.1:8443"
    assert reality["serverNames"] == ["example.com"]
cert_path = str(root / "var/lego/certificates/example.com.crt")
key_path = str(root / "var/lego/certificates/example.com.key")
for suffix, address, route_ports in (
    ("v4", v4_address, ports),
    ("v6", v6_address, ports),
    ("v4-to-v6", v4_address, cross_ports),
    ("v6-to-v4", v6_address, cross_ports),
):
    trojan = sing_inbounds[f"trojan-{suffix}-in"]
    assert trojan["listen"] == address
    assert trojan["listen_port"] == route_ports["trojan"]
    assert trojan["users"] == [
        {"password": state["credentials"]["trojan_password"]}
    ]
    assert trojan["tls"] == {
        "enabled": True,
        "server_name": "example.com",
        "certificate_path": cert_path,
        "key_path": key_path,
    }
tls_inbounds = [i for i in sing["inbounds"] if "tls" in i]
assert all(i["tls"]["certificate_path"] == cert_path for i in tls_inbounds)
assert all(i["tls"]["key_path"] == key_path for i in tls_inbounds)
v4_egress_tags = [
    "tuic-v4-in", "ss2022-v4-in", "anytls-v4-in", "trojan-v4-in",
    "tuic-v6-to-v4-in", "ss2022-v6-to-v4-in",
    "anytls-v6-to-v4-in", "trojan-v6-to-v4-in",
]
v6_egress_tags = [
    "tuic-v6-in", "ss2022-v6-in", "anytls-v6-in", "trojan-v6-in",
    "tuic-v4-to-v6-in", "ss2022-v4-to-v6-in",
    "anytls-v4-to-v6-in", "trojan-v4-to-v6-in",
]
assert sing["route"]["rules"][0] == {
    "port": [80, 443],
    "action": "sniff",
    "sniffer": ["http", "tls", "quic"],
    "timeout": "1s",
}
assert sing["route"]["rules"][1] == {
    "network": "tcp", "port": 25, "action": "reject"
}
assert sing["route"]["rules"][2] == {
    "inbound": v4_egress_tags,
    "action": "resolve",
    "server": "local",
    "strategy": "ipv4_only",
}
assert sing["route"]["rules"][3] == {
    "inbound": v6_egress_tags,
    "action": "resolve",
    "server": "strict-v6",
    "strategy": "ipv6_only",
}
assert sing["route"]["rules"][4] == {"ip_is_private": True, "action": "reject"}
assert sing["route"]["rules"][5] == {
    "inbound": v4_egress_tags,
    "ip_version": 6,
    "action": "reject",
}
assert sing["route"]["rules"][6] == {
    "inbound": v6_egress_tags,
    "ip_version": 4,
    "action": "reject",
}
assert sing["route"]["rules"][7] == {
    "inbound": v4_egress_tags,
    "action": "route",
    "outbound": "direct-v4",
}
assert sing["route"]["rules"][8] == {
    "inbound": v6_egress_tags,
    "action": "route",
    "outbound": "direct-v6",
}
sing_outbounds = {outbound["tag"]: outbound for outbound in sing["outbounds"]}
assert sing_outbounds == {
    "direct-v4": {
        "type": "direct",
        "tag": "direct-v4",
        "inet4_bind_address": v4_address,
        "domain_resolver": {"server": "local", "strategy": "ipv4_only"},
    },
    "direct-v6": {
        "type": "direct",
        "tag": "direct-v6",
        "inet6_bind_address": v6_address,
        "domain_resolver": {"server": "strict-v6", "strategy": "ipv6_only"},
    },
}
assert sing["dns"] == {
    "servers": [
        {"type": "local", "tag": "local", "prefer_go": True},
        {
            "type": "https",
            "tag": "strict-v6",
            "server": "2606:4700:4700::1111",
            "server_port": 443,
            "path": "/dns-query",
            "tls": {
                "enabled": True,
                "server_name": "cloudflare-dns.com",
                "insecure": False,
            },
        },
    ]
}
assert xray["dns"] == {
    "queryStrategy": "UseIP",
    "servers": [
        {"address": "localhost", "queryStrategy": "UseIPv4"},
        {
            "address": "https+local://[2606:4700:4700::1111]/dns-query",
            "queryStrategy": "UseIPv6",
        },
    ],
}
assert all(inbound["sniffing"] == {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": False,
} for inbound in xray["inbounds"])
assert {o["tag"]: o["protocol"] for o in xray["outbounds"]} == {
    "direct-v4": "freedom", "direct-v6": "freedom", "blocked": "blackhole"
}
xray_outbounds = {outbound["tag"]: outbound for outbound in xray["outbounds"]}
assert xray_outbounds["direct-v4"]["sendThrough"] == v4_address
assert xray_outbounds["direct-v4"]["targetStrategy"] == "ForceIPv4"
assert xray_outbounds["direct-v4"]["settings"]["domainStrategy"] == "ForceIPv4"
assert xray_outbounds["direct-v6"]["sendThrough"] == v6_address
assert xray_outbounds["direct-v6"]["targetStrategy"] == "ForceIPv6"
assert xray_outbounds["direct-v6"]["settings"]["domainStrategy"] == "ForceIPv6"
assert xray["routing"]["domainStrategy"] == "IPIfNonMatch"
assert xray["routing"]["rules"][0]["outboundTag"] == "blocked"
assert "169.254.0.0/16" in xray["routing"]["rules"][0]["ip"]
assert "fc00::/7" in xray["routing"]["rules"][0]["ip"]
assert xray["routing"]["rules"][1] == {
    "type": "field", "network": "tcp", "port": 25, "outboundTag": "blocked"
}
assert xray["routing"]["rules"][2] == {
    "type": "field",
    "inboundTag": [
        "vless-reality-vision-v4-in", "vless-reality-xhttp-v4-in",
        "vless-reality-vision-v6-to-v4-in", "vless-reality-xhttp-v6-to-v4-in",
    ],
    "outboundTag": "direct-v4",
}
assert xray["routing"]["rules"][3] == {
    "type": "field",
    "inboundTag": [
        "vless-reality-vision-v6-in", "vless-reality-xhttp-v6-in",
        "vless-reality-vision-v4-to-v6-in", "vless-reality-xhttp-v4-to-v6-in",
    ],
    "outboundTag": "direct-v6",
}

for family, hysteria, address, mode, bind_field, listen in (
    ("v4", hysteria_v4, v4_address, 4, "bindIPv4", f"{v4_address}:21000-21127"),
    ("v6", hysteria_v6, v6_address, 6, "bindIPv6", f"[{v6_address}]:21000-21127"),
    ("v4-to-v6", hysteria_v4_to_v6, v6_address, 6, "bindIPv6",
     f'{v4_address}:{cross_ports["hysteria2_start"]}-{cross_ports["hysteria2_end"]}'),
    ("v6-to-v4", hysteria_v6_to_v4, v4_address, 4, "bindIPv4",
     f'[{v6_address}]:{cross_ports["hysteria2_start"]}-{cross_ports["hysteria2_end"]}'),
):
    assert hysteria["listen"] == listen
    assert hysteria["tls"] == {"cert": cert_path, "key": key_path}
    assert hysteria["auth"]["password"] == "test-hy2-password"
    assert hysteria["obfs"]["salamander"]["password"] == "test-hy2-obfs-password"
    assert hysteria["sniff"] == {
        "enable": True,
        "timeout": "1s",
        "rewriteDomain": False,
        "tcpPorts": "80,443",
        "udpPorts": "443",
    }
    if mode == 6:
        assert hysteria["resolver"] == {
            "type": "https",
            "https": {
                "addr": "[2606:4700:4700::1111]:443",
                "timeout": "10s",
                "sni": "cloudflare-dns.com",
                "insecure": False,
            },
        }
    else:
        assert "resolver" not in hysteria
    assert hysteria["outbounds"] == [{
        "name": "direct",
        "type": "direct",
        "direct": {"mode": mode, bind_field: address},
    }]
    assert "reject(169.254.0.0/16)" in hysteria["acl"]["inline"]
    assert "reject(fc00::/7)" in hysteria["acl"]["inline"]
    assert "reject(all, tcp/25)" in hysteria["acl"]["inline"]
    assert hysteria["acl"]["inline"][-1] == "direct(all)"
assert not (root / "etc/config/hysteria.yaml").exists()
assert caddy.count(f"tls {cert_path} {key_path}") == 4
assert "protocols h1 h2" in caddy
assert "mihomo-v4.yaml" in caddy and "mihomo-v6.yaml" in caddy
assert "sing-box-v4.json" in caddy and "sing-box-v6.json" in caddy
assert "sing-box-v4-to-v6.json" in caddy and "sing-box-v6-to-v4.json" in caddy
assert "https://v4.example.com" in caddy and "https://v6.example.com" in caddy
assert "handle /test-subscription-token/v4/mihomo.yaml" in caddy
assert "handle /test-subscription-token/v6/mihomo.yaml" in caddy
assert "handle /test-v4-to-v6-token/v4-to-v6/mihomo.yaml" in caddy
assert "handle /test-v6-to-v4-token/v6-to-v4/mihomo.yaml" in caddy
assert caddy.count("handle /test-subscription-token/mihomo.yaml") == 2
assert (
    "handle /test-subscription-token/v4/mihomo.yaml {\n"
    "\t\trewrite * /mihomo-v4.yaml"
) in caddy
assert (
    "handle /test-subscription-token/v6/mihomo.yaml {\n"
    "\t\trewrite * /mihomo-v6.yaml"
) in caddy
assert 'header Content-Type "text/yaml; charset=utf-8"' in caddy
assert caddy.count('header Content-Type "application/json; charset=utf-8"') == 6
PY

links="$(
  NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
    bash -c 'source "$1"; show_subscription_links' _ "$ROOT/lib/common.sh"
)"
[[ "$links" == *'https://example.com/test-subscription-token/v4/mihomo.yaml'* ]]
[[ "$links" == *'https://example.com/test-subscription-token/v6/mihomo.yaml'* ]]
[[ "$links" == *'https://example.com/test-subscription-token/v4/sing-box.json'* ]]
[[ "$links" == *'https://example.com/test-subscription-token/v6/sing-box.json'* ]]
[[ "$links" == *'https://example.com/test-v4-to-v6-token/v4-to-v6/mihomo.yaml'* ]]
[[ "$links" == *'https://example.com/test-v6-to-v4-token/v6-to-v4/sing-box.json'* ]]
[[ "$(grep -c '（严格）' <<< "$links")" == 16 ]]

qr_url='https://example.com/test-subscription-token/v4/mihomo.yaml'
printf '%s' "$qr_url" \
  | "$QRC" --output-format unicode --invert \
    --ec-level M --scale 1 --border 4 > "$WORK/subscription-qr.unicode"
python3 "$ROOT/tests/unicode-qr-to-pbm.py" \
  < "$WORK/subscription-qr.unicode" > "$WORK/subscription-qr.pbm"
decoded_qr="$(
  zbarimg --quiet --raw "$WORK/subscription-qr.pbm" 2>/dev/null
)"
[[ "$decoded_qr" == "$qr_url" ]]
bash "$ROOT/tests/panel-qrcode.sh"
bash "$ROOT/tests/panel-route-guide.sh"
bash "$ROOT/tests/panel-third-party.sh"
bash "$ROOT/tests/route-diagnostics.sh"
SING_BOX_BIN="$SING_BOX" XRAY_BIN="$XRAY" \
  bash "$ROOT/tests/default-anyreality-install.sh"
SING_BOX_BIN="$SING_BOX" bash "$ROOT/tests/experimental-anyreality.sh"
