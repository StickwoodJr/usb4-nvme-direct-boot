# Contributing to USB4 NVMe Direct-Boot Suite

Thank you for your interest in improving direct-boot support for external NVMe SSDs over USB4 and Thunderbolt!

This project bridges empirical testing on physical hardware with upstream kernel patch proposals for `drivers/thunderbolt/`. We welcome contributions from systems engineers, kernel hackers, hardware enthusiasts, and distribution packagers.

---

## 🧭 Ways to Contribute

1. **Hardware Matrix Submissions:** Test new host platforms (AMD USB4, older Intel Titan Ridge / Alpine Ridge, Apple Silicon running Asahi) or enclosures (Intel JHL7440, JHL8440, Realtek) and submit your findings.
2. **Distribution Compatibility:** Add support for other initramfs engines (e.g. Arch `mkinitcpio`, openSUSE `dracut`, alpine `mkinitfs`).
3. **Upstream Patch Review:** Review, test, and provide feedback on [`patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch`](patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch).
4. **Documentation & Troubleshooting:** Improve explanations of motherboard BIOS quirks, fastboot behavior, and cable signal integrity.

---

## 📋 Hardware Test Submissions

When reporting test results for a new hardware combination, please include:
- **Host System:** Brand, Model, Processor (e.g. `Intel Core Ultra 9 275HX` or `AMD Ryzen 7 7840HS`).
- **Enclosure Bridge:** Controller model (e.g. `ASMedia ASM2464PD`, `Intel JHL7440`) and firmware revision if known.
- **NVMe SSD:** Drive model, capacity, and DRAM architecture (DRAM vs DRAM-less HMB).
- **OS & Kernel:** Distribution release and `uname -r`.
- **Output of verify script:** Attach output from `./setup_usb4_boot.sh --verify`.

---

## 💻 Scripting & Code Quality Standards

Before submitting a pull request modifying any scripts:
1. **ShellCheck Compliance:** All scripts must pass ShellCheck without warnings:
   ```bash
   shellcheck setup_usb4_boot.sh
   shellcheck scripts/*.sh
   shellcheck tests/*.sh
   ```
2. **Run the Automated Test Suite:**
   ```bash
   bash tests/run_all_tests.sh
   ```
3. **Preserve Idempotency & Safety:**
   - Any script modifying system state must support `--dry-run`.
   - Never write to or format block devices or partitions.
   - Drop-in files must be cleanly removable via `./setup_usb4_boot.sh --rollback`.

---

## 🐧 Upstream Kernel Patch Contributions

For changes directly affecting the proposed Linux kernel patch in `patches/`:
- Ensure compliance with the [Linux Kernel Patch Submission Guidelines](https://www.kernel.org/doc/html/latest/process/submitting-patches.html).
- Keep changes scoped to `drivers/thunderbolt/`.
- Validate syntax using `bash tests/test_patch_validation.sh`.
- Include standard sign-off tags (`Signed-off-by:`).

---

## 📜 Code of Conduct

We are committed to providing a friendly, safe, and welcoming environment for everyone, regardless of experience level, background, or identity. Please maintain an objective, respectful, and collaborative engineering dialogue.
