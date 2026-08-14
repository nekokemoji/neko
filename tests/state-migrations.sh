#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-state-migrations.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

# shellcheck source=versions.env
source "$ROOT/versions.env"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

fail_migration_test() {
  printf '状态迁移测试失败：%s\n' "$*" >&2
  exit 1
}

file_hash() {
  sha256sum "$1" | awk '{print $1}'
}

assert_no_state_temps() {
  if find "$WORK" \
      \( -name '*.tmp.*' -o -name '*.migration.*' \) \
      -print -quit | grep -q .; then
    fail_migration_test "迁移后遗留状态临时文件。"
  fi
}

for migration_function in \
  migrate_1_to_2 migrate_2_to_3 migrate_3_to_4 \
  state_finalize_current_schema state_migrate_to_current; do
  if "$migration_function" --source >/dev/null 2>&1; then
    fail_migration_test "$migration_function 接受缺失的选项参数。"
  fi
done

for schema in 1 2 3; do
  validate_state_source_contract \
    "$ROOT/tests/fixtures/state-schema${schema}.json" "$schema" "$schema"
  if validate_state_source_contract \
      "$ROOT/tests/fixtures/state-schema${schema}-invalid.json" \
      "$schema" "$schema" >/dev/null 2>&1; then
    fail_migration_test "非法 schema $schema fixture 被接受。"
  fi
done

schema1_source="$WORK/schema1-source.json"
schema2_source="$WORK/schema2-source.json"
schema3_source="$WORK/schema3-source.json"
cp -- "$ROOT/tests/fixtures/state-schema1.json" "$schema1_source"
cp -- "$ROOT/tests/fixtures/state-schema2.json" "$schema2_source"
cp -- "$ROOT/tests/fixtures/state-schema3.json" "$schema3_source"
schema1_hash="$(file_hash "$schema1_source")"
schema2_hash="$(file_hash "$schema2_source")"
schema3_hash="$(file_hash "$schema3_source")"

migrate_1_to_2 \
  --source "$schema1_source" --target "$WORK/schema2-next.json" \
  --acme-method http-01 \
  --ipv4-domain v4.example.com --ipv6-domain v6.example.com \
  --ipv4-address 127.0.0.1 --ipv6-address ::1
cmp -s -- \
  "$ROOT/tests/fixtures/state-schema1-to-2.json" "$WORK/schema2-next.json" \
  || fail_migration_test "1→2 结果与审计 fixture 不一致。"
[[ "$(file_hash "$schema1_source")" == "$schema1_hash" ]] \
  || fail_migration_test "1→2 修改了原文件。"

migrate_2_to_3 \
  --source "$schema2_source" --target "$WORK/schema3-next.json" \
  --network-mode dual \
  --ipv4-domain v4.example.com --ipv6-domain v6.example.com \
  --ipv4-address 127.0.0.1 --ipv6-address ::1 \
  --trojan-port 24500 --trojan-password test-trojan-password
cmp -s -- \
  "$ROOT/tests/fixtures/state-schema2-to-3.json" "$WORK/schema3-next.json" \
  || fail_migration_test "2→3 结果与审计 fixture 不一致。"
[[ "$(file_hash "$schema2_source")" == "$schema2_hash" ]] \
  || fail_migration_test "2→3 修改了原文件。"

migrate_3_to_4 \
  --source "$schema3_source" --target "$WORK/schema4-next.json" \
  --cross-hysteria2-start 27000 --cross-hysteria2-end 27127 \
  --cross-tuic-port 28000 --cross-ss2022-port 29000 \
  --cross-anytls-port 30000 --cross-trojan-port 31000 \
  --cross-vision-port 32000 --cross-xhttp-port 33000 \
  --cross-anyreality-port 35000 \
  --ipv4-to-ipv6-token test-v4-to-v6-token \
  --ipv6-to-ipv4-token test-v6-to-v4-token
cmp -s -- \
  "$ROOT/tests/fixtures/state-schema3-to-4.json" "$WORK/schema4-next.json" \
  || fail_migration_test "3→4 结果与审计 fixture 不一致。"
[[ "$(file_hash "$schema3_source")" == "$schema3_hash" ]] \
  || fail_migration_test "3→4 修改了原文件。"
assert_no_state_temps

bad_target="$WORK/bad-target.json"
if migrate_1_to_2 \
    --source "$ROOT/tests/fixtures/state-schema1-invalid.json" \
    --target "$bad_target" \
    --acme-method http-01 \
    --ipv4-domain v4.example.com --ipv6-domain v6.example.com \
    --ipv4-address 127.0.0.1 --ipv6-address ::1 >/dev/null 2>&1; then
  fail_migration_test "1→2 接受非法源状态。"
fi
[[ ! -e "$bad_target" ]] \
  || fail_migration_test "1→2 失败后创建了目标状态。"

if migrate_2_to_3 \
    --source "$schema2_source" --target "$bad_target" \
    --network-mode dual \
    --ipv4-domain v4.example.com --ipv6-domain v6.example.com \
    --ipv4-address 127.0.0.1 --ipv6-address ::1 \
    --trojan-port 23000 --trojan-password test-trojan-password \
    >/dev/null 2>&1; then
  fail_migration_test "2→3 接受冲突的新增端口。"
fi
[[ "$(file_hash "$schema2_source")" == "$schema2_hash" && ! -e "$bad_target" ]] \
  || fail_migration_test "2→3 失败后修改了源或目标。"

if migrate_3_to_4 \
    --source "$schema3_source" --target "$bad_target" \
    --cross-hysteria2-start 21000 --cross-hysteria2-end 21127 \
    --cross-tuic-port 28000 --cross-ss2022-port 29000 \
    --cross-anytls-port 30000 --cross-trojan-port 31000 \
    --cross-vision-port 32000 --cross-xhttp-port 33000 \
    --cross-anyreality-port 35000 \
    --ipv4-to-ipv6-token test-v4-to-v6-token \
    --ipv6-to-ipv4-token test-v6-to-v4-token >/dev/null 2>&1; then
  fail_migration_test "3→4 接受与基础范围冲突的跨族端口。"
fi
[[ "$(file_hash "$schema3_source")" == "$schema3_hash" && ! -e "$bad_target" ]] \
  || fail_migration_test "3→4 失败后修改了源或目标。"
assert_no_state_temps

run_full_migration() {
  local schema="$1" source
  local fixture="$ROOT/tests/fixtures/state-schema${schema}.json"
  local identity_before token_before
  source="$WORK/full-schema${schema}.json"
  [[ "$schema" != 4 ]] || fixture="$ROOT/tests/fixtures/state.json"
  cp -- "$fixture" "$source"
  identity_before="$(jq -cS '{
    domain,
    acme_email,
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality
  }' "$source")"
  if (( schema <= 2 )); then
    token_before="$(jq -r '.subscription.token' "$source")"
  else
    token_before="$(jq -r '.subscription.ipv4_token' "$source")"
  fi

  state_migrate_to_current \
    --source "$source" --target "$source" \
    --release "$NEKO_RELEASE" --acme-method http-01 \
    --network-mode dual \
    --ipv4-domain v4.example.com --ipv6-domain v6.example.com \
    --ipv4-address 127.0.0.1 --ipv6-address ::1 \
    --trojan-port 24500 --trojan-password test-trojan-password \
    --cross-hysteria2-start 27000 --cross-hysteria2-end 27127 \
    --cross-tuic-port 28000 --cross-ss2022-port 29000 \
    --cross-anytls-port 30000 --cross-trojan-port 31000 \
    --cross-vision-port 32000 --cross-xhttp-port 33000 \
    --ipv4-to-ipv6-token test-v4-to-v6-token \
    --ipv6-to-ipv4-token test-v6-to-v4-token \
    --anyreality-port 34000 --cross-anyreality-port 35000 \
    --anyreality-password test-anyreality-password \
    --anyreality-private-key \
      kF-xXmV_yq2mtuzBfBZw9g-VAqO712QGpKFVfOqbv1Q \
    --anyreality-public-key \
      BdhFQXLg2ajaJ3BbMQ5esGMIUCGph36ShM2DfzmyOyM \
    --anyreality-short-id 2122232425262728

  validate_state_source_contract "$source" "$NEKO_STATE_SCHEMA" "$NEKO_STATE_SCHEMA"
  [[ "$(jq -r '.schema' "$source")" == "$NEKO_STATE_SCHEMA" ]]
  [[ "$(jq -r '.release' "$source")" == "$NEKO_RELEASE" ]]
  [[ "$(jq -r '.subscription.ipv4_token' "$source")" == "$token_before" ]]
  [[ "$(jq -r '.subscription.ipv6_token' "$source")" == "$token_before" ]]
  [[ "$(jq -cS '{
    domain,
    acme_email,
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality
  }' "$source")" == "$identity_before" ]] \
    || fail_migration_test "schema $schema 的历史身份字段发生变化。"
}

for schema in 1 2 3 4; do
  run_full_migration "$schema"
done
assert_no_state_temps

rollback_state="$WORK/rollback-state.json"
cp -- "$ROOT/tests/fixtures/state-schema3.json" "$rollback_state"
rollback_hash="$(file_hash "$rollback_state")"
if state_migrate_to_current \
    --source "$rollback_state" --target "$rollback_state" \
    --release "$NEKO_RELEASE" --acme-method http-01 \
    --network-mode dual \
    --ipv4-domain v4.example.com --ipv6-domain v6.example.com \
    --ipv4-address 127.0.0.1 --ipv6-address ::1 \
    --trojan-port 24500 --trojan-password test-trojan-password \
    --cross-hysteria2-start 27000 --cross-hysteria2-end 27127 \
    --cross-tuic-port 22000 --cross-ss2022-port 29000 \
    --cross-anytls-port 30000 --cross-trojan-port 31000 \
    --cross-vision-port 32000 --cross-xhttp-port 33000 \
    --ipv4-to-ipv6-token test-v4-to-v6-token \
    --ipv6-to-ipv4-token test-v6-to-v4-token \
    --anyreality-port 34000 --cross-anyreality-port 35000 \
    --anyreality-password test-anyreality-password \
    --anyreality-private-key \
      kF-xXmV_yq2mtuzBfBZw9g-VAqO712QGpKFVfOqbv1Q \
    --anyreality-public-key \
      BdhFQXLg2ajaJ3BbMQ5esGMIUCGph36ShM2DfzmyOyM \
    --anyreality-short-id 2122232425262728 >/dev/null 2>&1; then
  fail_migration_test "总控迁移接受跨族端口冲突。"
fi
[[ "$(file_hash "$rollback_state")" == "$rollback_hash" ]] \
  || fail_migration_test "总控迁移失败后修改了原状态。"
assert_no_state_temps

atomic_state="$WORK/atomic-state.json"
cp -- "$ROOT/tests/fixtures/state.json" "$atomic_state"
NEKO_STATE="$atomic_state"
atomic_hash="$(file_hash "$atomic_state")"
if atomic_json_update '.ports.tuic = .ports.ss2022' >/dev/null 2>&1; then
  fail_migration_test "原子更新接受端口冲突。"
fi
[[ "$(file_hash "$atomic_state")" == "$atomic_hash" ]] \
  || fail_migration_test "原子更新失败后修改了原状态。"
assert_no_state_temps

printf '逐版本状态迁移、原子写入与失败清理测试通过。\n'
