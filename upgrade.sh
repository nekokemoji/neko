#!/usr/bin/env bash

# Upgrade an existing Neko installation to the current address-family-aware
# layout. Protocol credentials, ports, installed families and subscription
# URLs are preserved. Every changed file, unit and certificate is backed up.

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
QRC_STAGE_DIR=""
QRC_STAGED_BINARY=""
NEXTTRACE_STAGE_DIR=""
NEXTTRACE_STAGED_BINARY=""
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

cleanup_qrc_stage() {
  local base="${NEKO_UPDATE_TMP_DIR%/}"
  [[ -n "$QRC_STAGE_DIR" ]] || return 0
  if [[ -n "$base" && "$QRC_STAGE_DIR" == "$base"/neko-qrc-stage.* ]]; then
    rm -rf -- "$QRC_STAGE_DIR"
    QRC_STAGE_DIR=""
    QRC_STAGED_BINARY=""
  fi
}

cleanup_nexttrace_stage() {
  local base="${NEKO_UPDATE_TMP_DIR%/}"
  [[ -n "$NEXTTRACE_STAGE_DIR" ]] || return 0
  if [[ -n "$base" \
    && "$NEXTTRACE_STAGE_DIR" == "$base"/neko-nexttrace-stage.* ]]; then
    rm -rf -- "$NEXTTRACE_STAGE_DIR"
    NEXTTRACE_STAGE_DIR=""
    NEXTTRACE_STAGED_BINARY=""
  fi
}

stage_optional_qrc() {
  local qrc_source="${NEKO_UPDATE_QRC_BINARY:-}"
  local qrc_asset qrc_archive qrc_help

  case "${ARCH_OVERRIDE:-$(uname -m)}" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *)
      warn "当前 CPU 没有匹配的 qrc；升级仍会继续，文字订阅链接不受影响。"
      return 0
      ;;
  esac
  export ARCH

  if ! QRC_STAGE_DIR="$(
      mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-qrc-stage.XXXXXX"
    )"; then
    QRC_STAGE_DIR=""
    warn "无法创建 qrc 临时目录；升级仍会继续，文字订阅链接不受影响。"
    return 0
  fi
  QRC_STAGED_BINARY="${QRC_STAGE_DIR}/qrc"

  if [[ -n "$qrc_source" ]]; then
    if [[ ! -x "$qrc_source" ]] \
      || ! install -m 0755 "$qrc_source" "$QRC_STAGED_BINARY"; then
      warn "测试提供的 qrc 不可用；升级仍会继续，文字订阅链接不受影响。"
      cleanup_qrc_stage
      return 0
    fi
  else
    for qrc_source in curl sha256sum tar install; do
      if ! command -v "$qrc_source" >/dev/null 2>&1; then
        warn "缺少 ${qrc_source}，无法更新可选 qrc；文字订阅链接不受影响。"
        cleanup_qrc_stage
        return 0
      fi
    done
    qrc_asset="qrc_${QRC_VERSION}_linux_${ARCH}.tar.gz"
    qrc_archive="${QRC_STAGE_DIR}/qrc.tar.gz"
    if ! download_optional_verified "qrc ${QRC_VERSION}" \
        "https://github.com/fumiyas/qrc/releases/download/v${QRC_VERSION}/${qrc_asset}" \
        "$(sha_for_arch QRC)" "$qrc_archive"; then
      cleanup_qrc_stage
      return 0
    fi
    if ! tar --no-same-owner -xzf "$qrc_archive" \
        -C "$QRC_STAGE_DIR" qrc \
      || [[ ! -f "$QRC_STAGED_BINARY" ]] \
      || ! chmod 0755 "$QRC_STAGED_BINARY"; then
      warn "qrc 准备失败；升级仍会继续，文字订阅链接不受影响。"
      cleanup_qrc_stage
      return 0
    fi
  fi

  if ! qrc_help="$("$QRC_STAGED_BINARY" --help 2>&1)" \
    || ! grep -Fq -- '--output-format=<auto|ansi|sixel|unicode>' \
      <<< "$qrc_help"; then
    warn "qrc 运行检查失败；升级仍会继续，文字订阅链接不受影响。"
    cleanup_qrc_stage
    return 0
  fi
  ok "可选终端二维码组件 qrc ${QRC_VERSION} 已校验。"
}

install_staged_qrc() {
  local qrc_tmp=""
  [[ -n "$QRC_STAGED_BINARY" && -x "$QRC_STAGED_BINARY" ]] || return 0
  if ! qrc_tmp="$(mktemp "${NEKO_LIBEXEC}/.qrc.tmp.XXXXXX")" \
    || ! install -m 0755 "$QRC_STAGED_BINARY" "$qrc_tmp" \
    || ! mv -f -- "$qrc_tmp" "$NEKO_LIBEXEC/qrc"; then
    [[ -z "$qrc_tmp" ]] || rm -f -- "$qrc_tmp"
    warn "qrc 安装失败；已保留原状态，文字订阅链接不受影响。"
    return 0
  fi
  ok "终端二维码组件已更新。"
}

stage_optional_nexttrace() {
  local nexttrace_source="${NEKO_UPDATE_NEXTTRACE_BINARY:-}"
  local nexttrace_asset nexttrace_version

  case "${ARCH_OVERRIDE:-$(uname -m)}" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *)
      warn "当前 CPU 没有匹配的 NextTrace；升级仍会继续，只跳过三网线路测试。"
      return 0
      ;;
  esac
  export ARCH

  if ! NEXTTRACE_STAGE_DIR="$(
      mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-nexttrace-stage.XXXXXX"
    )"; then
    NEXTTRACE_STAGE_DIR=""
    warn "无法创建 NextTrace 临时目录；升级仍会继续，只跳过三网线路测试。"
    return 0
  fi
  NEXTTRACE_STAGED_BINARY="${NEXTTRACE_STAGE_DIR}/nexttrace-tiny"

  if [[ -n "$nexttrace_source" ]]; then
    if [[ ! -x "$nexttrace_source" ]] \
      || ! install -m 0755 \
        "$nexttrace_source" "$NEXTTRACE_STAGED_BINARY"; then
      warn "测试提供的 NextTrace 不可用；升级仍会继续，只跳过三网线路测试。"
      cleanup_nexttrace_stage
      return 0
    fi
  else
    for nexttrace_source in curl sha256sum install; do
      if ! command -v "$nexttrace_source" >/dev/null 2>&1; then
        warn "缺少 ${nexttrace_source}，无法更新可选 NextTrace；只跳过三网线路测试。"
        cleanup_nexttrace_stage
        return 0
      fi
    done
    nexttrace_asset="nexttrace-tiny_linux_${ARCH}"
    if ! download_optional_verified "NextTrace Tiny ${NEXTTRACE_VERSION}" \
        "https://github.com/nxtrace/NTrace-core/releases/download/v${NEXTTRACE_VERSION}/${nexttrace_asset}" \
        "$(sha_for_arch NEXTTRACE)" "$NEXTTRACE_STAGED_BINARY"; then
      cleanup_nexttrace_stage
      return 0
    fi
    if ! chmod 0755 "$NEXTTRACE_STAGED_BINARY"; then
      warn "NextTrace 准备失败；升级仍会继续，只跳过三网线路测试。"
      cleanup_nexttrace_stage
      return 0
    fi
  fi

  nexttrace_version="$("$NEXTTRACE_STAGED_BINARY" --version 2>&1 || true)"
  if ! grep -Fq "NextTrace v${NEXTTRACE_VERSION}" \
      <<< "$nexttrace_version"; then
    warn "NextTrace 运行检查失败；升级仍会继续，只跳过三网线路测试。"
    cleanup_nexttrace_stage
    return 0
  fi
  ok "可选三网线路组件 NextTrace Tiny ${NEXTTRACE_VERSION} 已校验。"
}

install_staged_nexttrace() {
  local nexttrace_tmp=""
  [[ -n "$NEXTTRACE_STAGED_BINARY" \
    && -x "$NEXTTRACE_STAGED_BINARY" ]] || return 0
  if ! nexttrace_tmp="$(
      mktemp "${NEKO_LIBEXEC}/.nexttrace-tiny.tmp.XXXXXX"
    )" \
    || ! install -m 0755 "$NEXTTRACE_STAGED_BINARY" "$nexttrace_tmp" \
    || ! mv -f -- "$nexttrace_tmp" "$NEKO_LIBEXEC/nexttrace-tiny"; then
    [[ -z "$nexttrace_tmp" ]] || rm -f -- "$nexttrace_tmp"
    warn "NextTrace 安装失败；已保留原状态，只跳过三网线路测试。"
    return 0
  fi
  ok "三网线路检测组件已更新。"
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
    "$BACKUP_DIR/diagnostics.sh" "$NEKO_LIBEXEC/diagnostics.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/hysteria-dual.sh" "$NEKO_LIBEXEC/hysteria-dual.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/qrc" "$NEKO_LIBEXEC/qrc" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/nexttrace-tiny" \
    "$NEKO_LIBEXEC/nexttrace-tiny" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/neko-hysteria.service" \
    "$NEKO_SYSTEMD/neko-hysteria.service" || rollback_ok=0
  systemctl daemon-reload >/dev/null 2>&1 || rollback_ok=0
  systemctl restart \
    neko-caddy.service neko-sing-box.service neko-xray.service neko-hysteria.service \
    >/dev/null 2>&1 || rollback_ok=0
  if (( rollback_ok == 1 )); then
    cleanup_qrc_stage
    cleanup_nexttrace_stage
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
  cleanup_qrc_stage
  cleanup_nexttrace_stage
  cleanup_backup
  exit "$rc"
}

trap finish_upgrade EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_installed_configs() {
  "$NEKO_LIBEXEC/sing-box" check -c "$NEKO_ETC/config/sing-box.json" >/dev/null
  if network_mode_has_ipv4; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "$NEKO_ETC/subscriptions/sing-box-v4.json" >/dev/null
  fi
  if network_mode_has_ipv6; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "$NEKO_ETC/subscriptions/sing-box-v6.json" >/dev/null
  fi
  "$NEKO_LIBEXEC/xray" run -test -c "$NEKO_ETC/config/xray.json" >/dev/null
  "$NEKO_LIBEXEC/caddy" validate \
    --config "$NEKO_ETC/config/Caddyfile" --adapter caddyfile >/dev/null
}

certificate_has_strict_domains() {
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || return 1
  certificate_has_active_domains "$CERT_FILE"
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
    if network_mode_has_ipv4; then
      [[ -n "${NEKO_UPDATE_IPV4_OVERRIDE:-}" ]] \
        || die "当前模式的 IPv4 测试覆盖缺失。"
      is_ipv4_literal "$NEKO_UPDATE_IPV4_OVERRIDE" || die "IPv4 测试覆盖无效。"
      SUBSCRIPTION_IPV4_ADDRESS="$NEKO_UPDATE_IPV4_OVERRIDE"
    else
      SUBSCRIPTION_IPV4_ADDRESS=""
    fi
    if network_mode_has_ipv6; then
      [[ -n "${NEKO_UPDATE_IPV6_OVERRIDE:-}" ]] \
        || die "当前模式的 IPv6 测试覆盖缺失。"
      is_ipv6_literal "$NEKO_UPDATE_IPV6_OVERRIDE" || die "IPv6 测试覆盖无效。"
      SUBSCRIPTION_IPV6_ADDRESS="$NEKO_UPDATE_IPV6_OVERRIDE"
    else
      SUBSCRIPTION_IPV6_ADDRESS=""
    fi
  else
    ensure_dns_query_tool
    check_strict_stack_dns "$DOMAIN" "$NETWORK_MODE"
  fi
}

main() {
  local current_schema current_release certificate_domain service state_tmp
  local legacy_token
  local -a domain_args=()

  if (( EUID != 0 )) && [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    die "请使用 root 运行升级脚本。"
  fi
  require_commands flock jq openssl find cp systemctl stat env ip awk sed timeout

  # Serialize before reading mutable state.  Panel address-family operations,
  # token rotation and certificate renewal use the same lock.
  mkdir -p -- "$(dirname -- "$NEKO_UPDATE_LOCK_FILE")"
  exec 9>"$NEKO_UPDATE_LOCK_FILE"
  flock -n 9 || die "另一个 Neko 维护任务正在运行。"

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
    && -r "$SCRIPT_DIR/runtime/diagnostics.sh" \
    && -r "$SCRIPT_DIR/runtime/renew.sh" \
    && -r "$SCRIPT_DIR/runtime/hysteria-dual.sh" \
    && -r "$SCRIPT_DIR/systemd/neko-hysteria.service" ]] || die "升级包不完整。"
  [[ -d "$NEKO_SYSTEMD" && -w "$NEKO_SYSTEMD" ]] \
    || die "systemd 单元目录不可写：${NEKO_SYSTEMD}"
  [[ -d "$NEKO_UPDATE_TMP_DIR" && -w "$NEKO_UPDATE_TMP_DIR" ]] \
    || die "升级临时目录不可写：${NEKO_UPDATE_TMP_DIR}"
  stage_optional_qrc
  stage_optional_nexttrace

  current_schema="$(jq -er '.schema // 1 | select(type == "number")' "$NEKO_STATE")" \
    || die "state.json 缺少有效 schema。"
  current_release="$(jq -r '.release // "unknown"' "$NEKO_STATE")"
  (( current_schema == 1 || current_schema == 2 || current_schema == 3 )) \
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
  if (( current_schema == 3 )); then
    NETWORK_MODE="$(jq -r '.network.mode // empty' "$NEKO_STATE")"
    NETWORK_MODE="$(normalize_network_mode "$NETWORK_MODE")" \
      || die "state.json 中的网络安装模式无效。"
  else
    NETWORK_MODE="$NETWORK_MODE_DUAL"
  fi
  if [[ "$ACME_METHOD" == "$ACME_METHOD_CLOUDFLARE" ]]; then
    assert_cloudflare_dns_token_file
  fi
  resolve_strict_endpoints
  if [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    assert_network_mode_kernel "$NETWORK_MODE"
    assert_strict_addresses_local "$NETWORK_MODE"
  fi

  BACKUP_DIR="$(mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-upgrade-backup.XXXXXX")"
  cp -a -- "$NEKO_ETC" "$BACKUP_DIR/etc"
  cp -a -- "$NEKO_VAR/lego" "$BACKUP_DIR/lego"
  cp -a -- "$NEKO_LIBEXEC/lib" "$BACKUP_DIR/lib"
  cp -a -- "$NEKO_LIBEXEC/versions.env" "$BACKUP_DIR/versions.env"
  cp -a -- "$NEKO_LIBEXEC/panel.sh" "$BACKUP_DIR/panel.sh"
  cp -a -- "$NEKO_LIBEXEC/renew.sh" "$BACKUP_DIR/renew.sh"
  [[ ! -e "$NEKO_LIBEXEC/diagnostics.sh" ]] \
    || cp -a -- "$NEKO_LIBEXEC/diagnostics.sh" "$BACKUP_DIR/diagnostics.sh"
  [[ ! -e "$NEKO_LIBEXEC/hysteria-dual.sh" ]] \
    || cp -a -- "$NEKO_LIBEXEC/hysteria-dual.sh" "$BACKUP_DIR/hysteria-dual.sh"
  [[ ! -e "$NEKO_LIBEXEC/qrc" ]] \
    || cp -a -- "$NEKO_LIBEXEC/qrc" "$BACKUP_DIR/qrc"
  [[ ! -e "$NEKO_LIBEXEC/nexttrace-tiny" ]] \
    || cp -a -- \
      "$NEKO_LIBEXEC/nexttrace-tiny" "$BACKUP_DIR/nexttrace-tiny"
  [[ ! -e "$NEKO_SYSTEMD/neko-hysteria.service" ]] \
    || cp -a -- \
      "$NEKO_SYSTEMD/neko-hysteria.service" "$BACKUP_DIR/neko-hysteria.service"
  ROLLBACK_READY=1

  install -m 0644 "$SCRIPT_DIR/lib/common.sh" "$NEKO_LIBEXEC/lib/common.sh"
  install -m 0644 "$SCRIPT_DIR/lib/render.sh" "$NEKO_LIBEXEC/lib/render.sh"
  install -m 0644 "$SCRIPT_DIR/lib/firewall.sh" "$NEKO_LIBEXEC/lib/firewall.sh"
  install -m 0644 "$SCRIPT_DIR/versions.env" "$NEKO_LIBEXEC/versions.env"
  install -m 0755 "$SCRIPT_DIR/runtime/panel.sh" "$NEKO_LIBEXEC/panel.sh"
  install -m 0755 \
    "$SCRIPT_DIR/runtime/diagnostics.sh" "$NEKO_LIBEXEC/diagnostics.sh"
  install -m 0755 "$SCRIPT_DIR/runtime/renew.sh" "$NEKO_LIBEXEC/renew.sh"
  install -m 0755 \
    "$SCRIPT_DIR/runtime/hysteria-dual.sh" "$NEKO_LIBEXEC/hysteria-dual.sh"
  install_staged_qrc
  install_staged_nexttrace
  install -m 0644 \
    "$SCRIPT_DIR/systemd/neko-hysteria.service" \
    "$NEKO_SYSTEMD/neko-hysteria.service"
  systemctl daemon-reload

  state_tmp="$(mktemp "${NEKO_STATE}.tmp.XXXXXX")"
  legacy_token="$(jq -r '.subscription.token // empty' "$NEKO_STATE")"
  jq \
    --arg release "$NEKO_RELEASE" \
    --arg network_mode "$NETWORK_MODE" \
    --arg v4_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
    --arg v6_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
    --arg v4_address "$SUBSCRIPTION_IPV4_ADDRESS" \
    --arg v6_address "$SUBSCRIPTION_IPV6_ADDRESS" \
    --arg acme_method "$ACME_METHOD" \
    --arg legacy_token "$legacy_token" \
    '.schema = 3
     | .release = $release
     | .network = {mode: $network_mode}
     | .subscription.ipv4_token = (
         if $network_mode == "ipv4-only" or $network_mode == "dual"
         then (.subscription.ipv4_token // (
           if $legacy_token != "" then $legacy_token else null end
         ))
         else null end
       )
     | .subscription.ipv6_token = (
         if $network_mode == "ipv6-only" or $network_mode == "dual"
         then (.subscription.ipv6_token // (
           if $legacy_token != "" then $legacy_token else null end
         ))
         else null end
       )
     | .subscription.ipv4_domain = (
         if $network_mode == "ipv4-only" or $network_mode == "dual"
         then $v4_domain else null end
       )
     | .subscription.ipv6_domain = (
         if $network_mode == "ipv6-only" or $network_mode == "dual"
         then $v6_domain else null end
       )
     | .subscription.ipv4_address = (
         if $network_mode == "ipv4-only" or $network_mode == "dual"
         then $v4_address else null end
       )
     | .subscription.ipv6_address = (
         if $network_mode == "ipv6-only" or $network_mode == "dual"
         then $v6_address else null end
       )
     | del(.subscription.token)
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
      || die "测试证书不包含当前已安装地址族所需的全部域名。"
    domain_args=()
    while IFS= read -r certificate_domain; do
      domain_args+=(--domains "$certificate_domain")
    done < <(active_certificate_domains)
    run_lego_acme "$NEKO_LIBEXEC/lego" webroot run \
      --path "$NEKO_VAR/lego" \
      --email "$ACME_EMAIL" \
      "${domain_args[@]}" \
      --accept-tos \
      --key-type EC256 \
      --force-cert-domains \
      --renew-force \
      --no-random-sleep
  fi
  certificate_has_strict_domains \
    || die "升级后的证书没有覆盖当前已安装地址族所需的全部域名。"
  openssl x509 -in "$CERT_FILE" -noout -checkend 604800 >/dev/null \
    || die "升级后的证书有效期不足 7 天。"
  while IFS= read -r certificate_domain; do
    openssl x509 -in "$CERT_FILE" -noout -checkhost "$certificate_domain" >/dev/null \
      || die "升级后的证书不包含 ${certificate_domain}。"
  done < <(active_certificate_domains)
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
  cleanup_qrc_stage
  cleanup_nexttrace_stage
  cleanup_backup
  ok "已从 Neko ${current_release} 升级到 ${NEKO_RELEASE}。"
  show_subscription_links
  if (( current_schema == 1 )); then
    warn "旧的单域名订阅 URL 已停用；请在客户端导入新的严格 IPv4/IPv6 链接。"
  else
    info "原有严格订阅 URL 与已安装地址族均已保留。"
  fi
}

main "$@"
