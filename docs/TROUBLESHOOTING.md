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

### 2. Controller Stuck in USB 3.2 Mode or Missing from BIOS Boot Menu
- **Symptom:** The external drive does not appear in the BIOS F12 Boot Menu when plugged into the USB4 port (or shows "no boot device found"), or it falls back to `/dev/sda` (UASP) instead of native PCIe NVMe (`/dev/nvme0n1`).
- **Physical Root Cause:**
  1. **The 1.5s vs 4.0s Link-Training Timing Race:** The ASMedia ASM2464PD bridge and Intel host retimer negotiate USB-PD, train high-speed differential pairs, and build the 40 Gbps PCIe Gen 4 x4 tunnel. This electrical handshake takes **2.5 to 4 seconds**. When motherboard UEFI firmware has **Fastboot: Minimal** enabled, BIOS POST finishes in under 1.5 seconds and queries the PCIe root port before the tunnel is established.
  2. **Retimer Capacitive State (Flea-Power):** High-speed USB4 retimers maintain physical layer PHY training registers powered by residual motherboard capacitance across normal warm reboots. If the link was disrupted, retimers can remain in an unsynchronized low-power state.
- **Permanent Solution & Discharge Procedure:**
  1. **In Motherboard BIOS (F2):** Set **Fastboot: Thorough** and enable **Extend BIOS POST Time: 5s** (ensures the BIOS waits for external Thunderbolt/PCIe devices before rendering the boot menu).
  2. **Perform a 30-Second Flea-Power Drain:**
     - Run: `sudo poweroff`
     - Disconnect the AC power adapter and the SSD cable.
     - **Hold the laptop power button down for 30 full seconds** (completely discharges retimer capacitors and forces cold link re-training).
     - Reconnect AC power, plug into the **rear USB4 port**, power on, and tap **F12** to select the drive.

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

### Can I use this drive on other computers (e.g. school labs, work PCs)?
**Yes, but subject to specific platform constraints:**

1. **Hardware Fallback is Automatic:**
   When connected to computers lacking USB4 (such as PCs with standard 10 Gbps or 20 Gbps USB-C ports), the ASM2464PD bridge automatically falls back to standard UASP (`/dev/sda`).
2. **UUID-Based Mounting:**
   Because Linux mounts filesystems by partition UUID rather than device node (`/dev/sda` vs `/dev/nvme0n1`), the root partition will mount cleanly regardless of whether the bus is operating as native NVMe or UASP SCSI.
3. **Hard Realities & Caveats on Secondary Systems:**
   - **Thunderbolt Security Levels (SL0 vs SL1/SL2):** If the secondary computer enforces User Authorization (`SL1`) or Secure Connect (`SL2`) in BIOS, pre-boot PCIe tunnels will be blocked unless the enclosure UUID is enrolled in the host's pre-boot Access Control List (ACL). In that scenario, boot via a standard USB 3.2 port.
   - **Kernel Version Dependency:** If the secondary PC runs Linux 6.8+, the `thunderbolt.host_reset=0` parameter is necessary to prevent tunnel teardown on its USB4 ports. On systems booting an internal OS, this configuration is irrelevant.
   - **BIOS Fastboot Quirks:** Motherboards with aggressive minimal POST times may fail to train the external 40 Gbps link on cold power-on. Keep a standard USB-A/C 10 Gbps cable handy as an instant universal fallback.
