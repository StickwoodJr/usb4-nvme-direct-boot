#!/usr/bin/env bash
# ==============================================================================
# scripts/apply_kernel_patch.sh - Helper Utility to Apply LKML Proposal to Kernel Tree
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="${SCRIPT_DIR}/patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch"

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] /path/to/linux-source-tree

Helper tool to validate and apply the pre-boot PCIe tunnel preservation patch
to a local Linux kernel git tree.

Options:
  --check, -c    Dry-run check whether the patch applies cleanly (default)
  --apply, -a    Apply the patch and create a git commit
  --reverse, -r  Reverse the patch
  -h, --help     Show this message

Example:
  $0 --check /usr/src/linux
  $0 --apply ~/git/linux
EOF
}

ACTION="check"
KERNEL_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|-c)
            ACTION="check"
            shift
            ;;
        --apply|-a)
            ACTION="apply"
            shift
            ;;
        --reverse|-r)
            ACTION="reverse"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            if [[ -z "$KERNEL_DIR" ]]; then
                KERNEL_DIR="$1"
                shift
            else
                echo "[-] Unknown argument: $1" >&2
                show_usage
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$KERNEL_DIR" ]]; then
    echo "[-] Error: Linux kernel source directory must be specified." >&2
    show_usage
    exit 1
fi

if [[ ! -d "$KERNEL_DIR" ]]; then
    echo "[-] Error: Directory does not exist: $KERNEL_DIR" >&2
    exit 1
fi

if [[ ! -f "${KERNEL_DIR}/drivers/thunderbolt/nhi.c" || ! -f "${KERNEL_DIR}/drivers/thunderbolt/tb.c" ]]; then
    echo "[-] Error: Target directory does not appear to be a Linux kernel tree with drivers/thunderbolt/." >&2
    exit 1
fi

cd "$KERNEL_DIR"

case "$ACTION" in
    check)
        echo "=== Checking patch compatibility against: $KERNEL_DIR ==="
        if git apply --check --ignore-whitespace "$PATCH_FILE"; then
            echo "[OK] Patch applies cleanly to this kernel tree."
            exit 0
        else
            echo "[-] Patch failed clean dry-run check. Hunk offsets or kernel version divergence detected." >&2
            exit 2
        fi
        ;;
    apply)
        echo "=== Applying patch to kernel tree: $KERNEL_DIR ==="
        if git apply --ignore-whitespace "$PATCH_FILE"; then
            echo "[OK] Patch applied successfully to working tree."
            echo "Modified files:"
            git status -s drivers/thunderbolt/
            exit 0
        else
            echo "[-] Error applying patch." >&2
            exit 1
        fi
        ;;
    reverse)
        echo "=== Reversing patch on kernel tree: $KERNEL_DIR ==="
        if git apply --reverse --ignore-whitespace "$PATCH_FILE"; then
            echo "[OK] Patch reversed successfully."
            exit 0
        else
            echo "[-] Error reversing patch." >&2
            exit 1
        fi
        ;;
esac
