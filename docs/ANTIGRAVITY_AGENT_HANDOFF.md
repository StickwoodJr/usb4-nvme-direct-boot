# Antigravity Agent Handoff: System Verification & Stress-Testing Suite
## Direct-Boot External USB4 NVMe Workstation (Ubuntu 26.04.1 LTS / Linux 7.0)

**Target System:** Alienware 16X Aurora (Arrow Lake-HX Core Ultra 9 275HX)  
**External Storage:** WD_BLACK SN7100 1TB NVMe in UGREEN ASMedia ASM2464PD Enclosure  
**Connection Mode:** Rear USB4 / Thunderbolt 4 Port (PCIe Gen 4 x4, 40 Gbps PAM2)  
**Upstream Kernel Reference:** [lore.kernel.org/linux-usb Thread](https://lore.kernel.org/linux-usb/BN8PR19MB275472A84381924206F01AE0FD882@BN8PR19MB2754.namprd19.prod.outlook.com/T/#u) | [Launchpad LP #2167764](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167764)  
**Primary Repositories:**
- Workspace Repository: `https://github.com/StickwoodJr/alienware-usb4-nvme-direct-boot.git`
- Upstream Packaging Repo: `https://github.com/StickwoodJr/usb4-nvme-direct-boot.git`

---

## 🛑 MANDATORY RULES OF ENGAGEMENT (STRICT SAFETY)

1. **INTERNAL DRIVE SAFETY DIRECTIVE:**
   - The host laptop contains an internal **Micron 2500 1TB NVMe SSD** hosting Windows 11 with BitLocker encryption behind Intel VMD (`/dev/nvme0n1` or masked PCIe volume).
   - **UNDER NO CIRCUMSTANCES** should you write, format, partition, mount, or execute destructive commands against the internal drive or VMD controllers.
   - All tests and file operations **MUST ONLY TARGET** the external root drive (`/dev/nvme*` or `/dev/sd*` hosting `/`) and user home directory.

2. **PURE FUNCTION, ZERO BLOAT:**
   - Do NOT install background daemons, telemetry agents, or superfluous system services.
   - All tools and tests are self-terminating, deterministic scripts.

3. **INDEPENDENT VERIFICATION:**
   - Do not assume previous reports are accurate. Verify every sysfs register, link state, PCIe speed, HMB status, and temperature directly from hardware.

---

## ⚡ QUICK-START PROMPT FOR ANTIGRAVITY AGENT

> **Agent Instruction:**  
> Paste the block below into your Antigravity chat on the external NVMe system:

```text
You are an expert Linux Kernel, Storage, and Virtualization Systems Engineer.
We are validating the direct-boot external USB4 NVMe workstation pipeline on this physical machine.

Review the mission requirements in ANTIGRAVITY_AGENT_HANDOFF.md.
Clone https://github.com/StickwoodJr/alienware-usb4-nvme-direct-boot.git and https://github.com/StickwoodJr/usb4-nvme-direct-boot.git if not already present.

Execute the following 5-phase testing battery:
1. Environment & Link Audit (verify PCIe Gen 4 x4, 40 Gbps, 64MB HMB via verify_usb4_environment.sh).
2. Thermal & SMART Health Baseline (nvme_health_audit.sh).
3. 6-VM Virtualization Stress Benchmark (benchmark_6vms.sh --stress for 300s, extract P50/P99/P99.9/P99.99 latencies, verify zero AER errors, zero IOMMU faults, zero NVMe timeouts).
4. Debian Packaging & Dracut Module Audit (verify 99usb4-boot dracut module and usb4-boot-config CLI).
5. Kernel Update & GRUB Persistence Check (dry update-initramfs -u and update-grub).

Follow all strict safety rules: NEVER touch the internal Windows BitLocker drive. Provide a complete markdown executive summary with exact benchmark numbers upon completion.
```

---

## 📋 STEP-BY-STEP TESTING BATTERY

### Phase 1: Environment & Physical Link Audit

Verify that the system is operating in native USB4 PCIe Gen 4 x4 mode rather than fallback USB 3.2 UASP mode:

```bash
cd ~/alienware-usb4-nvme-direct-boot || git clone https://github.com/StickwoodJr/alienware-usb4-nvme-direct-boot.git ~/alienware-usb4-nvme-direct-boot
cd ~/alienware-usb4-nvme-direct-boot

# Run pre-flight verification
bash verify_usb4_environment.sh
```

**Pass Criteria:**
- Block device is `/dev/nvme*n*` (NOT `/dev/sd*`).
- PCIe Link Speed reports **16.0 GT/s**, Width **x4**.
- Host Memory Buffer (HMB): **Feature 0x0d reports enabled (64 MB allocated)**.
- Kernel cmdline contains: `thunderbolt.host_reset=0`, `thunderbolt.clx=0`, `pcie_aspm=off`.
- Maximum Payload Size (MPS) is clamped to **128B** (hardware limit); MRRS is **512B**.

---

### Phase 2: Thermal & SMART Health Baseline

Record controller thermals and endurance before sustained load:

```bash
bash nvme_health_audit.sh
```

**Telemetry to Capture:**
- Controller Temperature ($< 70^\circ\text{C}$ safe threshold).
- Available Spare ($100\%$).
- Percentage Used & Data Units Written (TBW).
- Critical Warnings ($0x00$).

---

### Phase 3: Seneca College OPS345 6-VM Stress Benchmark

Simulate 6 concurrent production VMs (DNS, DHCP, Web, DB, Mail, Storage) saturating the NVMe drive for 300 seconds (60 GB total footprint):

```bash
# Run the sustained 300-second stress benchmark
bash benchmark_6vms.sh --stress
```

**Metrics to Collect & Evaluate:**
1. **Per-VM Throughput:** Read IOPS, Read MB/s, Write IOPS, Write MB/s.
2. **Percentile Latencies (µs):** P50, P99, **P99.9**, and **P99.99**.
3. **Aggregate Throughput:** Total combined IOPS and Total Bandwidth (MB/s).
4. **Post-Run Forensic Link Audit (Automated):**
   - Must confirm **zero** PCIe Advanced Error Reporting (`AER`) errors.
   - Must confirm **zero** Intel VT-d IOMMU page faults (`DMAR: fault`).
   - Must confirm **zero** NVMe driver timeouts (`nvme_timeout`) or controller resets (`CSTS=0xffffffff`).
   - Must confirm physical link remained locked in **`L0`** without `DL_Active` drops.

---

### Phase 4: Debian Packaging & Dracut Module Verification

Test the standalone packaging and dracut integration from `usb4-nvme-direct-boot`:

```bash
cd ~/usb4-nvme-direct-boot || git clone https://github.com/StickwoodJr/usb4-nvme-direct-boot.git ~/usb4-nvme-direct-boot
cd ~/usb4-nvme-direct-boot

# 1. Run full test suite (CLI tests, patch integrity, package structure)
bash tests/run_all_tests.sh

# 2. Test dracut module structure
ls -la modules.d/99usb4-boot/
# Verify module-setup.sh, 80-usb4-storage.rules, usb4-storage-authorizer, usb4-pre-trigger.sh are present and executable.

# 3. Test CLI non-destructive dry-run
./setup_usb4_boot.sh --dry-run
./setup_usb4_boot.sh --audit
```

**Pass Criteria:**
- All 9 CLI automated tests pass.
- Kernel patch structure verified (`patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch`).
- Debian package `dist/usb4-nvme-direct-boot_1.0.0_all.deb` validates cleanly with `dpkg-deb`.

---

### Phase 5: Kernel Update & GRUB Persistence Check

Verify that routine distribution updates (`apt upgrade`) will not wipe out the USB4 direct-boot configuration:

```bash
# Check that drop-in files exist
cat /etc/default/grub.d/99-usb4-transport.cfg 2>/dev/null || true
cat /etc/initramfs-tools/conf.d/usb4-rootdelay.conf 2>/dev/null || true

# Test dry regeneration
sudo update-initramfs -u
sudo update-grub

# Re-run environment verification to confirm parameters remained intact
cd ~/alienware-usb4-nvme-direct-boot
bash verify_usb4_environment.sh
```

**Pass Criteria:**
- `update-initramfs` and `update-grub` complete with return code `0`.
- `verify_usb4_environment.sh` reports `[PASS]` on all configuration checks.

---

## 📊 FINAL DELIVERABLE: REPORT TEMPLATE

Upon completing the 5 phases, format your report using the following structure:

```markdown
# USB4 Direct-Boot Workstation Verification Report

- **Date:** YYYY-MM-DD HH:MM:SS
- **Host Hardware:** Intel Core Ultra 9 275HX (Arrow Lake-HX)
- **Kernel Version:** $(uname -r)
- **Storage Device:** WD_BLACK SN7100 1TB (Firmware: 631110WD)
- **Active Bridge:** ASMedia ASM2464PD (NVM Firmware: $(cat /sys/bus/thunderbolt/devices/0-1/nvm_version 2>/dev/null || echo "N/A"))

## 1. Physical Link & HMB Status
- Connection Mode: [Native USB4 NVMe / USB 3.2 UASP]
- Link Speed / Width: [e.g. 16.0 GT/s x4]
- Host Memory Buffer (HMB): [Enabled / Disabled] (Allocated: XX MiB)
- MPS / MRRS Framing: [e.g. MPS 128B / MRRS 512B]

## 2. Thermal & SMART Endurance Baseline
- Controller Temperature: XX °C
- NAND Temperature: XX °C
- Available Spare: XX %
- Total Data Written: XX TBW

## 3. OPS345 6-VM Sustained Stress Benchmark (300s)
| VM Role | Read IOPS | Read MB/s | Write IOPS | Write MB/s | p50 (µs) | p99 (µs) | p99.9 (µs) | p99.99 (µs) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| DNS | ... | ... | ... | ... | ... | ... | ... | ... |
| DHCP | ... | ... | ... | ... | ... | ... | ... | ... |
| Web | ... | ... | ... | ... | ... | ... | ... | ... |
| DB | ... | ... | ... | ... | ... | ... | ... | ... |
| Mail | ... | ... | ... | ... | ... | ... | ... | ... |
| Storage | ... | ... | ... | ... | ... | ... | ... | ... |
| **AGGREGATE** | ... | ... | ... | ... | Total Bandwidth: XXXX MB/s | Total IOPS: XXXXX |

### Forensic Link Check:
- PCIe AER Errors: [0 Detected - PASS / Detected - FAIL]
- Intel VT-d DMAR Faults: [0 Detected - PASS / Detected - FAIL]
- NVMe Controller Timeouts: [0 Detected - PASS / Detected - FAIL]

## 4. Package & Persistence Audit
- Debian Package Integrity: [PASS / FAIL]
- Dracut 99usb4-boot Module: [PASS / FAIL]
- update-initramfs / update-grub Persistence: [PASS / FAIL]

## 5. Certification & Recommendation
[Statement confirming whether the system is 100% production-ready for Seneca College OPS345 multi-VM virtualization.]
```
