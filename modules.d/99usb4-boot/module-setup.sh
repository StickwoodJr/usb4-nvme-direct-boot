#!/usr/bin/env bash
# ==============================================================================
# /usr/lib/dracut/modules.d/99usb4-boot/module-setup.sh
# Enterprise Dracut Module: Early USB4 / Thunderbolt NVMe Direct-Boot
# ==============================================================================

# Determines whether this module should be included in the initramfs
check() {
    local root_dev dev_path pci_classes

    # In generic (non-hostonly) mode, always include for USB4 direct-boot capability
    [[ $hostonly ]] || return 0

    # 1. Check if hardware has a USB4 / Thunderbolt controller
    # PCI class 0x0c0340 = USB4 Host Controller; 0x088000 = Thunderbolt NHI
    pci_classes=$(cat /sys/bus/pci/devices/*/class 2>/dev/null || true)
    if [[ ! -d /sys/bus/thunderbolt ]] && ! echo "$pci_classes" | grep -qE "0x0c0340|0x088000"; then
        # No USB4/Thunderbolt hardware exists on this host
        return 255
    fi

    # 2. Check if administrative override or configuration exists
    if [[ -f /etc/usb4-boot.conf ]] || [[ -f /etc/dracut.conf.d/99-usb4.conf ]]; then
        return 0
    fi

    # 3. Check if any Thunderbolt/USB4 peripheral is currently attached
    if compgen -G "/sys/bus/thunderbolt/devices/*-*" > /dev/null; then
        return 0
    fi

    # 4. Check if root device is backed by Thunderbolt/USB4 or external NVMe
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ -n "$root_dev" && -b "$root_dev" ]]; then
        dev_path=$(udevadm info -q path -n "$root_dev" 2>/dev/null || true)
        if [[ "$dev_path" == *"/thunderbolt"* || "$dev_path" == *"/domain"* ]]; then
            return 0
        fi
        # External NVMe disk over PCIe or USB fallback
        if [[ "$root_dev" =~ ^/dev/nvme[0-9]+n[0-9]+ || "$root_dev" =~ ^/dev/sd[a-z]+ ]]; then
            local sys_block="/sys/class/block/${root_dev##*/}"
            if [[ -f "$sys_block/removable" && "$(cat "$sys_block/removable" 2>/dev/null)" == "1" ]]; then
                return 0
            fi
        fi
    fi

    # Hardware present, but not actively used for boot: opt-in only
    return 255
}

# Module dependencies: minimal, modular, zero bloat
depends() {
    echo "udev-rules kernel-modules"
    return 0
}

# Kernel modules: strictly required storage/bus transport; zero bloat
installkernel() {
    # thunderbolt: USB4 bus & host router manager
    # nvme: PCIe NVMe endpoint block driver
    # nvme_core: NVMe core subsystem & HMB controller
    # (pci_hotplug is built-in; intel_lpss_pci and thunderbolt_net are eliminated)
    instmods thunderbolt nvme nvme_core
}

# Binaries, udev rules, configs, and early-boot hooks
install() {
    # 1. Install udev rules for auto-authorization and PCIe rescan
    inst_rules "$moddir/80-usb4-storage.rules"

    # 2. Install lightweight POSIX authorization helper
    inst_script "$moddir/usb4-storage-authorizer" "/usr/lib/udev/usb4-storage-authorizer"

    # 3. Install modprobe configuration for Thunderbolt parameters
    if [[ -f /etc/modprobe.d/thunderbolt.conf ]]; then
        inst_simple "/etc/modprobe.d/thunderbolt.conf"
    fi

    # 4. Install early pre-trigger hook to preserve pre-boot BIOS tunnels
    inst_hook pre-trigger 00 "$moddir/usb4-pre-trigger.sh"

    # 5. Core utilities needed by udev scripts in initramfs
    inst_multiple -o udevadm cut tr grep sed
}
