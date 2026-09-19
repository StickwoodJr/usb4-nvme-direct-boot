#!/usr/bin/env bash
# ==============================================================================
# tests/test_deb_packaging.sh - Verification of Debian Package Generation
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Running Debian Package Build & Structure Verification ==="

# Build package
"${SCRIPT_DIR}/packaging/build_deb.sh" > /dev/null

DEB_FILE="${SCRIPT_DIR}/dist/usb4-nvme-direct-boot_1.0.0_all.deb"

if [[ ! -f "${DEB_FILE}" ]]; then
    echo "FAIL: Expected package not found at ${DEB_FILE}"
    exit 1
fi

# Verify control fields
control_info=$(dpkg-deb -I "${DEB_FILE}")
if ! echo "${control_info}" | grep -q "Package: usb4-nvme-direct-boot"; then
    echo "FAIL: Package name mismatch in debian control"
    exit 1
fi

# Verify essential files inside archive
archive_contents=$(dpkg-deb -c "${DEB_FILE}")

for file_target in \
    "./usr/sbin/usb4-boot-config" \
    "./usr/share/usb4-nvme-direct-boot/scripts/apply_usb4_direct_boot_fix.sh" \
    "./usr/share/usb4-nvme-direct-boot/scripts/rollback_usb4_fix.sh" \
    "./usr/share/doc/usb4-nvme-direct-boot/README.md" \
    "./usr/share/doc/usb4-nvme-direct-boot/copyright"; do
    if ! echo "${archive_contents}" | grep -q "${file_target}"; then
        echo "FAIL: Missing expected archive member: ${file_target}"
        exit 1
    fi
done

echo "OK: Debian package built and verified successfully."
exit 0
