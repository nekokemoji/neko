#!/usr/bin/env bash

# Upgrade an existing Neko 1.0.x/1.1.x installation to the current strict
# dual-stack layout. Protocol credentials, ports and subscription token are
# preserved. Every changed file, unit and certificate is backed up for rollback.

set -Eeuo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
NEKO_UPDATE_TMP_DIR="${NEKO_UPDATE_TMP_DIR:-/var/tmp}"
NEKO_UPDATE_LOCK_FILE="${NEKO_UPDATE_LOCK_FILE:-/run/lock/neko-maintenance.lock}"
BACKUP_DIR=""
ROLLBACK_READY=0
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

cleanup_backup() {
  local base="${NEKO_UPDATE_TMP_DIR%/}"
  if [[ -n "$BACKUP_DIR" && "$BACKUP_DIR" == "$base"/neko-upgrade-backup.* ]]; then
    rm -rf -- "$BACKUP_DIR"
  fi
}

restore_tree() {
  local backup="$1" target="$2"
  [[ -e "$backup" ]] || return 0
  rm -rf -- "$target"
  cp -a -- "$backup" "$target"
}

restore_optional_file() {
  local backup="$1" target="$2"
  if [[ -e "$backup" ]]; then
    cp -a -- "$backup" "$target"
  else
    rm -f -- "$target"
  fi
}

rollback_upgrade() {
  local rc="$1" rollback_ok=1
  set +e
  warn "升级未完成，正在恢复升级前的状态、证书和配置……"
  restore_tree "$BACKUP_DIR/etc" "$NEKO_ETC" || rollback_ok=0
  restore_tree "$BACKUP_DIR/lego" "$NEKO_VAR/lego" || rollback_ok=0
  restore_tree "$BACKUP_DIR/lib" "$NEKO_LIBEXEC/lib" || rollback_ok=0
  cp -a -- "$BACKUP_DIR/versions.env" "$NEKO_LIBEXEC/versions.env" || rollback_ok=0
  cp -a -- "$BACKUP_DIR/panel.sh" "$NEKO_LIBEXEC/panel.sh" || rollback_ok=0
  cp -a -- "$BACKUP_DIR/renew.sh" "$NEKO_LIBEXEC/renew.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/hysteria-dual.sh" "$NEKO_LIBEXEC/hysteria-dual.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/neko-hysteria.service" \
    "$NEKO_SYSTEMD/neko-hysteria.service" || rollback_ok=0
  systemctl daemon-reload >/dev/null 2>&1 || rollback_ok=0
  systemctl restart \
    neko-caddy.service neko-sing-box.service neko-xray.service neko-hysteria.service \
    >/dev/null 2>&1 || rollback_ok=0
  if (( rollback_ok == 1 )); then
    cleanup_backup
  else
    warn "自动恢复未完全成功；为防止数据丢失，备份保留在 ${BACKUP_DIR}。"
  fi
  exit "$rc"
}

finish_upgrade() {
  local rc=$?
  trap - EXIT ERR INT TERM
  if (( rc != 0 && ROLLBACK_READY == 1 )); then
    rollback_upgrade "$rc"
  fi
  cleanup_backup
  exit "$rc"
}

trap finish_upgrade EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_installed_configs() {
  "$NEKO_LIBEXEC/sing-box" check -c "$NEKO_ETC/config/sing-box.json" >/dev/null
  "$NEKO_LIBEXEC/xray" run -test -c "$NEKO_ETC/config/xray.json" >/dev/null
  "$NEKO_LIBEXEC/caddy" validate \
    --config "$NEKO_ETC/config/Caddyfile" --adapter caddyfile >/dev/null
}

certificate_has_strict_domains() {
  local certificate_domain
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || return 1
  for certificate_domain in \
    "$DOMAIN" "$SUBSCRIPTION_DOMAIN_IPV4" "$SUBSCRIPTION_DOMAIN_IPV6"; do
    openssl x509 -in "$CERT_FILE" -noout -checkhost "$certificate_domain" \
      >/dev/null 2>&1 || return 1
  done
}

set_certificate_permissions() {
  if [[ "${NEKO_UPDATE_TEST_MODE:-0}" == "1" ]]; then
    find "$NEKO_VAR/lego" -type d -exec chmod 0700 {} +
    find "$NEKO_VAR/lego" -type f -exec chmod 0600 {} +
    chmod 0750 "$NEKO_VAR/lego"
    find "$NEKO_VAR/lego/certificates" -type d -exec chmod 0750 {} +
    find "$NEKO_VAR/lego/certificates" -type f -exec chmod 0640 {} +
    return 0
  fi
  chown -R root:root "$NEKO_VAR/lego"
  find "$NEKO_VAR/lego" -type d -exec chmod 0700 {} +
  find "$NEKO_VAR/lego" -type f -exec chmod 0600 {} +
  chown "root:${NEKO_USER}" "$NEKO_VAR/lego"
  chmod 0750 "$NEKO_VAR/lego"
  chown -R "root:${NEKO_USER}" "$NEKO_VAR/lego/certificates"
  find "$NEKO_VAR/lego/certificates" -type d -exec chmod 0750 {} +
  find "$NEKO_VAR/lego/certificates" -type f -exec chmod 0640 {} +
}

resolve_strict_endpoints() {
  derive_subscription_domains "$DOMAIN"
  if [[ -n "${NEKO_UPDATE_IPV4_OVERRIDE:-}" || -n "${NEKO_UPDATE_IPV6_OVERRIDE:-}" ]]; then
    [[ -n "${NEKO_UPDATE_IPV4_OVERRIDE:-}" && -n "${NEKO_UPDATE_IPV6_OVERRIDE:-}" ]] \
      || die "测试覆盖必须同时提供 IPv4 与 IPv6 地址。"
    is_ipv4_literal "$NEKO_UPDATE_IPV4_OVERRIDE" || die "IPv4 测试覆盖无效。"
    is_ipv6_literal "$NEKO_UPDATE_IPV6_OVERRIDE" || die "IPv6 测试覆盖无效。"
    SUBSCRIPTION_IPV4_ADDRESS="$NEKO_UPDATE_IPV4_OVERRIDE"
    SUBSCRIPTION_IPV6_ADDRESS="$NEKO_UPDATE_IPV6_OVERRIDE"
  else
    check_strict_dual_stack_dns "$DOMAIN"
  fi
}

main() {
  local current_schema current_release certificate_domain service state_tmp

  if (( EUID != 0 )) && [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    die "请使用 root 运行升级脚本。"
  fi
  require_commands flock jq openssl find cp systemctl stat env ip
  [[ -r "$NEKO_STATE" ]] || die "没有找到已安装的 Neko：${NEKO_STATE}"
  [[ -d "$NEKO_ETC/config" && -d "$NEKO_ETC/subscriptions" ]] \
    || die "现有 Neko 配置或订阅目录不完整。"
  [[ -d "$NEKO_VAR/lego" ]] || die "现有 Neko 证书目录不完整。"
  [[ -r "$NEKO_LIBEXEC/lib/common.sh" && -r "$NEKO_LIBEXEC/lib/render.sh" \
    && -r "$NEKO_LIBEXEC/lib/firewall.sh" && -r "$NEKO_LIBEXEC/versions.env" \
    && -r "$NEKO_LIBEXEC/panel.sh" && -r "$NEKO_LIBEXEC/renew.sh" ]] \
    || die "现有 Neko 程序文件不完整。"
  for service in sing-box xray hysteria caddy lego; do
    [[ -x "$NEKO_LIBEXEC/$service" ]] || die "现有核心缺失：${service}"
  done
  [[ -r "$SCRIPT_DIR/lib/common.sh" && -r "$SCRIPT_DIR/lib/render.sh" \
    && -r "$SCRIPT_DIR/lib/firewall.sh" && -r "$SCRIPT_DIR/runtime/panel.sh" \
    && -r "$SCRIPT_DIR/runtime/renew.sh" \
    && -r "$SCRIPT_DIR/runtime/hysteria-dual.sh" \
    && -r "$SCRIPT_DIR/systemd/neko-hysteria.service" ]] || die "升级包不完整。"
  [[ -d "$NEKO_SYSTEMD" && -w "$NEKO_SYSTEMD" ]] \
    || die "systemd 单元目录不可写：${NEKO_SYSTEMD}"
  [[ -d "$NEKO_UPDATE_TMP_DIR" && -w "$NEKO_UPDATE_TMP_DIR" ]] \
    || die "升级临时目录不可写：${NEKO_UPDATE_TMP_DIR}"

  current_schema="$(jq -er '.schema // 1 | select(type == "number")' "$NEKO_STATE")" \
    || die "state.json 缺少有效 schema。"
  current_release="$(jq -r '.release // "unknown"' "$NEKO_STATE")"
  (( current_schema == 1 || current_schema == 2 )) \
    || die "不支持从 state schema ${current_schema} 升级。"
  DOMAIN="$(jq -er '.domain | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die "state.json 缺少域名。"
  ACME_EMAIL="$(jq -er '.acme_email | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die "state.json 缺少 ACME 邮箱。"
  validate_domain "$DOMAIN" || die "state.json 中的域名无效。"
  validate_email "$ACME_EMAIL" || die "state.json 中的 ACME 邮箱无效。"
  ACME_METHOD="$(jq -r '.acme.method // "http-01"' "$NEKO_STATE")"
  ACME_METHOD="$(normalize_acme_method "$ACME_METHOD")" \
    || die "state.json 中的 ACME 验证方式无效。"
  if [[ "$ACME_METHOD" == "$ACME_METHOD_CLOUDFLARE" ]]; then
    assert_cloudflare_dns_token_file
  fi
  resolve_strict_endpoints
  if [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    assert_dual_stack_kernel
    assert_strict_addresses_local
  fi

  mkdir -p -- "$(dirname -- "$NEKO_UPDATE_LOCK_FILE")"
  exec 9>"$NEKO_UPDATE_LOCK_FILE"
  flock -n 9 || die "另一个 Neko 维护任务正在运行。"

  BACKUP_DIR="$(mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-upgrade-backup.XXXXXX")"
  cp -a -- "$NEKO_ETC" "$BACKUP_DIR/etc"
  cp -a -- "$NEKO_VAR/lego" "$BACKUP_DIR/lego"
  cp -a -- "$NEKO_LIBEXEC/lib" "$BACKUP_DIR/lib"
  cp -a -- "$NEKO_LIBEXEC/versions.env" "$BACKUP_DIR/versions.env"
  cp -a -- "$NEKO_LIBEXEC/panel.sh" "$BACKUP_DIR/panel.sh"
  cp -a -- "$NEKO_LIBEXEC/renew.sh" "$BACKUP_DIR/renew.sh"
  [[ ! -e "$NEKO_LIBEXEC/hysteria-dual.sh" ]] \
    || cp -a -- "$NEKO_LIBEXEC/hysteria-dual.sh" "$BACKUP_DIR/hysteria-dual.sh"
  [[ ! -e "$NEKO_SYSTEMD/neko-hysteria.service" ]] \
    || cp -a -- \
      "$NEKO_SYSTEMD/neko-hysteria.service" "$BACKUP_DIR/neko-hysteria.service"
  ROLLBACK_READY=1

  install -m 0644 "$SCRIPT_DIR/lib/common.sh" "$NEKO_LIBEXEC/lib/common.sh"
  install -m 0644 "$SCRIPT_DIR/lib/render.sh" "$NEKO_LIBEXEC/lib/render.sh"
  install -m 0644 "$SCRIPT_DIR/lib/firewall.sh" "$NEKO_LIBEXEC/lib/firewall.sh"
  install -m 0644 "$SCRIPT_DIR/versions.env" "$NEKO_LIBEXEC/versions.env"
  install -m 0755 "$SCRIPT_DIR/runtime/panel.sh" "$NEKO_LIBEXEC/panel.sh"
  install -m 0755 "$SCRIPT_DIR/runtime/renew.sh" "$NEKO_LIBEXEC/renew.sh"
  install -m 0755 \
    "$SCRIPT_DIR/runtime/hysteria-dual.sh" "$NEKO_LIBEXEC/hysteria-dual.sh"
  install -m 0644 \
    "$SCRIPT_DIR/systemd/neko-hysteria.service" \
    "$NEKO_SYSTEMD/neko-hysteria.service"
  systemctl daemon-reload

  state_tmp="$(mktemp "${NEKO_STATE}.tmp.XXXXXX")"
  jq \
    --arg release "$NEKO_RELEASE" \
    --arg v4_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
    --arg v6_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
    --arg v4_address "$SUBSCRIPTION_IPV4_ADDRESS" \
    --arg v6_address "$SUBSCRIPTION_IPV6_ADDRESS" \
    --arg acme_method "$ACME_METHOD" \
    '.schema = 2
     | .release = $release
     | .network.listen_address = "::"
     | .subscription.ipv4_domain = $v4_domain
     | .subscription.ipv6_domain = $v6_domain
     | .subscription.ipv4_address = $v4_address
     | .subscription.ipv6_address = $v6_address
     | del(.subscription.shadowrocket_server)
     | .acme = {method: $acme_method}
     | .firewall.zones = (
         if (.firewall.zones | type) == "array" then .firewall.zones
         elif (.firewall.zone // "") != "" then [.firewall.zone]
         else [] end
       )' "$NEKO_STATE" > "$state_tmp"
  chmod 0600 "$state_tmp"
  chown root:root "$state_tmp" 2>/dev/null || true
  mv -f -- "$state_tmp" "$NEKO_STATE"

  # shellcheck source=lib/render.sh
  source "$NEKO_LIBEXEC/lib/render.sh"
  render_all
  rm -f -- \
    "$NEKO_ETC/subscriptions/mihomo.yaml" \
    "$NEKO_ETC/subscriptions/stash.yaml" \
    "$NEKO_ETC/subscriptions/shadowrocket.txt" \
    "$NEKO_ETC/subscriptions/shadowrocket.txt.before-ss2022-diagnostic" \
    "$NEKO_ETC/subscriptions/shadowrocket.txt.before-all-protocol-diagnostic"
  validate_installed_configs
  systemctl restart neko-caddy.service
  systemctl is-active --quiet neko-caddy.service

  load_state
  if ! certificate_has_strict_domains; then
    [[ "${NEKO_UPDATE_SKIP_ACME:-0}" != "1" ]] \
      || die "测试证书不包含三个严格双栈域名。"
    run_lego_acme "$NEKO_LIBEXEC/lego" webroot run \
      --path "$NEKO_VAR/lego" \
      --email "$ACME_EMAIL" \
      --domains "$DOMAIN" \
      --domains "$SUBSCRIPTION_DOMAIN_IPV4" \
      --domains "$SUBSCRIPTION_DOMAIN_IPV6" \
      --accept-tos \
      --key-type EC256 \
      --force-cert-domains \
      --renew-force \
      --no-random-sleep
  fi
  certificate_has_strict_domains || die "升级后的证书没有覆盖三个域名。"
  openssl x509 -in "$CERT_FILE" -noout -checkend 604800 >/dev/null \
    || die "升级后的证书有效期不足 7 天。"
  for certificate_domain in \
    "$DOMAIN" "$SUBSCRIPTION_DOMAIN_IPV4" "$SUBSCRIPTION_DOMAIN_IPV6"; do
    openssl x509 -in "$CERT_FILE" -noout -checkhost "$certificate_domain" >/dev/null \
      || die "升级后的证书不包含 ${certificate_domain}。"
  done
  set_certificate_permissions

  render_all
  validate_installed_configs
  systemctl restart \
    neko-caddy.service neko-sing-box.service neko-xray.service neko-hysteria.service
  if [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    sleep 2
  fi
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    systemctl is-active --quiet "${service}.service" || die "${service} 升级后未保持运行。"
  done

  ROLLBACK_READY=0
  cleanup_backup
  ok "已从 Neko ${current_release} 升级到 ${NEKO_RELEASE}。"
  show_subscription_links
  warn "旧的单域名订阅 URL 已停用；请在客户端删除旧订阅并导入对应的严格 IPv4/IPv6 链接。"
}

main "$@"
