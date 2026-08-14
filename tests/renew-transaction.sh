#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-renew-transaction.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

readonly -a SERVICES=(
  neko-caddy.service
  neko-sing-box.service
  neko-hysteria.service
  neko-xray.service
)

ORIGINAL_CERT="$WORK/certificates/original.crt"
ORIGINAL_KEY="$WORK/certificates/original.key"
RENEWED_CERT="$WORK/certificates/renewed.crt"
RENEWED_KEY="$WORK/certificates/renewed.key"
MISMATCH_KEY="$WORK/certificates/mismatch.key"
WRONG_SAN_CERT="$WORK/certificates/wrong-san.crt"
WRONG_SAN_KEY="$WORK/certificates/wrong-san.key"
SHORT_CERT="$WORK/certificates/short.crt"
SHORT_KEY="$WORK/certificates/short.key"
CASE_DIR=""
CASE_RC=0
CASE_OUTPUT=""
CASE_ORIGINAL_MANIFEST=""

generate_certificate() {
  local certificate="$1" key="$2" days="${3:-30}"
  local san="${4:-DNS:example.com,DNS:v4.example.com,DNS:v6.example.com}"
  openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
    -subj /CN=example.com \
    -addext "subjectAltName=${san}" \
    -keyout "$key" -out "$certificate" >/dev/null 2>&1
}

tree_manifest() {
  local directory="$1" path metadata digest
  (
    cd -- "$directory"
    while IFS= read -r -d '' path; do
      metadata="$(stat -c '%F|%a|%u:%g' "$path")"
      digest="-"
      if [[ -f "$path" && ! -L "$path" ]]; then
        digest="$(sha256sum "$path" | awk '{print $1}')"
      elif [[ -L "$path" ]]; then
        digest="$(readlink "$path")"
      fi
      printf '%s|%s|%s\n' "$path" "$metadata" "$digest"
    done < <(find . -mindepth 1 -print0 | sort -z)
  )
}

prepare_case() {
  local name="$1" config_file service
  CASE_DIR="$WORK/$name"
  mkdir -p \
    "$CASE_DIR/bin" "$CASE_DIR/etc/config" "$CASE_DIR/etc/subscriptions" \
    "$CASE_DIR/libexec/lib" "$CASE_DIR/systemd" \
    "$CASE_DIR/var/lego/accounts" "$CASE_DIR/var/lego/certificates" \
    "$CASE_DIR/systemctl/active"

  cp -a -- "$ROOT/tests/fixtures/state.json" "$CASE_DIR/etc/state.json"
  cp -a -- "$ROOT/lib/common.sh" "$ROOT/lib/state.sh" "$CASE_DIR/libexec/lib/"
  install -m 0755 "$ROOT/tests/fixtures/renew-lego.sh" \
    "$CASE_DIR/libexec/lego"
  install -m 0755 "$ROOT/tests/fixtures/renew-systemctl.sh" \
    "$CASE_DIR/bin/systemctl"
  for config_file in sing-box caddy xray hysteria; do
    install -m 0755 "$ROOT/tests/fixtures/renew-core.sh" \
      "$CASE_DIR/libexec/$config_file"
  done

  printf '%s\n' '{}' > "$CASE_DIR/etc/config/sing-box.json"
  printf '%s\n' '{}' > "$CASE_DIR/etc/config/xray.json"
  printf '%s\n' 'test.example {' '}' > "$CASE_DIR/etc/config/Caddyfile"
  for config_file in v4 v6 v4-to-v6 v6-to-v4; do
    printf '%s\n' 'listen: :21000' \
      > "$CASE_DIR/etc/config/hysteria-${config_file}.yaml"
    printf '%s\n' '{}' \
      > "$CASE_DIR/etc/subscriptions/sing-box-${config_file}.json"
  done

  cp -a -- "$ORIGINAL_CERT" \
    "$CASE_DIR/var/lego/certificates/example.com.crt"
  cp -a -- "$ORIGINAL_KEY" \
    "$CASE_DIR/var/lego/certificates/example.com.key"
  printf '%s\n' 'original-account-state' \
    > "$CASE_DIR/var/lego/accounts/registration.json"
  printf '%s\n' 'complete-lego-state' \
    > "$CASE_DIR/var/lego/accounts/account.json"
  chmod 0750 "$CASE_DIR/var/lego" "$CASE_DIR/var/lego/certificates"
  chmod 0700 "$CASE_DIR/var/lego/accounts"
  chmod 0640 "$CASE_DIR/var/lego/certificates/"*
  chmod 0600 "$CASE_DIR/var/lego/accounts/"*

  for service in "${SERVICES[@]}"; do
    : > "$CASE_DIR/systemctl/active/$service"
  done
  : > "$CASE_DIR/core.log"
  : > "$CASE_DIR/lego.log"
  : > "$CASE_DIR/systemctl.log"
  CASE_ORIGINAL_MANIFEST="$(tree_manifest "$CASE_DIR/var/lego")"
}

run_renewal() {
  local action="$1" core_failure="${2:-}" service_failure="${3:-}"
  local rollback_failure="${4:-0}" output_file="$CASE_DIR/output.log"
  local test_certificate="${5:-$RENEWED_CERT}"
  local test_key="${6:-$RENEWED_KEY}"
  if env \
      PATH="$CASE_DIR/bin:/usr/bin:/bin" \
      NEKO_RENEW_TEST_MODE=1 \
      NEKO_ETC="$CASE_DIR/etc" \
      NEKO_VAR="$CASE_DIR/var" \
      NEKO_LIBEXEC="$CASE_DIR/libexec" \
      NEKO_SYSTEMD="$CASE_DIR/systemd" \
      NEKO_STATE="$CASE_DIR/etc/state.json" \
      NEKO_USER=root \
      NEKO_RENEW_LOCK_FILE="$CASE_DIR/maintenance.lock" \
      NEKO_RENEW_BACKUP_ROOT="$CASE_DIR/var/renew-backups" \
      NEKO_RENEW_SERVICE_WAIT_SECONDS=0 \
      NEKO_RENEW_TEST_LEGO_ACTION="$action" \
      NEKO_RENEW_TEST_CERT="$test_certificate" \
      NEKO_RENEW_TEST_KEY="$test_key" \
      NEKO_RENEW_TEST_MISMATCH_KEY="$MISMATCH_KEY" \
      NEKO_RENEW_TEST_LEGO_LOG="$CASE_DIR/lego.log" \
      NEKO_RENEW_TEST_CORE_LOG="$CASE_DIR/core.log" \
      NEKO_RENEW_TEST_CORE_FAIL="$core_failure" \
      NEKO_RENEW_TEST_SYSTEMCTL_STATE_DIR="$CASE_DIR/systemctl" \
      NEKO_RENEW_TEST_SYSTEMCTL_LOG="$CASE_DIR/systemctl.log" \
      NEKO_RENEW_TEST_SYSTEMCTL_FAIL_SERVICE="$service_failure" \
      NEKO_RENEW_TEST_FAIL_ROLLBACK="$rollback_failure" \
      bash "$ROOT/runtime/renew.sh" >"$output_file" 2>&1; then
    CASE_RC=0
  else
    CASE_RC=$?
  fi
  CASE_OUTPUT="$(<"$output_file")"
}

assert_no_snapshot() {
  local snapshots=()
  if [[ -d "$CASE_DIR/var/renew-backups" ]]; then
    mapfile -t snapshots < <(
      find "$CASE_DIR/var/renew-backups" -mindepth 1 -maxdepth 1 -type d
    )
  fi
  (( ${#snapshots[@]} == 0 ))
}

assert_all_services_active() {
  local service
  for service in "${SERVICES[@]}"; do
    [[ -f "$CASE_DIR/systemctl/active/$service" ]]
  done
}

assert_original_state_restored() {
  [[ "$(tree_manifest "$CASE_DIR/var/lego")" == "$CASE_ORIGINAL_MANIFEST" ]]
  assert_all_services_active
  assert_no_snapshot
}

restart_sequence() {
  awk '$1 == "restart" {print $2}' "$CASE_DIR/systemctl.log"
}

assert_complete_core_validation() {
  local config_file
  for config_file in \
    "$CASE_DIR/etc/config/sing-box.json" \
    "$CASE_DIR/etc/subscriptions/sing-box-v4.json" \
    "$CASE_DIR/etc/subscriptions/sing-box-v6.json" \
    "$CASE_DIR/etc/subscriptions/sing-box-v4-to-v6.json" \
    "$CASE_DIR/etc/subscriptions/sing-box-v6-to-v4.json"; do
    grep -Fq "sing-box check -c $config_file" "$CASE_DIR/core.log"
  done
  grep -Fq \
    "xray run -test -c $CASE_DIR/etc/config/xray.json" "$CASE_DIR/core.log"
  grep -Fq \
    "caddy validate --config $CASE_DIR/etc/config/Caddyfile --adapter caddyfile" \
    "$CASE_DIR/core.log"
  for config_file in v4 v6 v4-to-v6 v6-to-v4; do
    grep -Fq \
      "hysteria server --disable-update-check --config $CASE_DIR/etc/config/hysteria-${config_file}.yaml" \
      "$CASE_DIR/core.log"
  done
}

mkdir -p "$WORK/certificates"
generate_certificate "$ORIGINAL_CERT" "$ORIGINAL_KEY"
generate_certificate "$RENEWED_CERT" "$RENEWED_KEY"
generate_certificate "$WORK/certificates/mismatch.crt" "$MISMATCH_KEY"
generate_certificate "$WRONG_SAN_CERT" "$WRONG_SAN_KEY" 30 DNS:example.com
generate_certificate "$SHORT_CERT" "$SHORT_KEY" 1

printf '[续期事务] 无变化时完整验证但不重启……\n'
prepare_case nochange
run_renewal nochange
(( CASE_RC == 0 ))
[[ "$CASE_OUTPUT" == *'尚未进入续期窗口'* ]]
[[ "$(tree_manifest "$CASE_DIR/var/lego")" == "$CASE_ORIGINAL_MANIFEST" ]]
if grep -q '^restart ' "$CASE_DIR/systemctl.log"; then
  printf '无变化续期不应重启服务。\n' >&2
  exit 1
fi
assert_no_snapshot
assert_complete_core_validation

printf '[续期事务] lego 部分写入后失败时恢复完整状态……\n'
prepare_case lego-failure
run_renewal fail
(( CASE_RC == 29 ))
[[ "$CASE_OUTPUT" == *'状态和服务已恢复'* ]]
assert_original_state_restored

printf '[续期事务] 成功续期按固定顺序提交……\n'
prepare_case success
run_renewal renew
(( CASE_RC == 0 ))
[[ "$CASE_OUTPUT" == *'服务健康检查通过'* ]]
cmp -s "$RENEWED_CERT" "$CASE_DIR/var/lego/certificates/example.com.crt"
cmp -s "$RENEWED_KEY" "$CASE_DIR/var/lego/certificates/example.com.key"
grep -Fxq 'renewed-account-state' \
  "$CASE_DIR/var/lego/accounts/registration.json"
[[ -f "$CASE_DIR/var/lego/renewal-marker" ]]
[[ "$(stat -c %a "$CASE_DIR/var/lego")" == 750 ]]
[[ "$(stat -c %a "$CASE_DIR/var/lego/certificates/example.com.crt")" == 640 ]]
[[ "$(restart_sequence)" == $'neko-caddy.service\nneko-sing-box.service\nneko-hysteria.service\nneko-xray.service' ]]
grep -Fq -- '--force-cert-domains' "$CASE_DIR/lego.log"
grep -Fq -- '--no-random-sleep' "$CASE_DIR/lego.log"
if grep -Fq -- '--renew-force' "$CASE_DIR/lego.log"; then
  printf '常规续期不应强制重签证书。\n' >&2
  exit 1
fi
assert_all_services_active
assert_no_snapshot
assert_complete_core_validation

printf '[续期事务] 非法证书恢复完整 lego 树……\n'
prepare_case invalid-certificate
run_renewal invalid
(( CASE_RC != 0 ))
[[ "$CASE_OUTPUT" == *'证书无法解析'* && "$CASE_OUTPUT" == *'状态和服务已恢复'* ]]
assert_original_state_restored

printf '[续期事务] 证书与私钥不匹配时恢复……\n'
prepare_case mismatched-key
run_renewal mismatch
(( CASE_RC != 0 ))
[[ "$CASE_OUTPUT" == *'证书与私钥不匹配'* ]]
assert_original_state_restored

printf '[续期事务] 严格 SAN 缺失时恢复……\n'
prepare_case missing-san
run_renewal renew '' '' 0 "$WRONG_SAN_CERT" "$WRONG_SAN_KEY"
(( CASE_RC != 0 ))
[[ "$CASE_OUTPUT" == *'不包含 v4.example.com'* ]]
assert_original_state_restored

printf '[续期事务] 有效期不足七天时恢复……\n'
prepare_case short-validity
run_renewal renew '' '' 0 "$SHORT_CERT" "$SHORT_KEY"
(( CASE_RC != 0 ))
[[ "$CASE_OUTPUT" == *'有效期不足七天'* ]]
assert_original_state_restored

printf '[续期事务] 核心配置验证失败时恢复……\n'
prepare_case config-failure
run_renewal renew sing-box
(( CASE_RC != 0 ))
[[ "$CASE_OUTPUT" == *'核心配置或订阅配置校验失败'* ]]
assert_original_state_restored

printf '[续期事务] 中途服务重启失败时恢复证书与原服务状态……\n'
prepare_case service-failure
run_renewal renew '' neko-sing-box.service
(( CASE_RC != 0 ))
[[ "$CASE_OUTPUT" == *'neko-sing-box 重启失败'* \
  && "$CASE_OUTPUT" == *'状态和服务已恢复'* ]]
assert_original_state_restored

printf '[续期事务] 原本停止的服务在失败恢复后仍保持停止……\n'
prepare_case inactive-service
rm -f -- "$CASE_DIR/systemctl/active/neko-xray.service"
run_renewal invalid
(( CASE_RC != 0 ))
[[ ! -e "$CASE_DIR/systemctl/active/neko-xray.service" ]]
for service in neko-caddy.service neko-sing-box.service neko-hysteria.service; do
  [[ -f "$CASE_DIR/systemctl/active/$service" ]]
done
[[ "$(tree_manifest "$CASE_DIR/var/lego")" == "$CASE_ORIGINAL_MANIFEST" ]]
assert_no_snapshot

printf '[续期事务] 回滚失败保留 root-only 快照与明确恢复路径……\n'
prepare_case rollback-failure
run_renewal invalid '' '' 1
(( CASE_RC != 0 ))
mapfile -t rollback_snapshots < <(
  find "$CASE_DIR/var/renew-backups" -mindepth 1 -maxdepth 1 -type d
)
(( ${#rollback_snapshots[@]} == 1 ))
rollback_snapshot="${rollback_snapshots[0]}"
[[ "$(stat -c %a "$rollback_snapshot")" == 700 ]]
[[ "$(tree_manifest "$rollback_snapshot/lego")" == "$CASE_ORIGINAL_MANIFEST" ]]
[[ "$(tree_manifest "$CASE_DIR/var/lego")" != "$CASE_ORIGINAL_MANIFEST" ]]
[[ "$CASE_OUTPUT" == *"${rollback_snapshot}/lego"* \
  && "$CASE_OUTPUT" == *"$CASE_DIR/var/lego"* ]]
if grep -q '^restart ' "$CASE_DIR/systemctl.log"; then
  printf '快照恢复失败后不应继续重启服务。\n' >&2
  exit 1
fi

printf '证书续期完整快照、验证、顺序重启与故障回滚测试通过。\n'
