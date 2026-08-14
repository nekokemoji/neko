#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${1:-}" == --version ]]; then
  printf 'lego version 5.2.2 linux/amd64\n'
  exit 0
fi

: "${NEKO_UPDATE_TEST_LEGO_LOG:?}"
: "${NEKO_UPDATE_TEST_CERT:?}"
: "${NEKO_UPDATE_TEST_KEY:?}"
: "${NEKO_VAR:?}"

printf '%s\n' "$*" >> "$NEKO_UPDATE_TEST_LEGO_LOG"
[[ " $* " == *' --force-cert-domains '* ]]
[[ " $* " == *' --renew-force '* ]]
[[ " $* " == *' --no-random-sleep '* ]]

install -m 0640 "$NEKO_UPDATE_TEST_CERT" \
  "$NEKO_VAR/lego/certificates/example.com.crt"
install -m 0640 "$NEKO_UPDATE_TEST_KEY" \
  "$NEKO_VAR/lego/certificates/example.com.key"
