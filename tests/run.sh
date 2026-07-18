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

for binary in "$XRAY" "$SING_BOX" "$HYSTERIA" "$CADDY" "$LEGO"; do
  [[ -x "$binary" ]] || {
    printf '缺少测试工具 %s；先运行 tests/fetch-pinned-tools.sh。\n' "$binary" >&2
    exit 1
  }
done

source "$ROOT/versions.env"

printf '[1/7] Bash 语法与可选 ShellCheck……\n'
mapfile -t shell_files <<< "$(find "$ROOT" -type f -name '*.sh' -print | sort)"
bash -n "${shell_files[@]}"
if command -v shellcheck >/dev/null 2>&1; then
  # Dynamic library sourcing and cross-file globals are intentional.
  shellcheck -x -e SC1090,SC1091,SC2016,SC2034 "${shell_files[@]}"
fi

printf '[2/7] 发行版与架构检测矩阵……\n'
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
  first_resolved_ipv4() { printf "192.0.2.44\n"; }
  first_resolved_ipv6() { printf "2001:db8::44\n"; }
  [[ "$(preferred_direct_address example.com)" == "192.0.2.44" ]]
  first_resolved_ipv4() { :; }
  [[ "$(preferred_direct_address example.com)" == "2001:db8::44" ]]
  is_safe_ip_literal 203.0.113.9
  is_safe_ip_literal 2001:db8::9
  ! is_safe_ip_literal 999.0.0.1
  ! is_safe_ip_literal "example.com"
' _ "$ROOT/lib/common.sh"

printf '[3/7] 冻结版本身份与 lego v5 CLI……\n'
[[ "$("$XRAY" version)" == *"$XRAY_VERSION"* ]]
[[ "$("$SING_BOX" version)" == *"$SING_BOX_VERSION"* ]]
[[ "$("$HYSTERIA" version 2>&1)" == *"v${HYSTERIA_VERSION}"* ]]
[[ "$("$CADDY" version)" == *"v${CADDY_VERSION}"* ]]
[[ "$("$LEGO" --version)" == *"$LEGO_VERSION"* ]]
[[ "$("$LEGO" run --help 2>&1)" == *"--http.webroot"* ]]
if grep -R "releases/latest\|/latest/download" "$ROOT/install.sh" "$ROOT/tests/fetch-pinned-tools.sh"; then
  printf '发现未冻结的 latest 下载地址。\n' >&2
  exit 1
fi
grep -Fq 'NEKO_WORK_BASE=/var/tmp' "$ROOT/install.sh"
grep -Fq 'minimum_kib=$((768 * 1024))' "$ROOT/install.sh"
grep -Fq 'mktemp -d "${NEKO_WORK_BASE}/neko-install.XXXXXX"' "$ROOT/install.sh"
if grep -Eq '\|[[:space:]]*head([[:space:]]|$)' "$ROOT/install.sh"; then
  printf '安装器包含可能在 pipefail 下触发 SIGPIPE 的 head 管道。\n' >&2
  exit 1
fi

printf '[4/7] 渲染服务端配置与客户端订阅……\n'
WORK="$(mktemp -d "$ROOT/tests/run.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/etc" "$WORK/var/lego/certificates" "$WORK/var/acme"
cp "$ROOT/tests/fixtures/state.json" "$WORK/etc/state.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -keyout "$WORK/var/lego/certificates/example.com.key" \
  -out "$WORK/var/lego/certificates/example.com.crt" >/dev/null 2>&1
NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
  bash -c 'source "$1"; source "$2"; render_all' \
  _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

printf '[5/7] 用真实冻结核心校验配置……\n'
"$SING_BOX" check -c "$WORK/etc/config/sing-box.json"
"$XRAY" run -test -c "$WORK/etc/config/xray.json"
"$CADDY" validate --config "$WORK/etc/config/Caddyfile" --adapter caddyfile >/dev/null
if [[ -x "$MIHOMO" ]]; then
  "$MIHOMO" -t -f "$WORK/etc/subscriptions/mihomo.yaml"
fi
set +e
PATH=/nonexistent "$HYSTERIA" server --disable-update-check \
  --config "$WORK/etc/config/hysteria.yaml" >"$WORK/hysteria-check.log" 2>&1
hysteria_rc=$?
set -e
(( hysteria_rc != 0 ))
grep -Fq 'executable file not found' "$WORK/hysteria-check.log"

printf '[6/7] 校验订阅节点、端口和 REALITY 自有证书目标……\n'
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
mihomo = yaml.safe_load((root / "etc/subscriptions/mihomo.yaml").read_text())
stash = yaml.safe_load((root / "etc/subscriptions/stash.yaml").read_text())
xray = json.loads((root / "etc/config/xray.json").read_text())
sing = json.loads((root / "etc/config/sing-box.json").read_text())
hysteria = yaml.safe_load((root / "etc/config/hysteria.yaml").read_text())
caddy = (root / "etc/config/Caddyfile").read_text()
shadow = yaml.safe_load((root / "etc/subscriptions/shadowrocket.txt").read_text())

assert len(mihomo["proxies"]) == 6
assert len(stash["proxies"]) == 5
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
assert all(
    p["server"] == state["subscription"]["shadowrocket_server"]
    for p in shadow_proxies
)
assert all(p["server"] == "example.com" for p in mihomo["proxies"])
assert all(p["server"] == "example.com" for p in stash["proxies"])
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
assert caddy.count(f"tls {cert_path} {key_path}") == 2
assert 'header Content-Type "text/yaml; charset=utf-8"' in caddy
PY

links="$(
  NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
    bash -c 'source "$1"; show_subscription_links' _ "$ROOT/lib/common.sh"
)"
[[ "$links" == *'https://example.com/test-subscription-token/mihomo.yaml'* ]]

cp "$WORK/etc/subscriptions/shadowrocket.txt" "$WORK/shadowrocket.before-diagnostic"
NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" \
  NEKO_TMP_DIR="$WORK" NEKO_DIAG_NO_CAPTURE=1 NEKO_DIAG_TEST_MODE=1 \
  bash "$ROOT/diagnose-shadowrocket-ss2022.sh" >/dev/null
base64 -d < "$WORK/etc/subscriptions/shadowrocket.txt" > "$WORK/shadowrocket-diagnostic.raw"
diagnostic_count="$(wc -l < "$WORK/shadowrocket-diagnostic.raw" | tr -d ' ')"
[[ "$diagnostic_count" == 5 || "$diagnostic_count" == 10 ]]
grep -Fq '#A-SIP002-Plain-Domain' "$WORK/shadowrocket-diagnostic.raw"
grep -Fq '#E-Legacy-FullB64-Domain' "$WORK/shadowrocket-diagnostic.raw"

# Exercise the real handoff: the all-protocol diagnostic must recover the
# structured source even while the SS2022 Base64 diagnostic is still active.
NEKO_ETC="$WORK/etc" NEKO_STATE="$WORK/etc/state.json" \
  NEKO_DIAG_ENDPOINT_OVERRIDE=198.51.100.20 NEKO_DIAG_NO_CAPTURE=1 NEKO_DIAG_TEST_MODE=1 \
  bash "$ROOT/diagnose-shadowrocket-all.sh" >/dev/null
python3 - "$WORK/etc/subscriptions/shadowrocket.txt" <<'PY'
import pathlib
import sys
import yaml

subscription = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
proxies = subscription["proxies"]
assert len(proxies) == 6
assert all(proxy["server"] == "198.51.100.20" for proxy in proxies)
assert all(
    proxy.get("sni", proxy.get("servername", "example.com")) == "example.com"
    for proxy in proxies
    if proxy["type"] in {"hysteria2", "tuic", "anytls", "vless"}
)
PY
NEKO_ETC="$WORK/etc" NEKO_STATE="$WORK/etc/state.json" NEKO_DIAG_TEST_MODE=1 \
  bash "$ROOT/diagnose-shadowrocket-all.sh" --restore >/dev/null
cmp -s "$WORK/shadowrocket.before-diagnostic" "$WORK/etc/subscriptions/shadowrocket.txt"
NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" \
  NEKO_TMP_DIR="$WORK" NEKO_DIAG_TEST_MODE=1 \
  bash "$ROOT/diagnose-shadowrocket-ss2022.sh" --restore >/dev/null
cmp -s "$WORK/shadowrocket.before-diagnostic" "$WORK/etc/subscriptions/shadowrocket.txt"

# Old state files without shadowrocket_server remain renderable and prefer
# IPv6 only when no IPv4 address is available.
jq 'del(.subscription.shadowrocket_server)' "$WORK/etc/state.json" > "$WORK/etc/state-old.json"
NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state-old.json" NEKO_USER=root \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    source "$2"
    first_resolved_ipv4() { :; }
    first_resolved_ipv6() { printf "2001:db8::55\n"; }
    render_all
    [[ "$SHADOWROCKET_SERVER" == "2001:db8::55" ]]
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
grep -Fq 'server: "2001:db8::55"' "$WORK/etc/subscriptions/shadowrocket.txt"

# Exercise the in-place updater in an isolated installation tree.
UPGRADE="$WORK/upgrade"
mkdir -p "$UPGRADE/etc/config" "$UPGRADE/etc/subscriptions" \
  "$UPGRADE/var/lego/certificates" "$UPGRADE/var/acme" \
  "$UPGRADE/libexec/lib" "$UPGRADE/mockbin"
cp "$ROOT/tests/fixtures/state.json" "$UPGRADE/etc/state.json"
cp "$ROOT/lib/common.sh" "$UPGRADE/libexec/lib/common.sh"
cp "$ROOT/lib/render.sh" "$UPGRADE/libexec/lib/render.sh"
cp "$ROOT/versions.env" "$UPGRADE/libexec/versions.env"
install -m 0755 "$XRAY" "$UPGRADE/libexec/xray"
install -m 0755 "$SING_BOX" "$UPGRADE/libexec/sing-box"
install -m 0755 "$CADDY" "$UPGRADE/libexec/caddy"
cp "$WORK/var/lego/certificates/example.com.crt" "$UPGRADE/var/lego/certificates/example.com.crt"
cp "$WORK/var/lego/certificates/example.com.key" "$UPGRADE/var/lego/certificates/example.com.key"
NEKO_ETC="$UPGRADE/etc" NEKO_VAR="$UPGRADE/var" NEKO_STATE="$UPGRADE/etc/state.json" \
  NEKO_LIBEXEC="$UPGRADE/libexec" NEKO_USER=root \
  bash -c 'source "$1"; source "$2"; render_all' \
  _ "$UPGRADE/libexec/lib/common.sh" "$UPGRADE/libexec/lib/render.sh"
install -m 0600 /dev/null "$UPGRADE/etc/subscriptions/shadowrocket.txt.before-ss2022-diagnostic"
install -m 0600 /dev/null "$UPGRADE/etc/subscriptions/shadowrocket.txt.before-all-protocol-diagnostic"
printf '#!/usr/bin/env bash\nexit 0\n' > "$UPGRADE/mockbin/systemctl"
chmod 0755 "$UPGRADE/mockbin/systemctl"
PATH="$UPGRADE/mockbin:$PATH" \
  NEKO_ETC="$UPGRADE/etc" NEKO_VAR="$UPGRADE/var" NEKO_STATE="$UPGRADE/etc/state.json" \
  NEKO_LIBEXEC="$UPGRADE/libexec" NEKO_USER=root \
  NEKO_UPDATE_TMP_DIR="$UPGRADE" NEKO_UPDATE_LOCK_FILE="$UPGRADE/update.lock" \
  NEKO_UPDATE_ENDPOINT_OVERRIDE=198.51.100.40 NEKO_UPDATE_TEST_MODE=1 \
  bash "$ROOT/update-shadowrocket.sh" >/dev/null
[[ "$(jq -r '.subscription.shadowrocket_server' "$UPGRADE/etc/state.json")" == "198.51.100.40" ]]
[[ "$(jq -r '.release' "$UPGRADE/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(grep -Fc 'server: "198.51.100.40"' "$UPGRADE/etc/subscriptions/shadowrocket.txt")" == 6 ]]
[[ ! -e "$UPGRADE/etc/subscriptions/shadowrocket.txt.before-ss2022-diagnostic" ]]
[[ ! -e "$UPGRADE/etc/subscriptions/shadowrocket.txt.before-all-protocol-diagnostic" ]]

cp "$UPGRADE/etc/state.json" "$UPGRADE/state.before-failed-update"
cp "$UPGRADE/etc/subscriptions/shadowrocket.txt" "$UPGRADE/shadowrocket.before-failed-update"
cat > "$UPGRADE/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == restart && ! -e "${NEKO_TEST_FAIL_MARKER:?}" ]]; then
  : > "$NEKO_TEST_FAIL_MARKER"
  exit 1
fi
exit 0
EOF
chmod 0755 "$UPGRADE/mockbin/systemctl"
set +e
PATH="$UPGRADE/mockbin:$PATH" NEKO_TEST_FAIL_MARKER="$UPGRADE/systemctl-failed-once" \
  NEKO_ETC="$UPGRADE/etc" NEKO_VAR="$UPGRADE/var" NEKO_STATE="$UPGRADE/etc/state.json" \
  NEKO_LIBEXEC="$UPGRADE/libexec" NEKO_USER=root \
  NEKO_UPDATE_TMP_DIR="$UPGRADE" NEKO_UPDATE_LOCK_FILE="$UPGRADE/update.lock" \
  NEKO_UPDATE_ENDPOINT_OVERRIDE=203.0.113.40 NEKO_UPDATE_TEST_MODE=1 \
  bash "$ROOT/update-shadowrocket.sh" >/dev/null 2>&1
failed_update_rc=$?
set -e
(( failed_update_rc != 0 ))
cmp -s "$UPGRADE/state.before-failed-update" "$UPGRADE/etc/state.json"
cmp -s "$UPGRADE/shadowrocket.before-failed-update" "$UPGRADE/etc/subscriptions/shadowrocket.txt"

printf '[7/7] 模拟订阅令牌轮换，并检查 systemd 安全关键项……\n'
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

printf '全部测试通过。\n'
