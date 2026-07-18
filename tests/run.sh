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
shadow = base64.b64decode((root / "etc/subscriptions/shadowrocket.txt").read_text()).decode().splitlines()

assert len(mihomo["proxies"]) == 6
assert len(stash["proxies"]) == 5
assert all(p["network"] != "xhttp" for p in stash["proxies"] if p["type"] == "vless")
stash_hy2 = next(p for p in stash["proxies"] if p["type"] == "hysteria2")
stash_tuic = next(p for p in stash["proxies"] if p["type"] == "tuic")
stash_vision = next(p for p in stash["proxies"] if p["type"] == "vless")
assert stash_hy2["auth"] == "test-hy2-password" and "password" not in stash_hy2
assert stash_tuic["version"] == 5
assert stash_vision["sni"] == "example.com" and "servername" not in stash_vision
assert [line.split(":", 1)[0] for line in shadow] == [
    "hysteria2", "tuic", "ss", "anytls", "vless", "vless"
]
assert "type=xhttp" in shadow[-1]

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
PY

links="$(
  NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" NEKO_STATE="$WORK/etc/state.json" NEKO_USER=root \
    bash -c 'source "$1"; show_subscription_links' _ "$ROOT/lib/common.sh"
)"
[[ "$links" == *'https://example.com/test-subscription-token/mihomo.yaml'* ]]

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
