#!/usr/bin/env bash

set -Eeuo pipefail

printf '%s\n' \
  'cloudflare: failed to find zone example.com.: [status code 403] 9109: Invalid access token'
exit 42
