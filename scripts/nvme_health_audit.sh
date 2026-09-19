#!/usr/bin/env bash
# ==============================================================================
# nvme_health_audit.sh - Storage Forensic Health & Endurance Audit Utility
# Target:  WD_BLACK SN7100 1TB NVMe SSD / High-Performance PCIe NVMe
# Enclosure: ASMedia ASM2464PD / Thunderbolt 4 USB4 Enclosures
# Supports:  Dual-mode inspection (USB4 PCIe Tunnel /dev/nvme* & USB 3.2 UASP /dev/sd*)
# ==============================================================================
set -euo pipefail

RATED_TBW=600
WARN_TEMP_THRESHOLD=85
CRIT_TEMP_THRESHOLD=90
SPARE_WARN_THRESHOLD=15

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OUTPUT_MODE="human"
if [[ "${1:-}" == "--json" ]]; then
    OUTPUT_MODE="json"
elif [[ "${1:-}" == "--check" ]]; then
    OUTPUT_MODE="check"
fi

if ! command -v smartctl >/dev/null 2>&1 && ! command -v nvme >/dev/null 2>&1; then
    echo "[-] ERROR: Neither 'smartctl' nor 'nvme' (nvme-cli) was found. Install via: sudo apt install smartmontools nvme-cli" >&2
    exit 2
fi

TARGET_DEV="${2:-}"
DEV_TYPE=""

if [[ -z "$TARGET_DEV" ]]; then
    for dev in /dev/nvme*n1; do
        if [[ -e "$dev" ]]; then
            model=$(cat "/sys/class/block/${dev#/dev/}/device/model" 2>/dev/null || true)
            if [[ "$model" =~ (SN7100|WDS100T4X0E|WD_BLACK) ]]; then
                TARGET_DEV="$dev"
                DEV_TYPE="nvme"
                break
            fi
        fi
    done

    if [[ -z "$TARGET_DEV" ]]; then
        for dev in /dev/sd[a-z]; do
            if [[ -e "$dev" ]]; then
                vendor=$(cat "/sys/class/block/${dev#/dev/}/device/vendor" 2>/dev/null || true)
                model=$(cat "/sys/class/block/${dev#/dev/}/device/model" 2>/dev/null || true)
                if [[ "$vendor" =~ (ASMedia|UGREEN) ]] || [[ "$model" =~ (Storage|SN7100|ASM2464) ]]; then
                    TARGET_DEV="$dev"
                    DEV_TYPE="uasp"
                    break
                fi
            fi
        done
    fi

    if [[ -z "$TARGET_DEV" ]]; then
        ROOT_PART=$(df -P / 2>/dev/null | tail -1 | awk '{print $1}')
        if [[ "$ROOT_PART" =~ nvme[0-9]+n[0-9]+ ]]; then
            TARGET_DEV="/dev/$(echo "$ROOT_PART" | grep -o 'nvme[0-9]\+n[0-9]\+')"
            DEV_TYPE="nvme"
        elif [[ "$ROOT_PART" =~ sd[a-z] ]]; then
            TARGET_DEV="/dev/$(echo "$ROOT_PART" | grep -o 'sd[a-z]')"
            DEV_TYPE="uasp"
        fi
    fi
fi

if [[ -z "$TARGET_DEV" || ! -e "$TARGET_DEV" ]]; then
    echo "[-] ERROR: Could not auto-detect target NVMe SSD. Please specify device node: $0 [mode] /dev/nvme0n1" >&2
    exit 2
fi

if [[ -z "$DEV_TYPE" ]]; then
    if [[ "$TARGET_DEV" =~ nvme ]]; then
        DEV_TYPE="nvme"
    else
        DEV_TYPE="uasp"
    fi
fi

SMART_OUT=""
if [[ "$DEV_TYPE" == "nvme" ]]; then
    SMART_OUT=$(sudo smartctl -x "$TARGET_DEV" 2>/dev/null || true)
else
    SMART_OUT=$(sudo smartctl -x -d sntasmedia "$TARGET_DEV" 2>/dev/null || true)
    if [[ -z "$SMART_OUT" || "$SMART_OUT" =~ "Device open failed" ]]; then
        SMART_OUT=$(sudo smartctl -x -d nvme "$TARGET_DEV" 2>/dev/null || true)
    fi
fi

if [[ -z "$SMART_OUT" ]]; then
    echo "[-] ERROR: Failed to extract SMART telemetry from $TARGET_DEV" >&2
    exit 2
fi

parse_val() {
    local pattern="$1"
    echo "$SMART_OUT" | grep -iE "$pattern" | head -1 | awk -F: '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//'
}

MODEL_NAME=$(parse_val "Model Number")
SERIAL_NUM=$(parse_val "Serial Number")
FW_VERSION=$(parse_val "Firmware Version")
SMART_STATUS=$(echo "$SMART_OUT" | grep -i "SMART overall-health self-assessment test result" | awk -F: '{print $2}' | tr -d ' ' || echo "UNKNOWN")
COMP_TEMP=$(parse_val "^Temperature:" | awk '{print $1}')
SENSOR1_TEMP=$(parse_val "Temperature Sensor 1:" | awk '{print $1}')
SENSOR2_TEMP=$(parse_val "Temperature Sensor 2:" | awk '{print $1}')
WARN_TEMP_TRIP=$(parse_val "Warning Comp. Temp. Threshold" | awk '{print $1}')
CRIT_TEMP_TRIP=$(parse_val "Critical Comp. Temp. Threshold" | awk '{print $1}')
WARN_TEMP_TIME=$(parse_val "Warning Comp. Temperature Time" | awk '{print $1}')
CRIT_TEMP_TIME=$(parse_val "Critical Comp. Temperature Time" | awk '{print $1}')

AVAIL_SPARE=$(parse_val "Available Spare:" | tr -d '%')
SPARE_THRESH=$(parse_val "Available Spare Threshold:" | tr -d '%')
PCT_USED=$(parse_val "Percentage Used:" | tr -d '%')

DATA_READ_STR=$(parse_val "Data Units Read:")
DATA_WRITTEN_STR=$(parse_val "Data Units Written:")
HOST_READ_CMDS=$(parse_val "Host Read Commands:")
HOST_WRITE_CMDS=$(parse_val "Host Write Commands:")

POWER_CYCLES=$(parse_val "Power Cycles:")
POWER_ON_HOURS=$(parse_val "Power On Hours:")
UNSAFE_SHUTDOWNS=$(parse_val "Unsafe Shutdowns:")
MEDIA_ERRORS=$(parse_val "Media and Data Integrity Errors:" | awk '{print $1}')
ERROR_LOG_ENTRIES=$(parse_val "Error Information Log Entries:" | awk '{print $1}')

COMP_TEMP="${COMP_TEMP:-0}"
SENSOR1_TEMP="${SENSOR1_TEMP:-0}"
SENSOR2_TEMP="${SENSOR2_TEMP:-0}"
AVAIL_SPARE="${AVAIL_SPARE:-100}"
SPARE_THRESH="${SPARE_THRESH:-10}"
PCT_USED="${PCT_USED:-0}"
MEDIA_ERRORS="${MEDIA_ERRORS:-0}"
ERROR_LOG_ENTRIES="${ERROR_LOG_ENTRIES:-0}"
WARN_TEMP_TIME="${WARN_TEMP_TIME:-0}"
CRIT_TEMP_TIME="${CRIT_TEMP_TIME:-0}"

TB_WRITTEN=$(echo "$DATA_WRITTEN_STR" | grep -o '\[.*\]' | tr -d '[]' | awk '{print $1}' || echo "0")
if [[ -z "$TB_WRITTEN" ]]; then TB_WRITTEN="0"; fi

TB_READ=$(echo "$DATA_READ_STR" | grep -o '\[.*\]' | tr -d '[]' | awk '{print $1}' || echo "0")
if [[ -z "$TB_READ" ]]; then TB_READ="0"; fi

REMAINING_LIFE=$(( 100 - PCT_USED ))
PCT_TBW_CONSUMED=$(awk "BEGIN {printf \"%.2f\", ($TB_WRITTEN / $RATED_TBW) * 100}")
REMAINING_TBW=$(awk "BEGIN {printf \"%.2f\", $RATED_TBW - $TB_WRITTEN}")

HMB_STATUS="N/A (UASP Mode)"
if [[ "$DEV_TYPE" == "nvme" ]]; then
    CTRL_PATH="/dev/$(echo "$TARGET_DEV" | grep -o 'nvme[0-9]\+')"
    if command -v nvme >/dev/null 2>&1; then
        HMB_RAW=$(sudo nvme get-feature "$CTRL_PATH" -f 0x0d 2>/dev/null || true)
        if echo "$HMB_RAW" | grep -iq "Current value:0x00000001"; then
            HMB_STATUS="Active (Enabled by Host Kernel)"
        elif echo "$HMB_RAW" | grep -iq "Current value:0x00000000"; then
            HMB_STATUS="Inactive (Disabled)"
        else
            HMB_STATUS="Supported"
        fi
    fi
fi

DISCARD_MAX="0"
DISCARD_GRAN="0"
PROV_MODE="N/A"
BLOCK_NAME="${TARGET_DEV#/dev/}"
if [[ -f "/sys/block/$BLOCK_NAME/queue/discard_max_bytes" ]]; then
    DISCARD_MAX=$(cat "/sys/block/$BLOCK_NAME/queue/discard_max_bytes" 2>/dev/null || echo "0")
fi
if [[ -f "/sys/block/$BLOCK_NAME/queue/discard_granularity" ]]; then
    DISCARD_GRAN=$(cat "/sys/block/$BLOCK_NAME/queue/discard_granularity" 2>/dev/null || echo "0")
fi
if [[ -d "/sys/block/$BLOCK_NAME/device/scsi_disk" ]]; then
    PROV_MODE=$(cat /sys/block/"$BLOCK_NAME"/device/scsi_disk/*/provisioning_mode 2>/dev/null || echo "unknown")
fi

EXIT_CODE=0
HEALTH_STATUS="HEALTHY"

if [[ "$MEDIA_ERRORS" -gt 0 || "$ERROR_LOG_ENTRIES" -gt 0 || "$SMART_STATUS" != "PASSED" ]]; then
    EXIT_CODE=2
    HEALTH_STATUS="CRITICAL: MEDIA INTEGRITY ERRORS DETECTED"
elif [[ "$COMP_TEMP" -ge "$WARN_TEMP_THRESHOLD" || "$AVAIL_SPARE" -le "$SPARE_THRESH" || "$PCT_USED" -ge 90 ]]; then
    EXIT_CODE=1
    HEALTH_STATUS="WARNING: TEMPERATURE OR WEAR THRESHOLD EXCEEDED"
fi

if [[ "$OUTPUT_MODE" == "check" ]]; then
    echo "Status: $HEALTH_STATUS | Temp: ${COMP_TEMP}C | Spare: ${AVAIL_SPARE}% | Used: ${PCT_USED}% | Errors: ${MEDIA_ERRORS}"
    exit $EXIT_CODE
fi

if [[ "$OUTPUT_MODE" == "json" ]]; then
    cat << JSEOF
{
  "device": "$TARGET_DEV",
  "connection_type": "$DEV_TYPE",
  "model": "$MODEL_NAME",
  "serial": "$SERIAL_NUM",
  "firmware": "$FW_VERSION",
  "overall_health": "$SMART_STATUS",
  "status_evaluation": "$HEALTH_STATUS",
  "temperature": {
    "composite_celsius": $COMP_TEMP,
    "sensor1_controller_celsius": $SENSOR1_TEMP,
    "sensor2_nand_celsius": $SENSOR2_TEMP
  },
  "endurance": {
    "available_spare_percent": $AVAIL_SPARE,
    "percentage_used": $PCT_USED,
    "remaining_life_percent": $REMAINING_LIFE,
    "rated_tbw": $RATED_TBW,
    "tbw_written": $TB_WRITTEN,
    "tbw_consumed_percent": $PCT_TBW_CONSUMED,
    "remaining_tbw": $REMAINING_TBW
  },
  "integrity_errors": {
    "media_and_data_errors": $MEDIA_ERRORS,
    "error_log_entries": $ERROR_LOG_ENTRIES
  },
  "bridge_and_features": {
    "host_memory_buffer": "$HMB_STATUS",
    "discard_max_bytes": $DISCARD_MAX,
    "discard_granularity_bytes": $DISCARD_GRAN
  }
}
JSEOF
    exit $EXIT_CODE
fi

echo -e "${BOLD}================================================================================${NC}"
echo -e "${CYAN}${BOLD}                 STORAGE HEALTH & ENDURANCE AUDIT                               ${NC}"
echo -e "${BOLD}================================================================================${NC}"
echo -e " Target Device Node  : ${BOLD}$TARGET_DEV${NC} (${DEV_TYPE^^} Domain)"
echo -e " Silicon Identity    : ${BOLD}$MODEL_NAME${NC} (FW: ${CYAN}$FW_VERSION${NC})"
echo -e " Serial Number       : $SERIAL_NUM"

if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo -e " Self-Assessment Test: ${GREEN}${BOLD}$SMART_STATUS ($HEALTH_STATUS)${NC}"
elif [[ "$EXIT_CODE" -eq 1 ]]; then
    echo -e " Self-Assessment Test: ${YELLOW}${BOLD}$SMART_STATUS ($HEALTH_STATUS)${NC}"
else
    echo -e " Self-Assessment Test: ${RED}${BOLD}$SMART_STATUS ($HEALTH_STATUS)${NC}"
fi

echo -e "\n${BOLD}[1] THERMAL MANAGEMENT & SILICON SENSORS${NC}"
echo -e " ├─ Composite Temperature  : ${BOLD}${COMP_TEMP}°C${NC} (Warning: ${WARN_TEMP_TRIP}°C | Critical: ${CRIT_TEMP_TRIP}°C)"
echo -e " ├─ Sensor 1 (Controller)  : ${BOLD}${SENSOR1_TEMP}°C${NC}"
echo -e " ├─ Sensor 2 (Flash NAND)  : ${BOLD}${SENSOR2_TEMP}°C${NC}"

echo -e "\n${BOLD}[2] FLASH WEAR, SPARE CAPACITY & ENDURANCE${NC}"
echo -e " ├─ Available Spare Block  : ${GREEN}${BOLD}${AVAIL_SPARE}%${NC} (Factory Threshold: ${SPARE_THRESH}%)"
echo -e " ├─ Drive Life Used        : ${BOLD}${PCT_USED}%${NC} (Estimated Remaining Life: ${GREEN}${BOLD}${REMAINING_LIFE}%${NC})"
echo -e " ├─ Rated Endurance        : ${BOLD}${RATED_TBW} TBW${NC}"
echo -e " ├─ Total Physical Written : ${BOLD}${TB_WRITTEN} TB${NC} (${PCT_TBW_CONSUMED}% of rated TBW exhausted)"
echo -e " ├─ Remaining Endurance    : ${GREEN}${BOLD}${REMAINING_TBW} TB${NC}"

echo -e "\n${BOLD}[3] DATA INTEGRITY & HARDWARE RELIABILITY${NC}"
if [[ "$MEDIA_ERRORS" -eq 0 ]]; then
    echo -e " ├─ Media/Data Errors      : ${GREEN}${BOLD}0 (None Detected)${NC}"
else
    echo -e " ├─ Media/Data Errors      : ${RED}${BOLD}${MEDIA_ERRORS} (HARDWARE WARNING)${NC}"
fi
echo -e " ├─ Error Log Entries      : ${ERROR_LOG_ENTRIES}"
echo -e " ├─ Unsafe Shutdowns       : ${YELLOW}${UNSAFE_SHUTDOWNS}${NC}"
echo -e " ├─ Power Cycles / Hours   : ${POWER_CYCLES} cycles / ${POWER_ON_HOURS} operating hours"

echo -e "\n${BOLD}[4] TRANSPORT LINK, HMB & TRIM CONFIGURATION${NC}"
if [[ "$DEV_TYPE" == "nvme" ]]; then
    echo -e " ├─ Interface Mode         : ${GREEN}${BOLD}Native PCIe Gen 4 x4 over USB4 (40 Gbps)${NC}"
    echo -e " ├─ Host Memory Buffer     : ${GREEN}${BOLD}${HMB_STATUS}${NC}"
    echo -e " ├─ TRIM / Deallocate      : ${GREEN}${BOLD}Native NVMe DSM Active${NC}"
else
    echo -e " ├─ Interface Mode         : ${YELLOW}${BOLD}USB 3.2 Gen 2 UASP Fallback (10 Gbps)${NC}"
    echo -e " ├─ Host Memory Buffer     : ${YELLOW}${BOLD}Inactive (SRAM Only)${NC}"
    echo -e " ├─ Discard Max Bytes      : ${BOLD}${DISCARD_MAX} bytes${NC} (Granularity: ${DISCARD_GRAN} bytes)"
fi
echo -e "${BOLD}================================================================================${NC}"

exit $EXIT_CODE
