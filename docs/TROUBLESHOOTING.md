# Troubleshooting & Diagnostic Guide
## High-Speed USB4 / Thunderbolt 4 External NVMe Storage Pipeline

---

## 1. Quick Emergency Recovery

If your system fails to boot or hangs at the initial ramdisk stage after a system update:

### Instant Fallback: The Side Port Trick
1. Unplug the external SSD cable from the USB4 port.
2. Plug it into any standard **USB 3.2 port** (e.g. side USB-C or USB-A port).
3. Power on the computer and select the drive from the boot menu.
4. **Why this works:** The ASM2464PD bridge immediately operates in standard USB Attached SCSI Protocol (UASP) mode (`/dev/sda`), bypassing all PCIe tunneling logic.
5. Once your desktop loads, simply rerun the installer to restore all boot configurations:
   ```bash
   sudo bash setup_usb4_boot.sh --apply
   ```
6. Move the cable back to the high-speed USB4 port and cold boot!

---

## 2. Common Issues & Root Causes

### 1. Boot Hangs at "Waiting for root device" / Dracut Timeout
- **Symptom:** System boots into GRUB, kernel loads, then freezes for 60–180 seconds before dropping to an emergency shell (`dracut:/#` or `(initramfs)`).
- **Cause:** Upstream Linux kernel regression (`thunderbolt.host_reset=1`) resetting the Thunderbolt host router during kernel initialization.
- **Fix:** Verify `/etc/default/grub.d/99-usb4-transport.cfg` contains `thunderbolt.host_reset=0` and run `sudo bash setup_usb4_boot.sh --apply`.

### 2. Controller Stuck in USB 3.2 Mode on USB4 Port
- **Symptom:** You plug into the high-speed rear port, but `verify_usb4_environment.sh` reports `/dev/sda` (UASP) instead of `/dev/nvme0n1`.
- **Cause:** The ASM2464PD bridge or host retimer retained USB 3.2 PHY state across warm reboots.
- **Fix:** Perform a **30-second flea-power drain**:
  1. `sudo poweroff`
  2. Disconnect AC power charger and SSD cable.
  3. Hold laptop/PC power button down for **30 full seconds**.
  4. Reconnect AC charger, connect SSD cable to USB4 port, and power on.

### 3. Drive Disconnects under Heavy Write Workloads (SCSI Command Timeout)
- **Symptom:** Drive freezes during massive file copies or database benchmarks when plugged into a USB 3.2 port; `dmesg` shows:
  ```text
  sd 0:0:0:0: [sda] tag#0 FAILED Result: hostbyte=DID_OK driverbyte=DRIVER_OK cmd_age=30s
  sd 0:0:0:0: [sda] tag#0 CDB: Unmap ...
  ```
- **Cause:** Unclamped TRIM / UNMAP requests in UASP mode exceeding ASM2464PD command buffer.
- **Fix:** Ensure `/etc/udev/rules.d/10-asm2464pd-trim.rules` is deployed. It clamps discard requests to 64MB:
  ```bash
  cat /sys/block/sda/queue/discard_max_bytes
  # Should report: 67108864
  ```

### 4. Cable Bandwidth Limitations
- **Symptom:** Negotiated link speed is PCIe Gen 3 or USB 3.2 despite connecting to a USB4 port.
- **Cause:** Using a standard USB-C charging cable instead of a certified 40 Gbps USB4 / Thunderbolt 4 cable.
- **Requirement:** Ensure your cable is marked with the **40** or **Thunderbolt ⚡** logo and is under 0.8 meters (passive) or actively retimed.

---

## 3. Multi-PC Portability

### Can I use this drive on other computers (e.g. school labs, work PCs)?
**Yes.**

1. **Hardware Fallback is Automatic:**
   When connected to computers lacking USB4 (such as PCs with standard 10 Gbps or 20 Gbps USB-C ports), the ASM2464PD bridge automatically falls back to standard UASP (`/dev/sda`).
2. **UUID-Based Mounting:**
   Because Linux mounts filesystems by partition UUID rather than device node (`/dev/sda` vs `/dev/nvme0n1`), the root partition will mount cleanly regardless of whether the bus is operating as native NVMe or UASP SCSI.
3. **Transport Parameters are Harmless on Other Hardware:**
   The kernel flags (`thunderbolt.host_reset=0`, `pcie_port_pm=off`) are harmless no-ops on systems lacking Thunderbolt controllers.
