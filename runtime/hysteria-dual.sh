#!/usr/bin/env bash

# Run the IPv4-only and IPv6-only Hysteria servers as one systemd service.
# If either child exits, stop the other one so systemd can restart the pair.

set -Eeuo pipefail

HYSTERIA="${NEKO_HYSTERIA_BINARY:-/usr/local/libexec/neko/hysteria}"
CONFIG_DIR="${NEKO_CONFIG_DIR:-/etc/neko/config}"
pids=()

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
stop_children() {
  local pid
  trap - EXIT INT TERM
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

# Invoked indirectly by the signal traps below.
# shellcheck disable=SC2329
stop_service() {
  stop_children
  exit 0
}

trap stop_service INT TERM
trap stop_children EXIT

"$HYSTERIA" server --disable-update-check \
  --config "$CONFIG_DIR/hysteria-v4.yaml" &
pids+=("$!")

"$HYSTERIA" server --disable-update-check \
  --config "$CONFIG_DIR/hysteria-v6.yaml" &
pids+=("$!")

set +e
wait -n "${pids[@]}"
child_rc=$?
set -e

(( child_rc != 0 )) || child_rc=1
exit "$child_rc"
