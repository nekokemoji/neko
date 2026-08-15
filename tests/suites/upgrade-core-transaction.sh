#!/usr/bin/env bash

# Five-core upgrade transaction, rollback, and fault-injection contracts.
# This file is sourced by tests/suites/upgrade.sh after its shared helpers.
# The quoted strings in write_core_test_binary deliberately write variables
# into the generated fixture instead of expanding them in this parent shell.
# shellcheck disable=SC2016,SC2154
[[ "${NEKO_TEST_SUITE_CONTEXT:-}" == 1 ]] || {
  printf '请通过 tests/run.sh 运行测试套件。\n' >&2
  exit 1
}

printf '[升级事务] 构造五核心固定版本测试归档……\n'

CORE_TEST_TARGET_VERSION="9.9.9-test"
CORE_TEST_OLD_VERSION="0.0.1-test"
CORE_TEST_RELEASE_ROOT="$WORK/core-upgrade-release"
CORE_TEST_ARCHIVES="$CORE_TEST_RELEASE_ROOT/archives"
CORE_TEST_TARGET_MANIFEST="$CORE_TEST_RELEASE_ROOT/versions.env"

write_core_test_binary() {
  local path="$1" component="$2" version="$3"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -Eeuo pipefail' \
    "component='$component'" \
    "version='$version'" \
    'if [[ -n "${NEKO_TEST_CORE_CALL_LOG:-}" ]]; then' \
    '  printf "%s|%s\n" "$component" "$*" >> "$NEKO_TEST_CORE_CALL_LOG"' \
    'fi' \
    'case "$component:$*" in' \
    '  xray:version) printf "Xray %s (transaction-test)\n" "$version" ;;' \
    '  sing-box:version) printf "sing-box version %s\n" "$version" ;;' \
    '  "sing-box:generate reality-keypair")' \
    '    printf "PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"' \
    '    printf "PublicKey: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n"' \
    '    ;;' \
    '  hysteria:version) printf "Version: v%s\n" "$version" ;;' \
    '  hysteria:server*)' \
    '    printf "exec: executable file not found in \\$PATH\n" >&2' \
    '    exit 1' \
    '    ;;' \
    '  caddy:version) printf "v%s\n" "$version" ;;' \
    '  lego:--version) printf "lego version %s linux/amd64\n" "$version" ;;' \
    'esac' \
    'exit 0' > "$path"
  chmod 0755 "$path"
}

set_core_test_manifest_value() {
  local manifest="$1" key="$2" value="$3"
  sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$manifest"
}

prepare_core_test_release() {
  local build="$CORE_TEST_RELEASE_ROOT/build" component hash arch
  mkdir -p \
    "$CORE_TEST_ARCHIVES" "$build/xray" "$build/caddy" "$build/lego"
  cp -a -- "$ROOT/versions.env" "$CORE_TEST_TARGET_MANIFEST"

  write_core_test_binary \
    "$build/xray/xray" xray "$CORE_TEST_TARGET_VERSION"
  write_core_test_binary \
    "$build/hysteria" hysteria "$CORE_TEST_TARGET_VERSION"
  write_core_test_binary \
    "$build/caddy/caddy" caddy "$CORE_TEST_TARGET_VERSION"
  write_core_test_binary \
    "$build/lego/lego" lego "$CORE_TEST_TARGET_VERSION"
  for arch in amd64 arm64; do
    mkdir -p "$build/sing-box-${CORE_TEST_TARGET_VERSION}-linux-${arch}"
    write_core_test_binary \
      "$build/sing-box-${CORE_TEST_TARGET_VERSION}-linux-${arch}/sing-box" \
      sing-box "$CORE_TEST_TARGET_VERSION"
  done

  python3 - "$build/xray/xray" "$CORE_TEST_ARCHIVES/xray.zip" <<'PY'
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as archive:
    archive.write(source, "xray")
PY
  tar -czf "$CORE_TEST_ARCHIVES/sing-box.tar.gz" -C "$build" \
    "sing-box-${CORE_TEST_TARGET_VERSION}-linux-amd64" \
    "sing-box-${CORE_TEST_TARGET_VERSION}-linux-arm64"
  install -m 0755 "$build/hysteria" "$CORE_TEST_ARCHIVES/hysteria"
  tar -czf "$CORE_TEST_ARCHIVES/caddy.tar.gz" -C "$build/caddy" caddy
  tar -czf "$CORE_TEST_ARCHIVES/lego.tar.gz" -C "$build/lego" lego

  for component in XRAY SING_BOX HYSTERIA CADDY LEGO; do
    set_core_test_manifest_value \
      "$CORE_TEST_TARGET_MANIFEST" "${component}_VERSION" \
      "$CORE_TEST_TARGET_VERSION"
  done
  for component in \
    'XRAY:xray.zip' 'SING_BOX:sing-box.tar.gz' 'HYSTERIA:hysteria' \
    'CADDY:caddy.tar.gz' 'LEGO:lego.tar.gz'; do
    hash="$(sha256sum "$CORE_TEST_ARCHIVES/${component#*:}" | awk '{print $1}')"
    for arch in AMD64 ARM64; do
      set_core_test_manifest_value \
        "$CORE_TEST_TARGET_MANIFEST" \
        "${component%%:*}_${arch}_SHA256" "$hash"
    done
  done
}

install_core_test_old_set() {
  local target="$1" component binary mode hash arch
  local -a specs=(
    'XRAY:xray:0750'
    'SING_BOX:sing-box:0711'
    'HYSTERIA:hysteria:0755'
    'CADDY:caddy:0701'
    'LEGO:lego:0754'
  )
  for component in "${specs[@]}"; do
    binary="${component#*:}"
    binary="${binary%%:*}"
    mode="${component##*:}"
    rm -f -- "$target/libexec/$binary"
    write_core_test_binary \
      "$target/libexec/$binary" "$binary" "$CORE_TEST_OLD_VERSION"
    chmod "$mode" "$target/libexec/$binary"
    set_core_test_manifest_value \
      "$target/libexec/versions.env" "${component%%:*}_VERSION" \
      "$CORE_TEST_OLD_VERSION"
    hash="$(sha256sum "$target/libexec/$binary" | awk '{print $1}')"
    for arch in AMD64 ARM64; do
      set_core_test_manifest_value \
        "$target/libexec/versions.env" \
        "${component%%:*}_${arch}_SHA256" "$hash"
    done
  done
}

prepare_core_transaction_case() {
  local target="$1" state_tmp
  prepare_upgrade_install "$target" 4 "$NEKO_RELEASE" dual true
  state_tmp="$(mktemp "$target/etc/state.json.tmp.XXXXXX")"
  jq '
    .subscription.ipv4_address = "192.0.2.10"
    | .subscription.ipv6_address = "2001:db8::10"
    |
    .experimental.anyreality = {
      enabled: true,
      port: 34000,
      cross_port: 35000,
      password: "preserved-anyreality-password",
      private_key: .reality.vision_private_key,
      public_key: .reality.vision_public_key,
      short_id: "2122232425262728"
    }
  ' "$target/etc/state.json" > "$state_tmp"
  mv -f -- "$state_tmp" "$target/etc/state.json"
  rm -f -- "$target/etc/subscriptions/"*
  NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    bash -c 'set -Eeuo pipefail; source "$1"; source "$2"; render_all' \
      _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
  NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      runtime_set_lego_permissions \
        --lego-dir "$NEKO_VAR/lego" --service-user "$NEKO_USER" \
        --ownership preserve --path-policy trusted
    ' _ "$ROOT/lib/common.sh"
  install_core_test_old_set "$target"
}

run_core_transaction_upgrade() {
  local target="$1" fail_points="${2:-}"
  shift 2 || true
  run_upgrade "$target" \
    NEKO_UPDATE_TARGET_VERSIONS_FILE="$CORE_TEST_TARGET_MANIFEST" \
    NEKO_UPDATE_CORE_ARCHIVE_DIR="$CORE_TEST_ARCHIVES" \
    NEKO_UPDATE_TEST_FAIL_POINTS="$fail_points" \
    NEKO_UPDATE_TEST_EVENT_LOG="$target/events.log" \
    NEKO_TEST_CORE_CALL_LOG="$target/core-calls.log" \
    NEKO_TEST_SYSTEMCTL_LOG="$target/systemctl.log" \
    "$@"
}

core_test_set_manifest() {
  local core_dir="$1" binary kind identity
  for binary in xray sing-box hysteria caddy lego; do
    if [[ -L "$core_dir/$binary" ]]; then
      kind=symlink
      identity="$(readlink "$core_dir/$binary")"
    else
      kind='file'
      identity="$(sha256sum "$core_dir/$binary" | awk '{print $1}')"
    fi
    printf '%s|%s|%s|%s\n' \
      "$binary" "$kind" "$(stat -c '%a:%u:%g' "$core_dir/$binary")" \
      "$identity"
  done
}

core_test_sensitive_manifest() {
  local target="$1"
  tar --sort=name --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -cf - -C "$target" etc var/lego \
    | sha256sum | awk '{print $1}'
}

assert_no_core_upgrade_temps() {
  local target="$1" allow_backup="${2:-false}"
  if find "$target/tmp" -maxdepth 1 \
      \( -name 'neko-qrc-stage.*' -o -name 'neko-nexttrace-stage.*' \
         -o -name 'neko-core-stage.*' \) -print -quit | grep -q .; then
    printf '核心升级后残留了暂存目录：%s\n' "$target" >&2
    return 1
  fi
  if find "$target/libexec" -maxdepth 1 \
      \( -name '.*.next.*' -o -name '.*.rollback.*' \
         -o -name '.versions.env.next.*' \) -print -quit | grep -q .; then
    printf '核心升级后残留了激活临时文件：%s\n' "$target" >&2
    return 1
  fi
  if [[ "$allow_backup" != true ]] \
    && find "$target/tmp" -maxdepth 1 -name 'neko-upgrade-backup.*' \
      -print -quit | grep -q .; then
    printf '核心升级后残留了备份目录：%s\n' "$target" >&2
    return 1
  fi
}

assert_core_transaction_failure_restored() {
  local target="$1" before="$2"
  [[ "$(upgrade_payload_manifest "$target")" == "$before" ]]
  grep -Fq '正在恢复升级前的状态' "$target/upgrade.log"
  assert_no_core_upgrade_temps "$target"
}

prepare_core_test_release

printf '[升级事务] 五核心整组成功、目标配置校验与清单最后提交……\n'
CORE_TX_OK="$WORK/core-upgrade-ok"
prepare_core_transaction_case "$CORE_TX_OK"
core_tx_sensitive_before="$(core_test_sensitive_manifest "$CORE_TX_OK")"
run_core_transaction_upgrade "$CORE_TX_OK" '' > "$CORE_TX_OK/upgrade.log"
[[ "$(core_test_sensitive_manifest "$CORE_TX_OK")" \
  == "$core_tx_sensitive_before" ]]
cmp -s -- "$CORE_TEST_TARGET_MANIFEST" "$CORE_TX_OK/libexec/versions.env"
for core_tx_binary in xray sing-box hysteria caddy lego; do
  core_tx_output="$(
    if [[ "$core_tx_binary" == lego ]]; then
      "$CORE_TX_OK/libexec/$core_tx_binary" --version
    else
      "$CORE_TX_OK/libexec/$core_tx_binary" version
    fi
  )"
  grep -Fq "$CORE_TEST_TARGET_VERSION" <<< "$core_tx_output"
  [[ "$(stat -c '%a:%u:%g' "$CORE_TX_OK/libexec/$core_tx_binary")" \
    == '755:0:0' ]]
done
core_tx_expected_events="$(printf '%s\n' \
  core-stage-validated \
  config-validated \
  activate-xray \
  activate-sing-box \
  activate-hysteria \
  activate-caddy \
  activate-lego \
  service-neko-caddy \
  service-neko-sing-box \
  service-neko-xray \
  service-neko-hysteria \
  manifest-committed)"
[[ "$(<"$CORE_TX_OK/events.log")" == "$core_tx_expected_events" ]]
grep -Fq 'sing-box|check -c' "$CORE_TX_OK/core-calls.log"
grep -Fq 'xray|run -test -c' "$CORE_TX_OK/core-calls.log"
grep -Fq 'caddy|validate --config' "$CORE_TX_OK/core-calls.log"
[[ "$(grep -Fc 'hysteria|server --disable-update-check --config' \
  "$CORE_TX_OK/core-calls.log")" -ge 4 ]]
assert_no_core_upgrade_temps "$CORE_TX_OK"

printf '[升级事务] ARM64 目标归档映射执行同一整组事务……\n'
CORE_TX_ARM64="$WORK/core-upgrade-arm64"
prepare_core_transaction_case "$CORE_TX_ARM64"
core_tx_sensitive_before="$(core_test_sensitive_manifest "$CORE_TX_ARM64")"
run_core_transaction_upgrade "$CORE_TX_ARM64" '' ARCH_OVERRIDE=arm64 \
  > "$CORE_TX_ARM64/upgrade.log"
[[ "$(core_test_sensitive_manifest "$CORE_TX_ARM64")" \
  == "$core_tx_sensitive_before" ]]
cmp -s -- "$CORE_TEST_TARGET_MANIFEST" "$CORE_TX_ARM64/libexec/versions.env"
assert_no_core_upgrade_temps "$CORE_TX_ARM64"

printf '[升级事务] 下载、复制、SHA、身份与暂存信号失败均不改安装……\n'
core_tx_prebackup_points=(
  download-xray.zip
  copy-xray.zip
  signal-int-after-core-staging
)
for core_tx_point in "${core_tx_prebackup_points[@]}"; do
  core_tx_slug="${core_tx_point//[^A-Za-z0-9]/-}"
  core_tx_target="$WORK/core-upgrade-pre-${core_tx_slug}"
  prepare_core_transaction_case "$core_tx_target"
  core_tx_before="$(upgrade_payload_manifest "$core_tx_target")"
  set +e
  run_core_transaction_upgrade "$core_tx_target" "$core_tx_point" \
    > "$core_tx_target/upgrade.log" 2>&1
  core_tx_rc=$?
  set -e
  (( core_tx_rc != 0 ))
  [[ "$(upgrade_payload_manifest "$core_tx_target")" == "$core_tx_before" ]]
  assert_no_core_upgrade_temps "$core_tx_target"
done

CORE_TX_BAD_SHA="$WORK/core-upgrade-bad-sha"
prepare_core_transaction_case "$CORE_TX_BAD_SHA"
cp -a -- "$CORE_TEST_TARGET_MANIFEST" "$CORE_TX_BAD_SHA/target.env"
set_core_test_manifest_value \
  "$CORE_TX_BAD_SHA/target.env" XRAY_AMD64_SHA256 \
  0000000000000000000000000000000000000000000000000000000000000000
core_tx_before="$(upgrade_payload_manifest "$CORE_TX_BAD_SHA")"
set +e
run_core_transaction_upgrade "$CORE_TX_BAD_SHA" '' \
  NEKO_UPDATE_TARGET_VERSIONS_FILE="$CORE_TX_BAD_SHA/target.env" \
  > "$CORE_TX_BAD_SHA/upgrade.log" 2>&1
core_tx_rc=$?
set -e
(( core_tx_rc != 0 ))
[[ "$(upgrade_payload_manifest "$CORE_TX_BAD_SHA")" == "$core_tx_before" ]]
grep -Fq 'SHA-256 校验失败' "$CORE_TX_BAD_SHA/upgrade.log"
assert_no_core_upgrade_temps "$CORE_TX_BAD_SHA"

CORE_TX_BAD_IDENTITY="$WORK/core-upgrade-bad-identity"
prepare_core_transaction_case "$CORE_TX_BAD_IDENTITY"
cp -a -- "$CORE_TEST_ARCHIVES" "$CORE_TX_BAD_IDENTITY/archives"
cp -a -- "$CORE_TEST_TARGET_MANIFEST" "$CORE_TX_BAD_IDENTITY/target.env"
write_core_test_binary \
  "$CORE_TX_BAD_IDENTITY/archives/hysteria" hysteria 8.8.8-test
core_tx_bad_hash="$(
  sha256sum "$CORE_TX_BAD_IDENTITY/archives/hysteria" | awk '{print $1}'
)"
set_core_test_manifest_value \
  "$CORE_TX_BAD_IDENTITY/target.env" HYSTERIA_AMD64_SHA256 \
  "$core_tx_bad_hash"
set_core_test_manifest_value \
  "$CORE_TX_BAD_IDENTITY/target.env" HYSTERIA_ARM64_SHA256 \
  "$core_tx_bad_hash"
core_tx_before="$(upgrade_payload_manifest "$CORE_TX_BAD_IDENTITY")"
set +e
run_core_transaction_upgrade "$CORE_TX_BAD_IDENTITY" '' \
  NEKO_UPDATE_TARGET_VERSIONS_FILE="$CORE_TX_BAD_IDENTITY/target.env" \
  NEKO_UPDATE_CORE_ARCHIVE_DIR="$CORE_TX_BAD_IDENTITY/archives" \
  > "$CORE_TX_BAD_IDENTITY/upgrade.log" 2>&1
core_tx_rc=$?
set -e
(( core_tx_rc != 0 ))
[[ "$(upgrade_payload_manifest "$CORE_TX_BAD_IDENTITY")" == "$core_tx_before" ]]
grep -Fq '无法确认目标版本' "$CORE_TX_BAD_IDENTITY/upgrade.log"
assert_no_core_upgrade_temps "$CORE_TX_BAD_IDENTITY"

printf '[升级事务] 每个激活点、服务点、配置和清单故障均完整回滚……\n'
core_tx_rollback_points=(
  staged-config-validation
  activation-copy-xray
  activate-xray
  activate-sing-box
  activate-hysteria
  activate-caddy
  activate-lego
  signal-term-after-core-activation
  service-neko-caddy
  service-neko-sing-box
  service-neko-xray
  service-neko-hysteria
  manifest-commit
)
for core_tx_point in "${core_tx_rollback_points[@]}"; do
  core_tx_slug="${core_tx_point//[^A-Za-z0-9]/-}"
  core_tx_target="$WORK/core-upgrade-rollback-${core_tx_slug}"
  prepare_core_transaction_case "$core_tx_target"
  core_tx_before="$(upgrade_payload_manifest "$core_tx_target")"
  set +e
  run_core_transaction_upgrade "$core_tx_target" "$core_tx_point" \
    > "$core_tx_target/upgrade.log" 2>&1
  core_tx_rc=$?
  set -e
  (( core_tx_rc != 0 ))
  assert_core_transaction_failure_restored "$core_tx_target" "$core_tx_before"
done

printf '[升级事务] 回滚恢复原服务启停状态……\n'
CORE_TX_INACTIVE="$WORK/core-upgrade-inactive-service"
prepare_core_transaction_case "$CORE_TX_INACTIVE"
core_tx_before="$(upgrade_payload_manifest "$CORE_TX_INACTIVE")"
set +e
run_core_transaction_upgrade "$CORE_TX_INACTIVE" staged-config-validation \
  NEKO_TEST_SYSTEMCTL_INACTIVE_PATTERN=neko-hysteria.service \
  > "$CORE_TX_INACTIVE/upgrade.log" 2>&1
core_tx_rc=$?
set -e
(( core_tx_rc != 0 ))
assert_core_transaction_failure_restored "$CORE_TX_INACTIVE" "$core_tx_before"
grep -Fxq 'stop neko-hysteria.service' "$CORE_TX_INACTIVE/systemctl.log"
for core_tx_service in neko-caddy neko-sing-box neko-xray; do
  grep -Fxq "restart ${core_tx_service}.service" \
    "$CORE_TX_INACTIVE/systemctl.log"
done

printf '[升级事务] 回滚文件或服务失败时保留 root-only 恢复快照……\n'
CORE_TX_ROLLBACK_FILE="$WORK/core-upgrade-rollback-file-failure"
prepare_core_transaction_case "$CORE_TX_ROLLBACK_FILE"
core_tx_old_core_manifest="$(core_test_set_manifest "$CORE_TX_ROLLBACK_FILE/libexec")"
set +e
run_core_transaction_upgrade "$CORE_TX_ROLLBACK_FILE" \
  'activate-caddy,rollback-file-xray' \
  > "$CORE_TX_ROLLBACK_FILE/upgrade.log" 2>&1
core_tx_rc=$?
set -e
(( core_tx_rc != 0 ))
core_tx_backups=("$CORE_TX_ROLLBACK_FILE/tmp"/neko-upgrade-backup.*)
(( ${#core_tx_backups[@]} == 1 )) && [[ -d "${core_tx_backups[0]}" ]]
core_tx_backup="${core_tx_backups[0]}"
[[ "$(stat -c '%a:%u:%g' "$core_tx_backup")" == '700:0:0' ]]
[[ "$(core_test_set_manifest "$core_tx_backup/core")" \
  == "$core_tx_old_core_manifest" ]]
grep -Fq "备份保留在 ${core_tx_backup}" \
  "$CORE_TX_ROLLBACK_FILE/upgrade.log"
grep -Fq '按 services.state 恢复服务启停状态' \
  "$CORE_TX_ROLLBACK_FILE/upgrade.log"
assert_no_core_upgrade_temps "$CORE_TX_ROLLBACK_FILE" true

CORE_TX_ROLLBACK_SERVICE="$WORK/core-upgrade-rollback-service-failure"
prepare_core_transaction_case "$CORE_TX_ROLLBACK_SERVICE"
core_tx_before="$(upgrade_payload_manifest "$CORE_TX_ROLLBACK_SERVICE")"
core_tx_old_core_manifest="$(
  core_test_set_manifest "$CORE_TX_ROLLBACK_SERVICE/libexec"
)"
set +e
run_core_transaction_upgrade "$CORE_TX_ROLLBACK_SERVICE" \
  'service-neko-xray,rollback-service-neko-caddy' \
  > "$CORE_TX_ROLLBACK_SERVICE/upgrade.log" 2>&1
core_tx_rc=$?
set -e
(( core_tx_rc != 0 ))
[[ "$(upgrade_payload_manifest "$CORE_TX_ROLLBACK_SERVICE")" \
  == "$core_tx_before" ]]
core_tx_backups=("$CORE_TX_ROLLBACK_SERVICE/tmp"/neko-upgrade-backup.*)
(( ${#core_tx_backups[@]} == 1 )) && [[ -d "${core_tx_backups[0]}" ]]
core_tx_backup="${core_tx_backups[0]}"
[[ "$(stat -c '%a:%u:%g' "$core_tx_backup")" == '700:0:0' ]]
[[ "$(core_test_set_manifest "$core_tx_backup/core")" \
  == "$core_tx_old_core_manifest" ]]
grep -Fq "备份保留在 ${core_tx_backup}" \
  "$CORE_TX_ROLLBACK_SERVICE/upgrade.log"
grep -Fq '按 services.state 恢复服务启停状态' \
  "$CORE_TX_ROLLBACK_SERVICE/upgrade.log"
assert_no_core_upgrade_temps "$CORE_TX_ROLLBACK_SERVICE" true
