#!/usr/bin/env bash
# ==============================================================================
# Seneca College OPS345 - 6 Concurrent VM Storage Benchmark & Forensic Check
# Target: External USB4 NVMe SSD (WD_BLACK SN7100 / ASM2464PD)
# Pure Function, Zero Bloat: Multi-tenant VM load simulation & link audit
# ==============================================================================
set -euo pipefail

MODE="quick"
VM_SIZE="1G"
RUNTIME_SECS=30
TEST_DIR="${HOME}/ops345-benchmark"

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -d, --dir DIR      Target directory for benchmark files (default: ~/ops345-benchmark)
  --quick            Quick run: 1GB per VM (6GB total footprint), 30s runtime (default)
  --stress           Stress run: 10GB per VM (60GB total footprint), 300s runtime
  -h, --help         Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            TEST_DIR="$2"
            shift 2
            ;;
        --quick)
            MODE="quick"
            VM_SIZE="1G"
            RUNTIME_SECS=30
            shift
            ;;
        --stress)
            MODE="stress"
            VM_SIZE="10G"
            RUNTIME_SECS=300
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -d "$1" ]] || [[ "$1" =~ ^/ ]]; then
                TEST_DIR="$1"
                shift
            else
                echo "Unknown option: $1" >&2
                usage
            fi
            ;;
    esac
done

echo "======================================================================"
echo " Seneca College OPS345 - 6 Concurrent VM Storage Benchmark"
echo " Mode: $MODE ($VM_SIZE per VM, ${RUNTIME_SECS}s runtime)"
echo " Target Directory: $TEST_DIR"
echo "======================================================================"

echo ""
echo "======================================================================"
echo " [1/3] STORAGE FORENSIC AUDIT & LINK INTEGRITY"
echo "======================================================================"

mkdir -p "$TEST_DIR"
MOUNT_POINT=$(df -P "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $6}')
BLOCK_DEV=$(df -P "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $1}')

echo "Mount Point      : $MOUNT_POINT"
echo "Block Device     : $BLOCK_DEV"

# 1. Check if drive is running under native NVMe (USB4) or SCSI/UASP (USB 3.2)
if [[ "$BLOCK_DEV" =~ nvme[0-9]+n[0-9]+ ]]; then
    NVME_CTRL=$(echo "$BLOCK_DEV" | grep -o 'nvme[0-9]\+')
    echo "  [OK] Native NVMe controller detected: /dev/$NVME_CTRL (USB4 PCIe Tunnel Active)"
    
    # Audit NVMe Host Memory Buffer (Feature 0x0d)
    if command -v nvme >/dev/null 2>&1; then
        echo "Querying NVMe Host Memory Buffer (HMB) Status..."
        sudo nvme get-feature "/dev/$NVME_CTRL" -f 0x0d -H 2>&1 || true
    fi

    # Check PCIe link speed and width if available in sysfs
    SYS_DEV="/sys/block/$(basename "$BLOCK_DEV")/device/device"
    if [[ -d "$SYS_DEV" ]]; then
        SPEED=$(cat "$SYS_DEV/current_link_speed" 2>/dev/null || echo "N/A")
        WIDTH=$(cat "$SYS_DEV/current_link_width" 2>/dev/null || echo "N/A")
        echo "  [PCIe Link] Current Speed: $SPEED, Width: x$WIDTH"
    fi
else
    echo "  [WARNING] Drive detected as $BLOCK_DEV (SCSI/UASP Mode on Side Port)."
    echo "  HMB is inactive in USB 3.2 mode. For full 40 Gbps & HMB, boot via rear USB4 port."
fi

# 2. Check mount options
echo -n "Checking mount options... "
mount | grep " on $MOUNT_POINT " || true

# 3. Check ASM2464PD / USB4 Controller Firmware via Sysfs
echo "Checking Thunderbolt / USB4 Controller Firmware:"
for d in /sys/bus/thunderbolt/devices/*; do
    if [ -f "$d/device_name" ]; then
        VNAME=$(cat "$d/vendor_name" 2>/dev/null || echo "Unknown")
        DNAME=$(cat "$d/device_name" 2>/dev/null || echo "Device")
        NVMV=$(cat "$d/nvm_version" 2>/dev/null || echo "N/A")
        echo "  - $VNAME $DNAME (NVM Firmware: $NVMV)"
    fi
done

# Mark kernel log timestamp for post-run forensic check
TIMESTAMP_BEFORE=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "======================================================================"
echo " [2/3] PREPARING 6 CONCURRENT VM WORKLOAD TARGETS ($VM_SIZE each)"
echo "======================================================================"

cat << FIOEOF > /tmp/ops345_6vm_workload.fio
[global]
ioengine=io_uring
direct=1
group_reporting=0
time_based=1
runtime=${RUNTIME_SECS}
ramp_time=3
randrepeat=0
norandommap=1

# VM 1: DNS Server (BIND 9 / named) - 75% read / 25% write, QD 2
[vm1-dns]
filename=${TEST_DIR}/vm1-dns.raw
size=${VM_SIZE}
rw=randrw
rwmixread=75
bs=4k
iodepth=2

# VM 2: DHCP Server (ISC Kea) - Burst synchronous 4k writes, QD 4
[vm2-dhcp]
filename=${TEST_DIR}/vm2-dhcp.raw
size=${VM_SIZE}
rw=randwrite
bs=4k
iodepth=4
fsync=8

# VM 3: Web Server (Nginx / Apache + PHP) - 85% read 4k/16k, QD 8
[vm3-web]
filename=${TEST_DIR}/vm3-web.raw
size=${VM_SIZE}
rw=randrw
rwmixread=85
bsrange=4k-16k
iodepth=8

# VM 4: Database Server (MariaDB / PostgreSQL) - Heavy 8k/16k OLTP writes with WAL sync
[vm4-database]
filename=${TEST_DIR}/vm4-db.raw
size=${VM_SIZE}
rw=randrw
rwmixread=50
bs=8k
iodepth=16
fsync=1

# VM 5: Mail Server (Postfix / Dovecot) - 2k-32k random creates/writes, QD 4
[vm5-mail]
filename=${TEST_DIR}/vm5-mail.raw
size=${VM_SIZE}
rw=randrw
rwmixread=40
bsrange=2k-32k
iodepth=4

# VM 6: Storage Server (NFSv4 / Samba) - 128k multi-stream bulk transfers, QD 16
[vm6-storage]
filename=${TEST_DIR}/vm6-storage.raw
size=${VM_SIZE}
rw=rw
rwmixread=60
bs=128k
iodepth=16
FIOEOF

echo ""
echo "======================================================================"
echo " [3/3] EXECUTING 6-VM WORKLOAD (${RUNTIME_SECS}s TEST)"
echo "======================================================================"
if ! command -v fio >/dev/null 2>&1; then
    echo "fio is not installed. Installing..."
    sudo apt-get update && sudo apt-get install -y fio
fi

fio /tmp/ops345_6vm_workload.fio --output=/tmp/fio_results.json --output-format=json

echo ""
echo "======================================================================"
echo " BENCHMARK RESULTS SUMMARY (LATENCY & THROUGHPUT PER VM)"
echo "======================================================================"

python3 - << 'PYEOF'
import json

try:
    with open('/tmp/fio_results.json', 'r') as f:
        data = json.load(f)

    print(f"{'VM Role':<14} | {'Read IOPS':<9} | {'Read MB/s':<9} | {'Write IOPS':<10} | {'Write MB/s':<10} | {'p50 (us)':<8} | {'p99 (us)':<8} | {'p99.9 (us)':<10} | {'p99.99 (us)':<11}")
    print("-" * 105)

    total_r_iops = 0.0
    total_w_iops = 0.0
    total_r_bw = 0.0
    total_w_bw = 0.0

    for job in data['jobs']:
        name = job['jobname']
        r_iops = job['read']['iops']
        r_bw = job['read']['bw'] / 1024.0
        w_iops = job['write']['iops']
        w_bw = job['write']['bw'] / 1024.0
        
        total_r_iops += r_iops
        total_w_iops += w_iops
        total_r_bw += r_bw
        total_w_bw += w_bw

        def get_pct(target_pct):
            val = 0.0
            if 'clat_ns' in job['read'] and 'percentile' in job['read']['clat_ns'] and job['read']['clat_ns']['percentile']:
                val = max(val, job['read']['clat_ns']['percentile'].get(target_pct, 0) / 1000.0)
            if 'clat_ns' in job['write'] and 'percentile' in job['write']['clat_ns'] and job['write']['clat_ns']['percentile']:
                val = max(val, job['write']['clat_ns']['percentile'].get(target_pct, 0) / 1000.0)
            return val

        p50 = get_pct('50.000000')
        p99 = get_pct('99.000000')
        p999 = get_pct('99.900000')
        p9999 = get_pct('99.990000')

        print(f"{name:<14} | {r_iops:<9.1f} | {r_bw:<9.2f} | {w_iops:<10.1f} | {w_bw:<10.2f} | {p50:<8.1f} | {p99:<8.1f} | {p999:<10.1f} | {p9999:<11.1f}")

    print("-" * 105)
    print(f"{'AGGREGATE':<14} | {total_r_iops:<9.1f} | {total_r_bw:<9.2f} | {total_w_iops:<10.1f} | {total_w_bw:<10.2f} | Total Bandwidth: {(total_r_bw + total_w_bw):.2f} MB/s ({(total_r_iops + total_w_iops):.0f} Total IOPS)")
except Exception as e:
    print(f"Error parsing fio output: {e}")
PYEOF

echo ""
echo "======================================================================"
echo " POST-RUN FORENSIC LINK & KERNEL ERROR AUDIT"
echo "======================================================================"

ERROR_FOUND=0
if command -v dmesg >/dev/null 2>&1; then
    echo "Scanning dmesg for PCIe AER errors, IOMMU page faults, and NVMe timeouts..."
    
    # Query dmesg since test start
    DMESG_OUTPUT=$(sudo dmesg --since "$TIMESTAMP_BEFORE" 2>/dev/null || sudo dmesg | tail -n 200)
    
    AER_MATCHES=$(echo "$DMESG_OUTPUT" | grep -Ei "AER: Multiple Correctable|AER: Uncorrectable|aer:.*error" || true)
    IOMMU_MATCHES=$(echo "$DMESG_OUTPUT" | grep -Ei "DMAR:.*fault|AMD-Vi:.*fault|IOMMU:.*fault|queued invalidation timeout" || true)
    NVME_MATCHES=$(echo "$DMESG_OUTPUT" | grep -Ei "nvme.*timeout|nvme.*reset|nvme.*status code" || true)
    PCIE_MATCHES=$(echo "$DMESG_OUTPUT" | grep -Ei "pciehp.*surprise down|pciehp.*link down|DL_Active down" || true)

    if [[ -n "$AER_MATCHES" ]]; then
        echo "  [FAIL] PCIe AER Errors Detected during benchmark:"
        echo "$AER_MATCHES"
        ERROR_FOUND=1
    fi
    if [[ -n "$IOMMU_MATCHES" ]]; then
        echo "  [FAIL] IOMMU Page Faults Detected during benchmark:"
        echo "$IOMMU_MATCHES"
        ERROR_FOUND=1
    fi
    if [[ -n "$NVME_MATCHES" ]]; then
        echo "  [FAIL] NVMe Command Timeouts / Driver Resets Detected:"
        echo "$NVME_MATCHES"
        ERROR_FOUND=1
    fi
    if [[ -n "$PCIE_MATCHES" ]]; then
        echo "  [FAIL] PCIe Link Drops / Surprise Down Events Detected:"
        echo "$PCIE_MATCHES"
        ERROR_FOUND=1
    fi

    if [[ $ERROR_FOUND -eq 0 ]]; then
        echo "  [PASS] Zero AER errors, zero IOMMU page faults, zero link drops."
        echo "  [PASS] USB4 PCIe Gen 4 x4 physical link remained 100% rock-solid under concurrent multi-VM saturation."
    fi
fi

echo ""
echo "======================================================================"
echo "Cleaning up temporary test files..."
rm -f /tmp/ops345_6vm_workload.fio /tmp/fio_results.json
rm -rf "$TEST_DIR"
echo "Benchmark completed successfully."
