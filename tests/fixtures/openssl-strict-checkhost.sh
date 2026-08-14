#!/usr/bin/env bash
set -euo pipefail

REAL_OPENSSL="${NEKO_UPDATE_TEST_REAL_OPENSSL:?}"

if [[ " $* " == *' x509 '* && " $* " == *' -checkhost '* ]]; then
  output="$($REAL_OPENSSL "$@" 2>&1)"
  printf '%s\n' "$output"
  [[ "$output" == *'does match certificate'* ]]
  exit
fi

exec "$REAL_OPENSSL" "$@"
