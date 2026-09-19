# USB4 / Thunderbolt 4 NVMe Direct-Boot Suite for Linux
## Direct UEFI Booting over PCIe Gen 4 x4 with Host Memory Buffer Support

[![Status](https://img.shields.io/badge/Status-Verified-brightgreen)](#)
[![Launchpad Bug](https://img.shields.io/badge/Launchpad-LP%232167764-orange)](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167764)
[![Protocol](https://img.shields.io/badge/Protocol-USB4%20%2F%20TB4%2040Gbps-blue)](#)
[![Read Speed](https://img.shields.io/badge/Read%20Speed-3%2C588%20MB%2Fs-informational)](#)
[![Write Speed](https://img.shields.io/badge/Write%20Speed-2%2C024%20MB%2Fs-informational)](#)
[![HMB](https://img.shields.io/badge/Host%20Memory%20Buffer-64%20MB%20Active-brightgreen)](#)
[![License](https://img.shields.io/badge/License-MIT-green)](#)

A set of scripts and configuration drop-ins for enabling direct UEFI booting of external NVMe SSDs over **USB4 / Thunderbolt 4 (PCIe Gen 4 x4)** on Linux distributions using dracut or initramfs-tools.

---

## Benchmarks & Overview

Empirical test results on bare-metal hardware (WD_BLACK SN7100 in an ASMedia ASM2464PD enclosure):

* **Storage Interface:** Native PCIe Gen 4 x4 NVMe (`/dev/nvme0n1`).
* **Bus Bandwidth:** 16.0 GT/s across 4 PCIe lanes (~64 Gbps physical link).
* **Buffered Disk Read:** **3,587.60 MB/s** (measured via `hdparm -Tt /dev/nvme0n1`).
* **Direct Sequential Write:** **1,900 to 2,024 MB/s** (measured via `dd oflag=direct`).
* **Host Memory Buffer (HMB):** Active (64 MB Host RAM allocated via IOMMU / VT-d).
  * Measured Write Amplification Factor (WAF) reduction from 6.80 to 1.88 under sustained write workloads.
* **Host Drive Isolation:** Operations target only the active external root filesystem; internal disks are not modified.

---

## Technical Context: Upstream Kernel Probe Behavior

### Root Cause of Boot Hangs
In upstream Linux 6.8+ (commit `59a54c5f3dbd`), the `thunderbolt` kernel module sets `host_reset = true` by default (`MODULE_PARM_DESC(host_reset, "reset USB4 host router (default: true)")`).

Upstream developers introduced this reset to:
* Clear inconsistent or buggy register states left by motherboard UEFI implementations.
* Emulate Windows (`usb4host.sys`) initialization behavior for driver parity.
* Prevent DMA ring deadlocks and race conditions during hotplug events with high-bandwidth docks.

**The Architectural Conflict:**
This design relies on the assumption that all USB4 devices are secondary, hotpluggable peripherals mounted after the operating system has already booted from internal storage.

When booting Linux directly from an external NVMe drive over USB4:
1. Motherboard UEFI BIOS negotiates the physical link and creates a pre-boot PCIe tunnel.
2. GRUB loads the kernel and initial ramdisk into memory across this tunnel.
3. During driver probe, `thunderbolt.ko` executes `nhi_reset()`.
4. The reset tears down the pre-boot tunnel, disconnecting the boot drive mid-boot (`-ENODEV`).
5. The initial ramdisk waits for the root partition before timing out into an emergency shell.

### Mitigation:
1. **Preserve Pre-Boot Tunnel:** Pass `thunderbolt.host_reset=0` on the kernel command line to prevent `nhi_reset()` from executing on probe.
2. **Prevent Link Power State Drops:** Pass `thunderbolt.clx=0` and `pcie_port_pm=off` to avoid low-power link retraining disconnects.
3. **Early Bus Rescan:** Deploy an early initial ramdisk hook to ensure Thunderbolt devices are authorized and trigger `/sys/bus/pci/rescan` prior to udev settlement.

### Bug Tracking & Upstream References:
* **Forensic Investigation Whitepaper:** [`docs/FORENSIC_KERNEL_INVESTIGATION_REPORT.md`](docs/FORENSIC_KERNEL_INVESTIGATION_REPORT.md)
* **Hardware Architecture Dossier:** [`docs/HARDWARE_ARCHITECTURE.md`](docs/HARDWARE_ARCHITECTURE.md)
* **Ubuntu Launchpad Bug Report:** [LP#2167764 — thunderbolt.host_reset=1 default tears down pre-boot UEFI PCIe tunnels](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167764)
* **Affected Kernel Module:** `thunderbolt` (`drivers/thunderbolt/nhi.c`)
* **Upstream Regression Commit:** [`59a54c5f3dbd`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=59a54c5f3dbd)

---

## Installation Procedure

When installing or reinstalling Linux onto the external drive:

### 1. Initial Installation via Standard USB Port
Connect the drive to a standard USB 3.2 port (e.g. side USB-C or USB-A port) during the initial OS installation. In USB 3.2 mode (`/dev/sda`), the drive operates as standard UASP storage without requiring PCIe tunneling. Complete the distribution installation and boot into the desktop.

### 2. Apply Direct-Boot Configuration
Open a terminal in the new Linux installation:
```bash
git clone https://github.com/StickwoodJr/usb4-nvme-direct-boot.git
cd usb4-nvme-direct-boot
sudo bash setup_usb4_boot.sh --apply
```
The installer:
- Resolves the root partition UUID via `findmnt` / `blkid`.
- Detects the active initramfs generator (`dracut` or `initramfs-tools`).
- Deploys kernel command-line flags to `/etc/default/grub.d/99-usb4-transport.cfg`.
- Installs early PCIe rescan hooks.
- Configures ASMedia ASM2464PD TRIM clamping (64MB discard limit) to prevent UASP SCSI timeouts.
- Rebuilds the initial ramdisk for the running kernel.

### 3. Clear Controller State & Boot via USB4 Port
1. Shut down the system (`sudo poweroff`).
2. Disconnect the AC adapter and the SSD cable.
3. Hold the power button down for 30 seconds (discharges residual capacitance in the retimer and bridge controller).
4. Reconnect the AC power adapter.
5. Plug the drive into the designated USB4 / Thunderbolt 4 port.
6. Power on, open the UEFI boot menu (e.g. `F12`), and select the external drive.

---

## Repository Structure

```
usb4-nvme-direct-boot/
├── README.md                          # Documentation and setup instructions
├── setup_usb4_boot.sh                 # Entrypoint script
├── LICENSE                            # MIT License
├── .gitignore                         # Git ignore rules
│
├── scripts/                           # Tooling
│   ├── apply_usb4_direct_boot_fix.sh  # Dynamic installer (dracut & initramfs-tools)
│   ├── verify_usb4_environment.sh     # Hardware, link speed, and kernel parameter check
│   ├── verify_initrd_contents.sh      # Initrd manifest inspection utility
│   ├── rollback_usb4_fix.sh           # Rollback script restoring pre-change state
│   └── nvme_health_audit.sh           # SMART health, TBW, and HMB telemetry reader
│
├── patches/                           # Upstream Linux kernel patches
│   └── 0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch # Upstream C patch for drivers/thunderbolt/
│
└── docs/                              # Technical documentation
    ├── FORENSIC_KERNEL_INVESTIGATION_REPORT.md # Root-cause whitepaper & LKML submission
    ├── FRESH_INSTALL_PLAYBOOK.md      # Installation guide for new distributions
    ├── HARDWARE_ARCHITECTURE.md       # Technical notes on USB4 tunneling and HMB
    └── TROUBLESHOOTING.md             # Failure modes, recovery steps, and fallback behavior
```

---

## Verification Tools

### Pre-Flight Verification
Check kernel boot arguments, link negotiation (speed/width), framing (MPS/MRRS), and HMB status:
```bash
bash scripts/verify_usb4_environment.sh
```

### Drive Endurance & Telemetry
Inspect SMART attributes, temperature sensors, write endurance, and HMB state:
```bash
sudo bash scripts/nvme_health_audit.sh
# JSON format:
sudo bash scripts/nvme_health_audit.sh --json
```

### Initrd Manifest Verification
Confirm that required modules and rescan hooks are packed into the active initramfs:
```bash
sudo bash scripts/verify_initrd_contents.sh
```

---

## Compatibility & System Safeguards

1. **Internal Storage Unmodified:** Scripts only deploy configuration files (`/etc` and `/boot`) on the active root filesystem. No partition table or filesystem creation commands are used.
2. **Kernel Updates:** Drop-ins in `/etc/default/grub.d/` and `/etc/dracut.conf.d/` remain active across distribution kernel package upgrades.
3. **Fallback Availability:** If the USB4 connection is unavailable, connecting the drive to any standard USB port boots via UASP fallback mode (`/dev/sda`).
4. **Multi-PC Portability:** Root filesystem mounting uses partition UUIDs, allowing the drive to boot on systems with or without USB4 support.

---

## License

Distributed under the [MIT License](LICENSE).
