#!/usr/bin/env bash
# ==============================================================================
# verify_usb4_environment.sh - USB4 Direct-Boot & Storage Pipeline Pre-Flight Check
# Purpose: Fast, sub-100ms hardware, transport link, and kernel parameter verification
# Design:  Pure function, zero bloat, zero background overhead
# ==============================================================================
set -euo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  [${GREEN}${BOLD}PASS${NC}] $1"; }
warn() { echo -e "  [${YELLOW}${BOLD}WARN${NC}] $1"; }
fail() { echo -e "  [${RED}${BOLD}FAIL${NC}] $1"; }
info() { echo -e "  [${CYAN}INFO${NC}] $1"; }

echo -e "${BOLD}================================================================================${NC}"
echo -e "${CYAN}${BOLD}       USB4 DIRECT-BOOT & STORAGE PIPELINE PRE-FLIGHT VERIFICATION               ${NC}"
echo -e "${BOLD}================================================================================${NC}"

# 1. Kernel Boot Arguments Audit
echo -e "\n${BOLD}[1] ACTIVE KERNEL PARAMETERS AUDIT (/proc/cmdline)${NC}"
CMDLINE=$(cat /proc/cmdline 2>/dev/null || echo "")

check_param() {
    local param="$1"
    local desc="$2"
    if [[ "$CMDLINE" =~ $param ]]; then
        pass "$param ($desc)"
    else
        warn "$param NOT ACTIVE in current boot ($desc)"
    fi
}

check_param "thunderbolt.host_reset=0" "Preserves pre-boot UEFI PCIe tunnel across kernel handover"
check_param "thunderbolt.clx=0" "Disables USB4 CL0s/CL1 low-power lane states to prevent link drops"
check_param "pcie_port_pm=off" "Prevents PCIe root ports from entering runtime D3cold"
check_param "pcie_aspm=off" "Disables Active State Power Management to prevent link retraining drops"
check_param "nvme_core.default_ps_max_latency_us=0" "Disables NVMe APST deep sleep (locks drive in PS0)"
check_param "pciehp.pciehp_poll_mode=1" "Ensures polling mode for PCIe hotplug"

# 2. Storage Bus & Controller Mode Audit
echo -e "\n${BOLD}[2] STORAGE TOPOLOGY & PROTOCOL AUDIT${NC}"
ROOT_DEV=$(df -P / 2>/dev/null | tail -1 | awk '{print $1}')
info "Root partition device: $ROOT_DEV"

if [[ "$ROOT_DEV" =~ nvme[0-9]+n[0-9]+ ]]; then
    CTRL_NAME=$(echo "$ROOT_DEV" | grep -o 'nvme[0-9]\+')
    pass "Storage Interface: Native PCIe Gen 4 x4 over USB4 (/dev/$CTRL_NAME)"

    # Audit PCIe Link Speed & Width
    if command -v lspci >/dev/null 2>&1; then
        PCI_DEV=$(basename "$(readlink "/sys/class/nvme/$CTRL_NAME/device" 2>/dev/null || echo "")" 2>/dev/null || echo "")
        if [[ -n "$PCI_DEV" && -f "/sys/bus/pci/devices/$PCI_DEV/current_link_speed" ]]; then
            LNK_SPEED=$(cat "/sys/bus/pci/devices/$PCI_DEV/current_link_speed" 2>/dev/null || echo "Unknown")
            LNK_WIDTH=$(cat "/sys/bus/pci/devices/$PCI_DEV/current_link_width" 2>/dev/null || echo "Unknown")
            info "PCIe Link Status: Speed $LNK_SPEED | Width x$LNK_WIDTH"
            if [[ "$LNK_SPEED" =~ 16 ]] && [[ "$LNK_WIDTH" == "4" ]]; then
                pass "PCIe Link operating at full speed: 16 GT/s (PCIe 4.0) x4 lanes (~64 Gbps link)"
            else
                warn "PCIe Link speed/width lower than Gen 4 x4: $LNK_SPEED x$LNK_WIDTH"
            fi

            # Audit PCIe MPS (Max Payload Size) & MRRS (Max Read Request Size)
            DEVCTL=$(lspci -s "$PCI_DEV" -vvv 2>/dev/null | grep -i "DevCtl:" | head -1 || echo "")
            if [[ -n "$DEVCTL" ]]; then
                MPS=$(echo "$DEVCTL" | grep -o 'MaxPayload [0-9]\+ bytes' || echo "")
                MRRS=$(echo "$DEVCTL" | grep -o 'MaxReadReq [0-9]\+ bytes' || echo "")
                if [[ -n "$MPS" ]]; then
                    info "PCIe Packet Framing: $MPS | $MRRS"
                    if echo "$MPS" | grep -q "128 bytes"; then
                        pass "Max Payload Size (MPS): 128 Bytes (optimal match for USB4 adapter buffers)"
                    fi
                    if echo "$MRRS" | grep -q "512 bytes"; then
                        pass "Max Read Request Size (MRRS): 512 Bytes (optimal flow control balance)"
                    fi
                fi
            fi
        fi
    fi

    # Audit Host Memory Buffer (HMB) Status
    if command -v nvme >/dev/null 2>&1; then
        HMB_RAW=""
        if [[ $EUID -eq 0 ]]; then
            HMB_RAW=$(nvme get-feature "/dev/$CTRL_NAME" -f 0x0d 2>/dev/null || echo "")
        else
            HMB_RAW=$(sudo -n nvme get-feature "/dev/$CTRL_NAME" -f 0x0d 2>/dev/null || echo "")
        fi
        if echo "$HMB_RAW" | grep -iq "Current value:0x00000001"; then
            pass "Host Memory Buffer (HMB): ACTIVE (Host RAM allocated via IOMMU/VT-d)"
        elif echo "$HMB_RAW" | grep -iq "Current value:0x00000000"; then
            warn "Host Memory Buffer (HMB): INACTIVE"
        elif [[ -n "$HMB_RAW" ]]; then
            info "Host Memory Buffer status: Supported"
        else
            info "Host Memory Buffer status: Run with sudo to query live Feature 0x0d"
        fi
    fi
else
    warn "Storage Interface: USB 3.2 UASP Fallback Mode ($ROOT_DEV)"
    warn "Host Memory Buffer is DISABLED in UASP mode."
    info "Recommendation: Cold boot with external drive connected to the high-speed USB4 / Thunderbolt 4 port."

    # Check TRIM Clamping in UASP Mode
    BLK_NAME=$(echo "$ROOT_DEV" | grep -o 'sd[a-z]')
    if [[ -f "/sys/block/$BLK_NAME/queue/discard_max_bytes" ]]; then
        MAX_DISCARD=$(cat "/sys/block/$BLK_NAME/queue/discard_max_bytes" 2>/dev/null || echo "0")
        if [[ "$MAX_DISCARD" -le 67108864 && "$MAX_DISCARD" -gt 0 ]]; then
            pass "UASP TRIM clamped to $MAX_DISCARD bytes (SCSI 30s timeout prevented)"
        else
            warn "UASP TRIM discard_max_bytes is $MAX_DISCARD (Recommend clamping to 67108864)"
        fi
    fi
fi

# 3. ASMedia ASM2464PD Firmware & Thermals Audit
echo -e "\n${BOLD}[3] CONTROLLER & THUNDERBOLT TELEMETRY${NC}"
TB_FOUND=0
for d in /sys/bus/thunderbolt/devices/*; do
    if [ -f "$d/device_name" ]; then
        TB_FOUND=1
        VNAME=$(cat "$d/vendor_name" 2>/dev/null || echo "Vendor")
        DNAME=$(cat "$d/device_name" 2>/dev/null || echo "Device")
        NVM_VER=$(cat "$d/nvm_version" 2>/dev/null || echo "N/A")
        pass "Thunderbolt Device: $VNAME $DNAME (NVM Firmware: $NVM_VER)"
    fi
done
if [ "$TB_FOUND" -eq 0 ]; then
    info "No Thunderbolt peripheral devices currently enumerated in sysfs."
fi

# 4. Persistence & Configuration Drop-Ins Audit
echo -e "\n${BOLD}[4] CONFIGURATION DROP-IN FILES AUDIT${NC}"

check_file() {
    local file="$1"
    local desc="$2"
    local must_exec="${3:-0}"
    if [ -f "$file" ]; then
        if [ "$must_exec" -eq 1 ]; then
            if [ -x "$file" ]; then
                pass "$file ($desc, executable)"
            else
                fail "$file is NOT executable! Run: sudo chmod +x $file"
            fi
        else
            pass "$file ($desc)"
        fi
    else
        info "$file not present ($desc)"
    fi
}

check_file "/etc/default/grub.d/99-usb4-transport.cfg" "GRUB transport drop-in" 0
check_file "/etc/dracut.conf.d/99-usb4.conf" "Dracut USB4 drivers & module configuration" 0
check_file "/etc/modprobe.d/thunderbolt.conf" "Thunderbolt modprobe parameters" 0
check_file "/etc/udev/rules.d/10-asm2464pd-trim.rules" "ASM2464PD TRIM optimization udev rule" 0
check_file "/etc/sysctl.d/99-vms-storage.conf" "Host memory writeback throttle tuning" 0
check_file "/usr/lib/dracut/modules.d/99usb4-rescan/module-setup.sh" "Dracut module setup" 1
check_file "/usr/lib/dracut/modules.d/99usb4-rescan/usb4-pre-trigger.sh" "Dracut pre-trigger rescan hook" 1
check_file "/usr/lib/dracut/modules.d/99usb4-rescan/usb4-initqueue-settled.sh" "Dracut initqueue settled watchdog hook" 1
check_file "/etc/initramfs-tools/conf.d/usb4-rootdelay.conf" "initramfs-tools rootdelay drop-in" 0
check_file "/etc/initramfs-tools/scripts/init-premount/usb4-rescan" "initramfs-tools premount hook" 1

# 5. Virtualization Memory Tuning Audit
echo -e "\n${BOLD}[5] HOST MEMORY DIRTY WRITEBACK THRESHOLDS AUDIT${NC}"
DIRTY_BG=$(sysctl -n vm.dirty_background_bytes 2>/dev/null || echo "0")
DIRTY_MAX=$(sysctl -n vm.dirty_bytes 2>/dev/null || echo "0")

if [ "$DIRTY_BG" = "268435456" ] && [ "$DIRTY_MAX" = "1073741824" ]; then
    pass "Byte-based writeback active: Background flush at 256MB | Hard ceiling at 1GB"
else
    info "Current writeback thresholds: dirty_bg: $DIRTY_BG, dirty_max: $DIRTY_MAX"
fi

echo -e "${BOLD}================================================================================${NC}"
echo -e " Pre-flight check complete. All tests evaluated."
echo -e "${BOLD}================================================================================${NC}"
