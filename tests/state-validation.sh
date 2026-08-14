#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-state-validation.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

source "$ROOT/lib/common.sh"

state_hash() {
  sha256sum "$1" | awk '{print $1}'
}

expect_source_valid() {
  local state_file="$1" before
  before="$(state_hash "$state_file")"
  validate_state_source_contract "$state_file" 1 "$NEKO_STATE_SCHEMA"
  [[ "$(state_hash "$state_file")" == "$before" ]]
}

expect_current_valid() {
  local state_file="$1" before
  before="$(state_hash "$state_file")"
  NEKO_STATE="$state_file" bash -c '
    set -Eeuo pipefail
    source "$1"
    load_state
  ' _ "$ROOT/lib/common.sh"
  [[ "$(state_hash "$state_file")" == "$before" ]]
}

expect_invalid_file() {
  local label="$1" state_file="$2" before
  before="$(state_hash "$state_file")"
  if validate_state_source_contract \
      "$state_file" 1 "$NEKO_STATE_SCHEMA" >/dev/null 2>&1; then
    printf '损坏状态被错误接受：%s\n' "$label" >&2
    exit 1
  fi
  if NEKO_STATE="$state_file" bash -c '
      set -Eeuo pipefail
      source "$1"
      load_state
    ' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
    printf 'load_state 错误接受损坏状态：%s\n' "$label" >&2
    exit 1
  fi
  [[ "$(state_hash "$state_file")" == "$before" ]] || {
    printf '拒绝损坏状态时修改了原文件：%s\n' "$label" >&2
    exit 1
  }
}

invalid_from_filter() {
  local label="$1" filter="$2" target="$WORK/invalid-${1}.json"
  jq "$filter" "$ROOT/tests/fixtures/state.json" > "$target"
  expect_invalid_file "$label" "$target"
}

for schema in 1 2 3; do
  expect_source_valid "$ROOT/tests/fixtures/state-schema${schema}.json"
done
expect_source_valid "$ROOT/tests/fixtures/state.json"
expect_invalid_file \
  escaped-nul-fixture "$ROOT/tests/fixtures/state-invalid-control.json"

# Earliest schema-1 installations did not always write an explicit schema;
# the upgrader has historically treated that form as schema 1.
jq 'del(.schema)' "$ROOT/tests/fixtures/state-schema1.json" \
  > "$WORK/schema1-implicit.json"
expect_source_valid "$WORK/schema1-implicit.json"

jq '
  .network.mode = "ipv4-only"
  | .ports.cross = null
  | .subscription.ipv6_token = null
  | .subscription.ipv4_to_ipv6_token = null
  | .subscription.ipv6_to_ipv4_token = null
  | .subscription.ipv6_domain = null
  | .subscription.ipv6_address = null
' "$ROOT/tests/fixtures/state.json" > "$WORK/ipv4-only.json"
expect_current_valid "$WORK/ipv4-only.json"

jq '
  .network.mode = "ipv6-only"
  | .ports.cross = null
  | .subscription.ipv4_token = null
  | .subscription.ipv4_to_ipv6_token = null
  | .subscription.ipv6_to_ipv4_token = null
  | .subscription.ipv4_domain = null
  | .subscription.ipv4_address = null
' "$ROOT/tests/fixtures/state.json" > "$WORK/ipv6-only.json"
expect_current_valid "$WORK/ipv6-only.json"
expect_current_valid "$ROOT/tests/fixtures/state.json"

jq '
  .experimental.anyreality = {
    enabled: true,
    port: 34000,
    cross_port: 35000,
    password: "preserved-anyreality-password",
    private_key: .reality.vision_private_key,
    public_key: .reality.vision_public_key,
    short_id: "2122232425262728"
  }
' "$ROOT/tests/fixtures/state.json" > "$WORK/anyreality.json"
expect_current_valid "$WORK/anyreality.json"

minimum_value=abcdefghijklmnop
printf -v maximum_value '%128s' ''
maximum_value="${maximum_value// /A}"
jq --arg minimum "$minimum_value" --arg maximum "$maximum_value" '
  .credentials.hysteria2_password = $minimum
  | .credentials.hysteria2_obfs_password = $maximum
  | .credentials.tuic_password = $minimum
  | .credentials.anytls_password = $maximum
  | .credentials.trojan_password = $minimum
  | .subscription.ipv4_token = $minimum
  | .subscription.ipv6_token = $maximum
  | .subscription.ipv4_to_ipv6_token = $minimum
  | .subscription.ipv6_to_ipv4_token = $maximum
  | .reality.xhttp_path = "/safe/multi_segment-1"
' "$ROOT/tests/fixtures/state.json" > "$WORK/legal-boundaries.json"
expect_current_valid "$WORK/legal-boundaries.json"

printf '%s\n' '{"schema":4,"domain":' > "$WORK/malformed.json"
expect_invalid_file malformed-json "$WORK/malformed.json"

invalid_from_filter root-array '[.]'
invalid_from_filter schema-string '.schema = "4"'
invalid_from_filter schema-fraction '.schema = 4.5'
invalid_from_filter domain-boolean '.domain = true'
invalid_from_filter email-array '.acme_email = []'
invalid_from_filter port-string '.ports.tuic = "22000"'
invalid_from_filter credential-number '.credentials.tuic_password = 123'
invalid_from_filter token-number '.subscription.ipv4_token = 123'
invalid_from_filter inactive-token-number '
  .network.mode = "ipv4-only"
  | .ports.cross = null
  | .subscription.ipv6_token = 123
  | .subscription.ipv4_to_ipv6_token = null
  | .subscription.ipv6_to_ipv4_token = null
'
invalid_from_filter anyreality-boolean-type '
  .experimental.anyreality = {enabled: "true"}
'

invalid_from_filter carriage-return '.domain = "example.com\rpoison"'
invalid_from_filter line-feed '.credentials.tuic_password = "poison\nvalue"'
invalid_from_filter escaped-nul '.subscription.ipv4_token = "poison\u0000value"'
invalid_from_filter unit-separator '.reality.xhttp_path = "/poison\u001fvalue"'
invalid_from_filter delete-control '.release = "poison\u007fvalue"'
invalid_from_filter tab-in-unknown-field '.unknown = "poison\tvalue"'
invalid_from_filter line-feed-in-key '. + {"poison\nkey": "safe"}'

invalid_from_filter uuid-uppercase '
  .credentials.tuic_uuid = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
'
invalid_from_filter uuid-missing-hyphens '
  .credentials.vision_uuid = "22222222222242228222222222222222"
'
invalid_from_filter base64-invalid-character '
  .credentials.ss2022_password = "MDEyMzQ1Njc4OWFiY2RlZ!=="
'
invalid_from_filter base64-wrong-length '
  .credentials.ss2022_password = "YWJjZA=="
'
invalid_from_filter base64-noncanonical '
  .credentials.ss2022_password = "MDEyMzQ1Njc4OWFiY2RlZh=="
'
invalid_from_filter urlsafe-short '.credentials.hysteria2_password = "short"'
invalid_from_filter urlsafe-character '.credentials.anytls_password = "invalid password value"'
invalid_from_filter token-short '.subscription.ipv4_token = "short"'
invalid_from_filter token-character '.subscription.ipv6_token = "invalid/token/value"'

invalid_from_filter reality-key-short '.reality.vision_private_key = "short"'
invalid_from_filter reality-key-character '
  .reality.xhttp_public_key = "FVuHPI9DrVZksjPE01p9Kbifs2M4DsnXlz6F+HId7SU"
'
invalid_from_filter short-id-uppercase '.reality.vision_short_id = "ABCDEF0123456789"'
invalid_from_filter short-id-length '.reality.xhttp_short_id = "1234"'

invalid_from_filter xhttp-relative '.reality.xhttp_path = "relative"'
invalid_from_filter xhttp-query '.reality.xhttp_path = "/safe?next=/poison"'
invalid_from_filter xhttp-fragment '.reality.xhttp_path = "/safe#poison"'
invalid_from_filter xhttp-parent '.reality.xhttp_path = "/safe/../escape"'
invalid_from_filter xhttp-current '.reality.xhttp_path = "/safe/./child"'
invalid_from_filter xhttp-percent '.reality.xhttp_path = "/safe/%2e%2e/escape"'
invalid_from_filter xhttp-double-slash '.reality.xhttp_path = "/safe//child"'

invalid_from_filter range-start '.ports.hysteria2_start = 9999'
invalid_from_filter range-width '.ports.hysteria2_end = 21126'
invalid_from_filter single-low '.ports.tuic = 9999'
invalid_from_filter base-single-duplicate '.ports.ss2022 = .ports.tuic'
invalid_from_filter range-single-conflict '.ports.tuic = 21050'
invalid_from_filter single-mode-cross-ports '
  .network.mode = "ipv4-only"
'
invalid_from_filter cross-range-conflict '
  .ports.cross.hysteria2_start = 21000
  | .ports.cross.hysteria2_end = 21127
'
invalid_from_filter cross-single-conflict '.ports.cross.tuic = .ports.tuic'
invalid_from_filter cross-range-single-conflict '.ports.cross.tuic = 27050'
invalid_from_filter anyreality-port-conflict '
  .experimental.anyreality = {
    enabled: true,
    port: 22000,
    cross_port: 35000,
    password: "preserved-anyreality-password",
    private_key: .reality.vision_private_key,
    public_key: .reality.vision_public_key,
    short_id: "2122232425262728"
  }
'
invalid_from_filter anyreality-cross-conflict '
  .experimental.anyreality = {
    enabled: true,
    port: 34000,
    cross_port: 28000,
    password: "preserved-anyreality-password",
    private_key: .reality.vision_private_key,
    public_key: .reality.vision_public_key,
    short_id: "2122232425262728"
  }
'

printf '状态、凭据、路径与端口完整验证通过。\n'
