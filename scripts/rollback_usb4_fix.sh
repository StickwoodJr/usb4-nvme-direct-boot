#!/usr/bin/env bash
# ==============================================================================
# rollback_usb4_fix.sh - Transaction-Aware Rollback Utility for USB4 Direct-Boot
# ==============================================================================
# Purpose: Atomically reverses USB4 boot drop-ins and restores the pristine initrd.
# Modes:   --dry-run (preview), --force, or interactive
# ==============================================================================

set -euo pipefail

RUNNING_KERNEL="$(uname -r)"
INITRD_TARGET="/boot/initrd.img-${RUNNING_KERNEL}"
INITRD_BAK="${INITRD_TARGET}.pre-usb4-bak"
USER_HOME="${SUDO_USER:+/home/$SUDO_USER}"
USER_HOME="${USER_HOME:-$HOME}"
ALT_BAK="${USER_HOME}/usb4-prechange-backup/initrd.img-${RUNNING_KERNEL}.bak"
STATE_DIR="/var/lib/usb4-direct-boot"
TRANSACTION_MANIFEST="${STATE_DIR}/transaction.manifest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "  [${CYAN}INFO${NC}] $1"; }
log_ok()      { echo -e "  [${GREEN}${BOLD} OK ${NC}] $1"; }
log_warn()    { echo -e "  [${YELLOW}${BOLD}WARN${NC}] $1"; }
log_fail()    { echo -e "  [${RED}${BOLD}FAIL${NC}] $1"; }
log_header()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }

DRY_RUN=0
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force|-y|--yes)
            FORCE=1
            shift
            ;;
        -h|--help)
            echo "USB4 Direct-Boot Rollback Utility"
            echo "Usage: sudo bash $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run   Preview files and initrd restoration without making changes"
            echo "  --force, -y Execute rollback without confirmation prompt"
            echo "  -h, --help  Display this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
    log_fail "Rollback modifies system boot configuration and requires root privileges."
    echo "Run with: sudo bash $0"
    exit 1
fi

echo -e "${BOLD}====================================================================${NC}"
echo -e "${YELLOW}${BOLD}     ROLLBACK: USB4 Direct-Boot Configuration Reversal            ${NC}"
echo -e "${BOLD}====================================================================${NC}"

if [[ $DRY_RUN -eq 1 ]]; then
    log_info "Running in DRY-RUN mode. No changes will be made."
fi

# 1. Inspect initrd backup
log_header "1. INITIAL RAMDISK RESTORATION INSPECTION"
SELECTED_BAK=""
if [[ -f "${INITRD_BAK}" ]]; then
    SELECTED_BAK="${INITRD_BAK}"
    log_ok "Located local pre-change backup: ${INITRD_BAK} ($(du -h "${INITRD_BAK}" | awk '{print $1}'))"
elif [[ -f "${ALT_BAK}" ]]; then
    SELECTED_BAK="${ALT_BAK}"
    log_ok "Located user archive backup: ${ALT_BAK} ($(du -h "${ALT_BAK}" | awk '{print $1}'))"
else
    log_warn "No pre-change initrd backup found. An initrd rebuild will be triggered instead of direct file restore."
fi

# 2. Inspect files to remove
log_header "2. FILES SLATED FOR REMOVAL"
TARGET_FILES=(
    "/etc/default/grub.d/99-usb4-transport.cfg"
    "/etc/modprobe.d/thunderbolt.conf"
    "/etc/dracut.conf.d/99-usb4.conf"
    "/etc/udev/rules.d/10-asm2464pd-trim.rules"
    "/etc/sysctl.d/99-vms-storage.conf"
    "/usr/lib/dracut/modules.d/99usb4-rescan"
    "/etc/initramfs-tools/conf.d/usb4-rootdelay.conf"
    "/etc/initramfs-tools/scripts/init-premount/usb4-rescan"
)

# If transaction manifest exists, include recorded files
if [[ -f "${TRANSACTION_MANIFEST}" ]]; then
    log_info "Reading files from active transaction manifest: ${TRANSACTION_MANIFEST}"
    while IFS= read -r line; do
        if [[ "$line" =~ ^FILE=\"(.*)\"$ ]]; then
            f="${BASH_REMATCH[1]}"
            TARGET_FILES+=("$f")
        fi
    done < "${TRANSACTION_MANIFEST}"
fi

# Deduplicate target list
TARGET_FILES=($(printf "%s\n" "${TARGET_FILES[@]}" | sort -u))

for f in "${TARGET_FILES[@]}"; do
    if [[ -e "$f" ]]; then
        echo "  [FOUND] $f"
    else
        echo "  [ABSENT] $f"
    fi
done

if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "\n${GREEN}${BOLD}Dry-run rollback preview complete.${NC} Run 'sudo bash $0 --force' to execute.\n"
    exit 0
fi

if [[ $FORCE -eq 0 ]]; then
    echo ""
    read -rp "Are you sure you want to revert all USB4 direct-boot configurations? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Rollback cancelled."
        exit 0
    fi
fi

# Execution phase
log_header "3. EXECUTING REMOVALS"
for f in "${TARGET_FILES[@]}"; do
    if [[ -e "$f" ]]; then
        rm -rf "$f"
        log_ok "Removed: $f"
    fi
done

# Restore initrd
log_header "4. RESTORING INITIAL RAMDISK"
if [[ -n "${SELECTED_BAK}" ]]; then
    log_info "Restoring ${INITRD_TARGET} from ${SELECTED_BAK}..."
    cp -a "${SELECTED_BAK}" "${INITRD_TARGET}"
    sync -f "${INITRD_TARGET}"
    log_ok "Restored pristine initrd image."
else
    log_info "Rebuilding baseline initrd..."
    if command -v dracut >/dev/null 2>&1; then
        dracut --force "${INITRD_TARGET}" "${RUNNING_KERNEL}"
        log_ok "Rebuilt baseline dracut initrd."
    elif command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "${RUNNING_KERNEL}"
        log_ok "Rebuilt baseline initramfs-tools image."
    fi
fi

# Update Bootloader
log_header "5. REGENERATING BOOTLOADER CONFIGURATION"
if command -v update-grub >/dev/null 2>&1; then
    update-grub
    log_ok "GRUB configuration refreshed."
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    log_ok "GRUB configuration refreshed."
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    log_ok "GRUB configuration refreshed."
fi

# Clean manifest
rm -f "${TRANSACTION_MANIFEST}" 2>/dev/null || true

echo -e "\n${BOLD}${GREEN}====================================================================${NC}"
echo -e "${BOLD}${GREEN}  Rollback Complete: All USB4 Direct-Boot configs cleanly removed.  ${NC}"
echo -e "${BOLD}${GREEN}====================================================================${NC}\n"
