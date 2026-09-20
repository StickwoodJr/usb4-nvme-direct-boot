# Ubuntu Launchpad Bug Report: Technical Analysis & Proposal

**Affected Package:** `linux (Ubuntu)`  
**Source Package:** `linux`  
**Binary Package:** `linux-image-7.0.0-31-generic` (Ubuntu 26.04 LTS Resolute / 24.04 HWE)  
**Upstream Subsystem:** `drivers/thunderbolt/` (Native Host Interface & Software Connection Manager)  
**Affected Hardware:** Intel Meteor Lake / Arrow Lake USB4 Host Interface `[8086:7ec2 / 8086:7ec4]`, AMD Hawk Point / Phoenix USB4 Host Interface `[1022:1502 / 1022:1669]`, ASMedia ASM2464PD, and external PCIe NVMe direct-boot topologies.  
**Related Bug Trackers:** 
- Launchpad Bug [LP #2078573](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2078573) (*"I can no longer boot from my Thunderbolt disk"*, Dell Latitude 5550)
- Launchpad Bug [LP #2159575](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2159575) (*Duplicate of LP #2078573*, ASUS Zenbook 14 UM3406HA, dracut)
- Launchpad Bug [LP #2167764](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167764)
- Upstream Commits: Mainline `59a54c5f3dbd` & `0fc70886569c` (Stable backport `cc4c94a5f6c4`)
- Related Issue: **CVE-2024-53194** (*Use-after-free of slot->bus in pciehp on hot remove*)

---

## 1. Summary of the Defect

When booting Linux directly from an external NVMe SSD over a USB4/Thunderbolt 4 PCIe Gen 4 x4 tunnel, motherboard UEFI firmware negotiates the link and builds the PCIe tunnel. GRUB2 executes and loads `vmlinuz` and `initrd.img` into host RAM across this tunnel.

However, during early kernel initialization inside the initramfs, `thunderbolt.ko` issues a Host Router Reset (`host_reset=true`). This drops the pre-boot PCIe tunnel mid-boot, causing `nvme_probe()` to encounter Master Abort (`0xFFFFFFFF`) and return terminal error `-ENODEV`. The root filesystem device is no longer enumerated on the bus during the initial scan, causing an initramfs timeout and emergency rescue shell drop:
```text
Gave up waiting for root file system device.
Common problems:
 - Boot args (cat /proc/cmdline)
 - Check rootdelay= (did the system wait long enough?)
 - Missing modules (cat /proc/modules; ls /dev)
ALERT! UUID=... does not exist. Dropping to a shell!
```
Under Ubuntu 26.04's `dracut` framework, the failure manifests similarly:
```text
Warning: /dev/disk/by-uuid/<UUID> does not exist.
Entering emergency mode. Exit the shell to continue.
```

---

## 2. Technical Sequence: The Teardown Behavior

Tracing `drivers/thunderbolt/nhi.c` and `drivers/thunderbolt/tb.c` details the sequence during early boot:

1. **`nhi_probe()` (`drivers/thunderbolt/nhi.c:1249`):**  
   Calls `nhi_reset(nhi)`. On USB4 v2 controllers (`REG_CAPS >= 0x40`), because module parameter `host_reset` defaults to `true`, it writes `REG_RESET_HRR` (`BIT 0`) to memory-mapped register `REG_RESET` (`0x39898`):
   ```c
   iowrite32(REG_RESET_HRR, nhi->iobase + REG_RESET);
   ```
   This asserts a hardware Host Router Reset. Register `ADP_PCIE_CS_0` bit `ADP_PCIE_CS_0_PE` (Path Enable, `BIT 31`) is cleared, tearing down the pre-boot PCIe tunnel. The PCIe Root Port register clears both `Presence Detect State` (`PDS`) and `Data Link Layer Link Active` (`DL_Active`).

2. **`tb_start()` (`drivers/thunderbolt/tb.c:3066-3070`):**  
   `nhi_probe()` invokes `tb_domain_add(tb, host_reset)`, which calls `tb_start(tb, reset = true)`.  
   `tb_start()` checks:
   ```c
   if (reset && tb_switch_is_usb4(tb->root_switch)) {
       discover = false;
       if (usb4_switch_version(tb->root_switch) == 1)
           tb_switch_reset(tb->root_switch);
   }
   ```
   Because `discover` is set to `false`, the kernel's built-in `tb_discover_tunnels()` and `tb_scan_switch()` are bypassed.

3. **Driver Probing Timing (`drivers/nvme/host/pci.c`):**  
   Concurrently, `nvme_probe()` attempts to enumerate the storage controller at the pre-boot ACPI address. Because the tunnel was dropped:
   ```text
   nvme 0000:06:00.0: Unable to change power state from D3cold to D0, device inaccessible
   nvme 0000:06:00.0: error -ENODEV: probe failed
   ```
   Under Linux driver core semantics, an endpoint that fails with `-ENODEV` is not automatically re-probed. Even when `thunderbolt.ko` re-enumerates the enclosure shortly afterward, the root filesystem UUID is not detected by `dracut`/`systemd` without a bus rescan.

---

## 3. Technical Analysis: Initramfs Userspace Authorization vs. In-Kernel Tunnel Preservation

In Launchpad Bug **LP #2078573**, an initial working hypothesis was considered where userspace tooling (such as `boltd` or udev rules inside the initramfs) might handle re-authorizing the device:
> *"What's going on is that it resets the topology, but the policy to re-authorize it doesn't happen because bolt is missing until the rootfs is loaded. So initramfs needs a hook to include: `/lib/udev/rules/90-bolt.rules`, `bolt.service`, `boltd`."*

However, subsequent testing from duplicate Bug **LP #2159575** (ASUS Zenbook 14 running Ubuntu 26.04 LTS Resolute on `dracut`) provides useful insights on why in-kernel tunnel preservation is more effective than userspace authorization:

### A. Testing on Modern Dracut (Ubuntu 26.04)
When testing on Ubuntu 26.04 with `dracut 110-11`, the same early boot timeout occurred out of the box, showing that initramfs framework updates alone do not automatically resolve the boot sequence.

### B. PCI Driver Core Probe Lifecycle and the Need for Bus Rescan
In the initramfs emergency shell of Bug LP #2159575, reporter Lucas observed the following behavior:
```sh
# 1. Authorizing the USB4 switch brings the link up:
echo 1 > /sys/bus/thunderbolt/devices/0-2/authorized

# 2. BUT the NVMe storage does not appear until an explicit bus rescan is triggered:
echo 1 > /sys/bus/pci/rescan
```

This occurs because `nvme_probe()` already returned `-ENODEV` during the kernel's initial bus walk when `host_reset` severed the link. Under standard Linux device driver core semantics, a device returning `-ENODEV` is not automatically re-probed.

Additionally, the upstream `bolt` project (`freedesktop.org/bolt`) focuses specifically on Thunderbolt domain management and `/sys/bus/thunderbolt/` authorization; it does not issue PCI bus rescans. Therefore, managing this purely in userspace requires coordinating early udev hooks, authorization daemons, and secondary PCI rescans during initramfs, whereas preserving the pre-boot tunnel in the kernel prevents the initial `-ENODEV` disconnect entirely.

### C. In-Tree Discovery Logic
`drivers/thunderbolt/tb.c` already contains native infrastructure for discovering and adopting pre-boot tunnels:
```c
/* In tb_discover_tunnels(): */
if (tb_tunnel_is_pci(tunnel)) {
    sw->boot = true;
    parent->boot = true;
}

/* In tb_scan_finalize_switch(): */
if (sw->boot) {
    sw->authorized = 1; /* Automatically authorized in-kernel */
}
```
When booted with `thunderbolt.host_reset=0`, `tb_start()` preserves `discover = true`. The kernel identifies the firmware-established tunnel, marks `sw->boot = true`, and authorizes the switch in-kernel without requiring external daemons.

---

## 4. Hardware Verification & Silicon Telemetry

Testing on physical hardware across both Intel and AMD architectures confirms that preserving pre-boot tunnels maintains link stability:

### Platform A: Intel Core Ultra 9 275HX (Arrow Lake-HX)
- **Host Interface:** Meteor Lake-P Thunderbolt 4 NHI `[8086:7ec2]`
- **Storage Enclosure:** ASMedia ASM2464PD (PCIe Gen 4 x4, Link Speed 16.0 GT/s, 64 Gbps link)
- **Drive:** WD_BLACK SN7100 2TB NVMe SSD
- **Kernel Command Line:** `thunderbolt.host_reset=0`
- **Telemetry:**
  ```text
  $ cat /sys/bus/thunderbolt/devices/0-1/boot
  1
  $ cat /sys/bus/thunderbolt/devices/0-1/authorized
  1
  ```
- **Observed Performance:**
  - Buffered Read: **3,587.60 MB/s**
  - Direct Write: **2,024.33 MB/s**
  - Host Memory Buffer (HMB): 64 MB host DDR5 RAM cleanly allocated via Intel VT-d IOMMU (WAF dropped from 6.80 to 1.88, significantly reducing NAND write wear).

### Platform B: AMD Hawk Point USB4 (ASUS Zenbook 14 UM3406HA, LP #2159575)
- **Host Interface:** AMD Hawk Point USB4 Host Router `[1022:1502]`
- **Observation:** Boot succeeds cleanly when pre-boot tunnel is preserved without link teardown.

### Platform C: Intel Core Ultra (Dell Latitude 5550, LP #2078573)
- **Host Interface:** Intel NHI
- **Observation:** Confirmed operational with `thunderbolt.host_reset=0`.

---

## 5. Related Upstream Observations & Impact

The reset behavior has also been discussed in related upstream contexts:
1. **PCIe Hotplug Synchronization (CVE-2024-53194):**  
   Clearing `Presence Detect State` and `DL_Active` asynchronously exposed a race condition in `pciehp` where `pci_slot` referenced a freed `pci_bus`. This was resolved upstream in mainline commit `20502f0b3f3a` by Bjorn Helgaas.
2. **Dock Controllers & eGPU Resources:**  
   Community discussions (Arch Linux, Fedora, eGPU.io) have noted that skipping host reset helps preserve pre-boot memory BAR allocations (such as Resizable BAR for external GPUs) and avoids controller resets on certain Thunderbolt docks.

---

## 6. Proposed Upstream Kernel Patch

To allow the driver to distinguish between hotpluggable accessories (which benefit from a clean reset for DisplayPort or MMIO reallocation) and active boot storage (which must not be severed), `drivers/thunderbolt/` can inspect whether an active pre-boot PCIe tunnel is present before issuing the reset.

If an active pre-boot tunnel is detected, the driver preserves `discover = true` and skips the reset, allowing `tb_discover_tunnels()` to adopt the device.

### Proposed Diff against Upstream Linux Mainline:
```diff
--- a/drivers/thunderbolt/nhi.c
+++ b/drivers/thunderbolt/nhi.c
@@ -1158,6 +1158,11 @@ static void nhi_reset(struct tb_nhi *nhi)
 		return;
 	}
 
+	if (nhi_has_active_boot_device(nhi)) {
+		dev_info(nhi->dev, "preserving pre-boot PCIe tunnel for active boot device\n");
+		return;
+	}
+
 	iowrite32(REG_RESET_HRR, nhi->iobase + REG_RESET);
 	msleep(100);
 }
--- a/drivers/thunderbolt/tb.c
+++ b/drivers/thunderbolt/tb.c
@@ -3059,6 +3077,11 @@ static int tb_start(struct tb *tb, bool reset)
 	tb_switch_tmu_enable(tb->root_switch);
 
+	if (tb_switch_has_active_pcie_tunnel(tb->root_switch)) {
+		tb_info(tb, "active PCIe boot tunnel detected, preserving topology\n");
+		reset = false;
+	}
+
 	if (reset && tb_switch_is_usb4(tb->root_switch)) {
 		discover = false;
 		if (usb4_switch_version(tb->root_switch) == 1)
```

The standalone patch and reference packaging are available at:  
[https://github.com/StickwoodJr/usb4-nvme-direct-boot](https://github.com/StickwoodJr/usb4-nvme-direct-boot)

---

## 7. Suggestions for the Ubuntu Kernel Team

1. **Re-evaluate Launchpad Bug #2078573 under `linux (Ubuntu)`:**  
   Consider re-opening the kernel task in light of the `-ENODEV` probe timing findings and dracut test results, which indicate that kernel-side tunnel preservation is more robust than userspace initramfs hooks.
2. **Consider In-Kernel Tunnel Preservation:**  
   Evaluate adopting conditional checks for active boot tunnels or documenting `thunderbolt.host_reset=0` as the recommended setting for external direct-boot environments.
3. **Documentation:**  
   Help provide guidance in Ubuntu release notes or documentation for users running external direct-boot NVMe configurations over USB4 / Thunderbolt.
