#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-production-facades.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

assert_functions() {
  local function_name
  for function_name in "$@"; do
    declare -F "$function_name" >/dev/null || {
      printf '兼容 façade 缺少函数：%s\n' "$function_name" >&2
      return 1
    }
  done
}

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
assert_functions \
  detect_platform runtime_validate_core_configs validate_domain \
  check_domain_resolution random_urlsafe download_verified subscription_url \
  load_state

# shellcheck source=lib/render.sh
source "$ROOT/lib/render.sh"
assert_functions \
  render_sing_box render_xray render_hysteria render_caddy \
  render_sing_box_client route_context_validate render_subscriptions render_all

NEKO_LIBEXEC="$ROOT" bash -c '
  set -Eeuo pipefail
  source "$1"
  for function_name in \
    enable_bbr restore_bbr rotate_subscription rotate_node_credentials \
    refresh_subscription_endpoints subscription_qr_menu \
    add_missing_address_family manage_address_families \
    open_third_party_checks manage_akdns show_route_guide draw_menu main; do
    declare -F "$function_name" >/dev/null
  done
' _ "$ROOT/runtime/panel.sh"

# The user runs /usr/local/bin/neko through a symlink. Ensure the façade selects
# modules from NEKO_LIBEXEC rather than resolving them beside the symlink path.
mkdir -p "$WORK/libexec/lib" "$WORK/libexec/panel" "$WORK/bin"
cp -a -- "$ROOT/lib/"*.sh "$WORK/libexec/lib/"
cp -a -- "$ROOT/runtime/panel.sh" "$WORK/libexec/panel.sh"
cp -a -- "$ROOT/runtime/panel/"*.sh "$WORK/libexec/panel/"
ln -s "$WORK/libexec/panel.sh" "$WORK/bin/neko"
NEKO_LIBEXEC="$WORK/libexec" bash -c '
  set -Eeuo pipefail
  source "$1"
  declare -F main enable_bbr manage_akdns >/dev/null
' _ "$WORK/bin/neko"

printf 'common、render、panel 兼容 façade 与符号链接模块解析契约通过。\n'
