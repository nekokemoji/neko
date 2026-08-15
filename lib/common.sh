#!/usr/bin/env bash

# Compatibility façade for shared installer and runtime helpers. Dedicated
# modules below own one responsibility each; existing callers keep sourcing
# lib/common.sh and receive the same public functions.

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
NEKO_STATE_SCHEMA=4

NEKO_COMMON_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common-platform.sh
source "${NEKO_COMMON_MODULE_DIR}/common-platform.sh"
# shellcheck source=lib/common-network.sh
source "${NEKO_COMMON_MODULE_DIR}/common-network.sh"
# shellcheck source=lib/common-credentials.sh
source "${NEKO_COMMON_MODULE_DIR}/common-credentials.sh"
# shellcheck source=lib/common-download.sh
source "${NEKO_COMMON_MODULE_DIR}/common-download.sh"
# shellcheck source=lib/common-acme.sh
source "${NEKO_COMMON_MODULE_DIR}/common-acme.sh"
# shellcheck source=lib/state.sh
source "${NEKO_COMMON_MODULE_DIR}/state.sh"
# shellcheck source=lib/common-subscription.sh
source "${NEKO_COMMON_MODULE_DIR}/common-subscription.sh"
unset NEKO_COMMON_MODULE_DIR
