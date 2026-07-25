#!/usr/bin/env bash

# Run every configured Hysteria address-family instance as one systemd service.
# A single-stack install starts one child. A dual-stack install starts both and
# stops the remaining child if either exits, so systemd can restart the group.

set -Eeuo pipefail

HYSTERIA="${NEKO_HYSTERIA_BINARY:-/usr/local/libexec/neko/hysteria}"
CONFIG_DIR="${NEKO_CONFIG_DIR:-/etc/neko/config}"
pids=()

# Invoked indirectly by the EXIT trap below.
# ShellCheck 0.9 reports trap-only functions as SC2317; newer releases use
# SC2329. Both warnings are false positives because the traps call this code.
# shellcheck disable=SC2317,SC2329
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
# shellcheck disable=SC2317,SC2329
stop_service() {
  stop_children
  exit 0
}

trap stop_service INT TERM
trap stop_children EXIT

for config_file in hysteria-v4.yaml hysteria-v6.yaml; do
  [[ -s "$CONFIG_DIR/$config_file" ]] || continue
  "$HYSTERIA" server --disable-update-check \
    --config "$CONFIG_DIR/$config_file" &
  pids+=("$!")
done

if (( ${#pids[@]} == 0 )); then
  printf '[错误] 没有找到可用的 Hysteria IPv4/IPv6 配置。\n' >&2
  exit 1
fi

set +e
wait -n "${pids[@]}"
child_rc=$?
set -e

(( child_rc != 0 )) || child_rc=1
exit "$child_rc"
