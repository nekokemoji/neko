#!/usr/bin/env bash

set -Eeuo pipefail

[[ "$1" == "66.66.66.66" ]]
[[ "${NEKO_AKDNS_TEST_REJECT_HEALTH:-0}" != "1" ]]
