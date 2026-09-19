#!/usr/bin/env bash
# ==============================================================================
# verify_initrd_contents.sh - Deep Inspection of Initial Ramdisk Image
# Uses lsinitramfs or lsinitrd to inspect concatenated CPIO archives
# ==============================================================================

set -euo pipefail

INITRD="/boot/initrd.img-$(uname -r)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  [${GREEN}${BOLD}PASS${NC}] $1"; }
fail() { echo -e "  [${RED}${BOLD}FAIL${NC}] $1"; }
info() { echo -e "  [${CYAN}INFO${NC}] $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root to read ${INITRD}.${NC}"
    echo "Run with: sudo bash $0"
    exit 1
fi

echo -e "${BOLD}================================================================================${NC}"
echo -e "${CYAN}${BOLD}       INITRD IMAGE CONTENT VERIFICATION: ${INITRD}        ${NC}"
echo -e "${BOLD}================================================================================${NC}"

if command -v lsinitramfs >/dev/null 2>&1; then
    info "Extracting file manifest via lsinitramfs..."
    MANIFEST=$(lsinitramfs "${INITRD}")

    check_manifest() {
        local pattern="$1"
        local desc="$2"
        local matches
        matches=$(echo "${MANIFEST}" | grep -E "${pattern}" || true)
        if [[ -n "${matches}" ]]; then
            pass "${desc}"
            echo "${matches}" | head -n 3 | while read -r line; do
                echo -e "       -> ${line}"
            done
        else
            fail "${desc} NOT FOUND matching pattern '${pattern}'"
        fi
    }

    echo -e "\n${BOLD}[1] KERNEL DRIVER MODULES AUDIT${NC}"
    check_manifest "thunderbolt\.ko" "Thunderbolt driver (thunderbolt.ko)"
    check_manifest "nvme\.ko" "NVMe PCIe host driver (nvme.ko)"
    check_manifest "nvme-core\.ko" "NVMe core subsystem driver (nvme-core.ko)"

    echo -e "\n${BOLD}[2] CONFIGURATION & MODPROBE DROP-INS AUDIT${NC}"
    check_manifest "etc/modprobe\.d/thunderbolt\.conf" "Modprobe drop-in (/etc/modprobe.d/thunderbolt.conf)"
    check_manifest "10-asm2464pd-trim\.rules" "UASP TRIM optimization rule (10-asm2464pd-trim.rules)"

    echo -e "\n${BOLD}[3] EARLY RESCAN HOOKS AUDIT${NC}"
    check_manifest "usb4-pre-trigger|usb4-rescan" "USB4 early rescan hook"

elif command -v lsinitrd >/dev/null 2>&1; then
    info "Extracting file manifest via lsinitrd..."
    MANIFEST=$(lsinitrd "${INITRD}")
    for drv in "thunderbolt" "nvme" "nvme_core"; do
        if echo "${MANIFEST}" | grep -q "${drv}"; then
            pass "Matched driver in initrd: ${drv}"
        fi
    done
fi

echo -e "\n${BOLD}================================================================================${NC}"
echo -e " Verification complete."
echo -e "${BOLD}================================================================================${NC}"
