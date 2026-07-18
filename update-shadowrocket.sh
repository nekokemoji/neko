#!/usr/bin/env bash

# In-place upgrade for an existing Neko installation.  It changes only the
# subscription renderer/state metadata and leaves protocol credentials, ports,
# certificates and server binaries untouched.

set -Eeuo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
NEKO_UPDATE_TMP_DIR="${NEKO_UPDATE_TMP_DIR:-/var/tmp}"
NEKO_UPDATE_LOCK_FILE="${NEKO_UPDATE_LOCK_FILE:-/run/lock/neko-shadowrocket-update.lock}"
INSTALLED_LIB="${NEKO_LIBEXEC}/lib"
INSTALLED_COMMON="${INSTALLED_LIB}/common.sh"
INSTALLED_RENDER="${INSTALLED_LIB}/render.sh"
INSTALLED_VERSIONS="${NEKO_LIBEXEC}/versions.env"
SUB_FILE="${NEKO_ETC}/subscriptions/shadowrocket.txt"
BACKUP_DIR=""
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_STATE NEKO_USER

# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

die_update() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

cleanup_backup() {
  local base="${NEKO_UPDATE_TMP_DIR%/}"
  if [[ -n "$BACKUP_DIR" && "$BACKUP_DIR" == "$base"/neko-shadowrocket-backup.* ]]; then
    rm -rf -- "$BACKUP_DIR"
  fi
}

regenerate() (
  set -Eeuo pipefail
  # shellcheck disable=SC1090
  source "$INSTALLED_COMMON"
  # shellcheck disable=SC1090
  source "$INSTALLED_RENDER"
  render_all
)

validate_installed_configs() {
  "$NEKO_LIBEXEC/sing-box" check -c "$NEKO_ETC/config/sing-box.json"
  "$NEKO_LIBEXEC/xray" run -test -c "$NEKO_ETC/config/xray.json"
  "$NEKO_LIBEXEC/caddy" validate \
    --config "$NEKO_ETC/config/Caddyfile" --adapter caddyfile >/dev/null
}

rollback() {
  local rc=$?
  trap - ERR
  set +e
  printf '[注意] 更新未完成，正在恢复原渲染器、状态和订阅……\n' >&2
  cp -a -- "$BACKUP_DIR/common.sh" "$INSTALLED_COMMON"
  cp -a -- "$BACKUP_DIR/render.sh" "$INSTALLED_RENDER"
  cp -a -- "$BACKUP_DIR/versions.env" "$INSTALLED_VERSIONS"
  cp -a -- "$BACKUP_DIR/state.json" "$NEKO_STATE"
  regenerate
  cp -a -- "$BACKUP_DIR/shadowrocket.txt" "$SUB_FILE"
  "$NEKO_LIBEXEC/caddy" validate \
    --config "$NEKO_ETC/config/Caddyfile" --adapter caddyfile >/dev/null 2>&1
  systemctl restart neko-caddy.service
  cleanup_backup
  exit "$rc"
}

if (( EUID != 0 )) && [[ "${NEKO_UPDATE_TEST_MODE:-0}" != 1 ]]; then
  die_update "请使用 root 运行。"
fi
for command_name in flock jq getent systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die_update "系统缺少 ${command_name}。"
done
[[ -r "$NEKO_STATE" ]] || die_update "没有找到已安装的 Neko。"
[[ -r "$INSTALLED_COMMON" && -r "$INSTALLED_RENDER" && -r "$INSTALLED_VERSIONS" ]] \
  || die_update "已安装的 Neko 文件不完整。"
[[ -s "$SUB_FILE" ]] || die_update "没有找到当前 Shadowrocket 订阅。"
[[ -r "$SCRIPT_DIR/lib/common.sh" && -r "$SCRIPT_DIR/lib/render.sh" ]] \
  || die_update "更新包缺少 lib/common.sh 或 lib/render.sh。"
grep -Fq 'preferred_direct_address' "$SCRIPT_DIR/lib/common.sh" \
  || die_update "更新包不包含直连地址选择逻辑。"
grep -Fq 'SHADOWROCKET_SERVER' "$SCRIPT_DIR/lib/render.sh" \
  || die_update "更新包不包含 Shadowrocket 直连地址渲染逻辑。"
[[ -d "$NEKO_UPDATE_TMP_DIR" && -w "$NEKO_UPDATE_TMP_DIR" ]] \
  || die_update "更新临时目录不可写：${NEKO_UPDATE_TMP_DIR}"

domain="$(jq -er '.domain | select(type == "string" and length > 0)' "$NEKO_STATE")" \
  || die_update "state.json 缺少域名。"
shadowrocket_server="${NEKO_UPDATE_ENDPOINT_OVERRIDE:-}"
if [[ -z "$shadowrocket_server" ]]; then
  shadowrocket_server="$(preferred_direct_address "$domain")" \
    || die_update "无法为 ${domain} 选择直连 A/AAAA 地址。"
fi
is_safe_ip_literal "$shadowrocket_server" \
  || die_update "Shadowrocket 直连地址格式无效。"

mkdir -p -- "$(dirname -- "$NEKO_UPDATE_LOCK_FILE")"
exec 9>"$NEKO_UPDATE_LOCK_FILE"
flock -n 9 || die_update "另一个订阅更新进程正在运行。"

BACKUP_DIR="$(mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-shadowrocket-backup.XXXXXX")"
cp -a -- "$INSTALLED_COMMON" "$BACKUP_DIR/common.sh"
cp -a -- "$INSTALLED_RENDER" "$BACKUP_DIR/render.sh"
cp -a -- "$INSTALLED_VERSIONS" "$BACKUP_DIR/versions.env"
cp -a -- "$NEKO_STATE" "$BACKUP_DIR/state.json"
cp -a -- "$SUB_FILE" "$BACKUP_DIR/shadowrocket.txt"
trap rollback ERR

install -m 0644 "$SCRIPT_DIR/lib/common.sh" "$INSTALLED_COMMON"
install -m 0644 "$SCRIPT_DIR/lib/render.sh" "$INSTALLED_RENDER"
install -m 0644 "$SCRIPT_DIR/versions.env" "$INSTALLED_VERSIONS"

state_tmp="$(mktemp "${NEKO_STATE}.tmp.XXXXXX")"
jq --arg server "$shadowrocket_server" --arg release "$NEKO_RELEASE" \
  '.subscription.shadowrocket_server = $server | .release = $release' \
  "$NEKO_STATE" > "$state_tmp"
chmod 0600 "$state_tmp"
chown root:root "$state_tmp" 2>/dev/null || true
mv -f -- "$state_tmp" "$NEKO_STATE"

regenerate
validate_installed_configs
systemctl restart neko-caddy.service
systemctl is-active --quiet neko-caddy.service

trap - ERR
rm -f -- \
  "${NEKO_ETC}/subscriptions/shadowrocket.txt.before-ss2022-diagnostic" \
  "${NEKO_ETC}/subscriptions/shadowrocket.txt.before-all-protocol-diagnostic"
cleanup_backup
printf '[完成] 已升级到 Neko %s。\n' "$NEKO_RELEASE"
printf '[完成] Shadowrocket 六个节点使用直连地址 %s；HTTPS、SNI、证书和 REALITY 域名保持不变。\n' \
  "$shadowrocket_server"
printf '原有订阅 URL、协议端口、密码、UUID 和证书均未改变。\n'
