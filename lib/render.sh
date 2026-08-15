#!/usr/bin/env bash

# Compatibility façade for server and subscription rendering. Dedicated
# modules own each render responsibility; existing callers keep sourcing this
# file and retain the same public function surface.

set -Eeuo pipefail

if ! declare -F load_state >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

NEKO_SUB_DIR="${NEKO_SUB_DIR:-${NEKO_ETC}/subscriptions}"
NEKO_CONFIG_DIR="${NEKO_CONFIG_DIR:-${NEKO_ETC}/config}"
# IPv4 server exits intentionally keep the system resolver so managed AKDNS
# still applies. Strict IPv6 exits use this literal endpoint and never need the
# AKDNS-managed system resolver to bootstrap their DNS connection.
NEKO_STRICT_IPV6_DNS_ADDRESS="2606:4700:4700::1111"
NEKO_STRICT_DNS_TLS_NAME="cloudflare-dns.com"

NEKO_RENDER_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/render-server.sh
source "${NEKO_RENDER_MODULE_DIR}/render-server.sh"
# shellcheck source=lib/render-caddy.sh
source "${NEKO_RENDER_MODULE_DIR}/render-caddy.sh"
# shellcheck source=lib/render-client.sh
source "${NEKO_RENDER_MODULE_DIR}/render-client.sh"
# shellcheck source=lib/render-route-model.sh
source "${NEKO_RENDER_MODULE_DIR}/render-route-model.sh"
# shellcheck source=lib/render-subscriptions.sh
source "${NEKO_RENDER_MODULE_DIR}/render-subscriptions.sh"
unset NEKO_RENDER_MODULE_DIR

render_all() {
  load_state
  mkdir -p "$NEKO_CONFIG_DIR" "$NEKO_SUB_DIR"
  render_sing_box
  render_xray
  render_hysteria
  render_subscriptions
  render_caddy
}
