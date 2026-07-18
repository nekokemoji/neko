#!/usr/bin/env bash

set -Eeuo pipefail

NEKO_ETC=/etc/neko
NEKO_VAR=/var/lib/neko
NEKO_LIBEXEC=/usr/local/libexec/neko
NEKO_SYSTEMD=/etc/systemd/system
NEKO_STATE=/etc/neko/state.json
NEKO_USER=neko-proxy
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

source /usr/local/libexec/neko/lib/common.sh

require_root
require_commands flock sha256sum systemctl

exec 9>/run/lock/neko-renew.lock
flock -n 9 || exit 0

load_state
[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || die "证书文件缺失，无法续期。"

before_hash="$(sha256sum "$CERT_FILE" "$KEY_FILE" | sha256sum | awk '{print $1}')"

/usr/local/libexec/neko/lego run \
  --path "$NEKO_VAR/lego" \
  --email "$ACME_EMAIL" \
  --domains "$DOMAIN" \
  --accept-tos \
  --key-type EC256 \
  --http \
  --http.webroot "$NEKO_VAR/acme" \
  --no-random-sleep

chown -R root:root "$NEKO_VAR/lego"
find "$NEKO_VAR/lego" -type d -exec chmod 0700 {} +
find "$NEKO_VAR/lego" -type f -exec chmod 0600 {} +
chown "root:${NEKO_USER}" "$NEKO_VAR/lego"
chmod 0750 "$NEKO_VAR/lego"
chown -R "root:${NEKO_USER}" "$NEKO_VAR/lego/certificates"
find "$NEKO_VAR/lego/certificates" -type d -exec chmod 0750 {} +
find "$NEKO_VAR/lego/certificates" -type f -exec chmod 0640 {} +

after_hash="$(sha256sum "$CERT_FILE" "$KEY_FILE" | sha256sum | awk '{print $1}')"
if [[ "$after_hash" != "$before_hash" ]]; then
  systemctl restart neko-caddy.service
  systemctl restart neko-sing-box.service neko-hysteria.service neko-xray.service
  ok "证书已更新，相关服务已重启。"
else
  info "证书尚未进入续期窗口。"
fi
