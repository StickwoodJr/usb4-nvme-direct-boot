#!/usr/bin/env bash
# ==============================================================================
# rollback_usb4_fix.sh - 1-Click Rollback Script for USB4 Direct-Boot Configuration
# Purpose: Cleanly removes all drop-in files and restores the pre-change initrd
# ==============================================================================

set -euo pipefail

RUNNING_KERNEL="$(uname -r)"
INITRD_TARGET="/boot/initrd.img-${RUNNING_KERNEL}"
INITRD_BAK="${INITRD_TARGET}.pre-usb4-bak"
USER_HOME="${SUDO_USER:+/home/$SUDO_USER}"
USER_HOME="${USER_HOME:-$HOME}"
ALT_BAK="${USER_HOME}/usb4-prechange-backup/initrd.img-${RUNNING_KERNEL}.bak"

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

if [[ $EUID -ne 0 ]]; then
    log_fail "This script modifies system boot configuration and must be run as root."
    echo "Run with: sudo bash $0"
    exit 1
fi

echo -e "${BOLD}====================================================================${NC}"
echo -e "${YELLOW}${BOLD}     ROLLBACK: USB4 Direct-Boot Configuration Reversal            ${NC}"
echo -e "${BOLD}====================================================================${NC}"

# 1. Restore pristine initrd
log_header "RESTORING INITIAL RAMDISK"
if [[ -f "${INITRD_BAK}" ]]; then
    log_info "Restoring from ${INITRD_BAK}..."
    cp -a "${INITRD_BAK}" "${INITRD_TARGET}"
    sync -f "${INITRD_TARGET}"
    log_ok "Restored ${INITRD_TARGET} from local backup."
elif [[ -f "${ALT_BAK}" ]]; then
    log_info "Restoring from ${ALT_BAK}..."
    cp -a "${ALT_BAK}" "${INITRD_TARGET}"
    sync -f "${INITRD_TARGET}"
    log_ok "Restored ${INITRD_TARGET} from user backup."
else
    log_warn "No pre-change initrd backup found."
fi

# 2. Remove configuration drop-in files
log_header "REMOVING DROP-IN CONFIGURATION FILES"

remove_file() {
    local f="$1"
    if [[ -e "$f" ]]; then
        rm -rf "$f"
        log_ok "Removed: $f"
    else
        log_info "Already absent: $f"
    fi
}

remove_file "/etc/default/grub.d/99-usb4-transport.cfg"
remove_file "/etc/modprobe.d/thunderbolt.conf"
remove_file "/etc/dracut.conf.d/99-usb4.conf"
remove_file "/etc/udev/rules.d/10-asm2464pd-trim.rules"
remove_file "/etc/sysctl.d/99-vms-storage.conf"
remove_file "/usr/lib/dracut/modules.d/99usb4-rescan"
remove_file "/etc/initramfs-tools/conf.d/usb4-rootdelay.conf"
remove_file "/etc/initramfs-tools/scripts/init-premount/usb4-rescan"

# 3. Update Bootloader
log_header "UPDATING BOOTLOADER CONFIGURATION"
if command -v update-grub >/dev/null 2>&1; then
    update-grub
    log_ok "GRUB configuration updated to default baseline."
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    log_ok "GRUB configuration updated to default baseline."
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    log_ok "GRUB configuration updated to default baseline."
fi

echo -e "\n${BOLD}${GREEN}====================================================================${NC}"
echo -e "${BOLD}${GREEN}      Rollback completed successfully! System is restored.         ${NC}"
echo -e "${BOLD}${GREEN}====================================================================${NC}\n"
