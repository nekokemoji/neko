#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
XRAY="$TOOLS/xray"
SING_BOX="$TOOLS/sing-box"
HYSTERIA="$TOOLS/hysteria"
CADDY="$TOOLS/caddy"
LEGO="$TOOLS/lego"
MIHOMO="${MIHOMO_BIN:-$TOOLS/mihomo}"

for binary in "$XRAY" "$SING_BOX" "$HYSTERIA" "$CADDY" "$LEGO" "$MIHOMO"; do
  [[ -x "$binary" ]] || {
    printf '缺少测试工具 %s；先运行 tests/fetch-pinned-tools.sh。\n' "$binary" >&2
    exit 1
  }
done

source "$ROOT/versions.env"

printf '[1/8] Bash 语法、ShellCheck 与 Python YAML……\n'
mapfile -t shell_files <<< "$(find "$ROOT" -type f -name '*.sh' -print | sort)"
bash -n "${shell_files[@]}"
command -v shellcheck >/dev/null 2>&1 \
  || { printf '缺少必需测试工具 shellcheck。\n' >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 \
  || { printf '缺少必需 Python 模块 PyYAML。\n' >&2; exit 1; }
# Dynamic library sourcing and cross-file globals are intentional.
shellcheck -x -e SC1090,SC1091,SC2016,SC2034 "${shell_files[@]}"

printf '[2/8] 发行版、架构、DNS 与防火墙区域逻辑……\n'
bash "$ROOT/tests/platform-matrix.sh"
bash -c '
  set -Eeuo pipefail
  source "$1"
  calls=0
  apt-get() { ((calls += 1)); }
  OS_FAMILY=debian install_dependencies >/dev/null
  [[ "$calls" == 2 ]]
' _ "$ROOT/lib/common.sh"
bash -c '
  set -Eeuo pipefail
  source "$1"
  calls=0
  microdnf() { ((calls += 1)); [[ "$1" == "-y" && "$2" == "install" ]]; }
  OS_FAMILY=rhel install_dependencies >/dev/null
  [[ "$calls" == 1 ]]
' _ "$ROOT/lib/common.sh"
bash -c '
  set -Eeuo pipefail
  source "$1"
  resolved_ipv4_addresses() {
    case "$1" in
      example.com|v4.example.com) printf "192.0.2.44\n" ;;
    esac
  }
  resolved_ipv6_addresses() {
    case "$1" in
      example.com|v6.example.com) printf "2001:db8::44\n" ;;
    esac
  }
  check_strict_dual_stack_dns example.com >/dev/null 2>&1
  [[ "$SUBSCRIPTION_DOMAIN_IPV4" == "v4.example.com" ]]
  [[ "$SUBSCRIPTION_DOMAIN_IPV6" == "v6.example.com" ]]
  [[ "$SUBSCRIPTION_IPV4_ADDRESS" == "192.0.2.44" ]]
  [[ "$SUBSCRIPTION_IPV6_ADDRESS" == "2001:db8::44" ]]
  is_safe_ip_literal 203.0.113.9
  is_safe_ip_literal 2001:db8::9
  ! is_safe_ip_literal 999.0.0.1
  ! is_safe_ip_literal "example.com"
' _ "$ROOT/lib/common.sh"
if bash -c '
  set -Eeuo pipefail
  source "$1"
  resolved_ipv4_addresses() {
    case "$1" in example.com|v4.example.com) printf "192.0.2.44\n" ;; esac
  }
  resolved_ipv6_addresses() {
    case "$1" in
      example.com|v6.example.com) printf "2001:db8::44\n" ;;
      v4.example.com) printf "2001:db8::99\n" ;;
    esac
  }
  check_strict_dual_stack_dns example.com
' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
  printf '严格 IPv4 域名带 AAAA 时没有被拒绝。\n' >&2
  exit 1
fi
if bash -c '
  set -Eeuo pipefail
  source "$1"
  resolved_ipv4_addresses() {
    case "$1" in
      example.com|v4.example.com) printf "192.0.2.44\n" ;;
      v6.example.com) printf "192.0.2.99\n" ;;
    esac
  }
  resolved_ipv6_addresses() {
    case "$1" in example.com|v6.example.com) printf "2001:db8::44\n" ;; esac
  }
  check_strict_dual_stack_dns example.com
' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
  printf '严格 IPv6 域名带 A 时没有被拒绝。\n' >&2
  exit 1
fi
bash -c '
  set -Eeuo pipefail
  source "$1"
  source "$2"
  firewall-cmd() {
    case "$1" in
      --get-default-zone) printf "public\n" ;;
      --get-zone-of-interface=eth0) printf "public\n" ;;
      --get-zone-of-interface=eth1) printf "public6\n" ;;
      *) return 1 ;;
    esac
  }
  ip() {
    case "$1:$2:$3:$4" in
      -4:route:show:default) printf "default via 192.0.2.1 dev eth0\n" ;;
      -6:route:show:default) printf "default via 2001:db8::1 dev eth1\n" ;;
    esac
  }
  zones="$(firewalld_target_zones)"
  [[ "$zones" == $'"'"'public\npublic6'"'"' ]]
' _ "$ROOT/lib/common.sh" "$ROOT/lib/firewall.sh"

printf '[3/8] 冻结版本身份与 lego v5 CLI……\n'
[[ "$("$XRAY" version)" == *"$XRAY_VERSION"* ]]
[[ "$("$SING_BOX" version)" == *"$SING_BOX_VERSION"* ]]
[[ "$("$HYSTERIA" version 2>&1)" == *"v${HYSTERIA_VERSION}"* ]]
[[ "$("$CADDY" version)" == *"v${CADDY_VERSION}"* ]]
[[ "$("$LEGO" --version)" == *"$LEGO_VERSION"* ]]
[[ "$("$MIHOMO" -v)" == *"${MIHOMO_VERSION}"* ]]
[[ "$("$LEGO" run --help 2>&1)" == *"--http.webroot"* ]]
[[ "$("$LEGO" run --help 2>&1)" == *"--dns"* ]]
if grep -R "releases/latest\|/latest/download" "$ROOT/install.sh" "$ROOT/tests/fetch-pinned-tools.sh"; then
  printf '发现未冻结的 latest 下载地址。\n' >&2
  exit 1
fi
grep -Fq 'NEKO_WORK_BASE=/var/tmp' "$ROOT/install.sh"
grep -Fq 'minimum_kib=$((768 * 1024))' "$ROOT/install.sh"
grep -Fq 'mktemp -d "${NEKO_WORK_BASE}/neko-install.XXXXXX"' "$ROOT/install.sh"
grep -Eq '^NEKO_SOURCE_COMMIT="[0-9a-f]{40}"$' "$ROOT/bootstrap.sh"
grep -Fq 'NEKO_RELEASE="1.1.1"' "$ROOT/versions.env"
grep -Fq -- '--force-cert-domains' "$ROOT/runtime/renew.sh"
grep -Fq -- '--renew-force' "$ROOT/upgrade.sh"
grep -Fq -- '--cloudflare-token-file' "$ROOT/install.sh"
grep -Fq -- '--dns cloudflare' "$ROOT/lib/common.sh"
if grep -Eq '\|[[:space:]]*head([[:space:]]|$)' "$ROOT/install.sh"; then
  printf '安装器包含可能在 pipefail 下触发 SIGPIPE 的 head 管道。\n' >&2
  exit 1
fi

ACME_WORK="$(mktemp -d "$ROOT/tests/acme.XXXXXX")"
mkdir -p "$ACME_WORK/bin"
cat > "$ACME_WORK/bin/lego-fake" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ -z "${CF_API_EMAIL:-}" ]]
[[ -z "${CF_API_KEY:-}" ]]
[[ -z "${CF_DNS_API_TOKEN:-}" ]]
[[ -z "${CF_ZONE_API_TOKEN:-}" ]]
[[ -z "${CF_API_EMAIL_FILE:-}" ]]
[[ -z "${CF_API_KEY_FILE:-}" ]]
[[ -z "${CF_ZONE_API_TOKEN_FILE:-}" ]]
[[ -z "${CF_BASE_URL:-}" ]]
[[ -z "${CF_BASE_URL_FILE:-}" ]]
[[ -z "${CLOUDFLARE_API_KEY:-}" ]]
[[ -z "${CLOUDFLARE_DNS_API_TOKEN:-}" ]]
[[ -z "${CLOUDFLARE_EMAIL:-}" ]]
[[ -z "${CLOUDFLARE_ZONE_API_TOKEN:-}" ]]
[[ -z "${CLOUDFLARE_BASE_URL:-}" ]]
[[ -z "${CLOUDFLARE_API_KEY_FILE:-}" ]]
[[ -z "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]]
[[ -z "${CLOUDFLARE_EMAIL_FILE:-}" ]]
[[ -z "${CLOUDFLARE_ZONE_API_TOKEN_FILE:-}" ]]
[[ -z "${CLOUDFLARE_BASE_URL_FILE:-}" ]]
printf '%s\n' "$@" > "$NEKO_TEST_ARGS_LOG"
printf '%s\n' "${CF_DNS_API_TOKEN_FILE:-}" > "$NEKO_TEST_ENV_LOG"
EOF
chmod 0755 "$ACME_WORK/bin/lego-fake"
printf '%s\n' 'test_Cloudflare-token_1234567890' > "$ACME_WORK/input-token"
chmod 0600 "$ACME_WORK/input-token"
NEKO_INSTALL_TEST_TOKEN_FILE="$ACME_WORK/input-token" bash -c '
  set -Eeuo pipefail
  unset CF_DNS_API_TOKEN CF_DNS_API_TOKEN_FILE \
    CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN_FILE
  source "$1"
  ACME_METHOD_INPUT=""
  CLOUDFLARE_TOKEN_SOURCE_FILE="$NEKO_INSTALL_TEST_TOKEN_FILE"
  collect_acme_settings
  [[ "$ACME_METHOD" == cloudflare-dns-01 ]]
  [[ "$CLOUDFLARE_DNS_TOKEN_INPUT" == test_Cloudflare-token_1234567890 ]]
' _ "$ROOT/install.sh"
if NEKO_INSTALL_TEST_TOKEN_FILE="$ACME_WORK/input-token" bash -c '
  set -Eeuo pipefail
  unset CF_DNS_API_TOKEN CF_DNS_API_TOKEN_FILE \
    CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN_FILE
  source "$1"
  ACME_METHOD_INPUT=http-01
  CLOUDFLARE_TOKEN_SOURCE_FILE="$NEKO_INSTALL_TEST_TOKEN_FILE"
  collect_acme_settings
' _ "$ROOT/install.sh" >/dev/null 2>&1; then
  printf 'HTTP-01 接受了不应使用的 Cloudflare Token。\n' >&2
  exit 1
fi
NEKO_VAR="$ACME_WORK/var" NEKO_TEST_MODE=1 \
  ACME_TEST_ROOT="$ACME_WORK" bash -c '
    set -Eeuo pipefail
    source "$1"
    token="test_Cloudflare-token_1234567890"
    validate_cloudflare_dns_token "$token"
    ! validate_cloudflare_dns_token short
    write_cloudflare_dns_token "$token"
    [[ "$(stat -c %a "$(dirname "$CLOUDFLARE_DNS_TOKEN_FILE")")" == 700 ]]
    [[ "$(stat -c %a "$CLOUDFLARE_DNS_TOKEN_FILE")" == 600 ]]
    chmod 0644 "$CLOUDFLARE_DNS_TOKEN_FILE"
    if (assert_cloudflare_dns_token_file >/dev/null 2>&1); then
      printf "权限过宽的 Cloudflare Token 文件未被拒绝。\n" >&2
      exit 1
    fi
    chmod 0600 "$CLOUDFLARE_DNS_TOKEN_FILE"
    assert_cloudflare_dns_token_file

    export NEKO_TEST_ARGS_LOG="$ACME_TEST_ROOT/dns-args"
    export NEKO_TEST_ENV_LOG="$ACME_TEST_ROOT/dns-env"
    ACME_METHOD=cloudflare-dns-01
    CF_DNS_API_TOKEN="must-not-leak"
    CF_ZONE_API_TOKEN_FILE="/must/not/leak"
    CLOUDFLARE_DNS_API_TOKEN_FILE="/must/not/leak-either"
    CLOUDFLARE_BASE_URL="https://attacker.invalid/"
    export CF_DNS_API_TOKEN CF_ZONE_API_TOKEN_FILE \
      CLOUDFLARE_DNS_API_TOKEN_FILE CLOUDFLARE_BASE_URL
    run_lego_acme "$ACME_TEST_ROOT/bin/lego-fake" standalone \
      run --domains example.com
    grep -Fxq -- "--dns" "$NEKO_TEST_ARGS_LOG"
    grep -Fxq cloudflare "$NEKO_TEST_ARGS_LOG"
    [[ "$(<"$NEKO_TEST_ENV_LOG")" == "$CLOUDFLARE_DNS_TOKEN_FILE" ]]
    ! grep -Eq "must-not-leak|$token" \
      "$NEKO_TEST_ARGS_LOG" "$NEKO_TEST_ENV_LOG"

    export NEKO_TEST_ARGS_LOG="$ACME_TEST_ROOT/http-args"
    export NEKO_TEST_ENV_LOG="$ACME_TEST_ROOT/http-env"
    ACME_METHOD=http-01
    unset CF_DNS_API_TOKEN CF_ZONE_API_TOKEN_FILE \
      CLOUDFLARE_DNS_API_TOKEN_FILE CLOUDFLARE_BASE_URL
    run_lego_acme "$ACME_TEST_ROOT/bin/lego-fake" webroot \
      run --domains example.com
    grep -Fxq -- "--http" "$NEKO_TEST_ARGS_LOG"
    grep -Fxq -- "--http.webroot" "$NEKO_TEST_ARGS_LOG"
    grep -Fxq "$NEKO_VAR/acme" "$NEKO_TEST_ARGS_LOG"
    [[ "$(<"$NEKO_TEST_ENV_LOG")" == "" ]]
  ' _ "$ROOT/lib/common.sh"
rm -rf -- "$ACME_WORK"

printf '[4/8] 渲染服务端配置与客户端订阅……\n'
WORK="$(mktemp -d "$ROOT/tests/run.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/etc" "$WORK/var/lego/certificates" "$WORK/var/acme"
cp "$ROOT/tests/fixtures/state.json" "$WORK/etc/state.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=example.com \
  -addext 'subjectAltName=DNS:example.com,DNS:v4.example.com,DNS:v6.example.com' \
  -keyout "$WORK/var/lego/certificates/example.com.key" \
  -out "$WORK/var/lego/certificates/example.com.crt" >/dev/null 2>&1

root_dir_name="${ROOT##*/}"
tar --exclude="${root_dir_name}/tests/run.*" \
  -czf "$WORK/bootstrap-source.tar.gz" -C "$ROOT/.." "$root_dir_name"
mkdir -p "$WORK/bootstrap-work"
NEKO_BOOTSTRAP_ARCHIVE="$WORK/bootstrap-source.tar.gz" \
  NEKO_BOOTSTRAP_WORK_BASE="$WORK/bootstrap-work" NEKO_BOOTSTRAP_TEST_MODE=1 \
  bash "$ROOT/bootstrap.sh" > "$WORK/bootstrap.log"
grep -Fq '[测试] Bootstrap 已成功校验固定安装包。' "$WORK/bootstrap.log"
if find "$WORK/bootstrap-work" -mindepth 1 -maxdepth 1 -name 'neko-bootstrap.*' | grep -q .; then
  printf 'Bootstrap 没有清理临时源码目录。\n' >&2
  exit 1
fi

NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
  bash -c 'source "$1"; source "$2"; render_all' \
  _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

printf '[5/8] 用真实冻结核心校验配置……\n'
"$SING_BOX" check -c "$WORK/etc/config/sing-box.json"
"$XRAY" run -test -c "$WORK/etc/config/xray.json"
"$CADDY" validate --config "$WORK/etc/config/Caddyfile" --adapter caddyfile >/dev/null
mkdir -p "$WORK/mihomo-v4" "$WORK/mihomo-v6"
"$MIHOMO" -d "$WORK/mihomo-v4" -t -f "$WORK/etc/subscriptions/mihomo-v4.yaml"
"$MIHOMO" -d "$WORK/mihomo-v6" -t -f "$WORK/etc/subscriptions/mihomo-v6.yaml"
set +e
PATH=/nonexistent "$HYSTERIA" server --disable-update-check \
  --config "$WORK/etc/config/hysteria.yaml" >"$WORK/hysteria-check.log" 2>&1
hysteria_rc=$?
set -e
(( hysteria_rc != 0 ))
grep -Fq 'executable file not found' "$WORK/hysteria-check.log"

printf '[6/8] 校验严格订阅、出口策略、端口和 REALITY 目标……\n'
bash -c '
  set -Eeuo pipefail
  source "$1"
  for ((round = 0; round < 50; round++)); do
    initialize_port_reservations
    reserve_random_range 128 range_start range_end
    reserve_random_port tuic
    reserve_random_port ss
    reserve_random_port anytls
    reserve_random_port vision
    reserve_random_port xhttp
    declare -A seen=()
    for ((port = range_start; port <= range_end; port++)); do seen[$port]=1; done
    for port in "$tuic" "$ss" "$anytls" "$vision" "$xhttp"; do
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
hysteria = yaml.safe_load((root / "etc/config/hysteria.yaml").read_text())
caddy = (root / "etc/config/Caddyfile").read_text()

expected_subscription_files = {
    "mihomo-v4.yaml", "mihomo-v6.yaml",
    "stash-v4.yaml", "stash-v6.yaml",
    "shadowrocket-v4.txt", "shadowrocket-v6.txt",
}
assert {p.name for p in (root / "etc/subscriptions").iterdir()} == expected_subscription_files

for family, address, ip_version in (
    ("v4", state["subscription"]["ipv4_address"], "ipv4"),
    ("v6", state["subscription"]["ipv6_address"], "ipv6"),
):
    mihomo = yaml.safe_load((root / f"etc/subscriptions/mihomo-{family}.yaml").read_text())
    stash = yaml.safe_load((root / f"etc/subscriptions/stash-{family}.yaml").read_text())
    shadow = yaml.safe_load((root / f"etc/subscriptions/shadowrocket-{family}.txt").read_text())

    assert len(mihomo["proxies"]) == 6
    assert all(p["server"] == address for p in mihomo["proxies"])
    assert all(p["ip-version"] == ip_version for p in mihomo["proxies"])
    assert len(stash["proxies"]) == 5
    assert all(p["server"] == address for p in stash["proxies"])
    assert all(p["network"] != "xhttp" for p in stash["proxies"] if p["type"] == "vless")
    stash_hy2 = next(p for p in stash["proxies"] if p["type"] == "hysteria2")
    stash_tuic = next(p for p in stash["proxies"] if p["type"] == "tuic")
    stash_vision = next(p for p in stash["proxies"] if p["type"] == "vless")
    assert stash_hy2["auth"] == "test-hy2-password" and "password" not in stash_hy2
    assert stash_tuic["version"] == 5
    assert stash_vision["sni"] == "example.com" and "servername" not in stash_vision

    shadow_proxies = shadow["proxies"]
    assert [p["type"] for p in shadow_proxies] == [
        "hysteria2", "tuic", "ss", "anytls", "vless", "vless"
    ]
    assert all(p["server"] == address for p in shadow_proxies)
    shadow_hy2, shadow_tuic, _, _, shadow_vision, shadow_xhttp = shadow_proxies
    assert shadow_hy2["port-range"] == "21000-21127"
    assert shadow_hy2["ports"] == "21000-21127"
    assert shadow_tuic["version"] == 5
    assert shadow_vision["network"] == "tcp"
    assert shadow_vision["reality-opts"]["public-key"] == state["reality"]["vision_public_key"]
    assert shadow_xhttp["network"] == "xhttp"
    assert shadow_xhttp["xhttp-opts"]["mode"] == "stream-one"
    assert shadow_xhttp["xhttp-opts"]["path"] == state["reality"]["xhttp_path"]

ports = state["ports"]
singles = [ports[k] for k in ("tuic", "ss2022", "anytls", "vless_reality_vision", "vless_reality_xhttp")]
assert len(set(singles)) == len(singles)
assert all(not (ports["hysteria2_start"] <= p <= ports["hysteria2_end"]) for p in singles)
assert ports["hysteria2_end"] - ports["hysteria2_start"] + 1 == 128

for inbound in xray["inbounds"]:
    reality = inbound["streamSettings"]["realitySettings"]
    assert reality["target"] == "127.0.0.1:8443"
    assert reality["serverNames"] == ["example.com"]
cert_path = str(root / "var/lego/certificates/example.com.crt")
key_path = str(root / "var/lego/certificates/example.com.key")
tls_inbounds = [i for i in sing["inbounds"] if "tls" in i]
assert all(i["tls"]["certificate_path"] == cert_path for i in tls_inbounds)
assert all(i["tls"]["key_path"] == key_path for i in tls_inbounds)
assert hysteria["tls"] == {"cert": cert_path, "key": key_path}
assert hysteria["auth"]["password"] == "test-hy2-password"
assert hysteria["obfs"]["salamander"]["password"] == "test-hy2-obfs-password"
assert sing["route"]["rules"][0] == {"ip_is_private": True, "action": "reject"}
assert sing["route"]["rules"][1] == {"network": "tcp", "port": 25, "action": "reject"}
assert {o["tag"]: o["protocol"] for o in xray["outbounds"]} == {
    "direct": "freedom", "blocked": "blackhole"
}
assert xray["routing"]["domainStrategy"] == "IPIfNonMatch"
assert xray["routing"]["rules"][0]["outboundTag"] == "blocked"
assert "169.254.0.0/16" in xray["routing"]["rules"][0]["ip"]
assert "fc00::/7" in xray["routing"]["rules"][0]["ip"]
assert xray["routing"]["rules"][1] == {
    "type": "field", "network": "tcp", "port": 25, "outboundTag": "blocked"
}
assert "reject(169.254.0.0/16)" in hysteria["acl"]["inline"]
assert "reject(fc00::/7)" in hysteria["acl"]["inline"]
assert "reject(all, tcp/25)" in hysteria["acl"]["inline"]
assert hysteria["acl"]["inline"][-1] == "direct(all)"
assert caddy.count(f"tls {cert_path} {key_path}") == 4
assert "protocols h1 h2" in caddy
assert "mihomo-v4.yaml" in caddy and "mihomo-v6.yaml" in caddy
assert "https://v4.example.com" in caddy and "https://v6.example.com" in caddy
assert 'header Content-Type "text/yaml; charset=utf-8"' in caddy
PY

links="$(
  NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
    bash -c 'source "$1"; show_subscription_links' _ "$ROOT/lib/common.sh"
)"
[[ "$links" == *'https://v4.example.com/test-subscription-token/mihomo.yaml'* ]]
[[ "$links" == *'https://v6.example.com/test-subscription-token/mihomo.yaml'* ]]
[[ "$(grep -c '（严格）' <<< "$links")" == 6 ]]

printf '[7/8] 模拟订阅令牌轮换，并检查 systemd 安全关键项……\n'
jq '.subscription.token = "replacement-token"' "$WORK/etc/state.json" > "$WORK/etc/state.new"
mv "$WORK/etc/state.new" "$WORK/etc/state.json"
NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
  bash -c 'source "$1"; source "$2"; render_all' \
  _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
grep -Fq '/replacement-token/mihomo.yaml' "$WORK/etc/config/Caddyfile"
if grep -Fq '/test-subscription-token/' "$WORK/etc/config/Caddyfile"; then
  printf '旧订阅令牌仍出现在 Caddy 配置中。\n' >&2
  exit 1
fi
grep -Fq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$ROOT/systemd/neko-sing-box.service"
grep -Fq 'AmbientCapabilities=CAP_NET_ADMIN' "$ROOT/systemd/neko-hysteria.service"
grep -Fq 'ReadWritePaths=/var/lib/neko' "$ROOT/systemd/neko-renew.service"
grep -Fq 'systemctl stop neko-renew.service' "$ROOT/runtime/panel.sh"

domain_gate_line="$(grep -n 'collect_identity' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
dependency_line="$(grep -n 'install_dependencies' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
lock_line="$(grep -n 'exec 9>/run/lock/neko-install.lock' "$ROOT/install.sh" | tail -n 1 | cut -d: -f1)"
(( domain_gate_line < dependency_line && dependency_line < lock_line ))

printf '[8/8] 模拟 1.0.x 原地升级成功与失败回滚……\n'
prepare_upgrade_install() {
  local target="$1"
  mkdir -p \
    "$target/etc/config" "$target/etc/subscriptions" \
    "$target/var/acme" "$target/libexec/lib" "$target/tmp"
  cp -a -- "$WORK/etc/config/." "$target/etc/config/"
  cp -a -- "$WORK/etc/subscriptions/mihomo-v4.yaml" \
    "$target/etc/subscriptions/mihomo.yaml"
  cp -a -- "$WORK/etc/subscriptions/stash-v4.yaml" \
    "$target/etc/subscriptions/stash.yaml"
  cp -a -- "$WORK/etc/subscriptions/shadowrocket-v4.txt" \
    "$target/etc/subscriptions/shadowrocket.txt"
  jq '
    .schema = 1
    | .release = "1.0.4-test"
    | del(.acme)
    | del(.network)
    | .subscription = {
        token: .subscription.token,
        shadowrocket_server: .subscription.ipv4_address
      }
    | .firewall = {manager: "none", zone: ""}
  ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  cp -a -- "$WORK/var/lego" "$target/var/lego"
  cp -a -- "$ROOT/lib/." "$target/libexec/lib/"
  cp -a -- "$ROOT/versions.env" "$target/libexec/versions.env"
  cp -a -- "$ROOT/runtime/panel.sh" "$ROOT/runtime/renew.sh" "$target/libexec/"
  ln -s "$SING_BOX" "$target/libexec/sing-box"
  ln -s "$XRAY" "$target/libexec/xray"
  ln -s "$CADDY" "$target/libexec/caddy"
  ln -s "$LEGO" "$target/libexec/lego"
}

run_upgrade() {
  local target="$1"
  shift
  env PATH="$ROOT/tests/helpers:$PATH" \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_LIBEXEC="$target/libexec" NEKO_STATE="$target/etc/state.json" \
    NEKO_USER=root NEKO_UPDATE_TMP_DIR="$target/tmp" \
    NEKO_UPDATE_LOCK_FILE="$target/upgrade.lock" \
    NEKO_UPDATE_TEST_MODE=1 NEKO_UPDATE_SKIP_ACME=1 \
    NEKO_UPDATE_IPV4_OVERRIDE=192.0.2.10 \
    NEKO_UPDATE_IPV6_OVERRIDE=2001:db8::10 \
    "$@" bash "$ROOT/upgrade.sh"
}

UPGRADE_OK="$WORK/upgrade-ok"
prepare_upgrade_install "$UPGRADE_OK"
run_upgrade "$UPGRADE_OK" > "$UPGRADE_OK/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_OK/etc/state.json")" == 2 ]]
[[ "$(jq -r '.release' "$UPGRADE_OK/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(jq -r '.subscription.ipv4_domain' "$UPGRADE_OK/etc/state.json")" == v4.example.com ]]
[[ "$(jq -r '.subscription.ipv6_domain' "$UPGRADE_OK/etc/state.json")" == v6.example.com ]]
[[ "$(jq -r '.subscription.shadowrocket_server // empty' "$UPGRADE_OK/etc/state.json")" == "" ]]
[[ "$(jq -r '.acme.method' "$UPGRADE_OK/etc/state.json")" == http-01 ]]
[[ "$(find "$UPGRADE_OK/etc/subscriptions" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 6 ]]
if find "$UPGRADE_OK/tmp" -maxdepth 1 -name 'neko-upgrade-backup.*' | grep -q .; then
  printf '升级成功后没有清理备份目录。\n' >&2
  exit 1
fi

UPGRADE_FAIL="$WORK/upgrade-fail"
prepare_upgrade_install "$UPGRADE_FAIL"
state_before="$(sha256sum "$UPGRADE_FAIL/etc/state.json" | awk '{print $1}')"
config_before="$(sha256sum "$UPGRADE_FAIL/etc/config/Caddyfile" | awk '{print $1}')"
set +e
run_upgrade "$UPGRADE_FAIL" \
  NEKO_TEST_SYSTEMCTL_FAIL_PATTERN='restart neko-caddy.service' \
  NEKO_TEST_SYSTEMCTL_FAIL_ONCE_FILE="$UPGRADE_FAIL/systemctl-failed-once" \
  > "$UPGRADE_FAIL/upgrade.log" 2>&1
upgrade_rc=$?
set -e
(( upgrade_rc != 0 ))
[[ "$(sha256sum "$UPGRADE_FAIL/etc/state.json" | awk '{print $1}')" == "$state_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/etc/config/Caddyfile" | awk '{print $1}')" == "$config_before" ]]
grep -Fq '正在恢复升级前的状态' "$UPGRADE_FAIL/upgrade.log"
if find "$UPGRADE_FAIL/tmp" -maxdepth 1 -name 'neko-upgrade-backup.*' | grep -q .; then
  printf '升级回滚后没有清理备份目录。\n' >&2
  exit 1
fi

printf '全部测试通过。\n'
