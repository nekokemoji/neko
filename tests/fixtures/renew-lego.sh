#!/usr/bin/env bash

set -Eeuo pipefail

: "${NEKO_VAR:?}"
: "${NEKO_RENEW_TEST_LEGO_ACTION:?}"
certificate_dir="$NEKO_VAR/lego/certificates"
certificate_file="$certificate_dir/example.com.crt"
key_file="$certificate_dir/example.com.key"

[[ -z "${NEKO_RENEW_TEST_LEGO_LOG:-}" ]] \
  || printf '%s\n' "$*" >> "$NEKO_RENEW_TEST_LEGO_LOG"

case "$NEKO_RENEW_TEST_LEGO_ACTION" in
  nochange)
    exit 0
    ;;
  renew|invalid|mismatch)
    printf '%s\n' 'renewed-account-state' \
      > "$NEKO_VAR/lego/accounts/registration.json"
    printf '%s\n' 'created-during-renewal' \
      > "$NEKO_VAR/lego/renewal-marker"
    chmod 0777 "$NEKO_VAR/lego/accounts/registration.json"
    ;;
  fail)
    printf '%s\n' 'partially-written-account-state' \
      > "$NEKO_VAR/lego/accounts/registration.json"
    printf '%s\n' 'created-before-renewal-failed' \
      > "$NEKO_VAR/lego/renewal-marker"
    exit 29
    ;;
  *)
    printf 'unknown renewal action: %s\n' \
      "$NEKO_RENEW_TEST_LEGO_ACTION" >&2
    exit 2
    ;;
esac

case "$NEKO_RENEW_TEST_LEGO_ACTION" in
  renew)
    cp -a -- "$NEKO_RENEW_TEST_CERT" "$certificate_file"
    cp -a -- "$NEKO_RENEW_TEST_KEY" "$key_file"
    ;;
  invalid)
    printf '%s\n' 'not-a-certificate' > "$certificate_file"
    cp -a -- "$NEKO_RENEW_TEST_KEY" "$key_file"
    ;;
  mismatch)
    cp -a -- "$NEKO_RENEW_TEST_CERT" "$certificate_file"
    cp -a -- "$NEKO_RENEW_TEST_MISMATCH_KEY" "$key_file"
    ;;
esac

chmod 0666 "$certificate_file" "$key_file"
