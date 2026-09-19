#!/usr/bin/env bash
# ==============================================================================
# tests/run_all_tests.sh - Master Test Runner for USB4 Direct-Boot Test Suite
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================================================"
echo " Starting USB4 Direct-Boot Automated Test Suite"
echo "========================================================================"

bash "${SCRIPT_DIR}/test_cli.sh"
echo ""
bash "${SCRIPT_DIR}/test_patch_validation.sh"

echo ""
echo "========================================================================"
echo " ALL TEST SUITES PASSED SUCCESSFULLY."
echo "========================================================================"
