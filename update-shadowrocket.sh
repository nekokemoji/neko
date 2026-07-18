#!/usr/bin/env bash

set -Eeuo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_LIB=/usr/local/libexec/neko/lib
INSTALLED_RENDER=${INSTALLED_LIB}/render.sh
BACKUP_DIR=""

die_update() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

cleanup_backup() {
  if [[ -n "$BACKUP_DIR" && "$BACKUP_DIR" == /var/tmp/neko-shadowrocket-backup.* ]]; then
    rm -rf -- "$BACKUP_DIR"
  fi
}

regenerate() {
  # shellcheck disable=SC1091
  source "${INSTALLED_LIB}/common.sh"
  # shellcheck disable=SC1091
  source "$INSTALLED_RENDER"
  render_all
}

rollback() {
  local rc=$?
  trap - ERR
  set +e
  printf '[注意] 更新未完成，正在恢复原订阅生成器……\n' >&2
  install -m 0644 "$BACKUP_DIR/render.sh" "$INSTALLED_RENDER"
  regenerate
  /usr/local/libexec/neko/caddy validate \
    --config /etc/neko/config/Caddyfile --adapter caddyfile >/dev/null 2>&1
  systemctl restart neko-caddy.service
  cleanup_backup
  exit "$rc"
}

(( EUID == 0 )) || die_update "请使用 root 运行。"
command -v flock >/dev/null 2>&1 || die_update "系统缺少 flock。"
[[ -r /etc/neko/state.json ]] || die_update "没有找到已安装的 Neko。"
[[ -r "$INSTALLED_RENDER" && -r "${INSTALLED_LIB}/common.sh" ]] \
  || die_update "已安装的 Neko 文件不完整。"
[[ -r "$SCRIPT_DIR/lib/render.sh" ]] || die_update "更新包缺少 lib/render.sh。"
grep -Fq 'port-range:' "$SCRIPT_DIR/lib/render.sh" \
  || die_update "更新包不包含 Shadowrocket 结构化订阅。"

exec 9>/run/lock/neko-shadowrocket-update.lock
flock -n 9 || die_update "另一个订阅更新进程正在运行。"

BACKUP_DIR="$(mktemp -d /var/tmp/neko-shadowrocket-backup.XXXXXX)"
cp -a -- "$INSTALLED_RENDER" "$BACKUP_DIR/render.sh"
trap rollback ERR

install -m 0644 "$SCRIPT_DIR/lib/render.sh" "$INSTALLED_RENDER"
regenerate

/usr/local/libexec/neko/sing-box check -c /etc/neko/config/sing-box.json
/usr/local/libexec/neko/xray run -test -c /etc/neko/config/xray.json
/usr/local/libexec/neko/caddy validate \
  --config /etc/neko/config/Caddyfile --adapter caddyfile >/dev/null
systemctl restart neko-caddy.service
systemctl is-active --quiet neko-caddy.service

trap - ERR
cleanup_backup
printf '[完成] Shadowrocket 订阅已切换为 2.2.90 结构化 YAML；订阅 URL 不变。\n'
