#!/usr/bin/env bash

set -Eeuo pipefail
umask 0077

NEKO_RENEW_TEST_MODE="${NEKO_RENEW_TEST_MODE:-0}"
if [[ "$NEKO_RENEW_TEST_MODE" == "1" ]]; then
  : "${NEKO_ETC:?NEKO_ETC is required in renewal test mode}"
  : "${NEKO_VAR:?NEKO_VAR is required in renewal test mode}"
  : "${NEKO_LIBEXEC:?NEKO_LIBEXEC is required in renewal test mode}"
  NEKO_SYSTEMD="${NEKO_SYSTEMD:-${NEKO_ETC}/systemd}"
  NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
  NEKO_USER="${NEKO_USER:-root}"
  NEKO_RENEW_LOCK_FILE="${NEKO_RENEW_LOCK_FILE:-${NEKO_VAR}/maintenance.lock}"
  NEKO_RENEW_BACKUP_ROOT="${NEKO_RENEW_BACKUP_ROOT:-${NEKO_VAR}/renew-backups}"
  NEKO_RENEW_SERVICE_WAIT_SECONDS="${NEKO_RENEW_SERVICE_WAIT_SECONDS:-0}"
else
  NEKO_ETC=/etc/neko
  NEKO_VAR=/var/lib/neko
  NEKO_LIBEXEC=/usr/local/libexec/neko
  NEKO_SYSTEMD=/etc/systemd/system
  NEKO_STATE=/etc/neko/state.json
  NEKO_USER=neko-proxy
  NEKO_RENEW_LOCK_FILE=/run/lock/neko-maintenance.lock
  NEKO_RENEW_BACKUP_ROOT=/var/lib/neko/renew-backups
  NEKO_RENEW_SERVICE_WAIT_SECONDS=2
fi
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

# shellcheck source=lib/common.sh
source "${NEKO_LIBEXEC}/lib/common.sh"

readonly NEKO_RENEW_MIN_VALIDITY_SECONDS=604800
readonly -a NEKO_RENEW_SERVICES=(
  neko-caddy
  neko-sing-box
  neko-hysteria
  neko-xray
)

declare -A NEKO_RENEW_ORIGINAL_SERVICE_ACTIVE=()
NEKO_RENEW_BACKUP_DIR=""
NEKO_RENEW_SNAPSHOT_READY=0
NEKO_RENEW_TRANSACTION_ACTIVE=0
NEKO_RENEW_COMMITTED=0

renewal_backup_dir_is_safe() {
  local directory="$1"
  local prefix="${NEKO_RENEW_BACKUP_ROOT%/}/neko-renew."
  local suffix="${directory#"$prefix"}"
  [[ "$directory" == "$prefix"* \
    && "$suffix" != "$directory" \
    && -n "$suffix" \
    && "$suffix" != */* ]]
}

prepare_renewal_backup_root() {
  local expected_owner=0
  [[ "$NEKO_RENEW_BACKUP_ROOT" == /* \
    && "$NEKO_RENEW_BACKUP_ROOT" != / ]] || return 1
  [[ ! -L "$NEKO_RENEW_BACKUP_ROOT" ]] || return 1
  if [[ "$NEKO_RENEW_TEST_MODE" == 1 ]]; then
    expected_owner="$EUID"
    install -d -m 0700 "$NEKO_RENEW_BACKUP_ROOT" || return 1
  else
    install -d -m 0700 -o root -g root "$NEKO_RENEW_BACKUP_ROOT" || return 1
  fi
  [[ ! -L "$NEKO_RENEW_BACKUP_ROOT" \
    && "$(stat -c %u "$NEKO_RENEW_BACKUP_ROOT")" == "$expected_owner" ]] \
    || return 1
  chmod 0700 "$NEKO_RENEW_BACKUP_ROOT"
}

cleanup_renewal_snapshot() {
  [[ -n "$NEKO_RENEW_BACKUP_DIR" ]] || return 0
  renewal_backup_dir_is_safe "$NEKO_RENEW_BACKUP_DIR" || return 1
  [[ ! -L "$NEKO_RENEW_BACKUP_DIR" ]] || return 1
  if [[ -d "$NEKO_RENEW_BACKUP_DIR" ]]; then
    rm -rf -- "$NEKO_RENEW_BACKUP_DIR" || return 1
  fi
  NEKO_RENEW_BACKUP_DIR=""
  NEKO_RENEW_SNAPSHOT_READY=0
}

certificate_pair_hash() {
  sha256sum "$CERT_FILE" "$KEY_FILE" | sha256sum | awk '{print $1}'
}

set_lego_permissions() {
  [[ -d "$NEKO_VAR/lego" && ! -L "$NEKO_VAR/lego" ]] || return 1
  [[ -d "$NEKO_VAR/lego/certificates" \
    && ! -L "$NEKO_VAR/lego/certificates" ]] || return 1
  if [[ "$NEKO_RENEW_TEST_MODE" != 1 ]]; then
    chown -R root:root "$NEKO_VAR/lego" || return 1
  fi
  find "$NEKO_VAR/lego" -type d -exec chmod 0700 {} + || return 1
  find "$NEKO_VAR/lego" -type f -exec chmod 0600 {} + || return 1
  if [[ "$NEKO_RENEW_TEST_MODE" != 1 ]]; then
    chown "root:${NEKO_USER}" "$NEKO_VAR/lego" || return 1
  fi
  chmod 0750 "$NEKO_VAR/lego" || return 1
  if [[ "$NEKO_RENEW_TEST_MODE" != 1 ]]; then
    chown -R "root:${NEKO_USER}" "$NEKO_VAR/lego/certificates" || return 1
  fi
  find "$NEKO_VAR/lego/certificates" -type d -exec chmod 0750 {} + || return 1
  find "$NEKO_VAR/lego/certificates" -type f -exec chmod 0640 {} +
}

snapshot_renewal_state() {
  local service original_state service_state service_state_rc
  prepare_renewal_backup_root || return 1
  NEKO_RENEW_BACKUP_DIR="$(
    mktemp -d "${NEKO_RENEW_BACKUP_ROOT%/}/neko-renew.XXXXXX"
  )" || return 1
  renewal_backup_dir_is_safe "$NEKO_RENEW_BACKUP_DIR" || return 1
  chmod 0700 "$NEKO_RENEW_BACKUP_DIR" || return 1
  cp -a -- "$NEKO_VAR/lego" "$NEKO_RENEW_BACKUP_DIR/lego" || return 1

  : > "$NEKO_RENEW_BACKUP_DIR/services"
  for service in "${NEKO_RENEW_SERVICES[@]}"; do
    service_state=""
    service_state_rc=0
    service_state="$(systemctl is-active "${service}.service" 2>/dev/null)" \
      || service_state_rc=$?
    original_state=0
    case "$service_state" in
      active) original_state=1 ;;
      inactive|failed) original_state=0 ;;
      *)
        warn "无法确认 ${service} 的续期前状态（退出码 ${service_state_rc}）。"
        return 1
        ;;
    esac
    NEKO_RENEW_ORIGINAL_SERVICE_ACTIVE["$service"]="$original_state"
    printf '%s=%s\n' "$service" "$original_state" \
      >> "$NEKO_RENEW_BACKUP_DIR/services"
  done
  printf 'snapshot=%s\ntarget=%s\n' \
    "$NEKO_RENEW_BACKUP_DIR/lego" "$NEKO_VAR/lego" \
    > "$NEKO_RENEW_BACKUP_DIR/RECOVERY"
  chmod 0600 \
    "$NEKO_RENEW_BACKUP_DIR/services" "$NEKO_RENEW_BACKUP_DIR/RECOVERY"
  NEKO_RENEW_SNAPSHOT_READY=1
}

validate_renewed_certificate() {
  local certificate_public_hash private_public_hash certificate_domain
  local subject_alternative_names
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || {
    warn "续期后的证书或私钥缺失。"
    return 1
  }
  openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || {
    warn "续期后的证书无法解析。"
    return 1
  }
  openssl pkey -in "$KEY_FILE" -passin pass: -noout >/dev/null 2>&1 || {
    warn "续期后的私钥无法解析。"
    return 1
  }
  certificate_public_hash="$(
    openssl x509 -in "$CERT_FILE" -pubkey -noout 2>/dev/null \
      | openssl pkey -pubin -outform DER 2>/dev/null \
      | sha256sum | awk '{print $1}'
  )" || return 1
  private_public_hash="$(
    openssl pkey -in "$KEY_FILE" -passin pass: -pubout -outform DER 2>/dev/null \
      | sha256sum | awk '{print $1}'
  )" || return 1
  [[ -n "$certificate_public_hash" \
    && "$certificate_public_hash" == "$private_public_hash" ]] || {
    warn "续期后的证书与私钥不匹配。"
    return 1
  }
  subject_alternative_names="$(
    openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null
  )" || return 1
  [[ "$subject_alternative_names" == *'DNS:'* ]] || {
    warn "续期后的证书没有 DNS SAN。"
    return 1
  }
  while IFS= read -r certificate_domain; do
    openssl verify -no-CAfile -no-CApath -partial_chain \
      -trusted "$CERT_FILE" -verify_hostname "$certificate_domain" "$CERT_FILE" \
      >/dev/null 2>&1 || {
        warn "续期后的证书不包含 ${certificate_domain}。"
        return 1
      }
  done < <(active_certificate_domains)
  openssl x509 -in "$CERT_FILE" -noout \
    -checkend "$NEKO_RENEW_MIN_VALIDITY_SECONDS" >/dev/null 2>&1 || {
      warn "续期后的证书有效期不足七天。"
      return 1
    }
}

validate_hysteria_server_config() {
  local config_file="$1" check_log check_rc=0
  [[ -s "$config_file" ]] || return 1
  check_log="$(mktemp "$NEKO_RENEW_BACKUP_DIR/hysteria-check.XXXXXX")" \
    || return 1
  if PATH=/nonexistent "$NEKO_LIBEXEC/hysteria" server \
      --disable-update-check --config "$config_file" \
      >"$check_log" 2>&1; then
    check_rc=0
  else
    check_rc=$?
  fi
  (( check_rc != 0 )) || return 1
  grep -Fq 'executable file not found' "$check_log"
}

validate_installed_runtime_configs() {
  local family
  "$NEKO_LIBEXEC/sing-box" check \
    -c "$NEKO_ETC/config/sing-box.json" >/dev/null 2>&1 || return 1
  if network_mode_has_ipv4; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "$NEKO_ETC/subscriptions/sing-box-v4.json" \
      >/dev/null 2>&1 || return 1
  fi
  if network_mode_has_ipv6; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "$NEKO_ETC/subscriptions/sing-box-v6.json" \
      >/dev/null 2>&1 || return 1
  fi
  if network_mode_has_cross_routes; then
    "$NEKO_LIBEXEC/sing-box" check \
      -c "$NEKO_ETC/subscriptions/sing-box-v4-to-v6.json" \
      >/dev/null 2>&1 || return 1
    "$NEKO_LIBEXEC/sing-box" check \
      -c "$NEKO_ETC/subscriptions/sing-box-v6-to-v4.json" \
      >/dev/null 2>&1 || return 1
  fi
  "$NEKO_LIBEXEC/xray" run -test \
    -c "$NEKO_ETC/config/xray.json" >/dev/null 2>&1 || return 1
  "$NEKO_LIBEXEC/caddy" validate \
    --config "$NEKO_ETC/config/Caddyfile" --adapter caddyfile \
    >/dev/null 2>&1 || return 1

  if network_mode_has_ipv4; then
    validate_hysteria_server_config \
      "$NEKO_ETC/config/hysteria-v4.yaml" || return 1
  fi
  if network_mode_has_ipv6; then
    validate_hysteria_server_config \
      "$NEKO_ETC/config/hysteria-v6.yaml" || return 1
  fi
  if network_mode_has_cross_routes; then
    for family in v4-to-v6 v6-to-v4; do
      validate_hysteria_server_config \
        "$NEKO_ETC/config/hysteria-${family}.yaml" || return 1
    done
  fi
}

restart_renewal_services() {
  local service
  for service in "${NEKO_RENEW_SERVICES[@]}"; do
    systemctl restart "${service}.service" || {
      warn "${service} 重启失败。"
      return 1
    }
    systemctl is-active --quiet "${service}.service" || {
      warn "${service} 重启后未保持运行。"
      return 1
    }
  done
  sleep "$NEKO_RENEW_SERVICE_WAIT_SECONDS"
  for service in "${NEKO_RENEW_SERVICES[@]}"; do
    systemctl is-active --quiet "${service}.service" || {
      warn "${service} 未通过重启后的健康检查。"
      return 1
    }
  done
}

restore_lego_snapshot() {
  local restore_stage failed_lego backup_name moved_current=0
  [[ "$NEKO_RENEW_SNAPSHOT_READY" == 1 \
    && -d "$NEKO_RENEW_BACKUP_DIR/lego" \
    && ! -L "$NEKO_RENEW_BACKUP_DIR/lego" ]] || return 1
  if [[ "$NEKO_RENEW_TEST_MODE" == 1 \
    && "${NEKO_RENEW_TEST_FAIL_ROLLBACK:-0}" == 1 ]]; then
    return 1
  fi

  backup_name="${NEKO_RENEW_BACKUP_DIR##*/}"
  restore_stage="${NEKO_VAR%/}/.lego-restore-${backup_name}"
  failed_lego="$NEKO_RENEW_BACKUP_DIR/failed-lego"
  [[ ! -e "$restore_stage" && ! -L "$restore_stage" \
    && ! -e "$failed_lego" && ! -L "$failed_lego" ]] || return 1
  cp -a -- "$NEKO_RENEW_BACKUP_DIR/lego" "$restore_stage" || return 1
  if [[ -e "$NEKO_VAR/lego" || -L "$NEKO_VAR/lego" ]]; then
    mv -- "$NEKO_VAR/lego" "$failed_lego" || return 1
    moved_current=1
  fi
  if mv -- "$restore_stage" "$NEKO_VAR/lego"; then
    return 0
  fi
  if (( moved_current == 1 )); then
    mv -- "$failed_lego" "$NEKO_VAR/lego" >/dev/null 2>&1 || true
  fi
  return 1
}

restore_original_service_states() {
  local service restore_failed=0
  for service in "${NEKO_RENEW_SERVICES[@]}"; do
    if [[ "${NEKO_RENEW_ORIGINAL_SERVICE_ACTIVE[$service]:-0}" == 1 ]]; then
      if ! systemctl restart "${service}.service" \
        || ! systemctl is-active --quiet "${service}.service"; then
        restore_failed=1
      fi
    else
      if ! systemctl stop "${service}.service"; then
        restore_failed=1
      elif systemctl is-active --quiet "${service}.service"; then
        restore_failed=1
      fi
    fi
  done
  sleep "$NEKO_RENEW_SERVICE_WAIT_SECONDS"
  for service in "${NEKO_RENEW_SERVICES[@]}"; do
    if [[ "${NEKO_RENEW_ORIGINAL_SERVICE_ACTIVE[$service]:-0}" == 1 ]]; then
      systemctl is-active --quiet "${service}.service" || restore_failed=1
    elif systemctl is-active --quiet "${service}.service"; then
      restore_failed=1
    fi
  done
  (( restore_failed == 0 ))
}

rollback_renewal_transaction() {
  local rollback_failed=0 recovery_path="$NEKO_RENEW_BACKUP_DIR/lego"
  warn "证书续期未提交，正在恢复续期前的完整状态。"
  if ! restore_lego_snapshot; then
    rollback_failed=1
  elif ! restore_original_service_states; then
    rollback_failed=1
  fi

  if (( rollback_failed == 0 )); then
    NEKO_RENEW_TRANSACTION_ACTIVE=0
    if cleanup_renewal_snapshot; then
      ok "证书、lego 状态和服务已恢复。"
      return 0
    fi
    rollback_failed=1
  fi

  warn "自动恢复未完全成功；续期前快照保留在：${recovery_path}"
  warn "请停止 Neko 服务，核对后将该快照恢复到：${NEKO_VAR}/lego"
  return 1
}

finish_renewal() {
  local rc=$?
  trap - EXIT
  trap '' HUP INT TERM
  if (( NEKO_RENEW_TRANSACTION_ACTIVE == 1 \
    && NEKO_RENEW_COMMITTED == 0 )); then
    rollback_renewal_transaction || rc=1
  elif (( NEKO_RENEW_COMMITTED == 0 )) \
    && [[ -n "$NEKO_RENEW_BACKUP_DIR" ]]; then
    cleanup_renewal_snapshot || rc=1
  fi
  exit "$rc"
}

if (( EUID != 0 )) && [[ "$NEKO_RENEW_TEST_MODE" != 1 ]]; then
  die "请使用 root 运行。"
fi
require_commands \
  awk chmod chown cp env find flock grep install mktemp mv openssl rm \
  sha256sum sleep stat systemctl timeout
[[ "$NEKO_RENEW_SERVICE_WAIT_SECONDS" =~ ^[0-9]+$ ]] \
  || die "续期服务健康检查等待时间无效。"

exec 9>"$NEKO_RENEW_LOCK_FILE"
flock -n 9 || exit 0

load_state
[[ -d "$NEKO_VAR/lego" && ! -L "$NEKO_VAR/lego" ]] \
  || die "lego 状态目录缺失或类型异常，无法续期。"
[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] \
  || die "证书文件缺失，无法续期。"

before_hash="$(certificate_pair_hash)"
domain_args=()
while IFS= read -r certificate_domain; do
  domain_args+=(--domains "$certificate_domain")
done < <(active_certificate_domains)

trap finish_renewal EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot_renewal_state || die "无法创建 root-only 的完整 lego 续期快照。"
NEKO_RENEW_TRANSACTION_ACTIVE=1

run_lego_acme "$NEKO_LIBEXEC/lego" webroot run \
  --path "$NEKO_VAR/lego" \
  --email "$ACME_EMAIL" \
  "${domain_args[@]}" \
  --accept-tos \
  --key-type EC256 \
  --force-cert-domains \
  --no-random-sleep

set_lego_permissions \
  || die "续期后的 lego 目录权限设置失败。"
validate_renewed_certificate \
  || die "续期后的证书与私钥校验失败。"
validate_installed_runtime_configs \
  || die "续期后的核心配置或订阅配置校验失败。"

after_hash="$(certificate_pair_hash)"
if [[ "$after_hash" != "$before_hash" ]]; then
  restart_renewal_services \
    || die "证书更新后的服务健康检查失败。"
  success_message="证书已更新，核心配置与服务健康检查通过。"
else
  success_message="证书尚未进入续期窗口；核心配置校验通过。"
fi

NEKO_RENEW_COMMITTED=1
NEKO_RENEW_TRANSACTION_ACTIVE=0
cleanup_renewal_snapshot \
  || die "续期已生效，但临时快照清理失败：${NEKO_RENEW_BACKUP_DIR}"
ok "$success_message"
