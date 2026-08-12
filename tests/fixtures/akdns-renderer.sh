#!/usr/bin/env bash

set -Eeuo pipefail

mode="$1"
server="${2:-}"
target="$3"
mkdir -p -- "$target"
if [[ "$mode" == on ]]; then
  [[ "$server" == "66.66.66.66" ]]
  printf 'on %s\n' "$server" > "$target/dns-mode"
else
  [[ -z "$server" ]]
  printf 'off\n' > "$target/dns-mode"
fi
