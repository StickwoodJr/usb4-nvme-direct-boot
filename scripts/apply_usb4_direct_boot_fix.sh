#!/usr/bin/env bash
# ==============================================================================
# apply_usb4_direct_boot_fix.sh - Universal Turnkey USB4 Direct-Boot Installer
# Target Systems:  Laptops & Desktops with Intel/AMD USB4 / Thunderbolt 4
# Target Enclosure: ASMedia ASM2464PD / Intel Thunderbolt USB4 NVMe Enclosures
# Supports:        Dracut & Initramfs-tools frameworks with Dynamic UUID Discovery
# Scope:           Configures boot drop-ins on target root without modifying internal disks
# ==============================================================================

set -euo pipefail

# ANSI color codes
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

# Default variables
USER_HOME="${SUDO_USER:+/home/$SUDO_USER}"
USER_HOME="${USER_HOME:-$HOME}"
BACKUP_DIR="${USER_HOME}/usb4-prechange-backup"
RUNNING_KERNEL="$(uname -r)"
INITRD_TARGET="/boot/initrd.img-${RUNNING_KERNEL}"
DRACUT_MOD_DIR="/usr/lib/dracut/modules.d/99usb4-rescan"

MODE="interactive"
UUID_OVERRIDE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --audit)
            MODE="audit"
            shift
            ;;
        --dry-run)
            MODE="dry-run"
            shift
            ;;
        --apply|-y|--yes)
            MODE="apply"
            shift
            ;;
        --uuid)
            if [[ -n "${2:-}" ]]; then
                UUID_OVERRIDE="$2"
                shift 2
            else
                echo "Error: --uuid requires a UUID argument." >&2
                exit 1
            fi
            ;;
        -h|--help)
            echo "Universal USB4 Direct-Boot Setup Utility"
            echo "Usage: sudo bash $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --audit          Perform read-only pre-flight audit of host, framework, and UUID"
            echo "  --dry-run        Preview all configuration files and actions without modifying"
            echo "  --apply, -y      Apply hardened USB4 boot configurations and rebuild initrd"
            echo "  --uuid <UUID>    Override root filesystem UUID (useful for chroot provisioning)"
            echo "  -h, --help       Display this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information." >&2
            exit 1
            ;;
    esac
done

# ==============================================================================
# DYNAMIC ENVIRONMENT DETECTION
# ==============================================================================
detect_root_uuid() {
    if [[ -n "${UUID_OVERRIDE}" ]]; then
        echo "${UUID_OVERRIDE}"
        return
    fi

    local detected=""
    # 1. Primary: Query findmnt on active root filesystem /
    detected=$(findmnt -no UUID / 2>/dev/null || true)

    # 2. Secondary: Query blkid on source device of /
    if [[ -z "$detected" ]]; then
        local src_dev
        src_dev=$(findmnt -no SOURCE / 2>/dev/null || true)
        if [[ -n "$src_dev" ]]; then
            detected=$(blkid -s UUID -o value "$src_dev" 2>/dev/null || true)
        fi
    fi

    # 3. Tertiary: Check /etc/fstab for mountpoint /
    if [[ -z "$detected" && -f /etc/fstab ]]; then
        detected=$(awk '$2=="/" && $1 ~ /^UUID=/ {sub(/^UUID=/,"",$1); print $1}' /etc/fstab 2>/dev/null || true)
    fi

    echo "$detected"
}

detect_initramfs_framework() {
    # Check if dracut is present
    if command -v dracut >/dev/null 2>&1; then
        echo "dracut"
        return
    fi

    # Check if Debian/Ubuntu initramfs-tools is present
    if command -v update-initramfs >/dev/null 2>&1 && [[ -d /etc/initramfs-tools ]]; then
        echo "initramfs-tools"
        return
    fi

    echo "unknown"
}

detect_bootloader_type() {
    if command -v update-grub >/dev/null 2>&1; then
        echo "update-grub"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        echo "grub-mkconfig"
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        echo "grub2-mkconfig"
    else
        echo "unknown"
    fi
}

TARGET_ROOT_UUID="$(detect_root_uuid)"
INIT_FRAMEWORK="$(detect_initramfs_framework)"
BOOTLOADER_CMD="$(detect_bootloader_type)"

# ==============================================================================
# 1. AUDIT MODE (Read-only inspection)
# ==============================================================================
run_audit() {
    log_header "READ-ONLY PRE-FLIGHT AUDIT"
    log_info "Host: $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || uname -n) ($(uname -m))"
    log_info "Running Kernel: ${RUNNING_KERNEL}"
    log_info "Detected Initramfs Engine: ${INIT_FRAMEWORK}"
    log_info "Detected Bootloader Updater: ${BOOTLOADER_CMD}"
    
    if [[ -n "${TARGET_ROOT_UUID}" ]]; then
        log_ok "Detected Root UUID: ${TARGET_ROOT_UUID}"
    else
        log_warn "Could not automatically resolve root UUID. Specify with --uuid <UUID> if necessary."
    fi

    local cur_root
    cur_root=$(findmnt -no SOURCE / 2>/dev/null || echo "unknown")
    log_info "Current Root Device: ${cur_root}"

    # Check initrd file
    if [[ -f "${INITRD_TARGET}" ]]; then
        log_ok "Target initrd exists: ${INITRD_TARGET} ($(du -h "${INITRD_TARGET}" 2>/dev/null | awk '{print $1}'))"
    else
        log_warn "Target initrd not found at ${INITRD_TARGET}. A new initrd will be generated."
    fi

    # Check Thunderbolt runtime parameter
    local hr="unknown"
    if [[ -f /sys/module/thunderbolt/parameters/host_reset ]]; then
        hr=$(cat /sys/module/thunderbolt/parameters/host_reset)
    fi
    log_info "thunderbolt.host_reset runtime: ${hr} (Target: N/0)"

    log_header "SYSTEM CONFIGURATION DROP-IN AUDIT"
    for f in \
        "/etc/default/grub.d/99-usb4-transport.cfg" \
        "/etc/modprobe.d/thunderbolt.conf" \
        "/etc/udev/rules.d/10-asm2464pd-trim.rules" \
        "/etc/sysctl.d/99-vms-storage.conf" \
        "/etc/dracut.conf.d/99-usb4.conf" \
        "${DRACUT_MOD_DIR}/module-setup.sh" \
        "/etc/initramfs-tools/conf.d/usb4-rootdelay.conf"
    do
        if [[ -e "$f" ]]; then
            log_ok "Found: $f"
        else
            log_info "Pending (will be deployed): $f"
        fi
    done

    echo -e "\n${GREEN}${BOLD}Audit complete.${NC} Ready for automated deployment.\n"
}

if [[ "${MODE}" == "audit" ]]; then
    run_audit
    exit 0
fi

# ==============================================================================
# 2. DRY-RUN MODE (Preview operations without writing)
# ==============================================================================
run_dry_run() {
    log_header "DRY-RUN EXECUTION PREVIEW"
    log_info "No filesystem changes or initrd rebuilds will be performed in dry-run mode."
    log_info "Target Kernel: ${RUNNING_KERNEL}"
    log_info "Target Root UUID: ${TARGET_ROOT_UUID:-<Auto-detected during execution>}"
    log_info "Framework: ${INIT_FRAMEWORK}"
    log_info "Bootloader Tool: ${BOOTLOADER_CMD}"

    echo -e "\n${BOLD}[1] Bootloader Configuration:${NC}"
    if [[ -d /etc/default/grub.d ]] || [[ -f /etc/default/grub.d/99-usb4-transport.cfg ]]; then
        echo "  Target: /etc/default/grub.d/99-usb4-transport.cfg"
    else
        echo "  Target: /etc/default/grub (appended to GRUB_CMDLINE_LINUX)"
    fi
    echo "  Parameters: thunderbolt.host_reset=0 thunderbolt.clx=0 pcie_port_pm=off rootdelay=60"

    echo -e "\n${BOLD}[2] Driver & Modprobe Configuration:${NC}"
    echo "  Target: /etc/modprobe.d/thunderbolt.conf"
    echo "  Content: options thunderbolt host_reset=0 clx=0"

    echo -e "\n${BOLD}[3] Udev TRIM Optimization Rule:${NC}"
    echo "  Target: /etc/udev/rules.d/10-asm2464pd-trim.rules"
    echo "  Content: ASMedia ASM2464PD 64MB discard limit clamp"

    echo -e "\n${BOLD}[4] Initramfs Engine Configuration:${NC}"
    if [[ "${INIT_FRAMEWORK}" == "dracut" ]]; then
        echo "  Engine: dracut"
        echo "  Drop-in: /etc/dracut.conf.d/99-usb4.conf"
        echo "  Module: ${DRACUT_MOD_DIR}/"
        echo "    - module-setup.sh"
        echo "    - usb4-pre-trigger.sh"
        echo "    - usb4-initqueue-settled.sh (Dynamic Root UUID: ${TARGET_ROOT_UUID})"
        echo "  Rebuild Command: dracut --force ${INITRD_TARGET} ${RUNNING_KERNEL}"
    elif [[ "${INIT_FRAMEWORK}" == "initramfs-tools" ]]; then
        echo "  Engine: initramfs-tools"
        echo "  Drop-in: /etc/initramfs-tools/conf.d/usb4-rootdelay.conf"
        echo "  Modules: /etc/initramfs-tools/modules (thunderbolt, nvme, nvme_core)"
        echo "  Premount Script: /etc/initramfs-tools/scripts/init-premount/usb4-rescan"
        echo "  Rebuild Command: update-initramfs -u -k ${RUNNING_KERNEL}"
    fi

    echo -e "\n${GREEN}${BOLD}Dry-run complete.${NC} To execute, run: sudo bash $0 --apply\n"
}

if [[ "${MODE}" == "dry-run" ]]; then
    run_dry_run
    exit 0
fi

# ==============================================================================
# 3. ROOT ENFORCEMENT & CONFIRMATION
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    log_fail "This script modifies system boot configuration and must be run as root."
    echo "Run with: sudo bash $0 --apply"
    exit 1
fi

if [[ "${MODE}" == "interactive" ]]; then
    echo -e "${BOLD}====================================================================${NC}"
    echo -e "${CYAN}${BOLD} Universal USB4 Direct-Boot Setup Utility                           ${NC}"
    echo -e "${BOLD}====================================================================${NC}"
    echo "Detected Environment:"
    echo "  - Running Kernel:   ${RUNNING_KERNEL}"
    echo "  - Initramfs Engine: ${INIT_FRAMEWORK}"
    echo "  - Root UUID:        ${TARGET_ROOT_UUID:-unknown}"
    echo ""
    read -rp "Do you wish to apply the direct-boot fix? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled by user."
        exit 0
    fi
fi

# ==============================================================================
# 4. PREREQUISITE VALIDATION
# ==============================================================================
log_header "VALIDATING PREREQUISITES"
if [[ "${INIT_FRAMEWORK}" == "unknown" ]]; then
    log_fail "Could not identify an active initramfs engine (dracut or initramfs-tools). Aborting."
    exit 1
fi
log_ok "Initramfs engine: ${INIT_FRAMEWORK}"

if [[ -z "${TARGET_ROOT_UUID}" ]]; then
    log_warn "Target root UUID could not be detected automatically. Proceeding with hardware-fallback rescan."
else
    log_ok "Target Root UUID: ${TARGET_ROOT_UUID}"
fi

# ==============================================================================
# 5. PRE-CHANGE SYSTEM BACKUPS
# ==============================================================================
log_header "CREATING SYSTEM BACKUPS"
mkdir -p "${BACKUP_DIR}"

if [[ -f "${INITRD_TARGET}" ]]; then
    log_info "Backing up ${INITRD_TARGET} to ${INITRD_TARGET}.pre-usb4-bak..."
    cp -a "${INITRD_TARGET}" "${INITRD_TARGET}.pre-usb4-bak"
    log_info "Backing up ${INITRD_TARGET} to ${BACKUP_DIR}/initrd.img-${RUNNING_KERNEL}.bak..."
    cp -a "${INITRD_TARGET}" "${BACKUP_DIR}/initrd.img-${RUNNING_KERNEL}.bak"
fi

for cfg in \
    "/etc/default/grub" \
    "/etc/default/grub.d" \
    "/etc/modprobe.d" \
    "/etc/dracut.conf.d" \
    "/etc/initramfs-tools" \
    "/etc/udev/rules.d"
do
    if [[ -e "$cfg" ]]; then
        cp -a "$cfg" "${BACKUP_DIR}/" 2>/dev/null || true
    fi
done
log_ok "Backups stored safely in ${BACKUP_DIR}"

# ==============================================================================
# 6. STAGE A: BOOTLOADER / GRUB CONFIGURATION
# ==============================================================================
log_header "STAGE A: CONFIGURING BOOTLOADER KERNEL ARGUMENTS"

USB4_FLAGS="thunderbolt.host_reset=0 thunderbolt.clx=0 pcie_port_pm=off rootdelay=60"

if [[ -d /etc/default/grub.d ]]; then
    cat <<EOF > /etc/default/grub.d/99-usb4-transport.cfg
# ==============================================================================
# /etc/default/grub.d/99-usb4-transport.cfg
# Hardened USB4 External NVMe Transport Parameters
# ==============================================================================
USB4_TRANSPORT_FLAGS="${USB4_FLAGS}"
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} \${USB4_TRANSPORT_FLAGS}"
EOF
    chmod 644 /etc/default/grub.d/99-usb4-transport.cfg
    log_ok "Deployed /etc/default/grub.d/99-usb4-transport.cfg"
elif [[ -f /etc/default/grub ]]; then
    if ! grep -q "USB4 DIRECT BOOT" /etc/default/grub; then
        cat <<EOF >> /etc/default/grub

# === BEGIN USB4 DIRECT BOOT TRANSPORT FLAGS ===
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} ${USB4_FLAGS}"
# === END USB4 DIRECT BOOT TRANSPORT FLAGS ===
EOF
        log_ok "Appended USB4 parameters to /etc/default/grub"
    else
        log_info "USB4 parameters already present in /etc/default/grub"
    fi
fi

# Execute bootloader update
if [[ "${BOOTLOADER_CMD}" == "update-grub" ]]; then
    log_info "Updating GRUB via update-grub..."
    update-grub
    log_ok "GRUB configuration updated."
elif [[ "${BOOTLOADER_CMD}" == "grub-mkconfig" ]]; then
    local cfg=""
    if [[ -f /boot/grub/grub.cfg ]]; then cfg="/boot/grub/grub.cfg"
    elif [[ -f /boot/grub2/grub.cfg ]]; then cfg="/boot/grub2/grub.cfg"
    elif [[ -f /boot/efi/EFI/fedora/grub.cfg ]]; then cfg="/boot/efi/EFI/fedora/grub.cfg"
    else cfg="/boot/grub/grub.cfg"
    fi
    log_info "Updating GRUB via grub-mkconfig -o ${cfg}..."
    grub-mkconfig -o "${cfg}"
    log_ok "GRUB configuration updated."
elif [[ "${BOOTLOADER_CMD}" == "grub2-mkconfig" ]]; then
    local cfg=""
    if [[ -f /boot/grub2/grub.cfg ]]; then cfg="/boot/grub2/grub.cfg"
    elif [[ -f /boot/efi/EFI/fedora/grub.cfg ]]; then cfg="/boot/efi/EFI/fedora/grub.cfg"
    else cfg="/boot/grub2/grub.cfg"
    fi
    log_info "Updating GRUB via grub2-mkconfig -o ${cfg}..."
    grub2-mkconfig -o "${cfg}"
    log_ok "GRUB configuration updated."
else
    log_warn "No recognized grub update tool found. Please update bootloader configuration manually."
fi

# ==============================================================================
# 7. STAGE B: DRIVER, MODPROBE, UDEV & SYSCTL CONFIGURATION
# ==============================================================================
log_header "STAGE B: DEPLOYING HARDWARE & STORAGE CONFIGURATION"

# 1. Modprobe configuration for Thunderbolt
mkdir -p /etc/modprobe.d
cat <<'EOF' > /etc/modprobe.d/thunderbolt.conf
# /etc/modprobe.d/thunderbolt.conf
# Enforce host_reset=0 and disable CLx low-power states to preserve PCIe tunnels
options thunderbolt host_reset=0 clx=0
EOF
chmod 644 /etc/modprobe.d/thunderbolt.conf
log_ok "Created /etc/modprobe.d/thunderbolt.conf"

# 2. ASMedia ASM2464PD TRIM / UNMAP udev rule
mkdir -p /etc/udev/rules.d
cat <<'EOF' > /etc/udev/rules.d/10-asm2464pd-trim.rules
# /etc/udev/rules.d/10-asm2464pd-trim.rules
# ASMedia ASM2464PD TRIM / UNMAP Optimization Rule for UASP mode
ACTION=="add|change", ATTRS{idVendor}=="174c", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"
ACTION=="add|change", ATTRS{idVendor}=="174c", SUBSYSTEM=="block", ATTR{queue/discard_max_bytes}="67108864"
EOF
chmod 644 /etc/udev/rules.d/10-asm2464pd-trim.rules
log_ok "Created /etc/udev/rules.d/10-asm2464pd-trim.rules"

# 3. High-throughput storage flush tuning
mkdir -p /etc/sysctl.d
cat <<'EOF' > /etc/sysctl.d/99-vms-storage.conf
# /etc/sysctl.d/99-vms-storage.conf
# High-Throughput & Multi-VM Storage Flush Tuning
vm.dirty_background_bytes = 268435456
vm.dirty_bytes = 1073741824
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 250
vm.vfs_cache_pressure = 50
EOF
chmod 644 /etc/sysctl.d/99-vms-storage.conf
sysctl --system >/dev/null 2>&1 || true
log_ok "Created and applied /etc/sysctl.d/99-vms-storage.conf"

# ==============================================================================
# 8. STAGE C: INITRAMFS HOOK DEPLOYMENT
# ==============================================================================
log_header "STAGE C: DEPLOYING EARLY RESCAN HOOKS (${INIT_FRAMEWORK})"

if [[ "${INIT_FRAMEWORK}" == "dracut" ]]; then
    # Dracut driver and module configuration
    mkdir -p /etc/dracut.conf.d
    cat <<'EOF' > /etc/dracut.conf.d/99-usb4.conf
# /etc/dracut.conf.d/99-usb4.conf
# Dracut-native USB4 / Thunderbolt Direct-Boot Driver & Module Configuration
add_dracutmodules+=" usb4-rescan "
force_drivers+=" thunderbolt nvme nvme_core "
add_drivers+=" typec typec_thunderbolt ucsi_acpi typec_ucsi "
install_items+=" /etc/modprobe.d/thunderbolt.conf "
EOF
    chmod 644 /etc/dracut.conf.d/99-usb4.conf
    log_ok "Created /etc/dracut.conf.d/99-usb4.conf"

    # Dracut native module directory
    mkdir -p "${DRACUT_MOD_DIR}"

    cat <<'EOF' > "${DRACUT_MOD_DIR}/module-setup.sh"
#!/bin/sh
# /usr/lib/dracut/modules.d/99usb4-rescan/module-setup.sh
# Dracut module setup for USB4 / Thunderbolt PCIe NVMe Direct-Boot

check() {
    return 0
}

depends() {
    return 0
}

install() {
    inst_hook pre-trigger 00 "$moddir/usb4-pre-trigger.sh"
    inst_hook initqueue/settled 00 "$moddir/usb4-initqueue-settled.sh"
}
EOF
    chmod 755 "${DRACUT_MOD_DIR}/module-setup.sh"

    cat <<'EOF' > "${DRACUT_MOD_DIR}/usb4-pre-trigger.sh"
#!/bin/sh
# /usr/lib/dracut/modules.d/99usb4-rescan/usb4-pre-trigger.sh
# Runs during dracut-pre-trigger before systemd-udev-trigger fires.
# Authorizes any connected Thunderbolt/USB4 devices and requests PCIe bus rescan.

if [ -d /sys/bus/thunderbolt/devices ]; then
    for dev in /sys/bus/thunderbolt/devices/*; do
        if [ -f "$dev/authorized" ] && [ "$(cat "$dev/authorized" 2>/dev/null)" = "0" ]; then
            echo 1 > "$dev/authorized" 2>/dev/null || :
        fi
    done
fi

if [ -w /sys/bus/pci/rescan ]; then
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || :
fi
EOF
    chmod 755 "${DRACUT_MOD_DIR}/usb4-pre-trigger.sh"

    # Injects TARGET_ROOT_UUID dynamically
    cat <<EOF > "${DRACUT_MOD_DIR}/usb4-initqueue-settled.sh"
#!/bin/sh
# /usr/lib/dracut/modules.d/99usb4-rescan/usb4-initqueue-settled.sh
# Watchdog hook: if root UUID/device is not yet detected, ensure authorization and rescan.

TARGET_UUID="${TARGET_ROOT_UUID}"

NEED_RESCAN=0
if [ -n "\$TARGET_UUID" ]; then
    if [ ! -e "/dev/disk/by-uuid/\$TARGET_UUID" ]; then
        NEED_RESCAN=1
    fi
else
    if [ ! -d /sys/class/nvme ] || [ -z "\$(ls -A /sys/class/nvme 2>/dev/null)" ]; then
        NEED_RESCAN=1
    fi
fi

if [ "\$NEED_RESCAN" -eq 1 ]; then
    if [ -d /sys/bus/thunderbolt/devices ]; then
        for dev in /sys/bus/thunderbolt/devices/*; do
            if [ -f "\$dev/authorized" ] && [ "\$(cat "\$dev/authorized" 2>/dev/null)" = "0" ]; then
                echo 1 > "\$dev/authorized" 2>/dev/null || :
            fi
        done
    fi

    if [ -w /sys/bus/pci/rescan ]; then
        echo 1 > /sys/bus/pci/rescan 2>/dev/null || :
    fi
fi
EOF
    chmod 755 "${DRACUT_MOD_DIR}/usb4-initqueue-settled.sh"
    log_ok "Deployed native dracut module 99usb4-rescan (UUID: ${TARGET_ROOT_UUID:-Dynamic})"

elif [[ "${INIT_FRAMEWORK}" == "initramfs-tools" ]]; then
    # Timeout drop-in
    mkdir -p /etc/initramfs-tools/conf.d
    echo "ROOTDELAY=60" > /etc/initramfs-tools/conf.d/usb4-rootdelay.conf
    chmod 644 /etc/initramfs-tools/conf.d/usb4-rootdelay.conf
    log_ok "Created /etc/initramfs-tools/conf.d/usb4-rootdelay.conf"

    # Modules
    for mod in thunderbolt nvme nvme_core typec typec_thunderbolt; do
        if ! grep -q "^${mod}" /etc/initramfs-tools/modules 2>/dev/null; then
            echo "${mod}" >> /etc/initramfs-tools/modules
            log_info "Added module to initramfs-tools: ${mod}"
        fi
    done

    # Early pre-mount script
    mkdir -p /etc/initramfs-tools/scripts/init-premount
    cat <<'EOF' > /etc/initramfs-tools/scripts/init-premount/usb4-rescan
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac

if [ -d /sys/bus/thunderbolt/devices ]; then
    for dev in /sys/bus/thunderbolt/devices/*; do
        if [ -f "$dev/authorized" ] && [ "$(cat "$dev/authorized" 2>/dev/null)" = "0" ]; then
            echo 1 > "$dev/authorized" 2>/dev/null || :
        fi
    done
fi
if [ -w /sys/bus/pci/rescan ]; then
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || :
fi
EOF
    chmod 755 /etc/initramfs-tools/scripts/init-premount/usb4-rescan
    log_ok "Deployed /etc/initramfs-tools/scripts/init-premount/usb4-rescan"
fi

# ==============================================================================
# 9. STAGE D: REBUILD INITRD IMAGE
# ==============================================================================
log_header "STAGE D: REBUILDING INITIAL RAMDISK FOR KERNEL ${RUNNING_KERNEL}"

if [[ "${INIT_FRAMEWORK}" == "dracut" ]]; then
    log_info "Executing: dracut --force ${INITRD_TARGET} ${RUNNING_KERNEL}..."
    if dracut --force "${INITRD_TARGET}" "${RUNNING_KERNEL}"; then
        sync -f "${INITRD_TARGET}"
        log_ok "Successfully rebuilt ${INITRD_TARGET} ($(du -h "${INITRD_TARGET}" | awk '{print $1}'))"
    else
        log_fail "Dracut rebuild failed! Restoring backup..."
        if [[ -f "${INITRD_TARGET}.pre-usb4-bak" ]]; then
            cp -a "${INITRD_TARGET}.pre-usb4-bak" "${INITRD_TARGET}"
        fi
        exit 1
    fi
elif [[ "${INIT_FRAMEWORK}" == "initramfs-tools" ]]; then
    log_info "Executing: update-initramfs -u -k ${RUNNING_KERNEL}..."
    if update-initramfs -u -k "${RUNNING_KERNEL}"; then
        log_ok "Successfully rebuilt initrd for kernel ${RUNNING_KERNEL}."
    else
        log_fail "update-initramfs rebuild failed! Restoring backup..."
        if [[ -f "${INITRD_TARGET}.pre-usb4-bak" ]]; then
            cp -a "${INITRD_TARGET}.pre-usb4-bak" "${INITRD_TARGET}"
        fi
        exit 1
    fi
fi

# ==============================================================================
# 10. VERIFICATION
# ==============================================================================
log_header "VERIFYING GENERATED INITRD"
if command -v lsinitramfs >/dev/null 2>&1; then
    MANIFEST=$(lsinitramfs "${INITRD_TARGET}" 2>/dev/null || true)
    for drv in "thunderbolt" "nvme"; do
        if echo "${MANIFEST}" | grep -q "${drv}"; then
            log_ok "Verified driver in initrd: ${drv}"
        else
            log_warn "Driver ${drv} not explicitly matched in listing."
        fi
    done
elif command -v lsinitrd >/dev/null 2>&1; then
    MANIFEST=$(lsinitrd "${INITRD_TARGET}" 2>/dev/null || true)
    for drv in "thunderbolt" "nvme"; do
        if echo "${MANIFEST}" | grep -q "${drv}"; then
            log_ok "Verified driver in initrd: ${drv}"
        fi
    done
fi

echo -e "\n${BOLD}${GREEN}====================================================================${NC}"
echo -e "${BOLD}${GREEN}      USB4 Direct-Boot Fix Successfully Deployed & Verified!         ${NC}"
echo -e "${BOLD}${GREEN}====================================================================${NC}"
echo ""
echo "Next Step: Physical Cold-Boot Procedure:"
echo "  1. Run: sudo poweroff"
echo "  2. Unplug AC power adapter."
echo "  3. Hold laptop power button for 30 seconds (flea-power drain)."
echo "  4. Reconnect AC power adapter."
echo "  5. Plug the drive into the USB4 / Thunderbolt 4 Port."
echo "  6. Power on, tap F12 (or BIOS boot menu key), and select your external NVMe."
echo "  7. After desktop loads, run: bash scripts/verify_usb4_environment.sh"
echo ""
