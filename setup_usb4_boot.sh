#!/usr/bin/env bash
# ==============================================================================
# setup_usb4_boot.sh - USB4 / Thunderbolt 4 Direct-Boot CLI & Management Suite
# ==============================================================================
# Provides a safe, discoverable entrypoint for auditing, applying, verifying,
# and rolling back USB4 direct-boot configurations on Linux.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/scripts/apply_usb4_direct_boot_fix.sh"
ROLLBACK="${SCRIPT_DIR}/scripts/rollback_usb4_fix.sh"
VERIFY="${SCRIPT_DIR}/scripts/verify_usb4_environment.sh"
AUDIT_HEALTH="${SCRIPT_DIR}/scripts/nvme_health_audit.sh"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

show_usage() {
    cat <<EOF
${BOLD}==============================================================================${NC}
${CYAN}${BOLD} USB4 / Thunderbolt 4 NVMe Direct-Boot Management Utility ${NC}
${BOLD}==============================================================================${NC}
${YELLOW}NOTICE: This utility applies kernel and initramfs boot configurations designed
specifically for external NVMe direct-boot topologies over USB4 / TB4.
Review documentation in docs/ before applying to production laptops.${NC}

${BOLD}USAGE:${NC}
  ./setup_usb4_boot.sh [COMMAND] [OPTIONS]

${BOLD}PRIMARY COMMANDS:${NC}
  --audit             Perform a non-destructive pre-flight audit of the host,
                      kernel version, controller, and boot environment.
  --dry-run           Preview all configuration files, udev rules, and dracut
                      drop-ins without modifying any system state.
  --apply, -y         Apply direct-boot drop-in configurations, install hooks,
                      and rebuild the target initial ramdisk (requires sudo).
  --verify            Run runtime hardware link verification and telemetry checks.
  --rollback          Completely remove all deployed drop-in configurations and
                      restore pristine pre-change initrd/grub state (requires sudo).
  --health            Query SMART attributes, temperature, and Host Memory Buffer.

${BOLD}OPTIONS:${NC}
  --uuid <UUID>       Explicitly set root partition UUID (useful for chroot installs).
  --non-interactive   Skip interactive confirmation prompts in --apply mode.
  -h, --help          Display this help documentation.

${BOLD}EXAMPLES:${NC}
  # 1. Check system readiness without changing anything:
  ./setup_usb4_boot.sh --audit

  # 2. Preview planned changes:
  ./setup_usb4_boot.sh --dry-run

  # 3. Apply configurations (requires root):
  sudo ./setup_usb4_boot.sh --apply

  # 4. Completely undo all changes:
  sudo ./setup_usb4_boot.sh --rollback

  # 5. Check active 16.0 GT/s PCIe Gen 4 x4 and HMB status after booting:
  ./setup_usb4_boot.sh --verify

EOF
}

if [[ $# -eq 0 ]]; then
    show_usage
    exit 0
fi

case "$1" in
    -h|--help|help)
        show_usage
        exit 0
        ;;
    --audit)
        exec bash "${INSTALLER}" --audit "${@:2}"
        ;;
    --dry-run)
        exec bash "${INSTALLER}" --dry-run "${@:2}"
        ;;
    --apply|-y|--yes)
        exec bash "${INSTALLER}" "$@"
        ;;
    --rollback)
        if [[ ! -f "${ROLLBACK}" ]]; then
            echo -e "${RED}[ERROR] Rollback script not found at ${ROLLBACK}${NC}" >&2
            exit 1
        fi
        exec bash "${ROLLBACK}" "${@:2}"
        ;;
    --verify)
        if [[ ! -f "${VERIFY}" ]]; then
            echo -e "${RED}[ERROR] Verification script not found at ${VERIFY}${NC}" >&2
            exit 1
        fi
        exec bash "${VERIFY}" "${@:2}"
        ;;
    --health)
        if [[ ! -f "${AUDIT_HEALTH}" ]]; then
            echo -e "${RED}[ERROR] Health audit script not found at ${AUDIT_HEALTH}${NC}" >&2
            exit 1
        fi
        exec bash "${AUDIT_HEALTH}" "${@:2}"
        ;;
    --uuid)
        exec bash "${INSTALLER}" "$@"
        ;;
    *)
        echo -e "${RED}[ERROR] Unknown option: $1${NC}\n" >&2
        show_usage
        exit 1
        ;;
esac
