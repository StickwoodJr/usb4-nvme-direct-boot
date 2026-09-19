# Future Fresh Linux Installation Playbook
## Turnkey USB4 Direct-Boot Setup for High-Performance External NVMe Drives

---

## 1. Overview & Architecture

When installing or reinstalling Linux (Ubuntu, Fedora, Debian, etc.) on an external NVMe drive inside a USB4 / Thunderbolt 4 enclosure (e.g., ASMedia ASM2464PD), major technical hurdles exist on fresh installs:

1. **New Partition UUID**: Reformatting the drive generates a brand-new filesystem UUID for the root partition.
2. **Upstream Linux Kernel Regression (`thunderbolt.host_reset=1`)**: Every stock Linux kernel >= 6.13 resets the Thunderbolt host router (`nhi_reset()`) upon probe. When booting over a USB4 port, this destroys the pre-boot PCIe tunnel created by the UEFI BIOS, causing an immediate boot hang at `initramfs` (*"Waiting for root device"*).
3. **Missing Early Initramfs Modules**: Default initrd configurations do not force-load `thunderbolt`, `nvme`, or early PCIe bus rescan hooks.

This playbook provides a repeatable, foolproof protocol to set up any fresh Linux installation for native PCIe Gen 4 x4 direct booting at full speed (**~3,600 MB/s read, ~2,000 MB/s write**) in under 3 minutes.

---

## 2. The Golden Rule: Side Port First

> [!IMPORTANT]
> **Always perform the initial OS installation while connected to a standard USB 3.2 port (e.g. side USB-C or USB-A port with an adapter).**

### Why?
Most modern USB4 bridges (such as the ASMedia ASM2464PD) are dual-mode controllers:
- **USB4 / Thunderbolt 4 Port**: Negotiates PCIe Gen 4 x4 tunneling over USB4 (requires `thunderbolt.host_reset=0` and early PCIe rescan).
- **Standard USB 3.2 Port**: Automatically falls back to standard USB 3.2 Gen 2 UASP mode (`/dev/sda`).

By installing via a standard USB 3.2 port:
- The Linux installer sees the drive as a standard, bulletproof USB mass storage device.
- Zero risk of PCIe tunnel drops or installer crashes during partitioning and package installation.
- The system will boot reliably on the first attempt into the newly installed OS.

---

## 3. The 3-Step Turnkey Setup Protocol

```
+-----------------------------------------------------------------------------------+
|  STEP 1: INSTALL VIA STANDARD USB PORT                                            |
|    - Connect drive to standard USB 3.2 port                                       |
|    - Install Ubuntu / Linux normally                                              |
|    - Reboot into the fresh desktop                                                |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|  STEP 2: RUN TURNKEY FIX SCRIPT                                                   |
|    - git clone repository                                                         |
|    - sudo bash setup_usb4_boot.sh --apply                                         |
|    - Script auto-detects UUID, framework (dracut/initramfs-tools), & updates GRUB  |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|  STEP 3: CONTROLLER PHY RESET & USB4 DIRECT BOOT                                  |
|    - sudo poweroff                                                                |
|    - Unplug AC, hold power button 30s (flea-power drain)                          |
|    - Plug into USB4 / Thunderbolt 4 port & boot via UEFI                          |
|    - 100% Native PCIe Gen 4 x4 Direct Boot!                                       |
+-----------------------------------------------------------------------------------+
```

### Step 1: Install Linux Normally (Standard USB Port)
1. Plug your USB installation media (Live USB) into the computer.
2. Plug your external drive into a standard USB 3.2 port.
3. Power on, enter the UEFI Boot Menu, and boot into the Linux installer.
4. Target the external drive (e.g. `/dev/sda`) for installation:
   - EFI System Partition: `512 MB - 1024 MB` (FAT32, mount `/boot/efi`)
   - Root Partition: Remainder of drive (ext4, mount `/`)
   > [!CAUTION]
   > Take care never to format or overwrite your computer's internal storage drive containing your primary operating system!
5. Complete installation and reboot into your fresh Linux desktop (still using the standard USB port).

---

### Step 2: Apply the Universal USB4 Direct-Boot Fix
Open a terminal in your fresh Linux installation:

```bash
# 1. Clone the repository
git clone https://github.com/StickwoodJr/usb4-nvme-direct-boot.git
cd usb4-nvme-direct-boot

# 2. (Optional) Run read-only pre-flight audit
bash setup_usb4_boot.sh --audit

# 3. Apply the fix and rebuild initrd
sudo bash setup_usb4_boot.sh --apply
```

#### What the script does automatically:
1. **Dynamic UUID Detection**: Queries `findmnt -no UUID /` to capture your new root filesystem UUID (no hardcoded values).
2. **Framework Detection**: Detects whether your distro uses `dracut` (Ubuntu 26.04+, Fedora, openSUSE) or `initramfs-tools` (Debian, older Ubuntu, Mint).
3. **GRUB Parameters**: Deploys `/etc/default/grub.d/99-usb4-transport.cfg` with:
   ```text
   thunderbolt.host_reset=0 thunderbolt.clx=0 pcie_port_pm=off rootdelay=60
   ```
   and runs `update-grub` / `grub-mkconfig`.
4. **Thunderbolt Modprobe**: Deploys `/etc/modprobe.d/thunderbolt.conf` with `options thunderbolt host_reset=0 clx=0`.
5. **ASM2464PD TRIM Optimization**: Deploys `/etc/udev/rules.d/10-asm2464pd-trim.rules` to clamp UASP TRIM discard requests to 64MB (preventing SCSI 30s timeouts).
6. **Virtualization Memory Tuning**: Deploys `/etc/sysctl.d/99-vms-storage.conf` for multi-VM dirty memory management.
7. **Early PCIe Rescan Hooks**: Deploys native early-boot hooks to authorize the USB4 bridge and rescan the PCIe bus before `udevadm trigger` fires.
8. **Initrd Rebuild**: Automatically backs up the original initrd and rebuilds the initial ramdisk for the active kernel.

---

### Step 3: Controller PHY Reset & High-Speed Port Direct Boot

Because switching bridge controllers from USB 3.2 PHY mode to USB4 / PCIe Gen 4 x4 PHY mode requires clearing the controller and retimer state:

1. Shut down the system:
   ```bash
   sudo poweroff
   ```
2. Unplug the AC power adapter from the computer (if on a laptop).
3. Unplug the external SSD cable.
4. **Press and hold the power button for 30 full seconds** (flea-power drain).
5. Reconnect the AC power adapter.
6. Connect your high-speed cable into the **USB4 / Thunderbolt 4 Port**.
7. Turn on the computer and immediately enter the UEFI Boot Menu (e.g., tap `F12`, `F11`, or `F8` depending on manufacturer).
8. Select your external NVMe drive or distribution bootloader.

---

## 4. Verification & Health Audit

Once your desktop loads over the USB4 port:

```bash
# 1. Run the live environment audit
bash scripts/verify_usb4_environment.sh
```

### Expected Output:
- **Storage Interface**: `Native PCIe Gen 4 x4 over USB4 (/dev/nvme0)`
- **PCIe Link Speed**: `16 GT/s (PCIe 4.0) x4 lanes (~64 Gbps link)`
- **Host Memory Buffer (HMB)**: `ACTIVE (Host RAM allocated via IOMMU/VT-d)`
- **Kernel Parameters**: All parameters (`thunderbolt.host_reset=0`, `thunderbolt.clx=0`, `pcie_port_pm=off`) reported as **`[PASS]`**.

### Performance Benchmark Test:
```bash
# Buffered read speed test
sudo hdparm -Tt /dev/nvme0n1

# Direct sequential write speed test (4GB)
dd if=/dev/zero of=~/speedtest.tmp bs=1M count=4096 oflag=direct status=progress conv=fdatasync && rm -f ~/speedtest.tmp
```
- **Read Speed**: `~3,580 - 3,600 MB/s`
- **Write Speed**: `~1,900 - 2,050 MB/s`

---

## 5. Alternative: Live USB Chroot Provisioning (Advanced)

If you prefer to apply the fix *before* the first reboot directly from the Live USB installation environment:

```bash
# Assuming external root partition is /dev/nvme0n1p2 and EFI is /dev/nvme0n1p1:
sudo mount /dev/nvme0n1p2 /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
for i in /dev /dev/pts /proc /sys /run; do sudo mount -B $i /mnt$i; done

# Chroot into the new install
sudo chroot /mnt

# Clone and apply
git clone https://github.com/StickwoodJr/usb4-nvme-direct-boot.git
cd usb4-nvme-direct-boot
sudo bash setup_usb4_boot.sh --apply

# Exit and clean unmount
exit
sudo umount -R /mnt
sudo poweroff
```

---

## 6. Emergency Recovery & Troubleshooting

### Problem: System hangs at boot after a major kernel upgrade
**Instant Resolution**:
1. Unplug the cable from the USB4 port.
2. Plug it into a standard USB 3.2 port.
3. Power on and enter the boot menu.
4. The system will **instantly boot** in UASP USB 3.2 fallback mode (`/dev/sda`).
5. Once booted into the desktop, rerun:
   ```bash
   sudo bash setup_usb4_boot.sh --apply
   ```
6. Move the cable back to the USB4 port and resume native PCIe Gen 4 x4 operation!

---

## 7. Cross-Distribution Support Matrix

| Distribution | Default Initramfs | Supported | Notes |
| :--- | :--- | :---: | :--- |
| **Ubuntu 26.04+ LTS** | `dracut` | **Yes (Tested)** | Uses native `99usb4-rescan` dracut module |
| **Ubuntu 24.04 LTS** | `initramfs-tools` | **Yes** | Deploys `init-premount` hook & modules |
| **Fedora 40/41/42** | `dracut` | **Yes** | Fully native dracut architecture |
| **Debian 12 / 13** | `initramfs-tools` | **Yes** | Uses `update-initramfs` |
| **Arch Linux** | `mkinitcpio` | Manual | Add `thunderbolt nvme` to `/etc/mkinitcpio.conf` |
| **openSUSE Tumbleweed** | `dracut` | **Yes** | Fully native dracut architecture |
