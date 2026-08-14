#!/bin/bash

set -Eeuo pipefail

core_name="${0##*/}"
[[ -z "${NEKO_RENEW_TEST_CORE_LOG:-}" ]] \
  || printf '%s %s\n' "$core_name" "$*" >> "$NEKO_RENEW_TEST_CORE_LOG"

case "${NEKO_RENEW_TEST_CORE_FAIL:-}" in
  "$core_name"|all)
    printf '%s\n' "injected ${core_name} validation failure" >&2
    exit 23
    ;;
esac

if [[ "$core_name" == hysteria ]]; then
  [[ "$*" == *'server'* && "$*" == *'--config'* ]] || exit 24
  printf '%s\n' 'exec: "sysctl": executable file not found in $PATH' >&2
  exit 1
fi

exit 0
