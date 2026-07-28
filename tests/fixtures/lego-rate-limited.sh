#!/usr/bin/env bash

set -Eeuo pipefail

trap 'exit 143' TERM
printf '%s\n' \
  'WARN retry: acme: error: 429 :: urn:ietf:params:acme:error:rateLimited :: too many certificates (5) already issued for this exact set of identifiers, retry after 2026-07-29 03:47:06 UTC'
sleep 30
if [[ -n "${NEKO_TEST_ACME_FINISHED:-}" ]]; then
  printf 'unexpected\n' > "$NEKO_TEST_ACME_FINISHED"
fi
