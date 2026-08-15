#!/usr/bin/env bash

set -Eeuo pipefail

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
NEKO_PANEL_TMP_DIR="${NEKO_PANEL_TMP_DIR:-/var/tmp}"
NEKO_MAINTENANCE_LOCK_FILE="${NEKO_MAINTENANCE_LOCK_FILE:-/run/lock/neko-maintenance.lock}"
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

# shellcheck source=lib/common.sh
source "${NEKO_LIBEXEC}/lib/common.sh"
# shellcheck source=lib/render.sh
source "${NEKO_LIBEXEC}/lib/render.sh"
# shellcheck source=lib/firewall.sh
source "${NEKO_LIBEXEC}/lib/firewall.sh"
# shellcheck source=lib/transaction.sh
source "${NEKO_LIBEXEC}/lib/transaction.sh"

NEKO_PANEL_MODULE_DIR="${NEKO_LIBEXEC}/panel"
if [[ ! -d "$NEKO_PANEL_MODULE_DIR" ]]; then
  NEKO_PANEL_MODULE_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
  )/panel"
fi
# shellcheck source=runtime/panel/system.sh
source "${NEKO_PANEL_MODULE_DIR}/system.sh"
# shellcheck source=runtime/panel/access.sh
source "${NEKO_PANEL_MODULE_DIR}/access.sh"
# shellcheck source=runtime/panel/family.sh
source "${NEKO_PANEL_MODULE_DIR}/family.sh"
# shellcheck source=runtime/panel/third-party.sh
source "${NEKO_PANEL_MODULE_DIR}/third-party.sh"
# shellcheck source=runtime/panel/akdns-menu.sh
source "${NEKO_PANEL_MODULE_DIR}/akdns-menu.sh"
# shellcheck source=runtime/panel/route-guide.sh
source "${NEKO_PANEL_MODULE_DIR}/route-guide.sh"
# shellcheck source=runtime/panel/ui.sh
source "${NEKO_PANEL_MODULE_DIR}/ui.sh"
unset NEKO_PANEL_MODULE_DIR

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
