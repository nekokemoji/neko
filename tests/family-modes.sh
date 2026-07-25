#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
XRAY="$TOOLS/xray"
SING_BOX="$TOOLS/sing-box"
HYSTERIA="$TOOLS/hysteria"
CADDY="$TOOLS/caddy"
MIHOMO="${MIHOMO_BIN:-$TOOLS/mihomo}"
WORK="$(mktemp -d /tmp/neko-family-modes.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

for binary in "$XRAY" "$SING_BOX" "$HYSTERIA" "$CADDY" "$MIHOMO"; do
  [[ -x "$binary" ]] || {
    printf '地址族测试缺少核心：%s\n' "$binary" >&2
    exit 1
  }
done

prepare_mode() {
  local mode="$1" target="$2"
  mkdir -p \
    "$target/etc" "$target/var/lego/certificates" \
    "$target/var/acme" "$target/mihomo"
  case "$mode" in
    ipv4-only)
      jq '
        .network.mode = "ipv4-only"
        | .subscription.ipv6_token = null
        | .subscription.ipv6_domain = null
        | .subscription.ipv6_address = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    ipv6-only)
      jq '
        .network.mode = "ipv6-only"
        | .subscription.ipv4_token = null
        | .subscription.ipv4_domain = null
        | .subscription.ipv4_address = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    dual)
      cp -a -- "$ROOT/tests/fixtures/state.json" "$target/etc/state.json"
      ;;
    *) return 64 ;;
  esac
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj /CN=example.com \
    -addext 'subjectAltName=DNS:example.com,DNS:v4.example.com,DNS:v6.example.com' \
    -keyout "$target/var/lego/certificates/example.com.key" \
    -out "$target/var/lego/certificates/example.com.crt" >/dev/null 2>&1
}

render_mode() {
  local target="$1"
  NEKO_ETC="$target/etc" \
    NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" \
    NEKO_USER=root \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      source "$2"
      render_all
    ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
}

printf '[地址族] 三种模式使用冻结核心校验……\n'
for mode in ipv4-only ipv6-only dual; do
  target="$WORK/core-$mode"
  prepare_mode "$mode" "$target"
  render_mode "$target"
  "$SING_BOX" check -c "$target/etc/config/sing-box.json"
  "$XRAY" run -test -c "$target/etc/config/xray.json" >/dev/null
  "$CADDY" validate \
    --config "$target/etc/config/Caddyfile" --adapter caddyfile >/dev/null

  case "$mode" in
    ipv4-only)
      families=(v4)
      ;;
    ipv6-only)
      families=(v6)
      ;;
    dual)
      families=(v4 v6)
      ;;
  esac
  for family in "${families[@]}"; do
    "$SING_BOX" check \
      -c "$target/etc/subscriptions/sing-box-${family}.json"
    mkdir -p "$target/mihomo/$family"
    "$MIHOMO" -d "$target/mihomo/$family" -t \
      -f "$target/etc/subscriptions/mihomo-${family}.yaml" >/dev/null
    set +e
    PATH=/nonexistent "$HYSTERIA" server --disable-update-check \
      --config "$target/etc/config/hysteria-${family}.yaml" \
      >"$target/hysteria-${family}.log" 2>&1
    hysteria_rc=$?
    set -e
    (( hysteria_rc != 0 ))
    grep -Fq 'executable file not found' "$target/hysteria-${family}.log"
  done
done

printf '[地址族] Caddy 接受证书扩容前的短暂双栈配置……\n'
CADDY_EXPAND="$WORK/caddy-expand"
mkdir -p "$CADDY_EXPAND/etc" "$CADDY_EXPAND/var/lego/certificates"
cp -a -- "$ROOT/tests/fixtures/state.json" "$CADDY_EXPAND/etc/state.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj /CN=example.com \
  -addext 'subjectAltName=DNS:example.com,DNS:v4.example.com' \
  -keyout "$CADDY_EXPAND/var/lego/certificates/example.com.key" \
  -out "$CADDY_EXPAND/var/lego/certificates/example.com.crt" >/dev/null 2>&1
render_mode "$CADDY_EXPAND"
"$CADDY" validate \
  --config "$CADDY_EXPAND/etc/config/Caddyfile" --adapter caddyfile >/dev/null

printf '[地址族] DNS 与路由检查只要求所选地址族……\n'
bash -c '
  set -Eeuo pipefail
  source "$1"
  query_log="$2"
  resolved_ipv4_addresses() {
    printf "A %s\n" "$1" >> "$query_log"
    case "$1" in
      example.com|v4.example.com) printf "192.0.2.44\n" ;;
    esac
  }
  resolved_ipv6_addresses() {
    printf "AAAA %s\n" "$1" >> "$query_log"
  }
  NETWORK_MODE=ipv4-only
  check_strict_stack_dns example.com "$NETWORK_MODE" >/dev/null 2>&1
  [[ "$SUBSCRIPTION_IPV4_ADDRESS" == 192.0.2.44 ]]
  [[ -z "$SUBSCRIPTION_IPV6_ADDRESS" ]]
  ! grep -Fq "v6.example.com" "$query_log"
' _ "$ROOT/lib/common.sh" "$WORK/dns-v4.log"

bash -c '
  set -Eeuo pipefail
  source "$1"
  query_log="$2"
  resolved_ipv4_addresses() {
    printf "A %s\n" "$1" >> "$query_log"
  }
  resolved_ipv6_addresses() {
    printf "AAAA %s\n" "$1" >> "$query_log"
    case "$1" in
      example.com|v6.example.com) printf "2001:db8::44\n" ;;
    esac
  }
  NETWORK_MODE=ipv6-only
  check_strict_stack_dns example.com "$NETWORK_MODE" >/dev/null 2>&1
  [[ -z "$SUBSCRIPTION_IPV4_ADDRESS" ]]
  [[ "$SUBSCRIPTION_IPV6_ADDRESS" == 2001:db8::44 ]]
  ! grep -Fq "v4.example.com" "$query_log"
' _ "$ROOT/lib/common.sh" "$WORK/dns-v6.log"

if bash -c '
  set -Eeuo pipefail
  source "$1"
  resolved_ipv4_addresses() {
    case "$1" in example.com|v4.example.com) printf "192.0.2.44\n" ;; esac
  }
  resolved_ipv6_addresses() {
    case "$1" in example.com) printf "2001:db8::44\n" ;; esac
  }
  check_strict_stack_dns example.com ipv4-only
' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
  printf 'IPv4-only 错误接受了基础域名的 AAAA。\n' >&2
  exit 1
fi

if bash -c '
  set -Eeuo pipefail
  source "$1"
  dig() {
    printf "%s\n" \
      ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1" \
      "v4.example.com. 60 IN CNAME target.example.net." \
      "target.example.net. 60 IN A 192.0.2.44"
  }
  [[ -z "$(resolved_ipv4_addresses v4.example.com)" ]]
' _ "$ROOT/lib/common.sh"; then
  :
else
  printf '严格 DNS 检查错误接受了 CNAME 目标地址。\n' >&2
  exit 1
fi

printf '[地址族] 旧安装缺少 dig 时只补 DNS 查询依赖……\n'
DNS_TOOL_LOG="$WORK/dns-tool.log"
bash -c '
  set -Eeuo pipefail
  source "$1"
  log="$2"
  PATH=/nonexistent
  apt-get() {
    printf "%s\n" "$*" >> "$log"
    if [[ "$1" == install ]]; then
      eval "dig() { :; }"
    fi
  }
  ensure_dns_query_tool >/dev/null
  command -v dig >/dev/null
' _ "$ROOT/lib/common.sh" "$DNS_TOOL_LOG"
grep -Fxq 'update' "$DNS_TOOL_LOG"
grep -Fxq 'install -y --no-install-recommends bind9-dnsutils' "$DNS_TOOL_LOG"

printf '[地址族] 安装参数接受三种模式并保持非交互兼容默认值……\n'
for requested_mode in ipv4-only ipv6-only dual; do
  bash -c '
    set -Eeuo pipefail
    source "$1"
    trap - EXIT
    NETWORK_MODE_INPUT="$2"
    collect_network_mode
    [[ "$NETWORK_MODE" == "$2" ]]
  ' _ "$ROOT/install.sh" "$requested_mode"
done
bash -c '
  set -Eeuo pipefail
  source "$1"
  trap - EXIT
  NETWORK_MODE_INPUT=""
  collect_network_mode >/dev/null
  [[ "$NETWORK_MODE" == "$NETWORK_MODE_DUAL" ]]
' _ "$ROOT/install.sh" </dev/null

printf '[地址族] Hysteria 监管器支持单进程与双进程……\n'
SUPERVISOR="$WORK/supervisor"
mkdir -p "$SUPERVISOR/config"
cat > "$SUPERVISOR/fake-hysteria" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
config=""
while (( $# )); do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "${config##*/}" >> "$NEKO_SUPERVISOR_LOG"
exit 0
EOF
chmod 0755 "$SUPERVISOR/fake-hysteria"
printf 'listen: v4\n' > "$SUPERVISOR/config/hysteria-v4.yaml"
set +e
NEKO_HYSTERIA_BINARY="$SUPERVISOR/fake-hysteria" \
  NEKO_CONFIG_DIR="$SUPERVISOR/config" \
  NEKO_SUPERVISOR_LOG="$SUPERVISOR/started" \
  "$ROOT/runtime/hysteria-dual.sh"
supervisor_rc=$?
set -e
(( supervisor_rc != 0 ))
[[ "$(<"$SUPERVISOR/started")" == hysteria-v4.yaml ]]

printf '[地址族] 控制面板按地址族重置 Token……\n'
prepare_rotate_case() {
  local name="$1" mode="$2" target
  target="$WORK/rotate-$name"
  prepare_mode "$mode" "$target"
}

run_rotate_case() {
  local name="$1" input="$2" target
  target="$WORK/rotate-$name"
  env \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    NEKO_LIBEXEC="$ROOT" NEKO_TEST_NEW_TOKEN="new-${name}-token-value" \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      acquire_maintenance_lock() { :; }
      release_maintenance_lock() { :; }
      random_urlsafe() { printf "%s" "$NEKO_TEST_NEW_TOKEN"; }
      render_all() { printf "render\n" >> "$NEKO_ETC/calls"; }
      validate_runtime_configs() { :; }
      systemctl() { return 0; }
      show_subscription_links() { :; }
      rotate_subscription <<< "$2"
    ' _ "$ROOT/runtime/panel.sh" "$input" \
    > "$target/output" 2>&1
}

prepare_rotate_case ipv4 dual
old_v6_token="$(jq -r '.subscription.ipv6_token' "$WORK/rotate-ipv4/etc/state.json")"
run_rotate_case ipv4 $'1\ny'
[[ "$(jq -r '.subscription.ipv4_token' "$WORK/rotate-ipv4/etc/state.json")" \
  == new-ipv4-token-value ]]
[[ "$(jq -r '.subscription.ipv6_token' "$WORK/rotate-ipv4/etc/state.json")" \
  == "$old_v6_token" ]]

prepare_rotate_case ipv6 dual
old_v4_token="$(jq -r '.subscription.ipv4_token' "$WORK/rotate-ipv6/etc/state.json")"
run_rotate_case ipv6 $'2\ny'
[[ "$(jq -r '.subscription.ipv4_token' "$WORK/rotate-ipv6/etc/state.json")" \
  == "$old_v4_token" ]]
[[ "$(jq -r '.subscription.ipv6_token' "$WORK/rotate-ipv6/etc/state.json")" \
  == new-ipv6-token-value ]]

prepare_rotate_case both dual
run_rotate_case both $'3\ny'
[[ "$(jq -r '.subscription.ipv4_token' "$WORK/rotate-both/etc/state.json")" \
  == new-both-token-value ]]
[[ "$(jq -r '.subscription.ipv6_token' "$WORK/rotate-both/etc/state.json")" \
  == new-both-token-value ]]

prepare_rotate_case absent ipv4-only
absent_hash="$(sha256sum "$WORK/rotate-absent/etc/state.json" | awk '{print $1}')"
run_rotate_case absent $'2'
[[ "$(sha256sum "$WORK/rotate-absent/etc/state.json" | awk '{print $1}')" \
  == "$absent_hash" ]]
[[ ! -e "$WORK/rotate-absent/etc/calls" ]]
grep -Fq 'IPv6 尚未安装' "$WORK/rotate-absent/output"

prepare_rotate_case single-both ipv4-only
run_rotate_case single-both $'3\ny\ny'
[[ "$(jq -r '.subscription.ipv4_token' \
  "$WORK/rotate-single-both/etc/state.json")" == new-single-both-token-value ]]
[[ "$(jq -r '.subscription.ipv6_token // empty' \
  "$WORK/rotate-single-both/etc/state.json")" == "" ]]

printf '[地址族] 面板补装成功与失败回滚……\n'
prepare_add_case() {
  local name="$1" target
  target="$WORK/add-$name"
  prepare_mode ipv4-only "$target"
  mkdir -p "$target/tmp"
  printf 'dummy certificate\n' \
    > "$target/var/lego/certificates/example.com.crt"
  printf 'dummy key\n' \
    > "$target/var/lego/certificates/example.com.key"
}

run_add_case() {
  local name="$1" case_mode="$2" target
  target="$WORK/add-$name"
  set +e
  env \
    CASE_MODE="$case_mode" CASE_DIR="$target" \
    NEKO_ETC="$target/etc" NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" NEKO_USER=root \
    NEKO_LIBEXEC="$ROOT" NEKO_PANEL_TMP_DIR="$target/tmp" \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      acquire_maintenance_lock() { printf "lock\n" >> "$CASE_DIR/calls"; }
      release_maintenance_lock() { printf "unlock\n" >> "$CASE_DIR/calls"; }
      assert_network_mode_kernel() { printf "kernel\n" >> "$CASE_DIR/calls"; }
      check_strict_stack_dns() {
        printf "dns\n" >> "$CASE_DIR/calls"
        SUBSCRIPTION_DOMAIN_IPV4="v4.example.com"
        SUBSCRIPTION_DOMAIN_IPV6="v6.example.com"
        SUBSCRIPTION_IPV4_ADDRESS="127.0.0.1"
        SUBSCRIPTION_IPV6_ADDRESS="::1"
      }
      assert_strict_addresses_local() { printf "local\n" >> "$CASE_DIR/calls"; }
      preflight_family_firewall_add() { printf "firewall-preflight\n" >> "$CASE_DIR/calls"; }
      random_urlsafe() { printf "new-ipv6-family-token"; }
      render_all() { printf "render\n" >> "$CASE_DIR/calls"; }
      validate_runtime_configs() { printf "validate\n" >> "$CASE_DIR/calls"; }
      certificate_has_active_domains() {
        if [[ "$CASE_MODE" != expand ]]; then
          return 0
        fi
        local count=0
        [[ ! -e "$CASE_DIR/certificate-checks" ]] \
          || count="$(<"$CASE_DIR/certificate-checks")"
        count=$((count + 1))
        printf "%s\n" "$count" > "$CASE_DIR/certificate-checks"
        (( count >= 2 ))
      }
      run_lego_acme() {
        printf "%s|%s\n" "$ACME_METHOD" "$*" >> "$CASE_DIR/lego-calls"
      }
      set_runtime_certificate_permissions() { :; }
      firewalld_target_zones() {
        printf "%s\n" public existing6 new6
      }
      firewall-cmd() {
        printf "%s\n" "$*" >> "$CASE_DIR/firewall-calls"
        case "$*" in
          *"--permanent --zone=existing6 --query-service=neko-proxy"*)
            return 0
            ;;
          *"--permanent"*"--query-service=neko-proxy"*)
            return 1
            ;;
          *) return 0 ;;
        esac
      }
      openssl() { return 0; }
      systemctl() { return 0; }
      restart_runtime_services() {
        printf "restart\n" >> "$CASE_DIR/calls"
        [[ "$CASE_MODE" != rollback && "$CASE_MODE" != firewall-rollback ]]
      }
      show_subscription_links() { :; }
      add_missing_address_family ipv6 <<< "y"
    ' _ "$ROOT/runtime/panel.sh" > "$target/output" 2>&1
  printf '%s\n' "$?" > "$target/rc"
  set -e
}

prepare_add_case success
old_ipv4_token="$(jq -r '.subscription.ipv4_token' \
  "$WORK/add-success/etc/state.json")"
run_add_case success success
[[ "$(<"$WORK/add-success/rc")" == 0 ]]
[[ "$(jq -r '.network.mode' "$WORK/add-success/etc/state.json")" == dual ]]
[[ "$(jq -r '.subscription.ipv4_token' \
  "$WORK/add-success/etc/state.json")" == "$old_ipv4_token" ]]
[[ "$(jq -r '.subscription.ipv6_token' \
  "$WORK/add-success/etc/state.json")" == new-ipv6-family-token ]]
[[ "$(jq -r '.subscription.ipv6_address' \
  "$WORK/add-success/etc/state.json")" == ::1 ]]
[[ "$(find "$WORK/add-success/tmp" -maxdepth 1 -name 'neko-family-backup.*' \
  | wc -l | tr -d ' ')" == 0 ]]

state_success_hash="$(sha256sum "$WORK/add-success/etc/state.json" | awk '{print $1}')"
env \
  NEKO_ETC="$WORK/add-success/etc" NEKO_VAR="$WORK/add-success/var" \
  NEKO_STATE="$WORK/add-success/etc/state.json" NEKO_USER=root \
  NEKO_LIBEXEC="$ROOT" \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    render_all() { printf "unexpected-render\n" >> "$NEKO_ETC/noop-calls"; }
    show_subscription_links() { :; }
    add_missing_address_family ipv6
  ' _ "$ROOT/runtime/panel.sh" > "$WORK/add-success/noop-output" 2>&1
[[ "$(sha256sum "$WORK/add-success/etc/state.json" | awk '{print $1}')" \
  == "$state_success_hash" ]]
[[ ! -e "$WORK/add-success/etc/noop-calls" ]]
grep -Fq 'IPv6 已经安装' "$WORK/add-success/noop-output"

prepare_add_case rollback
rollback_hash="$(sha256sum "$WORK/add-rollback/etc/state.json" | awk '{print $1}')"
run_add_case rollback rollback
[[ "$(<"$WORK/add-rollback/rc")" != 0 ]]
[[ "$(sha256sum "$WORK/add-rollback/etc/state.json" | awk '{print $1}')" \
  == "$rollback_hash" ]]
[[ "$(find "$WORK/add-rollback/tmp" -maxdepth 1 -name 'neko-family-backup.*' \
  | wc -l | tr -d ' ')" == 0 ]]
grep -Fq '已恢复补装前' "$WORK/add-rollback/output"

prepare_add_case expand
run_add_case expand expand
[[ "$(<"$WORK/add-expand/rc")" == 0 ]]
[[ "$(<"$WORK/add-expand/certificate-checks")" == 2 ]]
grep -Fq \
  'http-01|'"$ROOT"'/lego webroot run --path '"$WORK"'/add-expand/var/lego' \
  "$WORK/add-expand/lego-calls"
grep -Fq -- '--domains example.com --domains v4.example.com --domains v6.example.com' \
  "$WORK/add-expand/lego-calls"

prepare_add_case firewall-rollback
jq '
  .firewall = {
    manager: "firewalld",
    zone: "public",
    zones: ["public"]
  }
' "$WORK/add-firewall-rollback/etc/state.json" \
  > "$WORK/add-firewall-rollback/etc/state.json.tmp"
mv -f -- \
  "$WORK/add-firewall-rollback/etc/state.json.tmp" \
  "$WORK/add-firewall-rollback/etc/state.json"
firewall_rollback_hash="$(
  sha256sum "$WORK/add-firewall-rollback/etc/state.json" | awk '{print $1}'
)"
run_add_case firewall-rollback firewall-rollback
[[ "$(<"$WORK/add-firewall-rollback/rc")" != 0 ]]
[[ "$(sha256sum "$WORK/add-firewall-rollback/etc/state.json" | awk '{print $1}')" \
  == "$firewall_rollback_hash" ]]
grep -Fq -- \
  '--permanent --zone=new6 --add-service=neko-proxy' \
  "$WORK/add-firewall-rollback/firewall-calls"
grep -Fq -- \
  '--permanent --zone=new6 --remove-service=neko-proxy' \
  "$WORK/add-firewall-rollback/firewall-calls"
if grep -Fq -- '--zone=existing6 --add-service=neko-proxy' \
  "$WORK/add-firewall-rollback/firewall-calls" \
  || grep -Fq -- '--zone=existing6 --remove-service=neko-proxy' \
    "$WORK/add-firewall-rollback/firewall-calls"; then
  printf 'firewalld 回滚错误修改了预先存在的区域规则。\n' >&2
  exit 1
fi

NEKO_ETC=/ NEKO_VAR=/var NEKO_LIBEXEC="$ROOT" \
  bash -c '
    set -Eeuo pipefail
    source "$1"
    ! family_restore_paths_are_safe
  ' _ "$ROOT/runtime/panel.sh"

printf '地址族模式、Token 与面板补装事务测试通过。\n'
