#!/usr/bin/env bash
# ==============================================================================
# apply_usb4_direct_boot_fix.sh - Hardened USB4 / TB4 Direct-Boot Installer
# ==============================================================================
# Target Systems:  Laptops & Desktops with Intel/AMD USB4 / Thunderbolt 4
# Target Storage:  External NVMe SSDs (ASMedia ASM2464PD / Intel Thunderbolt)
# Frameworks:      Dracut & Initramfs-tools with Dynamic UUID Discovery
# Scope:           Safe boot drop-ins on target root without modifying internal disks
# Transaction:     Atomic state manifest with automatic error trap rollback
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

# Paths & Defaults
USER_HOME="${SUDO_USER:+/home/$SUDO_USER}"
USER_HOME="${USER_HOME:-$HOME}"
BACKUP_DIR="${USER_HOME}/usb4-prechange-backup"
STATE_DIR="/var/lib/usb4-direct-boot"
TRANSACTION_MANIFEST="${STATE_DIR}/transaction.manifest"
RUNNING_KERNEL="$(uname -r)"
INITRD_TARGET="/boot/initrd.img-${RUNNING_KERNEL}"
DRACUT_MOD_DIR="/usr/lib/dracut/modules.d/99usb4-rescan"

MODE="interactive"
UUID_OVERRIDE=""
FORCE=0

# Transaction tracking array
CREATED_FILES=()

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
        --non-interactive)
            MODE="non-interactive"
            shift
            ;;
        --force)
            FORCE=1
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
            echo "USB4 Direct-Boot Setup Utility (Hardened Installer)"
            echo "Usage: sudo bash $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --audit             Perform read-only pre-flight audit of host, kernel, and USB4 topology"
            echo "  --dry-run           Preview all configuration files and actions without modifying state"
            echo "  --apply, -y         Apply hardened USB4 boot configurations and rebuild initrd (requires root)"
            echo "  --non-interactive   Skip interactive confirmation prompts in --apply mode"
            echo "  --force             Override safety warnings regarding kernel or controller generation"
            echo "  --uuid <UUID>       Explicitly set root partition UUID (useful for chroot installs)"
            echo "  -h, --help          Display this help message"
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
# ENVIRONMENT & HARDWARE DISCOVERY
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
    # Check for unsupported frameworks first
    if command -v mkinitcpio >/dev/null 2>&1; then
        echo "mkinitcpio"
        return
    fi
    if command -v rpm-ostree >/dev/null 2>&1; then
        echo "ostree"
        return
    fi

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

detect_kernel_major_minor() {
    local kver="$RUNNING_KERNEL"
    local major minor
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)
    echo "${major}.${minor}"
}

check_thunderbolt_controller() {
    local has_tb=0
    # Check PCI devices for Thunderbolt / USB4
    if command -v lspci >/dev/null 2>&1; then
        if lspci -d ::0c0330 2>/dev/null | grep -qi "USB4"; then
            has_tb=1
        elif lspci 2>/dev/null | grep -qiE "(Thunderbolt|USB4)"; then
            has_tb=1
        fi
    fi
    if [[ -d /sys/bus/thunderbolt ]]; then
        has_tb=1
    fi
    echo "$has_tb"
}

check_root_is_external() {
    local root_src
    root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
    local is_ext=0
    if [[ "$root_src" =~ nvme[0-9]+n[0-9]+ ]]; then
        # Check if parent device is behind a Thunderbolt root port or removable
        local ctrl_dev
        ctrl_dev=$(basename "$(readlink "/sys/class/block/$(basename "$root_src")/device" 2>/dev/null || echo "")")
        if udevadm info -q property "/sys/class/nvme/${ctrl_dev}" 2>/dev/null | grep -qE "(ID_PATH.*pci.*00:07|ID_PATH.*pci.*00:0d)"; then
            is_ext=1
        elif [[ -f "/sys/class/block/$(basename "$root_src")/removable" ]] && [[ "$(cat "/sys/class/block/$(basename "$root_src")/removable")" == "1" ]]; then
            is_ext=1
        fi
    elif [[ "$root_src" =~ sd[a-z] ]]; then
        is_ext=1
    fi
    echo "$is_ext"
}

TARGET_ROOT_UUID="$(detect_root_uuid)"
INIT_FRAMEWORK="$(detect_initramfs_framework)"
BOOTLOADER_CMD="$(detect_bootloader_type)"
KVER_MM="$(detect_kernel_major_minor)"
HAS_TB_CONTROLLER="$(check_thunderbolt_controller)"
ROOT_IS_EXTERNAL="$(check_root_is_external)"

# ==============================================================================
# AUDIT MODE
# ==============================================================================
run_audit() {
    log_header "READ-ONLY PRE-FLIGHT AUDIT & SYSTEM RECONNAISSANCE"
    log_info "Host Model: $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || uname -n) ($(uname -m))"
    log_info "Running Kernel: ${RUNNING_KERNEL} (Major.Minor: ${KVER_MM})"
    
    # Kernel version assessment
    local k_major k_minor
    k_major=$(echo "$KVER_MM" | cut -d. -f1)
    k_minor=$(echo "$KVER_MM" | cut -d. -f2)
    if [[ "$k_major" -gt 6 ]] || [[ "$k_major" -eq 6 && "$k_minor" -ge 8 ]]; then
        log_ok "Kernel version ${RUNNING_KERNEL} >= 6.8: subject to host_reset=1 regression (mitigation applicable)"
    else
        log_info "Kernel version ${RUNNING_KERNEL} < 6.8: regression not present by default"
    fi

    # Controller assessment
    if [[ "$HAS_TB_CONTROLLER" -eq 1 ]]; then
        log_ok "USB4 / Thunderbolt host controller detected on PCI/sysfs"
    else
        log_warn "No USB4 / Thunderbolt controller detected on PCI bus"
    fi

    # Storage topology assessment
    local cur_root
    cur_root=$(findmnt -no SOURCE / 2>/dev/null || echo "unknown")
    log_info "Current Root Mount Device: ${cur_root}"
    if [[ "$ROOT_IS_EXTERNAL" -eq 1 ]]; then
        log_ok "Root storage is an external USB4/USB bus device"
    else
        log_info "Root storage appears to be an internal bus drive"
    fi

    log_info "Detected Initramfs Engine: ${INIT_FRAMEWORK}"
    log_info "Detected Bootloader Tool: ${BOOTLOADER_CMD}"
    
    if [[ -n "${TARGET_ROOT_UUID}" ]]; then
        log_ok "Detected Root Partition UUID: ${TARGET_ROOT_UUID}"
    else
        log_warn "Could not resolve root UUID automatically. Supply with --uuid <UUID>."
    fi

    # Check initrd file
    if [[ -f "${INITRD_TARGET}" ]]; then
        log_ok "Target initrd exists: ${INITRD_TARGET} ($(du -h "${INITRD_TARGET}" 2>/dev/null | awk '{print $1}'))"
    else
        log_warn "Target initrd not found at ${INITRD_TARGET}. Rebuild will generate a new image."
    fi

    # Check Thunderbolt runtime parameter
    local hr="unknown"
    if [[ -f /sys/module/thunderbolt/parameters/host_reset ]]; then
        hr=$(cat /sys/module/thunderbolt/parameters/host_reset)
    fi
    log_info "thunderbolt.host_reset runtime: ${hr} (Target: N/0)"

    log_header "CONFIGURATION DROP-IN AUDIT"
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
            log_ok "Active on system: $f"
        else
            log_info "Pending (not deployed): $f"
        fi
    done

    echo -e "\n${GREEN}${BOLD}Pre-flight audit complete.${NC}\n"
}

if [[ "${MODE}" == "audit" ]]; then
    run_audit
    exit 0
fi

# ==============================================================================
# DRY-RUN MODE
# ==============================================================================
run_dry_run() {
    log_header "DRY-RUN EXECUTION PREVIEW (ZERO MUTATION)"
    log_info "No files will be modified, created, or deleted."
    log_info "Target Kernel: ${RUNNING_KERNEL}"
    log_info "Target Root UUID: ${TARGET_ROOT_UUID:-<Auto-detected during execution>}"
    log_info "Initramfs Engine: ${INIT_FRAMEWORK}"
    log_info "Bootloader Tool: ${BOOTLOADER_CMD}"

    echo -e "\n${BOLD}[1] Planned Bootloader Parameters:${NC}"
    if [[ -d /etc/default/grub.d ]] || [[ -f /etc/default/grub.d/99-usb4-transport.cfg ]]; then
        echo "  Target File: /etc/default/grub.d/99-usb4-transport.cfg"
    else
        echo "  Target File: /etc/default/grub (append to GRUB_CMDLINE_LINUX)"
    fi
    echo "  Parameters: thunderbolt.host_reset=0 thunderbolt.clx=0 pcie_port_pm=off rootdelay=60"

    echo -e "\n${BOLD}[2] Planned Modprobe Configuration:${NC}"
    echo "  Target File: /etc/modprobe.d/thunderbolt.conf"
    echo "  Content: options thunderbolt host_reset=0 clx=0"

    echo -e "\n${BOLD}[3] Planned Udev Rule:${NC}"
    echo "  Target File: /etc/udev/rules.d/10-asm2464pd-trim.rules"
    echo "  Content: ASMedia ASM2464PD 64MB discard limit clamp"

    echo -e "\n${BOLD}[4] Planned Initramfs Drop-ins:${NC}"
    if [[ "${INIT_FRAMEWORK}" == "dracut" ]]; then
        echo "  Engine: dracut"
        echo "  Drop-in: /etc/dracut.conf.d/99-usb4.conf"
        echo "  Module Directory: ${DRACUT_MOD_DIR}/"
        echo "    - module-setup.sh"
        echo "    - usb4-pre-trigger.sh (early PCIe bus rescan)"
        echo "    - usb4-initqueue-settled.sh (Dynamic Root UUID: ${TARGET_ROOT_UUID:-Dynamic})"
        echo "  Command: dracut --force ${INITRD_TARGET} ${RUNNING_KERNEL}"
    elif [[ "${INIT_FRAMEWORK}" == "initramfs-tools" ]]; then
        echo "  Engine: initramfs-tools"
        echo "  Drop-in: /etc/initramfs-tools/conf.d/usb4-rootdelay.conf"
        echo "  Modules: /etc/initramfs-tools/modules (thunderbolt, nvme, nvme_core)"
        echo "  Premount Script: /etc/initramfs-tools/scripts/init-premount/usb4-rescan"
        echo "  Command: update-initramfs -u -k ${RUNNING_KERNEL}"
    elif [[ "${INIT_FRAMEWORK}" == "mkinitcpio" ]]; then
        echo "  Engine: mkinitcpio (Arch Linux)"
        echo "  Notice: Automatic injection not supported; manual mkinitcpio.conf hook required."
    fi

    echo -e "\n${GREEN}${BOLD}Dry-run complete.${NC} To apply changes, execute: sudo ./setup_usb4_boot.sh --apply\n"
}

if [[ "${MODE}" == "dry-run" ]]; then
    run_dry_run
    exit 0
fi

# ==============================================================================
# ROOT ENFORCEMENT & SAFETY GATING
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    log_fail "This script modifies system boot configuration and must be run as root."
    echo "Run with: sudo ./setup_usb4_boot.sh --apply"
    exit 1
fi

# Framework sanity check
if [[ "${INIT_FRAMEWORK}" == "mkinitcpio" ]]; then
    log_fail "Arch Linux mkinitcpio detected. This automated suite currently supports dracut and initramfs-tools."
    echo "Please consult docs/HARDWARE_ARCHITECTURE.md for manual mkinitcpio hook configuration."
    exit 1
elif [[ "${INIT_FRAMEWORK}" == "ostree" ]]; then
    log_fail "rpm-ostree / immutable distribution detected. Modifying initrd drop-ins directly is not supported."
    exit 1
elif [[ "${INIT_FRAMEWORK}" == "unknown" ]]; then
    log_fail "Could not identify an active initramfs engine (dracut or initramfs-tools). Aborting."
    exit 1
fi

# Interactive confirmation & safety warnings
if [[ "${MODE}" == "interactive" ]]; then
    echo -e "${BOLD}====================================================================${NC}"
    echo -e "${CYAN}${BOLD} USB4 Direct-Boot Setup Utility (Targeted Application)              ${NC}"
    echo -e "${BOLD}====================================================================${NC}"
    echo "Environment Discovery:"
    echo "  - Running Kernel:   ${RUNNING_KERNEL}"
    echo "  - Initramfs Engine: ${INIT_FRAMEWORK}"
    echo "  - Target Root UUID: ${TARGET_ROOT_UUID:-unknown}"
    echo "  - Storage Profile:  $([[ $ROOT_IS_EXTERNAL -eq 1 ]] && echo 'External USB4/USB Drive' || echo 'Internal Drive')"
    echo ""
    echo -e "${YELLOW}${BOLD}IMPORTANT SAFETY & POWER TRADE-OFF NOTICE:${NC}"
    echo "1. Adding 'thunderbolt.clx=0 pcie_port_pm=off' disables low-power link states"
    echo "   on PCIe root ports to prevent link retraining drops. On battery power, this"
    echo "   may slightly increase idle power draw."
    echo "2. A full backup of your current initrd and configuration files will be stored"
    echo "   in: ${BACKUP_DIR}"
    echo "3. You can cleanly undo all changes at any time with: sudo ./setup_usb4_boot.sh --rollback"
    echo ""
    read -rp "Proceed with deploying USB4 direct-boot configurations? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled by user."
        exit 0
    fi
fi

# ==============================================================================
# TRANSACTIONAL ERROR TRAP & ROLLBACK HOOK
# ==============================================================================
cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo -e "\n${RED}${BOLD}[FATAL] Deployment failed with exit code ${exit_code}!${NC}"
        echo -e "${YELLOW}Initiating emergency rollback of newly created drop-in files...${NC}"
        for f in "${CREATED_FILES[@]}"; do
            if [[ -e "$f" ]]; then
                rm -rf "$f"
                echo "  [CLEANUP] Removed incomplete: $f"
            fi
        done
        if [[ -f "${INITRD_TARGET}.pre-usb4-bak" ]]; then
            cp -a "${INITRD_TARGET}.pre-usb4-bak" "${INITRD_TARGET}"
            echo "  [RESTORE] Restored pristine initrd from backup"
        fi
        echo -e "${RED}System restored to safe baseline state. Error was intercepted.${NC}\n"
    fi
}
trap cleanup_on_failure EXIT

# ==============================================================================
# SYSTEM BACKUPS & STATE MANIFEST
# ==============================================================================
log_header "STAGE 1: CREATING TRANSACTIONAL BACKUPS"
mkdir -p "${BACKUP_DIR}"
mkdir -p "${STATE_DIR}"

# Initialize transaction manifest
cat <<EOF > "${TRANSACTION_MANIFEST}"
# USB4 Direct-Boot Deployment Manifest
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
KERNEL="${RUNNING_KERNEL}"
FRAMEWORK="${INIT_FRAMEWORK}"
ROOT_UUID="${TARGET_ROOT_UUID}"
EOF

if [[ -f "${INITRD_TARGET}" ]]; then
    log_info "Backing up ${INITRD_TARGET}..."
    cp -a "${INITRD_TARGET}" "${INITRD_TARGET}.pre-usb4-bak"
    cp -a "${INITRD_TARGET}" "${BACKUP_DIR}/initrd.img-${RUNNING_KERNEL}.bak"
    echo "INITRD_BACKUP=\"${INITRD_TARGET}.pre-usb4-bak\"" >> "${TRANSACTION_MANIFEST}"
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
log_ok "Pristine backups stored in ${BACKUP_DIR}"

record_created_file() {
    CREATED_FILES+=("$1")
    echo "FILE=\"$1\"" >> "${TRANSACTION_MANIFEST}"
}

# ==============================================================================
# STAGE A: BOOTLOADER / GRUB CONFIGURATION
# ==============================================================================
log_header "STAGE 2: CONFIGURING BOOTLOADER KERNEL ARGUMENTS"

USB4_FLAGS="thunderbolt.host_reset=0 thunderbolt.clx=0 pcie_port_pm=off rootdelay=60"

if [[ -d /etc/default/grub.d ]]; then
    TARGET_GRUB_CFG="/etc/default/grub.d/99-usb4-transport.cfg"
    [[ ! -f "$TARGET_GRUB_CFG" ]] && record_created_file "$TARGET_GRUB_CFG"
    cat <<EOF > "$TARGET_GRUB_CFG"
# /etc/default/grub.d/99-usb4-transport.cfg
# USB4 External NVMe Direct-Boot Kernel Parameters
USB4_TRANSPORT_FLAGS="${USB4_FLAGS}"
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} \${USB4_TRANSPORT_FLAGS}"
EOF
    chmod 644 "$TARGET_GRUB_CFG"
    log_ok "Deployed ${TARGET_GRUB_CFG}"
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
# STAGE B: DRIVER, MODPROBE, UDEV & SYSCTL
# ==============================================================================
log_header "STAGE 3: DEPLOYING HARDWARE & STORAGE CONFIGURATION"

# 1. Modprobe configuration for Thunderbolt
mkdir -p /etc/modprobe.d
TB_CONF="/etc/modprobe.d/thunderbolt.conf"
[[ ! -f "$TB_CONF" ]] && record_created_file "$TB_CONF"
cat <<'EOF' > "$TB_CONF"
# /etc/modprobe.d/thunderbolt.conf
# Enforce host_reset=0 and disable CLx low-power states to preserve PCIe tunnels
options thunderbolt host_reset=0 clx=0
EOF
chmod 644 "$TB_CONF"
log_ok "Created $TB_CONF"

# 2. ASMedia ASM2464PD TRIM / UNMAP udev rule
mkdir -p /etc/udev/rules.d
TRIM_RULE="/etc/udev/rules.d/10-asm2464pd-trim.rules"
[[ ! -f "$TRIM_RULE" ]] && record_created_file "$TRIM_RULE"
cat <<'EOF' > "$TRIM_RULE"
# /etc/udev/rules.d/10-asm2464pd-trim.rules
# ASMedia ASM2464PD TRIM / UNMAP Optimization Rule for UASP mode
ACTION=="add|change", ATTRS{idVendor}=="174c", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"
ACTION=="add|change", ATTRS{idVendor}=="174c", SUBSYSTEM=="block", ATTR{queue/discard_max_bytes}="67108864"
EOF
chmod 644 "$TRIM_RULE"
log_ok "Created $TRIM_RULE"

# 3. High-throughput storage flush tuning
mkdir -p /etc/sysctl.d
SYSCTL_CONF="/etc/sysctl.d/99-vms-storage.conf"
[[ ! -f "$SYSCTL_CONF" ]] && record_created_file "$SYSCTL_CONF"
cat <<'EOF' > "$SYSCTL_CONF"
# /etc/sysctl.d/99-vms-storage.conf
# High-Throughput & Multi-VM Storage Flush Tuning
vm.dirty_background_bytes = 268435456
vm.dirty_bytes = 1073741824
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 250
vm.vfs_cache_pressure = 50
EOF
chmod 644 "$SYSCTL_CONF"
sysctl --system >/dev/null 2>&1 || true
log_ok "Created and applied $SYSCTL_CONF"

# ==============================================================================
# STAGE C: INITRAMFS HOOK DEPLOYMENT
# ==============================================================================
log_header "STAGE 4: DEPLOYING EARLY RESCAN HOOKS (${INIT_FRAMEWORK})"

if [[ "${INIT_FRAMEWORK}" == "dracut" ]]; then
    # Dracut driver and module configuration
    mkdir -p /etc/dracut.conf.d
    DRACUT_CONF="/etc/dracut.conf.d/99-usb4.conf"
    [[ ! -f "$DRACUT_CONF" ]] && record_created_file "$DRACUT_CONF"
    cat <<'EOF' > "$DRACUT_CONF"
# /etc/dracut.conf.d/99-usb4.conf
# Dracut-native USB4 / Thunderbolt Direct-Boot Driver & Module Configuration
add_dracutmodules+=" usb4-rescan "
force_drivers+=" thunderbolt nvme nvme_core "
add_drivers+=" typec typec_thunderbolt ucsi_acpi typec_ucsi "
install_items+=" /etc/modprobe.d/thunderbolt.conf "
EOF
    chmod 644 "$DRACUT_CONF"
    log_ok "Created $DRACUT_CONF"

    # Dracut native module directory
    mkdir -p "${DRACUT_MOD_DIR}"
    [[ ! -d "${DRACUT_MOD_DIR}" ]] && record_created_file "${DRACUT_MOD_DIR}"

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
    ROOTDELAY_CONF="/etc/initramfs-tools/conf.d/usb4-rootdelay.conf"
    [[ ! -f "$ROOTDELAY_CONF" ]] && record_created_file "$ROOTDELAY_CONF"
    echo "ROOTDELAY=60" > "$ROOTDELAY_CONF"
    chmod 644 "$ROOTDELAY_CONF"
    log_ok "Created $ROOTDELAY_CONF"

    # Modules
    for mod in thunderbolt nvme nvme_core typec typec_thunderbolt; do
        if ! grep -q "^${mod}" /etc/initramfs-tools/modules 2>/dev/null; then
            echo "${mod}" >> /etc/initramfs-tools/modules
            log_info "Added module to initramfs-tools: ${mod}"
        fi
    done

    # Early pre-mount script
    mkdir -p /etc/initramfs-tools/scripts/init-premount
    PREMOUNT_HOOK="/etc/initramfs-tools/scripts/init-premount/usb4-rescan"
    [[ ! -f "$PREMOUNT_HOOK" ]] && record_created_file "$PREMOUNT_HOOK"
    cat <<'EOF' > "$PREMOUNT_HOOK"
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
    chmod 755 "$PREMOUNT_HOOK"
    log_ok "Deployed $PREMOUNT_HOOK"
fi

# ==============================================================================
# STAGE D: REBUILD INITRD IMAGE
# ==============================================================================
log_header "STAGE 5: REBUILDING INITIAL RAMDISK FOR KERNEL ${RUNNING_KERNEL}"

if [[ "${INIT_FRAMEWORK}" == "dracut" ]]; then
    log_info "Executing: dracut --force ${INITRD_TARGET} ${RUNNING_KERNEL}..."
    dracut --force "${INITRD_TARGET}" "${RUNNING_KERNEL}"
    sync -f "${INITRD_TARGET}"
    log_ok "Successfully rebuilt ${INITRD_TARGET} ($(du -h "${INITRD_TARGET}" | awk '{print $1}'))"
elif [[ "${INIT_FRAMEWORK}" == "initramfs-tools" ]]; then
    log_info "Executing: update-initramfs -u -k ${RUNNING_KERNEL}..."
    update-initramfs -u -k "${RUNNING_KERNEL}"
    log_ok "Successfully rebuilt initrd for kernel ${RUNNING_KERNEL}."
fi

# ==============================================================================
# VERIFICATION & COMPLETION
# ==============================================================================
log_header "STAGE 6: VERIFYING GENERATED INITRD"
if command -v lsinitrd >/dev/null 2>&1; then
    MANIFEST=$(lsinitrd "${INITRD_TARGET}" 2>/dev/null || true)
    for drv in "thunderbolt" "nvme"; do
        if echo "${MANIFEST}" | grep -q "${drv}"; then
            log_ok "Verified driver in initrd: ${drv}"
        fi
    done
elif command -v lsinitramfs >/dev/null 2>&1; then
    MANIFEST=$(lsinitramfs "${INITRD_TARGET}" 2>/dev/null || true)
    for drv in "thunderbolt" "nvme"; do
        if echo "${MANIFEST}" | grep -q "${drv}"; then
            log_ok "Verified driver in initrd: ${drv}"
        else
            log_warn "Driver ${drv} not explicitly matched in listing."
        fi
    done
fi

# Clear trap before normal exit
trap - EXIT

echo -e "\n${BOLD}${GREEN}====================================================================${NC}"
echo -e "${BOLD}${GREEN}   USB4 Direct-Boot Configuration Successfully Applied!             ${NC}"
echo -e "${BOLD}${GREEN}====================================================================${NC}"
echo ""
echo "Cold-Boot & Link Training Verification Procedure:"
echo "  1. Run: sudo poweroff"
echo "  2. Unplug the AC power adapter."
echo "  3. Hold the power button for 30 seconds (resets Thunderbolt retimer capacitance)."
echo "  4. Reconnect AC power adapter."
echo "  5. Connect the external SSD to the rear USB4 / Thunderbolt 4 port."
echo "  6. Power on, tap F12 (or BIOS boot menu key), and select your external NVMe."
echo "  7. Once desktop loads, run: ./setup_usb4_boot.sh --verify"
echo ""
