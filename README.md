# USB4 / Thunderbolt 4 NVMe Direct-Boot Workaround Suite for Linux
## Targeted Workaround & Kernel Forensics for Direct UEFI Booting over PCIe Gen 4 x4

[![CI Tests](https://github.com/StickwoodJr/usb4-nvme-direct-boot/actions/workflows/ci.yml/badge.svg)](https://github.com/StickwoodJr/usb4-nvme-direct-boot/actions)
[![Launchpad Bug](https://img.shields.io/badge/Launchpad-LP%232167764-orange)](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167764)
[![Protocol](https://img.shields.io/badge/Protocol-USB4%20%2F%20TB4%2040Gbps-blue)](#)
[![Status](https://img.shields.io/badge/Status-Lab%20Verified%20%2F%20Workaround-blue)](#)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)


> [!WARNING]
> **Experimental Workstation Tooling & System Scope:**
> This repository provides kernel command-line parameters (`thunderbolt.host_reset=0`, `pcie_port_pm=off`, `thunderbolt.clx=0`) and initial ramdisk drop-in configurations engineered to prevent pre-boot PCIe tunnel teardowns when direct-booting Linux from external NVMe SSDs.
> 
> Applying these configurations modifies system boot arguments. Disabling PCIe link power management (`pcie_port_pm=off`, `clx=0`) prevents low-power link retraining disconnects during boot, but can increase idle power draw on laptops and alter suspend/resume behavior on complex docking stations. Test thoroughly on your specific hardware. Reversible at any time with `./setup_usb4_boot.sh --rollback`.

---

## 📋 Hardware & Distribution Support Matrix

| Subsystem / Layer | Validated Hardware / Environment | Experimental / Untested | Unsupported / Out of Scope |
| :--- | :--- | :--- | :--- |
| **Host Processors** | Intel Core Ultra 9 275HX (Arrow Lake-HX), Meteor Lake-P | AMD Ryzen 6000/7000/8000 USB4, Intel Tiger/Alder Lake TB4 | Legacy USB 3.0 / USB 2.0 host ports |
| **USB4 / TB Bridges** | **ASMedia ASM2464PD** (40 Gbps, PCIe Gen 4 x4) | Intel Goshen Ridge (JHL8440), Titan Ridge (JHL7440) | Realtek RTL9210, JMicron JMS583 (USB 3.2 UASP only) |
| **Storage NVMe** | WD_BLACK SN7100 1TB (DRAM-less, HMB enabled) | Samsung 980/990 Pro, Crucial P3/T500, Kioxia Exceria | SATA M.2 SSDs (not PCIe tunneled) |
| **Linux Kernels** | Linux **6.8.0** through **7.0.x** (Ubuntu generic) | Linux 6.9 – 6.14 mainline / distribution kernels | Kernels < 6.8 (regression not present) |
| **Initramfs Engine**| **dracut** (Ubuntu 26.04, Fedora 39+, RHEL 9+) | **initramfs-tools** (Debian, Ubuntu 22.04/24.04 LTS) | **mkinitcpio** (Arch Linux), **rpm-ostree** (Silverblue) |
| **Bootloader** | **GRUB2** (`update-grub`, `grub-mkconfig`) | `systemd-boot` (requires manual cmdline entry) | Legacy BIOS / MBR booting |

---

## ⚡ Quick Start: 3-Step Setup

### Step 1: Pre-Flight Audit (Non-destructive)
Inspect your host, kernel version, and root partition without modifying any files:
```bash
git clone https://github.com/StickwoodJr/usb4-nvme-direct-boot.git
cd usb4-nvme-direct-boot
./setup_usb4_boot.sh --audit
```

### Step 2: Preview & Apply Configuration
Preview planned drop-ins and then apply:
```bash
# Preview actions (zero writes):
./setup_usb4_boot.sh --dry-run

# Apply configuration & rebuild initramfs (requires sudo):
sudo ./setup_usb4_boot.sh --apply
```

### Step 3: Cold Boot Procedure
1. Power off the system completely: `sudo poweroff`
2. Unplug the AC power adapter and external drive.
3. Hold the laptop power button down for **30 seconds** (discharges residual retimer capacitance).
4. Reconnect AC power and plug the drive into the **rear USB4 / Thunderbolt 4 port**.
5. Power on, tap **F12** (or your platform's boot menu key), and select the external NVMe.
6. Verify runtime status once booted into the desktop:
   ```bash
   ./setup_usb4_boot.sh --verify
   ```

---

## 🔄 First-Class Transactional Rollback

All modifications can be cleanly and completely reversed at any time. The installer saves a backup of your original initial ramdisk and records an atomic transaction manifest in `/var/lib/usb4-direct-boot/transaction.manifest`.

```bash
# Preview rollback actions:
./setup_usb4_boot.sh --rollback --dry-run

# Execute full reversal (restores pristine initrd & removes drop-ins):
sudo ./setup_usb4_boot.sh --rollback
```

---

## 🔬 Technical Root Cause: The Teardown Cascade

### The Upstream Defect (Linux 6.8+)
In upstream Linux 6.8+, commit [`59a54c5f3dbd`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=59a54c5f3dbd) established an unconditional default policy setting `host_reset = true` within `drivers/thunderbolt/nhi.c`.

Upstream maintainers intended this reset to clear inconsistent boot-firmware DisplayPort bandwidth allocations and reclaim exhausted AMD PCIe BAR space for docking stations. However, maintainers operated under the assumption that all USB4 devices are secondary, hotpluggable peripherals mounted after the operating system has already booted from internal storage.

### The Execution Failure
1. **UEFI POST:** The motherboard BIOS negotiates 40 Gbps and builds a PCIe Gen 4 x4 tunnel to the external NVMe SSD. GRUB loads the kernel and initial ramdisk across this tunnel.
2. **Driver Probe (`nhi_probe`):** `thunderbolt.ko` initializes and calls `nhi_reset()`. On USB4 v2 host routers, this writes `REG_RESET_HRR` (`BIT(0)`) to `REG_RESET` (`0x39898`), executing a hardware Host Router Reset.
3. **Tunnel Annihilation:** Register `ADP_PCIE_CS_0` bit `ADP_PCIE_CS_0_PE` (Path Enable) is cleared, physically severing the active PCIe tunnel.
4. **Discovery Suppression (`tb_start`):** In `tb_start()`, `reset == true` sets `discover = false`, skipping `tb_discover_tunnels()` entirely.
5. **Storage Deadlock (`nvme_probe`):** Concurrently, `nvme_probe()` attempts to access the device. Reads return Master Abort (`0xFFFFFFFF`), power transition `D3cold` to `D0` fails, and `nvme_probe()` aborts with terminal error `-ENODEV`. Linux driver core never re-probes endpoints that return `-ENODEV`, panicking the initial ramdisk (`ALERT! UUID=... does not exist`).

### Upstream Status & Bug Trackers
- **Launchpad Umbrella Tracker:** [Ubuntu Launchpad Bug LP #2167764](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167764).
- **Related Historical Trackers:** [LP #2078573](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2078573) (*Dell Latitude 5550*) and duplicate [LP #2159575](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2159575) (*ASUS Zenbook 14, dracut*).
- **Consolidated Defect Report:** Collaborative Launchpad defect submission draft in [`docs/UBUNTU_LAUNCHPAD_BUG_REPORT.md`](docs/UBUNTU_LAUNCHPAD_BUG_REPORT.md).
- **Related Security Issue:** [CVE-2024-53194](https://nvd.nist.gov/vuln/detail/CVE-2024-53194) (*PCIe hotplug use-after-free triggered by host router resets*).
- **Upstream LKML Proposal:** Formal patch modifying `drivers/thunderbolt/nhi.c` and `drivers/thunderbolt/tb.c` to preserve pre-boot PCIe tunnels for external boot storage is staged in [`patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch`](patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch).
- **Scope Clarification:** **This repository is a local workaround suite pending official upstream kernel changes.** It is not an officially accepted upstream kernel patch, nor a general Thunderbolt performance framework.

---

## ⚠️ Known Side Effects & System Scope

Disabling PCIe link power management and USB4 low-power lane states is an effective workaround to prevent link retraining drops, but it alters system-wide bus behavior. Review these documented side effects before deploying:

| Subsystem / Scenario | Observed / Potential Side Effect | Technical Impact & Measurement | Mitigation / Recommendation |
| :--- | :--- | :--- | :--- |
| **Battery Life / Idle Power** | `pcie_port_pm=off` prevents PCIe root ports from entering runtime `D3cold`. | Laptop idle power consumption increases by **~1.2W to 2.8W** while running on battery. | Use AC power for high-performance direct-boot workloads; revert via `--rollback` if running on battery long-term. |
| **Multi-Display Docks** | `thunderbolt.host_reset=0` preserves firmware tunnels instead of clearing them. | Complex daisy-chained docks (e.g. CalDigit TS4, Dell WD19TB/WD22TB4) may fail to negotiate full DisplayPort bandwidth (falling back to HBR2 instead of HBR3/DSC) if boot firmware allocated suboptimal tunnels. | Connect displays directly to laptop HDMI/DP or power-cycle the dock after boot. |
| **System Suspend / Resume** | `thunderbolt.clx=0` keeps high-speed lanes out of CL0s/CL1 low-power states. | On certain platforms, modern standby (`s2idle`) may experience higher drain or occasional PCIe hotplug wake latency. | Test system suspend (`systemctl suspend`) after initial deployment. |
| **Host Authorization (SL1/SL2)** | Machines with Thunderbolt Security Levels enabled in BIOS. | If user authorization is enforced by firmware, pre-boot tunnels are rejected unless the enclosure is enrolled in the host pre-boot ACL. | Boot via a standard USB 3.2 port (bypassing PCIe tunneling) on restricted corporate/institutional PCs. |

---


## 🛠️ CLI Reference & Utility Scripts

```bash
./setup_usb4_boot.sh [COMMAND] [OPTIONS]
```

| Command / Script | Function / Scope |
| :--- | :--- |
| `setup_usb4_boot.sh --audit` | Read-only pre-flight audit of kernel, host model, controller, and UUID. |
| `setup_usb4_boot.sh --dry-run` | Zero-mutation preview of files to be created and initramfs commands. |
| `setup_usb4_boot.sh --apply` | Installs drop-ins, creates transaction manifest, and rebuilds initrd. |
| `setup_usb4_boot.sh --rollback` | Completely reverses all configuration changes and restores backup initrd. |
| `setup_usb4_boot.sh --verify` | Runtime check of PCIe link speed (16.0 GT/s), width (x4), and HMB status. |
| `setup_usb4_boot.sh --health` | Audits SMART attributes, drive temperature, TBW endurance, and HMB state. |
| `packaging/build_deb.sh` | Builds standalone `.deb` package (`dist/usb4-nvme-direct-boot_1.0.0_all.deb`). |
| `scripts/apply_kernel_patch.sh` | Helper tool to validate/apply upstream LKML C patch to Linux trees. |
| `tests/run_all_tests.sh` | Master automated test suite (CLI flags, kernel patch validation, .deb build). |


---

### Standalone Debian/Ubuntu Package (`.deb`)

For systems requiring distribution package tracking instead of executing raw shell scripts:

```bash
# Build the package locally
./packaging/build_deb.sh

# Install via dpkg/apt
sudo dpkg -i dist/usb4-nvme-direct-boot_1.0.0_all.deb

# Once installed, management is available globally via:
sudo usb4-boot-config --audit
sudo usb4-boot-config --dry-run
sudo usb4-boot-config --apply
```

---

## 📁 Repository Directory Structure

```
usb4-nvme-direct-boot/
├── README.md                          # Documentation and support matrix
├── setup_usb4_boot.sh                 # Unified CLI management entrypoint
├── CONTRIBUTING.md                    # Guidelines for testing and submitting patches
├── LICENSE                            # MIT License
├── .gitignore                         # Git ignore rules
│
├── packaging/                         # Debian packaging scripts & metadata
│   ├── build_deb.sh                   # Automated .deb builder
│   └── debian/DEBIAN/control          # Package control metadata
│
├── scripts/                           # Core implementation scripts
│   ├── apply_usb4_direct_boot_fix.sh  # Transaction-aware installer (dracut & initramfs-tools)
│   ├── rollback_usb4_fix.sh           # Atomic rollback script restoring pre-change state
│   ├── verify_usb4_environment.sh     # Hardware link speed, width, and parameter verification
│   ├── verify_initrd_contents.sh      # Initial ramdisk driver manifest validator
│   └── nvme_health_audit.sh           # SMART health, TBW, and HMB telemetry reader
│
├── tests/                             # Automated test suite
│   ├── run_all_tests.sh               # Master test runner
│   ├── test_cli.sh                    # CLI argument and flag verification harness
│   ├── test_patch_validation.sh       # Linux kernel patch structure and diff validator
│   └── test_deb_packaging.sh          # Debian package builder & payload test
│
├── patches/                           # Upstream Linux kernel proposals
│   └── 0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch # Production C patch for drivers/thunderbolt/
│
└── docs/                              # Detailed engineering documentation
    ├── EXECUTIVE_SUMMARY.md           # 2-minute overview: what goes wrong, what we change, side effects
    ├── FORENSIC_KERNEL_INVESTIGATION_REPORT.md # In-depth forensic whitepaper & LKML submission
    ├── FRESH_INSTALL_PLAYBOOK.md      # Installation guide for new distributions
    ├── HARDWARE_ARCHITECTURE.md       # Technical notes on USB4 tunneling, retimers, and HMB
    └── TROUBLESHOOTING.md             # Common failure modes, recovery steps, and BIOS retimer physics
```

---

## ⚖️ License & Disclaimers

Distributed under the [MIT License](LICENSE).

This project is an independent open-source engineering investigation and workaround suite. It is not officially affiliated with Canonical Ltd., Intel Corporation, AMD, Western Digital, or ASMedia Technology Inc.
