#!/bin/sh
# ==============================================================================
# /usr/lib/dracut/modules.d/99usb4-boot/usb4-pre-trigger.sh
# Runs during dracut pre-trigger hook stage (BEFORE udevadm trigger)
# Ensures modules are loaded, pre-boot tunnels are preserved, and storage
# devices are ready for udev coldplugging.
# ==============================================================================

# Ensure kernel modules are loaded with proper parameters
modprobe -q thunderbolt 2>/dev/null || true
modprobe -q nvme 2>/dev/null || true
modprobe -q nvme_core 2>/dev/null || true

# Check if Thunderbolt devices are already enumerated by BIOS pre-boot
if [ -d /sys/bus/thunderbolt/devices ]; then
    for dev in /sys/bus/thunderbolt/devices/*-*; do
        [ -e "$dev/authorized" ] || continue
        if [ "$(cat "$dev/authorized" 2>/dev/null)" = "0" ]; then
            rel_path="/devices/${dev##*/}"
            # Qualify device before authorizing
            if /usr/lib/udev/usb4-storage-authorizer "$rel_path" 2>/dev/null; then
                echo 1 > "$dev/authorized" 2>/dev/null || true
            fi
        fi
    done
fi

# Controlled PCIe rescan to guarantee NVMe endpoint instantiation
if [ -f /sys/bus/pci/rescan ]; then
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
fi
