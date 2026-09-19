#!/usr/bin/env bash
# ==============================================================================
# tests/test_cli.sh - Test Harness for USB4 Boot CLI Interface
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${SCRIPT_DIR}/setup_usb4_boot.sh"

TEST_COUNT=0
PASS_COUNT=0

test_assert() {
    local name="$1"
    local cmd="$2"
    local expected_code="${3:-0}"
    local expected_pattern="${4:-}"

    TEST_COUNT=$((TEST_COUNT + 1))
    echo -n "Test ${TEST_COUNT}: ${name} ... "
    
    local output
    local status=0
    output=$(eval "$cmd" 2>&1) || status=$?

    if [[ $status -ne $expected_code ]]; then
        echo "FAILED (Exit status $status, expected $expected_code)"
        echo "Output was: $output"
        return 1
    fi

    if [[ -n "$expected_pattern" ]] && ! echo "$output" | grep -qiE "$expected_pattern"; then
        echo "FAILED (Output did not match pattern '$expected_pattern')"
        echo "Output was: $output"
        return 1
    fi

    echo "PASSED"
    PASS_COUNT=$((PASS_COUNT + 1))
}

echo "======================================================================"
echo " Running Automated CLI Tests for setup_usb4_boot.sh"
echo "======================================================================"

# Test 1: Help message
test_assert "Display Help via -h" \
    "${CLI} -h" 0 "USAGE:"

# Test 2: Help message via --help
test_assert "Display Help via --help" \
    "${CLI} --help" 0 "PRIMARY COMMANDS:"

# Test 3: Unknown argument error handling
test_assert "Reject unknown options" \
    "${CLI} --invalid-flag" 1 "Unknown option"

# Test 4: Read-only Audit Mode
test_assert "Run Audit Mode" \
    "${CLI} --audit" 0 "PRE-FLIGHT AUDIT"

# Test 5: Dry-Run Mode
test_assert "Run Dry-Run Mode" \
    "${CLI} --dry-run" 0 "DRY-RUN EXECUTION PREVIEW"

# Test 6: Dry-Run Rollback
test_assert "Run Rollback Dry-Run" \
    "${CLI} --rollback --dry-run" 0 "ROLLBACK: USB4 Direct-Boot"

# Test 7: Non-root protection on --apply
test_assert "Reject --apply without root" \
    "${SCRIPT_DIR}/scripts/apply_usb4_direct_boot_fix.sh --apply" 1 "must be run as root"

# Test 8: Custom UUID passing in dry-run
test_assert "Honor --uuid override in dry-run" \
    "${CLI} --dry-run --uuid 11111111-2222-3333-4444-555555555555" 0 "11111111-2222-3333-4444-555555555555"

# Test 9: Verify mode runs cleanly
test_assert "Run Verify Mode" \
    "${CLI} --verify" 0 "PRE-FLIGHT VERIFICATION"

echo "======================================================================"
echo " Results: ${PASS_COUNT} of ${TEST_COUNT} tests passed."
echo "======================================================================"

if [[ $PASS_COUNT -ne $TEST_COUNT ]]; then
    exit 1
fi
exit 0
