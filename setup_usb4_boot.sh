#!/usr/bin/env bash
# ==============================================================================
# setup_usb4_boot.sh - Universal Turnkey USB4 Direct-Boot Setup Entrypoint
# Native PCIe Gen 4 x4 Direct Boot over USB4 / Thunderbolt 4 for Linux
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/scripts/apply_usb4_direct_boot_fix.sh"

if [[ ! -f "${TARGET_SCRIPT}" ]]; then
    echo "[-] Error: Installer script not found at ${TARGET_SCRIPT}" >&2
    exit 1
fi

exec bash "${TARGET_SCRIPT}" "$@"
