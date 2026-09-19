# Linux Fresh Installation Guide
## Setup Procedure for External NVMe Drives over USB4 / Thunderbolt 4

---

## 1. Overview

When installing Linux (Ubuntu, Fedora, Debian, etc.) onto an external NVMe drive connected via a USB4 / Thunderbolt 4 bridge (such as the ASMedia ASM2464PD):

1. **New Partition UUID**: Reformatting the drive generates a new filesystem UUID for the root partition.
2. **Upstream Kernel Parameter (`thunderbolt.host_reset=1`)**: In Linux kernels >= 6.8, `thunderbolt.ko` defaults to resetting the host controller on probe, which disconnects the pre-boot PCIe tunnel created by UEFI firmware.
3. **Initramfs Configuration**: Standard distribution initramfs images do not always force early module loading or issue early bus rescans for tunneled PCIe storage.

This guide provides the installation and configuration steps to enable direct booting over the high-speed interface.

---

## 2. Recommended Approach: Initial Installation via Standard USB Port

> [!NOTE]
> It is recommended to perform the initial distribution installation while connected to a standard USB 3.2 port (or using a USB-A adapter).

### Rationale:
Dual-mode bridge controllers (like the ASMedia ASM2464PD) operate as follows:
- **USB4 Port**: Negotiates PCIe Gen 4 x4 tunneling through the host controller.
- **USB 3.2 Port**: Operates as standard USB Attached SCSI Protocol (UASP) storage (`/dev/sda`).

Installing through a USB 3.2 port allows the distribution installer to run against a standard mass storage device without relying on PCIe tunneling during partitioning and initial kernel setup. Once the initial boot succeeds, the configuration script can be applied before switching to the USB4 port.

---

## 3. Installation Steps

```
+-----------------------------------------------------------------------------------+
|  STEP 1: INITIAL INSTALL VIA USB 3.2 PORT                                         |
|    - Connect drive to standard USB port                                           |
|    - Install Linux distribution normally                                         |
|    - Complete first boot into desktop                                             |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|  STEP 2: RUN CONFIGURATION SCRIPT                                                 |
|    - Clone repository                                                             |
|    - sudo bash setup_usb4_boot.sh --apply                                         |
|    - Script configures GRUB flags, rescan hooks, and rebuilds initrd              |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|  STEP 3: RESET CONTROLLER PHY & BOOT USB4                                         |
|    - Power off system                                                             |
|    - 30-second power drain to clear retimer state                                 |
|    - Connect to USB4 port and select drive in UEFI boot menu                      |
+-----------------------------------------+-----------------------------------------+
```

### Step 1: Install Distribution (Standard USB Port)
1. Insert the installation media (Live USB) into the system.
2. Connect the external NVMe drive to a standard USB 3.2 port.
3. Boot into the installer from the UEFI boot menu.
4. Select the external drive as the installation target:
   - EFI System Partition: `512 MB - 1024 MB` (FAT32, mounted at `/boot/efi`)
   - Root Partition: Remainder of drive (ext4, mounted at `/`)
   > [!CAUTION]
   > Verify the selected target drive carefully to avoid modifying internal storage.
5. Complete installation and reboot into the installed system.

---

### Step 2: Apply USB4 Direct-Boot Configuration
Open a terminal in the newly installed system:

```bash
# 1. Clone repository
git clone https://github.com/StickwoodJr/usb4-nvme-direct-boot.git
cd usb4-nvme-direct-boot

# 2. Optional: run read-only audit
bash setup_usb4_boot.sh --audit

# 3. Apply boot configurations and rebuild initrd
sudo bash setup_usb4_boot.sh --apply
```

#### Automated Actions:
1. **UUID Detection**: Detects the root partition UUID via `findmnt` / `blkid`.
2. **Framework Detection**: Identifies whether the system uses `dracut` or `initramfs-tools`.
3. **GRUB Configuration**: Deploys `/etc/default/grub.d/99-usb4-transport.cfg` with:
   ```text
   thunderbolt.host_reset=0 thunderbolt.clx=0 pcie_port_pm=off rootdelay=60
   ```
   and updates the bootloader configuration.
4. **Modprobe Configuration**: Writes `/etc/modprobe.d/thunderbolt.conf` (`options thunderbolt host_reset=0 clx=0`).
5. **TRIM / UNMAP Rule**: Installs `/etc/udev/rules.d/10-asm2464pd-trim.rules` to clamp UASP discard requests to 64MB.
6. **Rescan Hooks**: Deploys early-boot hooks to authorize devices and rescan the PCIe bus before udev settlement.
7. **Initrd Rebuild**: Creates a backup of the current initrd and rebuilds the image with the new configuration.

---

### Step 3: Controller State Reset & USB4 Boot

Switching the bridge controller from USB 3.2 PHY mode to USB4 PCIe mode requires clearing retained controller state:

1. Shut down the system:
   ```bash
   sudo poweroff
   ```
2. Unplug the AC power adapter (if using a laptop) and disconnect the external drive.
3. Hold the power button down for 30 seconds to drain flea power and clear retimer registers.
4. Reconnect the AC power adapter.
5. Connect the drive to the **USB4 / Thunderbolt 4 port**.
6. Power on, open the UEFI boot menu, and select the external NVMe drive.

---

## 4. Verification

After booting via the USB4 port:

```bash
# Verify link speed and kernel parameters
bash scripts/verify_usb4_environment.sh
```

### Expected Output:
- **Storage Interface**: `Native PCIe Gen 4 x4 over USB4 (/dev/nvme0)`
- **PCIe Link Speed**: `16 GT/s (PCIe 4.0) x4 lanes`
- **Host Memory Buffer (HMB)**: `ACTIVE`
- **Kernel Parameters**: `thunderbolt.host_reset=0`, `thunderbolt.clx=0`, `pcie_port_pm=off`

---

## 5. Alternative: Chroot Configuration from Live USB

To apply the configuration prior to the first reboot from a Live environment:

```bash
# Mount target root and EFI partitions (adjust device names as needed)
sudo mount /dev/nvme0n1p2 /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
for i in /dev /dev/pts /proc /sys /run; do sudo mount -B $i /mnt$i; done

# Chroot into the target installation
sudo chroot /mnt

# Clone and run installer
git clone https://github.com/StickwoodJr/usb4-nvme-direct-boot.git
cd usb4-nvme-direct-boot
sudo bash setup_usb4_boot.sh --apply

# Exit and unmount
exit
sudo umount -R /mnt
sudo poweroff
```

---

## 6. Recovery & Troubleshooting

### If system hangs at boot after a kernel update:
1. Disconnect the drive from the USB4 port.
2. Connect to a standard USB 3.2 port.
3. Power on and select the drive from the boot menu.
4. The system will boot using UASP mode (`/dev/sda`).
5. Run the configuration script to update the initrd for the new kernel:
   ```bash
   sudo bash setup_usb4_boot.sh --apply
   ```
6. Reconnect to the USB4 port and boot normally.

---

## 7. Distribution Support Matrix

| Distribution | Default Initramfs | Supported | Notes |
| :--- | :--- | :---: | :--- |
| **Ubuntu 26.04+ LTS** | `dracut` | Yes | Uses native `99usb4-rescan` dracut module |
| **Ubuntu 24.04 LTS** | `initramfs-tools` | Yes | Deploys `init-premount` hook & modules |
| **Fedora 40/41/42** | `dracut` | Yes | Native dracut module |
| **Debian 12 / 13** | `initramfs-tools` | Yes | Uses `update-initramfs` |
| **Arch Linux** | `mkinitcpio` | Manual | Add `thunderbolt nvme` to `/etc/mkinitcpio.conf` |
| **openSUSE Tumbleweed** | `dracut` | Yes | Native dracut module |
