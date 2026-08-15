#!/usr/bin/env bash

# Historical state migration and upgrade rollback contracts.
# This file is sourced by tests/run.sh so the suites keep one shared fixture.
# shellcheck disable=SC2154
[[ "${NEKO_TEST_SUITE_CONTEXT:-}" == 1 ]] || {
  printf '请通过 tests/run.sh 运行测试套件。\n' >&2
  exit 1
}

printf '[10/10] 模拟旧版本原地升级成功与失败回滚……\n'
prepare_upgrade_install() {
  local target="$1" schema="${2:-1}" source_release="${3:-}"
  local source_mode="${4:-dual}"
  local source_has_trojan="${5:-false}" state_tmp
  mkdir -p \
    "$target/etc/config" "$target/etc/subscriptions" \
    "$target/var/acme" "$target/libexec/lib" "$target/systemd" "$target/tmp" \
    "$target/firewall"
  cp -a -- "$WORK/etc/config/." "$target/etc/config/"
  if [[ "$source_release" == "1.2.3-test" ]]; then
    cp -a -- \
      "$WORK/etc/subscriptions/mihomo-v4.yaml" \
      "$WORK/etc/subscriptions/mihomo-v6.yaml" \
      "$WORK/etc/subscriptions/stash-v4.yaml" \
      "$WORK/etc/subscriptions/stash-v6.yaml" \
      "$WORK/etc/subscriptions/shadowrocket-v4.txt" \
      "$WORK/etc/subscriptions/shadowrocket-v6.txt" \
      "$target/etc/subscriptions/"
  else
    cp -a -- "$WORK/etc/subscriptions/mihomo-v4.yaml" \
      "$target/etc/subscriptions/mihomo.yaml"
    cp -a -- "$WORK/etc/subscriptions/stash-v4.yaml" \
      "$target/etc/subscriptions/stash.yaml"
    cp -a -- "$WORK/etc/subscriptions/shadowrocket-v4.txt" \
      "$target/etc/subscriptions/shadowrocket.txt"
  fi
  if [[ "$schema" == 1 ]]; then
    jq '
      .schema = 1
      | .release = "1.0.4-test"
      | del(.acme)
      | del(.network)
      | del(.ports.cross)
      | .subscription = {
          token: .subscription.ipv4_token,
          shadowrocket_server: .subscription.ipv4_address
        }
      | .firewall = {manager: "none", zone: ""}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  elif [[ "$schema" == 2 ]]; then
    jq --arg release "${source_release:-1.1.1-test}" '
      .schema = 2
      | .release = $release
      | .acme = {method: "http-01"}
      | .network = {listen_address: "::"}
      | .subscription.token = .subscription.ipv4_token
      | del(
          .subscription.ipv4_token,
          .subscription.ipv6_token,
          .subscription.ipv4_to_ipv6_token,
          .subscription.ipv6_to_ipv4_token,
          .ports.cross
        )
      | .firewall = {manager: "none", zone: "", zones: []}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  elif [[ "$schema" == 3 ]]; then
    jq \
      --arg release "${source_release:-1.2.4-test}" \
      --arg mode "$source_mode" '
      .schema = 3
      | .release = $release
      | .network = {mode: $mode}
      | .subscription.ipv4_to_ipv6_token = null
      | .subscription.ipv6_to_ipv4_token = null
      | .ports.cross = null
      | if $mode == "ipv4-only" then
          .subscription.ipv6_token = null
          | .subscription.ipv6_domain = null
          | .subscription.ipv6_address = null
        elif $mode == "ipv6-only" then
          .subscription.ipv4_token = null
          | .subscription.ipv4_domain = null
          | .subscription.ipv4_address = null
        else . end
      | .firewall = {manager: "none", zone: "", zones: []}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  else
    jq \
      --arg release "${source_release:-1.9.0-test}" \
      --arg mode "$source_mode" '
      .schema = 4
      | .release = $release
      | .network = {mode: $mode}
      | if $mode == "ipv4-only" then
          .subscription.ipv6_token = null
          | .subscription.ipv4_to_ipv6_token = null
          | .subscription.ipv6_to_ipv4_token = null
          | .subscription.ipv6_domain = null
          | .subscription.ipv6_address = null
          | .ports.cross = null
        elif $mode == "ipv6-only" then
          .subscription.ipv4_token = null
          | .subscription.ipv4_to_ipv6_token = null
          | .subscription.ipv6_to_ipv4_token = null
          | .subscription.ipv4_domain = null
          | .subscription.ipv4_address = null
          | .ports.cross = null
        else . end
      | .firewall = {manager: "none", zone: "", zones: []}
    ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
  fi
  if [[ "$source_has_trojan" != true ]]; then
    state_tmp="$(mktemp "$target/etc/state.json.tmp.XXXXXX")"
    jq 'del(.ports.trojan, .credentials.trojan_password)' \
      "$target/etc/state.json" > "$state_tmp"
    mv -f -- "$state_tmp" "$target/etc/state.json"
  fi
  cp -a -- "$WORK/var/lego" "$target/var/lego"
  cp -a -- "$ROOT/lib/." "$target/libexec/lib/"
  cp -a -- "$ROOT/versions.env" "$target/libexec/versions.env"
  cp -a -- "$ROOT/runtime/panel.sh" "$ROOT/runtime/renew.sh" "$target/libexec/"
  cp -a -- "$ROOT/runtime/panel" "$target/libexec/"
  cp -a -- \
    "$ROOT/tests/fixtures/neko-hysteria-legacy.service" \
    "$target/systemd/neko-hysteria.service"
  ln -s "$SING_BOX" "$target/libexec/sing-box"
  ln -s "$XRAY" "$target/libexec/xray"
  ln -s "$HYSTERIA" "$target/libexec/hysteria"
  ln -s "$CADDY" "$target/libexec/caddy"
  ln -s "$LEGO" "$target/libexec/lego"
}

run_upgrade() {
  local target="$1"
  shift
  env PATH="$ROOT/tests/helpers:$PATH" \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_LIBEXEC="$target/libexec" NEKO_SYSTEMD="$target/systemd" \
    NEKO_STATE="$target/etc/state.json" \
    NEKO_USER=root NEKO_UPDATE_TMP_DIR="$target/tmp" \
    NEKO_UPDATE_LOCK_FILE="$target/upgrade.lock" \
    FIREWALLD_SERVICE_FILE="$target/firewall/neko-proxy.xml" \
    UFW_PROFILE_FILE="$target/firewall/neko-proxy.ufw" \
    NEKO_TEST_FIREWALL_LOG="$target/firewall/commands.log" \
    NEKO_UPDATE_TEST_MODE=1 NEKO_UPDATE_SKIP_ACME=1 \
    NEKO_UPDATE_QRC_BINARY="$QRC" \
    NEKO_UPDATE_NEXTTRACE_BINARY="$NEXTTRACE" \
    NEKO_UPDATE_IPV4_OVERRIDE=192.0.2.10 \
    NEKO_UPDATE_IPV6_OVERRIDE=2001:db8::10 \
    "$@" bash "$ROOT/upgrade.sh"
}

upgrade_payload_manifest() {
  local target="$1"
  tar --sort=name --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -cf - -C "$target" etc var libexec systemd \
    | sha256sum | awk '{print $1}'
}

assert_trojan_migrated() {
  local target="$1" trojan_port expected_inbounds=1
  trojan_port="$(jq -r '.ports.trojan' "$target/etc/state.json")"
  [[ "$trojan_port" =~ ^[0-9]+$ ]]
  (( trojan_port >= 10000 && trojan_port <= 60000 ))
  jq -e '
    (.credentials.trojan_password | test("^[A-Za-z0-9_-]{16,128}$"))
    and ([.ports.hysteria2_start, .ports.hysteria2_end] as $range
      | (.ports.trojan < $range[0] or .ports.trojan > $range[1]))
    and ([.ports.tuic, .ports.ss2022, .ports.anytls,
          .ports.trojan, .ports.vless_reality_vision,
          .ports.vless_reality_xhttp] | length == (unique | length))
  ' "$target/etc/state.json" >/dev/null
  [[ "$(jq -r '.network.mode' "$target/etc/state.json")" != dual ]] \
    || expected_inbounds=4
  jq -e --argjson expected "$expected_inbounds" '
    [.inbounds[] | select(.type == "trojan")] | length == $expected
  ' "$target/etc/config/sing-box.json" >/dev/null
}

assert_cross_routes_migrated() {
  local target="$1"
  jq -e '
    .network.mode == "dual"
    and (.ports.cross | type == "object")
    and (.ports.cross.hysteria2_end - .ports.cross.hysteria2_start == 127)
    and (.subscription.ipv4_to_ipv6_token
      | test("^[A-Za-z0-9_-]{16,128}$"))
    and (.subscription.ipv6_to_ipv4_token
      | test("^[A-Za-z0-9_-]{16,128}$"))
  ' "$target/etc/state.json" >/dev/null
  NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    bash -c 'source "$1"; load_state' \
      _ "$target/libexec/lib/common.sh"
  [[ -s "$target/etc/config/hysteria-v4-to-v6.yaml" ]]
  [[ -s "$target/etc/config/hysteria-v6-to-v4.yaml" ]]
  [[ -s "$target/etc/subscriptions/sing-box-v4-to-v6.json" ]]
  [[ -s "$target/etc/subscriptions/sing-box-v6-to-v4.json" ]]
}

assert_anyreality_migrated() {
  local target="$1" expected_inbounds=1 profile=v4
  [[ "$(jq -r '.network.mode' "$target/etc/state.json")" != dual ]] \
    || expected_inbounds=4
  [[ "$(jq -r '.network.mode' "$target/etc/state.json")" != ipv6-only ]] \
    || profile=v6
  jq -e '
    .experimental.anyreality.enabled == true
    and (.experimental.anyreality.port | type == "number")
    and (.experimental.anyreality.password | test("^[A-Za-z0-9_-]{16,128}$"))
    and (.experimental.anyreality.private_key | test("^[A-Za-z0-9_-]{43}$"))
    and (.experimental.anyreality.public_key | test("^[A-Za-z0-9_-]{43}$"))
    and (.experimental.anyreality.short_id | test("^[0-9a-f]{16}$"))
  ' "$target/etc/state.json" >/dev/null
  [[ "$(jq '[.inbounds[] | select(.tag | startswith("anyreality-"))] | length' \
    "$target/etc/config/sing-box.json")" == "$expected_inbounds" ]]
  grep -Fq 'name: "AnyReality"' \
    "$target/etc/subscriptions/shadowrocket-${profile}.txt"
}

UPGRADE_VERSION_MANIFEST_MISMATCH="$WORK/upgrade-version-manifest-mismatch"
prepare_upgrade_install "$UPGRADE_VERSION_MANIFEST_MISMATCH"
sed -i 's/^XRAY_VERSION=.*/XRAY_VERSION="0.0.0-test"/' \
  "$UPGRADE_VERSION_MANIFEST_MISMATCH/libexec/versions.env"
version_manifest_before="$(
  upgrade_payload_manifest "$UPGRADE_VERSION_MANIFEST_MISMATCH"
)"
set +e
run_upgrade "$UPGRADE_VERSION_MANIFEST_MISMATCH" \
  NEKO_TEST_SYSTEMCTL_LOG="$UPGRADE_VERSION_MANIFEST_MISMATCH/systemctl.log" \
  > "$UPGRADE_VERSION_MANIFEST_MISMATCH/upgrade.log" 2>&1
version_manifest_rc=$?
set -e
(( version_manifest_rc != 0 ))
[[ "$(upgrade_payload_manifest "$UPGRADE_VERSION_MANIFEST_MISMATCH")" \
  == "$version_manifest_before" ]]
[[ ! -e "$UPGRADE_VERSION_MANIFEST_MISMATCH/systemctl.log" ]]
[[ ! -e "$UPGRADE_VERSION_MANIFEST_MISMATCH/firewall/commands.log" ]]
if find "$UPGRADE_VERSION_MANIFEST_MISMATCH/tmp" -mindepth 1 -print -quit \
    | grep -q .; then
  printf '核心清单不同时不应创建升级暂存或备份。\n' >&2
  exit 1
fi
grep -Fq '已安装 Xray 无法确认版本 0.0.0-test；未开始升级' \
  "$UPGRADE_VERSION_MANIFEST_MISMATCH/upgrade.log"

UPGRADE_ACTUAL_CORE_MISMATCH="$WORK/upgrade-actual-core-mismatch"
prepare_upgrade_install "$UPGRADE_ACTUAL_CORE_MISMATCH"
rm -f -- "$UPGRADE_ACTUAL_CORE_MISMATCH/libexec/xray"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "Xray 0.0.0-test (unexpected)\\n"' \
  > "$UPGRADE_ACTUAL_CORE_MISMATCH/libexec/xray"
chmod 0755 "$UPGRADE_ACTUAL_CORE_MISMATCH/libexec/xray"
actual_core_before="$(upgrade_payload_manifest "$UPGRADE_ACTUAL_CORE_MISMATCH")"
set +e
run_upgrade "$UPGRADE_ACTUAL_CORE_MISMATCH" \
  NEKO_TEST_SYSTEMCTL_LOG="$UPGRADE_ACTUAL_CORE_MISMATCH/systemctl.log" \
  > "$UPGRADE_ACTUAL_CORE_MISMATCH/upgrade.log" 2>&1
actual_core_rc=$?
set -e
(( actual_core_rc != 0 ))
[[ "$(upgrade_payload_manifest "$UPGRADE_ACTUAL_CORE_MISMATCH")" \
  == "$actual_core_before" ]]
[[ ! -e "$UPGRADE_ACTUAL_CORE_MISMATCH/systemctl.log" ]]
[[ ! -e "$UPGRADE_ACTUAL_CORE_MISMATCH/firewall/commands.log" ]]
if find "$UPGRADE_ACTUAL_CORE_MISMATCH/tmp" -mindepth 1 -print -quit \
    | grep -q .; then
  printf '实际核心不匹配时不应创建升级暂存或备份。\n' >&2
  exit 1
fi
grep -Fq '无法确认版本 26.3.27；未开始升级' \
  "$UPGRADE_ACTUAL_CORE_MISMATCH/upgrade.log"

UPGRADE_INVALID_STATE="$WORK/upgrade-invalid-state"
prepare_upgrade_install "$UPGRADE_INVALID_STATE" 4 1.9.0-test dual true
jq '.reality.xhttp_path = "/safe?next=/poison"' \
  "$UPGRADE_INVALID_STATE/etc/state.json" \
  > "$UPGRADE_INVALID_STATE/etc/state.invalid.json"
mv -f -- \
  "$UPGRADE_INVALID_STATE/etc/state.invalid.json" \
  "$UPGRADE_INVALID_STATE/etc/state.json"
invalid_state_before="$(upgrade_payload_manifest "$UPGRADE_INVALID_STATE")"
set +e
run_upgrade "$UPGRADE_INVALID_STATE" \
  NEKO_TEST_SYSTEMCTL_LOG="$UPGRADE_INVALID_STATE/systemctl.log" \
  > "$UPGRADE_INVALID_STATE/upgrade.log" 2>&1
invalid_state_rc=$?
set -e
(( invalid_state_rc != 0 ))
[[ "$(upgrade_payload_manifest "$UPGRADE_INVALID_STATE")" \
  == "$invalid_state_before" ]]
[[ ! -e "$UPGRADE_INVALID_STATE/systemctl.log" ]]
[[ ! -e "$UPGRADE_INVALID_STATE/firewall/commands.log" ]]
if find "$UPGRADE_INVALID_STATE/tmp" -mindepth 1 -print -quit | grep -q .; then
  printf '损坏状态被拒绝前不应创建升级暂存或备份。\n' >&2
  exit 1
fi
grep -Fq '现有 state.json 不符合可升级状态契约；未开始升级' \
  "$UPGRADE_INVALID_STATE/upgrade.log"

UPGRADE_OK="$WORK/upgrade-ok"
prepare_upgrade_install "$UPGRADE_OK"
upgrade_identity_before="$(jq -cS '{ports, credentials, reality, token: .subscription.token}' \
  "$UPGRADE_OK/etc/state.json")"
run_upgrade "$UPGRADE_OK" > "$UPGRADE_OK/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_OK/etc/state.json")" == 4 ]]
[[ "$(jq -r '.release' "$UPGRADE_OK/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(jq -r '.network.mode' "$UPGRADE_OK/etc/state.json")" == dual ]]
[[ "$(jq -r '.subscription.ipv4_domain' "$UPGRADE_OK/etc/state.json")" == v4.example.com ]]
[[ "$(jq -r '.subscription.ipv6_domain' "$UPGRADE_OK/etc/state.json")" == v6.example.com ]]
[[ "$(jq -r '.subscription.shadowrocket_server // empty' "$UPGRADE_OK/etc/state.json")" == "" ]]
[[ "$(jq -r '.acme.method' "$UPGRADE_OK/etc/state.json")" == http-01 ]]
[[ "$(jq -cS '{
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality,
    token: .subscription.ipv4_token
  }' \
  "$UPGRADE_OK/etc/state.json")" == "$upgrade_identity_before" ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_OK/etc/state.json")" \
  == "$(jq -r '.token' <<< "$upgrade_identity_before")" ]]
[[ "$(find "$UPGRADE_OK/etc/subscriptions" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 16 ]]
[[ -x "$UPGRADE_OK/libexec/hysteria-dual.sh" ]]
[[ -x "$UPGRADE_OK/libexec/route-diagnostics.sh" ]]
[[ -x "$UPGRADE_OK/libexec/akdns.sh" ]]
for panel_module in \
  system.sh access.sh family.sh third-party.sh akdns-menu.sh route-guide.sh ui.sh; do
  [[ -r "$UPGRADE_OK/libexec/panel/$panel_module" ]]
done
[[ ! -e "$UPGRADE_OK/libexec/diagnostics.sh" ]]
cmp -s -- "$QRC" "$UPGRADE_OK/libexec/qrc"
cmp -s -- "$NEXTTRACE" "$UPGRADE_OK/libexec/nexttrace-tiny"
grep -Fq 'ExecStart=/usr/local/libexec/neko/hysteria-dual.sh' \
  "$UPGRADE_OK/systemd/neko-hysteria.service"
[[ -s "$UPGRADE_OK/etc/config/hysteria-v4.yaml" ]]
[[ -s "$UPGRADE_OK/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_OK/etc/config/hysteria.yaml" ]]
assert_trojan_migrated "$UPGRADE_OK"
assert_cross_routes_migrated "$UPGRADE_OK"
assert_anyreality_migrated "$UPGRADE_OK"
if find "$UPGRADE_OK/tmp" -maxdepth 1 \
    \( -name 'neko-upgrade-backup.*' -o -name 'neko-qrc-stage.*' -o -name 'neko-nexttrace-stage.*' \) \
    | grep -q .; then
  printf '升级成功后没有清理备份目录。\n' >&2
  exit 1
fi

UPGRADE_ACME="$WORK/upgrade-acme"
prepare_upgrade_install "$UPGRADE_ACME"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj /CN=wrong.example.net -addext 'subjectAltName=DNS:wrong.example.net' \
  -keyout "$UPGRADE_ACME/var/lego/certificates/example.com.key" \
  -out "$UPGRADE_ACME/var/lego/certificates/example.com.crt" \
  >/dev/null 2>&1
mkdir -p "$UPGRADE_ACME/helpers"
install -m 0755 "$ROOT/tests/fixtures/openssl-strict-checkhost.sh" \
  "$UPGRADE_ACME/helpers/openssl"
rm -f -- "$UPGRADE_ACME/libexec/lego"
install -m 0755 "$ROOT/tests/fixtures/upgrade-lego.sh" \
  "$UPGRADE_ACME/libexec/lego"
run_upgrade "$UPGRADE_ACME" \
  NEKO_UPDATE_SKIP_ACME=0 \
  NEKO_UPDATE_TEST_REAL_OPENSSL="$(command -v openssl)" \
  NEKO_UPDATE_TEST_LEGO_LOG="$UPGRADE_ACME/lego.log" \
  NEKO_UPDATE_TEST_CERT="$WORK/var/lego/certificates/example.com.crt" \
  NEKO_UPDATE_TEST_KEY="$WORK/var/lego/certificates/example.com.key" \
  PATH="$UPGRADE_ACME/helpers:$ROOT/tests/helpers:$PATH" \
  > "$UPGRADE_ACME/upgrade.log"
if [[ ! -s "$UPGRADE_ACME/lego.log" ]]; then
  printf '升级未对缺少严格域名的证书执行 ACME。\n' >&2
  jq '{schema, network, subscription}' "$UPGRADE_ACME/etc/state.json" >&2
  openssl x509 -in "$UPGRADE_ACME/var/lego/certificates/example.com.crt" \
    -noout -ext subjectAltName >&2
  exit 1
fi
grep -Fq -- '--force-cert-domains' "$UPGRADE_ACME/lego.log"
grep -Fq -- '--renew-force' "$UPGRADE_ACME/lego.log"
openssl x509 -in "$UPGRADE_ACME/var/lego/certificates/example.com.crt" \
  -noout -checkhost v4.example.com | grep -Fq 'does match certificate'
openssl x509 -in "$UPGRADE_ACME/var/lego/certificates/example.com.crt" \
  -noout -checkhost v6.example.com | grep -Fq 'does match certificate'

UPGRADE_SCHEMA2="$WORK/upgrade-schema2"
prepare_upgrade_install "$UPGRADE_SCHEMA2" 2
schema2_identity_before="$(jq -cS '{ports, credentials, reality, token: .subscription.token}' \
  "$UPGRADE_SCHEMA2/etc/state.json")"
run_upgrade "$UPGRADE_SCHEMA2" > "$UPGRADE_SCHEMA2/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_SCHEMA2/etc/state.json")" == 4 ]]
[[ "$(jq -r '.release' "$UPGRADE_SCHEMA2/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(jq -cS '{
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality,
    token: .subscription.ipv4_token
  }' \
  "$UPGRADE_SCHEMA2/etc/state.json")" == "$schema2_identity_before" ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_SCHEMA2/etc/state.json")" \
  == "$(jq -r '.token' <<< "$schema2_identity_before")" ]]
[[ -x "$UPGRADE_SCHEMA2/libexec/hysteria-dual.sh" ]]
[[ -x "$UPGRADE_SCHEMA2/libexec/akdns.sh" ]]
[[ ! -e "$UPGRADE_SCHEMA2/libexec/diagnostics.sh" ]]
[[ -s "$UPGRADE_SCHEMA2/etc/config/hysteria-v4.yaml" ]]
[[ -s "$UPGRADE_SCHEMA2/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_SCHEMA2/etc/config/hysteria.yaml" ]]
assert_trojan_migrated "$UPGRADE_SCHEMA2"
assert_cross_routes_migrated "$UPGRADE_SCHEMA2"
assert_anyreality_migrated "$UPGRADE_SCHEMA2"

UPGRADE_123="$WORK/upgrade-1.2.3"
prepare_upgrade_install "$UPGRADE_123" 2 1.2.3-test
release_123_identity_before="$(jq -cS '{ports, credentials, reality, token: .subscription.token}' \
  "$UPGRADE_123/etc/state.json")"
[[ "$(find "$UPGRADE_123/etc/subscriptions" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 6 ]]
run_upgrade "$UPGRADE_123" > "$UPGRADE_123/upgrade.log"
[[ "$(jq -r '.release' "$UPGRADE_123/etc/state.json")" == "$NEKO_RELEASE" ]]
[[ "$(jq -cS '{
    ports: (.ports | del(.trojan, .cross)),
    credentials: (.credentials | del(.trojan_password)),
    reality,
    token: .subscription.ipv4_token
  }' \
  "$UPGRADE_123/etc/state.json")" == "$release_123_identity_before" ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_123/etc/state.json")" \
  == "$(jq -r '.token' <<< "$release_123_identity_before")" ]]
[[ "$(find "$UPGRADE_123/etc/subscriptions" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 16 ]]
[[ -s "$UPGRADE_123/etc/subscriptions/sing-box-v4.json" ]]
[[ -s "$UPGRADE_123/etc/subscriptions/sing-box-v6.json" ]]
assert_trojan_migrated "$UPGRADE_123"
assert_cross_routes_migrated "$UPGRADE_123"
assert_anyreality_migrated "$UPGRADE_123"

UPGRADE_CURRENT="$WORK/upgrade-current"
prepare_upgrade_install "$UPGRADE_CURRENT" 3 1.7.0-test dual true
current_trojan_before="$(
  jq -cS '{port: .ports.trojan, password: .credentials.trojan_password}' \
    "$UPGRADE_CURRENT/etc/state.json"
)"
run_upgrade "$UPGRADE_CURRENT" > "$UPGRADE_CURRENT/upgrade.log"
[[ "$(jq -cS '{port: .ports.trojan, password: .credentials.trojan_password}' \
  "$UPGRADE_CURRENT/etc/state.json")" == "$current_trojan_before" ]]
assert_trojan_migrated "$UPGRADE_CURRENT"
assert_cross_routes_migrated "$UPGRADE_CURRENT"
assert_anyreality_migrated "$UPGRADE_CURRENT"

UPGRADE_SCHEMA4="$WORK/upgrade-schema4"
prepare_upgrade_install "$UPGRADE_SCHEMA4" 4 1.9.0-test dual true
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
' "$UPGRADE_SCHEMA4/etc/state.json" > "$UPGRADE_SCHEMA4/etc/state.anyreality.json"
mv -f -- "$UPGRADE_SCHEMA4/etc/state.anyreality.json" \
  "$UPGRADE_SCHEMA4/etc/state.json"
schema4_identity_before="$(jq -cS '{
  ports,
  credentials,
  reality,
  experimental,
  tokens: {
    ipv4: .subscription.ipv4_token,
    ipv6: .subscription.ipv6_token,
    ipv4_to_ipv6: .subscription.ipv4_to_ipv6_token,
    ipv6_to_ipv4: .subscription.ipv6_to_ipv4_token
  }
}' "$UPGRADE_SCHEMA4/etc/state.json")"
run_upgrade "$UPGRADE_SCHEMA4" \
  NEKO_TEST_LISTENING_PORTS="34000,35000" \
  > "$UPGRADE_SCHEMA4/upgrade.log"
[[ "$(jq -cS '{
  ports,
  credentials,
  reality,
  experimental,
  tokens: {
    ipv4: .subscription.ipv4_token,
    ipv6: .subscription.ipv6_token,
    ipv4_to_ipv6: .subscription.ipv4_to_ipv6_token,
    ipv6_to_ipv4: .subscription.ipv6_to_ipv4_token
  }
}' "$UPGRADE_SCHEMA4/etc/state.json")" == "$schema4_identity_before" ]]
assert_trojan_migrated "$UPGRADE_SCHEMA4"
assert_cross_routes_migrated "$UPGRADE_SCHEMA4"
assert_anyreality_migrated "$UPGRADE_SCHEMA4"

UPGRADE_SCHEMA4_CONFLICT="$WORK/upgrade-schema4-conflict"
prepare_upgrade_install "$UPGRADE_SCHEMA4_CONFLICT" 4 1.10.0-test dual true
jq '
  .experimental.anyreality = {
    enabled: true,
    port: .ports.anytls,
    cross_port: .ports.cross.anytls,
    password: "conflicting-anyreality-password",
    private_key: .reality.vision_private_key,
    public_key: .reality.vision_public_key,
    short_id: "3132333435363738"
  }
' "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json" \
  > "$UPGRADE_SCHEMA4_CONFLICT/etc/state.anyreality.json"
mv -f -- "$UPGRADE_SCHEMA4_CONFLICT/etc/state.anyreality.json" \
  "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json"
schema4_conflict_before="$(
  sha256sum "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json" | awk '{print $1}'
)"
set +e
run_upgrade "$UPGRADE_SCHEMA4_CONFLICT" \
  > "$UPGRADE_SCHEMA4_CONFLICT/upgrade.log" 2>&1
schema4_conflict_rc=$?
set -e
(( schema4_conflict_rc != 0 ))
grep -Fq 'AnyReality 端口' "$UPGRADE_SCHEMA4_CONFLICT/upgrade.log"
grep -Fq '与 AnyTLS 冲突' "$UPGRADE_SCHEMA4_CONFLICT/upgrade.log"
[[ "$(sha256sum "$UPGRADE_SCHEMA4_CONFLICT/etc/state.json" | awk '{print $1}')" \
  == "$schema4_conflict_before" ]]

UPGRADE_FIREWALL="$WORK/upgrade-firewall"
prepare_upgrade_install "$UPGRADE_FIREWALL" 3 1.6.1-test dual false
printf '%s\n' '<service><port protocol="tcp" port="23000"/></service>' \
  > "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
jq '
  .firewall = {manager: "firewalld", zone: "public", zones: ["public"]}
' "$UPGRADE_FIREWALL/etc/state.json" \
  > "$UPGRADE_FIREWALL/etc/state.firewall.json"
mv -f -- \
  "$UPGRADE_FIREWALL/etc/state.firewall.json" \
  "$UPGRADE_FIREWALL/etc/state.json"
run_upgrade "$UPGRADE_FIREWALL" > "$UPGRADE_FIREWALL/upgrade.log"
firewall_trojan_port="$(
  jq -r '.ports.trojan' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_cross_trojan_port="$(
  jq -r '.ports.cross.trojan' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_anyreality_port="$(
  jq -r '.experimental.anyreality.port' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_cross_anyreality_port="$(
  jq -r '.experimental.anyreality.cross_port' "$UPGRADE_FIREWALL/etc/state.json"
)"
firewall_cross_hy2_range="$(
  jq -r '.ports.cross | "\(.hysteria2_start)-\(.hysteria2_end)"' \
    "$UPGRADE_FIREWALL/etc/state.json"
)"
grep -Fq "protocol=\"tcp\" port=\"${firewall_trojan_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"tcp\" port=\"${firewall_cross_trojan_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"tcp\" port=\"${firewall_anyreality_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"tcp\" port=\"${firewall_cross_anyreality_port}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fq "protocol=\"udp\" port=\"${firewall_cross_hy2_range}\"" \
  "$UPGRADE_FIREWALL/firewall/neko-proxy.xml"
grep -Fxq -- '--reload' "$UPGRADE_FIREWALL/firewall/commands.log"
grep -Fxq -- '--zone=public --query-service=neko-proxy' \
  "$UPGRADE_FIREWALL/firewall/commands.log"
assert_trojan_migrated "$UPGRADE_FIREWALL"
assert_cross_routes_migrated "$UPGRADE_FIREWALL"
assert_anyreality_migrated "$UPGRADE_FIREWALL"

UPGRADE_FIREWALL_INACTIVE="$WORK/upgrade-firewall-inactive"
prepare_upgrade_install "$UPGRADE_FIREWALL_INACTIVE" 3 1.6.1-test dual false
printf '%s\n' '<service><port protocol="tcp" port="23000"/></service>' \
  > "$UPGRADE_FIREWALL_INACTIVE/firewall/neko-proxy.xml"
jq '
  .firewall = {manager: "firewalld", zone: "public", zones: ["public"]}
' "$UPGRADE_FIREWALL_INACTIVE/etc/state.json" \
  > "$UPGRADE_FIREWALL_INACTIVE/etc/state.firewall.json"
mv -f -- \
  "$UPGRADE_FIREWALL_INACTIVE/etc/state.firewall.json" \
  "$UPGRADE_FIREWALL_INACTIVE/etc/state.json"
inactive_state_before="$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/etc/state.json" | awk '{print $1}'
)"
inactive_profile_before="$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/firewall/neko-proxy.xml" \
    | awk '{print $1}'
)"
set +e
run_upgrade "$UPGRADE_FIREWALL_INACTIVE" \
  NEKO_TEST_FIREWALL_INACTIVE=1 \
  > "$UPGRADE_FIREWALL_INACTIVE/upgrade.log" 2>&1
inactive_upgrade_rc=$?
set -e
(( inactive_upgrade_rc != 0 ))
[[ "$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/etc/state.json" | awk '{print $1}'
)" == "$inactive_state_before" ]]
[[ "$(
  sha256sum "$UPGRADE_FIREWALL_INACTIVE/firewall/neko-proxy.xml" \
    | awk '{print $1}'
)" == "$inactive_profile_before" ]]
grep -Fq 'firewalld 当前未运行；未开始升级' \
  "$UPGRADE_FIREWALL_INACTIVE/upgrade.log"

UPGRADE_V4="$WORK/upgrade-v4-only"
prepare_upgrade_install "$UPGRADE_V4" 3 1.2.4-test ipv4-only
v4_token_before="$(jq -r '.subscription.ipv4_token' "$UPGRADE_V4/etc/state.json")"
run_upgrade "$UPGRADE_V4" > "$UPGRADE_V4/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_V4/etc/state.json")" == 4 ]]
[[ "$(jq -r '.network.mode' "$UPGRADE_V4/etc/state.json")" == ipv4-only ]]
[[ "$(jq -r '.subscription.ipv4_token' "$UPGRADE_V4/etc/state.json")" \
  == "$v4_token_before" ]]
[[ "$(jq -r '.subscription.ipv6_token // empty' "$UPGRADE_V4/etc/state.json")" == "" ]]
[[ "$(jq -r '.subscription.ipv4_to_ipv6_token // empty' \
  "$UPGRADE_V4/etc/state.json")" == "" ]]
[[ "$(jq -r '.ports.cross // empty' "$UPGRADE_V4/etc/state.json")" == "" ]]
[[ "$(find "$UPGRADE_V4/etc/subscriptions" -maxdepth 1 -type f \
  | wc -l | tr -d ' ')" == 4 ]]
[[ -s "$UPGRADE_V4/etc/config/hysteria-v4.yaml" ]]
[[ ! -e "$UPGRADE_V4/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_V4/etc/config/hysteria-v4-to-v6.yaml" ]]
[[ ! -e "$UPGRADE_V4/etc/config/hysteria-v6-to-v4.yaml" ]]
assert_trojan_migrated "$UPGRADE_V4"
assert_anyreality_migrated "$UPGRADE_V4"

UPGRADE_V6="$WORK/upgrade-v6-only"
prepare_upgrade_install "$UPGRADE_V6" 3 1.2.4-test ipv6-only
v6_token_before="$(jq -r '.subscription.ipv6_token' "$UPGRADE_V6/etc/state.json")"
run_upgrade "$UPGRADE_V6" > "$UPGRADE_V6/upgrade.log"
[[ "$(jq -r '.schema' "$UPGRADE_V6/etc/state.json")" == 4 ]]
[[ "$(jq -r '.network.mode' "$UPGRADE_V6/etc/state.json")" == ipv6-only ]]
[[ "$(jq -r '.subscription.ipv6_token' "$UPGRADE_V6/etc/state.json")" \
  == "$v6_token_before" ]]
[[ "$(jq -r '.subscription.ipv4_token // empty' "$UPGRADE_V6/etc/state.json")" == "" ]]
[[ "$(jq -r '.subscription.ipv6_to_ipv4_token // empty' \
  "$UPGRADE_V6/etc/state.json")" == "" ]]
[[ "$(jq -r '.ports.cross // empty' "$UPGRADE_V6/etc/state.json")" == "" ]]
[[ "$(find "$UPGRADE_V6/etc/subscriptions" -maxdepth 1 -type f \
  | wc -l | tr -d ' ')" == 4 ]]
[[ ! -e "$UPGRADE_V6/etc/config/hysteria-v4.yaml" ]]
[[ -s "$UPGRADE_V6/etc/config/hysteria-v6.yaml" ]]
[[ ! -e "$UPGRADE_V6/etc/config/hysteria-v4-to-v6.yaml" ]]
[[ ! -e "$UPGRADE_V6/etc/config/hysteria-v6-to-v4.yaml" ]]
assert_trojan_migrated "$UPGRADE_V6"
assert_anyreality_migrated "$UPGRADE_V6"

UPGRADE_FAIL="$WORK/upgrade-fail"
prepare_upgrade_install "$UPGRADE_FAIL"
# Model a pre-R8 installation: the façade existed, but no panel module tree did.
rm -rf -- "$UPGRADE_FAIL/libexec/panel"
printf '%s\n' '#!/usr/bin/env bash' 'printf "legacy panel\\n"' \
  > "$UPGRADE_FAIL/libexec/panel.sh"
chmod 0755 "$UPGRADE_FAIL/libexec/panel.sh"
printf '%s\n' '<service><port protocol="tcp" port="23000"/></service>' \
  > "$UPGRADE_FAIL/firewall/neko-proxy.xml"
jq '
  .firewall = {manager: "firewalld", zone: "public", zones: ["public"]}
' "$UPGRADE_FAIL/etc/state.json" > "$UPGRADE_FAIL/etc/state.firewall.json"
mv -f -- \
  "$UPGRADE_FAIL/etc/state.firewall.json" "$UPGRADE_FAIL/etc/state.json"
cp -a -- "$ROOT/tests/helpers/systemctl" "$UPGRADE_FAIL/libexec/qrc"
cp -a -- "$ROOT/tests/helpers/systemctl" "$UPGRADE_FAIL/libexec/nexttrace-tiny"
qrc_before="$(sha256sum "$UPGRADE_FAIL/libexec/qrc" | awk '{print $1}')"
nexttrace_before="$(
  sha256sum "$UPGRADE_FAIL/libexec/nexttrace-tiny" | awk '{print $1}'
)"
state_before="$(sha256sum "$UPGRADE_FAIL/etc/state.json" | awk '{print $1}')"
config_before="$(sha256sum "$UPGRADE_FAIL/etc/config/Caddyfile" | awk '{print $1}')"
unit_before="$(sha256sum "$UPGRADE_FAIL/systemd/neko-hysteria.service" | awk '{print $1}')"
firewall_before="$(
  sha256sum "$UPGRADE_FAIL/firewall/neko-proxy.xml" | awk '{print $1}'
)"
subscriptions_before="$(
  find "$UPGRADE_FAIL/etc/subscriptions" -maxdepth 1 -type f -printf '%f\n' \
    | sort | sha256sum | awk '{print $1}'
)"
set +e
run_upgrade "$UPGRADE_FAIL" \
  NEKO_TEST_SYSTEMCTL_FAIL_PATTERN='restart neko-sing-box.service' \
  NEKO_TEST_SYSTEMCTL_FAIL_ONCE_FILE="$UPGRADE_FAIL/systemctl-failed-once" \
  > "$UPGRADE_FAIL/upgrade.log" 2>&1
upgrade_rc=$?
set -e
(( upgrade_rc != 0 ))
[[ "$(sha256sum "$UPGRADE_FAIL/etc/state.json" | awk '{print $1}')" == "$state_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/etc/config/Caddyfile" | awk '{print $1}')" == "$config_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/systemd/neko-hysteria.service" | awk '{print $1}')" == "$unit_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/firewall/neko-proxy.xml" | awk '{print $1}')" \
  == "$firewall_before" ]]
grep -Fxq -- '--reload' "$UPGRADE_FAIL/firewall/commands.log"
[[ "$(sha256sum "$UPGRADE_FAIL/libexec/qrc" | awk '{print $1}')" == "$qrc_before" ]]
[[ "$(sha256sum "$UPGRADE_FAIL/libexec/nexttrace-tiny" | awk '{print $1}')" \
  == "$nexttrace_before" ]]
[[ "$(
  find "$UPGRADE_FAIL/etc/subscriptions" -maxdepth 1 -type f -printf '%f\n' \
    | sort | sha256sum | awk '{print $1}'
)" == "$subscriptions_before" ]]
[[ ! -e "$UPGRADE_FAIL/libexec/hysteria-dual.sh" ]]
[[ ! -e "$UPGRADE_FAIL/libexec/akdns.sh" ]]
[[ ! -e "$UPGRADE_FAIL/libexec/diagnostics.sh" ]]
[[ ! -e "$UPGRADE_FAIL/libexec/panel" ]]
grep -Fq '正在恢复升级前的状态' "$UPGRADE_FAIL/upgrade.log"
if find "$UPGRADE_FAIL/tmp" -maxdepth 1 \
    \( -name 'neko-upgrade-backup.*' -o -name 'neko-qrc-stage.*' -o -name 'neko-nexttrace-stage.*' \) \
    | grep -q .; then
  printf '升级回滚后没有清理备份目录。\n' >&2
  exit 1
fi

# shellcheck source=tests/suites/upgrade-core-transaction.sh
source "$ROOT/tests/suites/upgrade-core-transaction.sh"

printf '全部测试通过。\n'
