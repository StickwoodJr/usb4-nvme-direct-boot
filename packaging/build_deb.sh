#!/usr/bin/env bash
# ==============================================================================
# packaging/build_deb.sh - Automated Debian/Ubuntu .deb Package Builder
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="${SCRIPT_DIR}/packaging/debian"
BUILD_DIR="${SCRIPT_DIR}/packaging/build"
OUTPUT_DIR="${SCRIPT_DIR}/dist"

PACKAGE_NAME="usb4-nvme-direct-boot"
VERSION="1.0.0"
ARCH="all"
DEB_FILE="${OUTPUT_DIR}/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

echo "=== Building ${PACKAGE_NAME} Debian Package (${VERSION}) ==="

# Clean build directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/DEBIAN"
mkdir -p "${BUILD_DIR}/usr/sbin"
mkdir -p "${BUILD_DIR}/usr/share/usb4-nvme-direct-boot/scripts"
mkdir -p "${BUILD_DIR}/usr/share/doc/${PACKAGE_NAME}"
mkdir -p "${OUTPUT_DIR}"

# Copy control and maintainer scripts
cp "${PKG_ROOT}/DEBIAN/control" "${BUILD_DIR}/DEBIAN/control"
if [[ -f "${PKG_ROOT}/DEBIAN/postinst" ]]; then
    cp "${PKG_ROOT}/DEBIAN/postinst" "${BUILD_DIR}/DEBIAN/postinst"
    chmod 755 "${BUILD_DIR}/DEBIAN/postinst"
fi
if [[ -f "${PKG_ROOT}/DEBIAN/prerm" ]]; then
    cp "${PKG_ROOT}/DEBIAN/prerm" "${BUILD_DIR}/DEBIAN/prerm"
    chmod 755 "${BUILD_DIR}/DEBIAN/prerm"
fi

# Copy CLI binary to /usr/sbin
cp "${SCRIPT_DIR}/setup_usb4_boot.sh" "${BUILD_DIR}/usr/sbin/usb4-boot-config"
chmod 755 "${BUILD_DIR}/usr/sbin/usb4-boot-config"

# Copy core scripts
cp "${SCRIPT_DIR}/scripts/apply_usb4_direct_boot_fix.sh" "${BUILD_DIR}/usr/share/usb4-nvme-direct-boot/scripts/"
cp "${SCRIPT_DIR}/scripts/rollback_usb4_fix.sh" "${BUILD_DIR}/usr/share/usb4-nvme-direct-boot/scripts/"
cp "${SCRIPT_DIR}/scripts/verify_usb4_environment.sh" "${BUILD_DIR}/usr/share/usb4-nvme-direct-boot/scripts/"
cp "${SCRIPT_DIR}/scripts/nvme_health_audit.sh" "${BUILD_DIR}/usr/share/usb4-nvme-direct-boot/scripts/"
chmod 755 "${BUILD_DIR}/usr/share/usb4-nvme-direct-boot/scripts/"*.sh

# Copy documentation & license
cp "${SCRIPT_DIR}/README.md" "${BUILD_DIR}/usr/share/doc/${PACKAGE_NAME}/"
cp "${SCRIPT_DIR}/LICENSE" "${BUILD_DIR}/usr/share/doc/${PACKAGE_NAME}/copyright"
if [[ -f "${SCRIPT_DIR}/docs/TROUBLESHOOTING.md" ]]; then
    cp "${SCRIPT_DIR}/docs/TROUBLESHOOTING.md" "${BUILD_DIR}/usr/share/doc/${PACKAGE_NAME}/"
fi
if [[ -f "${SCRIPT_DIR}/docs/FORENSIC_KERNEL_INVESTIGATION_REPORT.md" ]]; then
    cp "${SCRIPT_DIR}/docs/FORENSIC_KERNEL_INVESTIGATION_REPORT.md" "${BUILD_DIR}/usr/share/doc/${PACKAGE_NAME}/"
fi
if [[ -f "${SCRIPT_DIR}/docs/UBUNTU_LAUNCHPAD_BUG_REPORT.md" ]]; then
    cp "${SCRIPT_DIR}/docs/UBUNTU_LAUNCHPAD_BUG_REPORT.md" "${BUILD_DIR}/usr/share/doc/${PACKAGE_NAME}/"
fi
if [[ -f "${SCRIPT_DIR}/docs/EXECUTIVE_SUMMARY.md" ]]; then
    cp "${SCRIPT_DIR}/docs/EXECUTIVE_SUMMARY.md" "${BUILD_DIR}/usr/share/doc/${PACKAGE_NAME}/"
fi

# Set permissions
chmod 755 "${BUILD_DIR}/DEBIAN"
chmod 644 "${BUILD_DIR}/DEBIAN/control"

# Build package
dpkg-deb --build --root-owner-group "${BUILD_DIR}" "${DEB_FILE}"

echo "Package successfully generated: ${DEB_FILE}"
dpkg-deb --info "${DEB_FILE}"
dpkg-deb --contents "${DEB_FILE}"
