#!/usr/bin/env bash

set -Eeuo pipefail

: "${NEKO_RENEW_TEST_SYSTEMCTL_STATE_DIR:?}"
state_dir="$NEKO_RENEW_TEST_SYSTEMCTL_STATE_DIR"
command_name="${1:-}"
shift || true

[[ -z "${NEKO_RENEW_TEST_SYSTEMCTL_LOG:-}" ]] \
  || printf '%s %s\n' "$command_name" "$*" \
    >> "$NEKO_RENEW_TEST_SYSTEMCTL_LOG"

service_arguments() {
  local argument
  for argument in "$@"; do
    [[ "$argument" == -* ]] || printf '%s\n' "$argument"
  done
}

case "$command_name" in
  is-active)
    all_active=1
    while IFS= read -r service; do
      [[ -f "$state_dir/active/$service" ]] || all_active=0
    done < <(service_arguments "$@")
    if (( all_active == 1 )); then
      [[ " $* " == *' --quiet '* ]] || printf '%s\n' active
    else
      [[ " $* " == *' --quiet '* ]] || printf '%s\n' inactive
      exit 3
    fi
    ;;
  restart)
    while IFS= read -r service; do
      if [[ "${NEKO_RENEW_TEST_SYSTEMCTL_FAIL_SERVICE:-}" == "$service" \
        && ! -e "$state_dir/restart-failed-once" ]]; then
        : > "$state_dir/restart-failed-once"
        exit 25
      fi
      : > "$state_dir/active/$service"
    done < <(service_arguments "$@")
    ;;
  stop)
    while IFS= read -r service; do
      rm -f -- "$state_dir/active/$service"
    done < <(service_arguments "$@")
    ;;
  *)
    exit 26
    ;;
esac
