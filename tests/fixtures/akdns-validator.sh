#!/usr/bin/env bash

set -Eeuo pipefail

root="${NEKO_AKDNS_SYSTEM_ROOT%/}"
resolv="${root}/etc/resolv.conf"
if [[ "${NEKO_AKDNS_TEST_REJECT_ACTIVE:-0}" == "1" \
  && -f "$resolv" && ! -L "$resolv" \
  && "$(awk '$1 == "nameserver" {print $2}' "$resolv")" == "66.66.66.66" ]]; then
  exit 1
fi
[[ -z "${NEKO_AKDNS_VALIDATOR_LOG:-}" ]] \
  || printf '%s\n' "${1:-0}" >> "$NEKO_AKDNS_VALIDATOR_LOG"
