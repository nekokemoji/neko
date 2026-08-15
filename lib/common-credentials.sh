#!/usr/bin/env bash

# Credential and identifier generation helpers. Loaded through lib/common.sh.

random_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes"
}

random_urlsafe() {
  local bytes="$1"
  openssl rand -base64 "$bytes" | tr -d '\n=' | tr '+/' '-_'
}

random_base64() {
  local bytes="$1"
  openssl rand -base64 "$bytes" | tr -d '\n'
}

new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr 'A-F' 'a-f' < /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-F' 'a-f'
  else
    local hex
    hex="$(random_hex 16)"
    printf '%s-%s-4%s-%x%s-%s\n' \
      "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
      "$(( (16#${hex:16:1} & 3) | 8 ))" "${hex:17:3}" "${hex:20:12}"
  fi
}

random_number() {
  local min="$1" max="$2" value
  value="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
  printf '%d\n' "$(( min + value % (max - min + 1) ))"
}
