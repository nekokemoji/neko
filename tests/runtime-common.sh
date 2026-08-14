#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-runtime-common.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/config" "$WORK/subscriptions"
cat > "$WORK/bin/runtime-tool" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
tool="${0##*/}"
printf '%s|%s\n' "$tool" "$*" >> "$NEKO_RUNTIME_TEST_COMMAND_LOG"
printf 'stdout:%s\n' "$tool"
printf 'stderr:%s\n' "$tool" >&2
[[ "${NEKO_RUNTIME_TEST_FAIL_TOOL:-}" != "$tool" ]]
EOF
chmod 0755 "$WORK/bin/runtime-tool"
for tool in sing-box xray caddy; do
  ln -s runtime-tool "$WORK/bin/$tool"
done

source "$ROOT/lib/common.sh"
export NEKO_RUNTIME_TEST_COMMAND_LOG="$WORK/commands.log"
: > "$NEKO_RUNTIME_TEST_COMMAND_LOG"
runtime_validate_core_configs \
  --libexec-dir "$WORK/bin" --config-dir "$WORK/config" \
  --subscription-dir "$WORK/subscriptions" \
  --network-mode dual --output all-quiet
cat > "$WORK/expected-commands.log" <<EOF
sing-box|check -c $WORK/config/sing-box.json
sing-box|check -c $WORK/subscriptions/sing-box-v4.json
sing-box|check -c $WORK/subscriptions/sing-box-v6.json
sing-box|check -c $WORK/subscriptions/sing-box-v4-to-v6.json
sing-box|check -c $WORK/subscriptions/sing-box-v6-to-v4.json
xray|run -test -c $WORK/config/xray.json
caddy|validate --config $WORK/config/Caddyfile --adapter caddyfile
EOF
cmp -s "$WORK/expected-commands.log" "$NEKO_RUNTIME_TEST_COMMAND_LOG"

: > "$NEKO_RUNTIME_TEST_COMMAND_LOG"
runtime_validate_core_configs \
  --libexec-dir "$WORK/bin" --config-dir "$WORK/config" \
  --subscription-dir "$WORK/subscriptions" \
  --network-mode ipv6-only --output all-quiet
[[ "$(wc -l < "$NEKO_RUNTIME_TEST_COMMAND_LOG")" == 4 ]]
grep -Fq 'sing-box-v6.json' "$NEKO_RUNTIME_TEST_COMMAND_LOG"
if grep -Fq 'sing-box-v4.json' "$NEKO_RUNTIME_TEST_COMMAND_LOG"; then
  printf 'IPv6-only 公共校验不应检查 IPv4 订阅。\n' >&2
  exit 1
fi

set +e
NEKO_RUNTIME_TEST_FAIL_TOOL=caddy runtime_validate_core_configs \
  --libexec-dir "$WORK/bin" --config-dir "$WORK/config" \
  --subscription-dir "$WORK/subscriptions" \
  --network-mode ipv4-only --output all-quiet
validation_rc=$?
invalid_output="$(runtime_validate_core_configs --network-mode dual 2>&1)"
invalid_rc=$?
set -e
(( validation_rc != 0 ))
(( invalid_rc == 64 ))
[[ "$invalid_output" == *'核心校验选项不完整'* ]]

LEGO_DIR="$WORK/lego"
mkdir -p "$LEGO_DIR/accounts" "$LEGO_DIR/certificates/archive"
: > "$LEGO_DIR/accounts/account.json"
: > "$LEGO_DIR/certificates/example.crt"
chmod -R 0777 "$LEGO_DIR"
runtime_set_lego_permissions \
  --lego-dir "$LEGO_DIR" --service-user unused \
  --ownership preserve --path-policy reject-symlinks
[[ "$(stat -c %a "$LEGO_DIR")" == 750 ]]
[[ "$(stat -c %a "$LEGO_DIR/accounts")" == 700 ]]
[[ "$(stat -c %a "$LEGO_DIR/accounts/account.json")" == 600 ]]
[[ "$(stat -c %a "$LEGO_DIR/certificates")" == 750 ]]
[[ "$(stat -c %a "$LEGO_DIR/certificates/archive")" == 750 ]]
[[ "$(stat -c %a "$LEGO_DIR/certificates/example.crt")" == 640 ]]

NEKO_RUNTIME_TEST_CHOWN_LOG="$WORK/chown.log" bash -c '
  set -Eeuo pipefail
  source "$1"
  chown() { printf "%s\n" "$*" >> "$NEKO_RUNTIME_TEST_CHOWN_LOG"; }
  runtime_set_lego_permissions \
    --lego-dir "$2" --service-user neko-test \
    --ownership managed --path-policy trusted
' _ "$ROOT/lib/common.sh" "$LEGO_DIR"
cat > "$WORK/expected-chown.log" <<EOF
-R root:root $LEGO_DIR
root:neko-test $LEGO_DIR
-R root:neko-test $LEGO_DIR/certificates
EOF
cmp -s "$WORK/expected-chown.log" "$WORK/chown.log"

ln -s "$LEGO_DIR" "$WORK/lego-link"
set +e
runtime_set_lego_permissions \
  --lego-dir "$WORK/lego-link" --service-user unused \
  --ownership preserve --path-policy reject-symlinks
symlink_rc=$?
set -e
(( symlink_rc != 0 ))

SERVICE_LOG="$WORK/services.log"
: > "$SERVICE_LOG"
systemctl_runtime_test() {
  printf '%s\n' "$*" >> "$SERVICE_LOG"
  [[ "${NEKO_RUNTIME_TEST_INACTIVE:-}" != "${*: -1}" ]]
}
runtime_restart_service_set \
  --systemctl-command systemctl_runtime_test --wait-seconds 0 \
  -- neko-caddy neko-sing-box neko-xray neko-hysteria
cat > "$WORK/expected-services.log" <<'EOF'
restart neko-caddy.service neko-sing-box.service neko-xray.service neko-hysteria.service
is-active --quiet neko-caddy.service
is-active --quiet neko-sing-box.service
is-active --quiet neko-xray.service
is-active --quiet neko-hysteria.service
EOF
cmp -s "$WORK/expected-services.log" "$SERVICE_LOG"

set +e
NEKO_RUNTIME_TEST_INACTIVE=neko-xray.service runtime_services_are_active \
  --systemctl-command systemctl_runtime_test \
  -- neko-caddy neko-sing-box neko-xray neko-hysteria
service_rc=$?
set -e
(( service_rc != 0 ))

printf '公共核心校验、lego 权限与服务健康契约测试通过。\n'
