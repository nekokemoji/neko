#!/usr/bin/env bash

set -Eeuo pipefail

state_dir="${NEKO_AKDNS_SYSTEMCTL_STATE_DIR:?}"
mkdir -p "$state_dir"
[[ -z "${NEKO_AKDNS_SYSTEMCTL_LOG:-}" ]] \
  || printf '%s\n' "$*" >> "$NEKO_AKDNS_SYSTEMCTL_LOG"

command_name="${1:-}"
shift || true

service_name() {
  local argument
  for argument in "$@"; do
    [[ "$argument" == -* ]] || printf '%s\n' "$argument"
  done
}

case "$command_name" in
  is-active)
    service="$(service_name "$@" | tail -n 1)"
    [[ -f "$state_dir/${service}.active" ]]
    ;;
  is-enabled)
    service="$(service_name "$@" | tail -n 1)"
    [[ -f "$state_dir/${service}.enabled" ]] || exit 1
    printf '%s\n' "$(<"$state_dir/${service}.enabled")"
    ;;
  start|restart)
    while IFS= read -r service; do
      : > "$state_dir/${service}.active"
    done < <(service_name "$@")
    ;;
  stop)
    while IFS= read -r service; do
      rm -f -- "$state_dir/${service}.active"
    done < <(service_name "$@")
    ;;
  enable)
    while IFS= read -r service; do
      printf 'enabled\n' > "$state_dir/${service}.enabled"
    done < <(service_name "$@")
    ;;
  disable)
    while IFS= read -r service; do
      printf 'disabled\n' > "$state_dir/${service}.enabled"
    done < <(service_name "$@")
    ;;
  mask)
    while IFS= read -r service; do
      printf 'masked\n' > "$state_dir/${service}.enabled"
    done < <(service_name "$@")
    ;;
  unmask)
    while IFS= read -r service; do
      if [[ -f "$state_dir/${service}.enabled" \
        && "$(<"$state_dir/${service}.enabled")" == masked* ]]; then
        printf 'disabled\n' > "$state_dir/${service}.enabled"
      fi
    done < <(service_name "$@")
    ;;
  *)
    ;;
esac
