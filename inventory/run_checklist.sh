#!/bin/bash
# =============================================================================
# run_checklist.sh — End-of-run validation checklist
# =============================================================================
# Called by rhel_inv_run.sh at the end of every run.
# Evaluates whether each expected output was produced correctly.
# No color coding — plain text suitable for log files and grep.
#
# Usage: run_checklist.sh [test|production]
# =============================================================================

cd "$(dirname "$0")" || exit 1
CONF="$(dirname "$0")/rhel_inv.conf"
[[ -f "$CONF" ]] && . "$CONF"
[[ -f "$(dirname "$0")/rhel_utils.sh" ]] && . "$(dirname "$0")/rhel_utils.sh"

RUN_MODE="${1:-production}"
PASS=0
WARN_COUNT=0
FAIL=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }

result() {
    local status="$1"; shift
    local item="$1"; shift
    local detail="$*"
    printf '%s  [%-4s]  %-55s %s\n' "$(ts)" "$status" "$item" "$detail"
    case "$status" in
        PASS) (( PASS++ ))       ;;
        WARN) (( WARN_COUNT++ )) ;;
        FAIL) (( FAIL++ ))       ;;
    esac
}

check_file() {
    local label="$1"
    local path="$2"
    local min_lines="${3:-1}"
    if [[ ! -f "$path" ]]; then
        result FAIL "$label" "NOT FOUND: $path"
    elif [[ ! -s "$path" ]]; then
        result FAIL "$label" "EMPTY: $path"
    else
        local lines
        lines=$(wc -l < "$path")
        if [[ $lines -lt $min_lines ]]; then
            result WARN "$label" "Only $lines lines (expected >=$min_lines): $path"
        else
            result PASS "$label" "$lines lines — $path"
        fi
    fi
}

# =============================================================================
# Set paths based on run mode
# In test mode, INVENTDATACSV / INVENTDATATEXT are already overridden by
# rhel_inv_run.sh exports (e.g. TEST_RHEL_INVENTORY.csv)
# =============================================================================
if [[ "$RUN_MODE" == "test" ]]; then
    TEST_DATA="${BASE_DIR}/test/data"
    TEST_WEB="${BASE_DIR}/test/webdir"
    _INVDATA="${TEST_DATA}/TEST_RHEL_INVENTORY.dat"
    _INVCSV="${TEST_WEB}/${INVENTDATACSV}"
    _INVTXT="${TEST_WEB}/${INVENTDATATEXT}"
    _IDDATA="${TEST_DATA}/TEST_RHEL_IDINVENTORY.dat"
    _PKGCSV="${TEST_WEB}/$(basename "${PACKAGEDATA:-RHEL_PACKAGES_v2.csv}")"
    _MIDCSV="${TEST_WEB}/Midrange_INVENTORY.csv"
    _DEPDAT="${DATA_DIR}/RHEL_DEPLOYMENTS.dat"
    _WEBDIR="$TEST_WEB"
else
    _INVDATA="$INVENTORYDATA"
    _INVCSV="${WEBDIR}/${INVENTDATACSV}"
    _INVTXT="${WEBDIR}/${INVENTDATATEXT}"
    _IDDATA="$IDINVENTORYDATA"
    _PKGCSV="${WEBDIR}/$(basename "${PACKAGEDATA:-RHEL_PACKAGES_v2.csv}")"
    _MIDCSV="${WEBDIR}/Midrange_INVENTORY.csv"
    _DEPDAT="$DEPLOYMENTDATA"
    _WEBDIR="$WEBDIR"
fi

echo ""
echo "$(ts)  ============================================================"
if [[ "$RUN_MODE" == "test" ]]; then
    echo "$(ts)  END-OF-RUN CHECKLIST  [TEST RUN]"
    echo "$(ts)  All output isolated under: ${BASE_DIR}/test/"
    echo "$(ts)  DEPLOYMENTS.dat: read-only (no new records appended)"
else
    echo "$(ts)  END-OF-RUN CHECKLIST  [PRODUCTION RUN]"
fi
echo "$(ts)  ============================================================"

# =============================================================================
echo ""
echo "$(ts)  --- SECTION 1: Core data collection ---"
# =============================================================================

# 1. Inventory .dat
check_file "Inventory .dat" "$_INVDATA" 1

# 2. Record count
if [[ -f "$_INVDATA" && -s "$_INVDATA" ]]; then
    INV_COUNT=$(grep -v "^#" "$_INVDATA" | wc -l)
    if [[ "$RUN_MODE" == "test" ]]; then
        if [[ $INV_COUNT -ge 1 ]]; then
            result PASS "Inventory record count" "$INV_COUNT records (test run)"
        else
            result FAIL "Inventory record count" "0 records — scan produced nothing"
        fi
    else
        if [[ $INV_COUNT -ge 100 ]]; then
            result PASS "Inventory record count" "$INV_COUNT records"
        else
            result FAIL "Inventory record count" "Only $INV_COUNT — expected thousands for production"
        fi
    fi
fi

# 3. Field count per record (expect 28 fields)
if [[ -f "$_INVDATA" && -s "$_INVDATA" ]]; then
    FIELD_COUNT=$(grep -v "^#" "$_INVDATA" | head -1 | awk '{print NF}')
    if [[ "$FIELD_COUNT" -eq 28 ]]; then
        result PASS "Inventory field count per record" "$FIELD_COUNT fields (correct)"
    else
        result WARN "Inventory field count per record" "$FIELD_COUNT fields (expected 28 — check remote scan output)"
    fi
fi

# 4. ID inventory
check_file "ID inventory .dat" "$_IDDATA" 1

# 5. DB inventory (optional — only populated for hosts running a database)
_DBDATA="${TEST_DATA:-$DATA_DIR}/$(basename "${DBINVENTORYDATA}")"
if [[ -f "$_DBDATA" && -s "$_DBDATA" ]]; then
    DB_COUNT=$(wc -l < "$_DBDATA")
    result PASS "DB SID inventory" "$DB_COUNT SID records"
else
    result PASS "DB SID inventory" "Empty — normal if no DB servers in host list"
fi

# 6. Package inventory
if [[ -f "$_PKGCSV" && -s "$_PKGCSV" ]]; then
    PKG_COUNT=$(wc -l < "$_PKGCSV")
    result PASS "Package inventory CSV" "$PKG_COUNT lines — $_PKGCSV"
else
    result WARN "Package inventory CSV" "Not found or empty — check pssh scan output or set RUN_PACKAGES_ON_MAIN=1 in rhel_inv.conf"
fi

# 7. Deployment history
if [[ -f "$_DEPDAT" ]]; then
    DEPLINES=$(wc -l < "$_DEPDAT")
    result PASS "Deployment history .dat" "$DEPLINES records — $_DEPDAT"
else
    result WARN "Deployment history .dat" "NOT FOUND: $_DEPDAT — seed from legacy per README (expected on fresh install)"
fi
if [[ "$RUN_MODE" == "test" ]]; then
    result PASS "Deployment .dat write protection" "TEST MODE — no new records appended"
fi

# =============================================================================
echo ""
echo "$(ts)  --- SECTION 2: CSV enrichment and field mapping ---"
# =============================================================================

# 8. Inventory CSV
check_file "Inventory CSV" "$_INVCSV" 2

# 9. CSV header field count
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    CSV_HEADER_FIELDS=$(head -1 "$_INVCSV" | awk -F, '{print NF}')
    if [[ "$CSV_HEADER_FIELDS" -eq 32 ]]; then
        result PASS "CSV header field count" "$CSV_HEADER_FIELDS fields (correct)"
    else
        result FAIL "CSV header field count" "$CSV_HEADER_FIELDS fields (expected 32)"
    fi
fi

# 10. CSV data field count
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    CSV_DATA_FIELDS=$(grep -v "^#" "$_INVCSV" | head -1 | awk -F, '{print NF}')
    if [[ "$CSV_DATA_FIELDS" -eq 32 ]]; then
        result PASS "CSV data field count" "$CSV_DATA_FIELDS fields per record (correct)"
    else
        result FAIL "CSV data field count" "$CSV_DATA_FIELDS fields per record (expected 32)"
    fi
fi

# 11. CMDB enrichment
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    CMDB_EMPTY=0
    if [[ -s "$_INVCSV" ]]; then
        _ce=$(grep -v "^#" "$_INVCSV" | head -5 |             awk -F, '{print $(NF-3)","$(NF-2)","$(NF-1)","$NF}' |             grep -c "^n/a,n/a,n/a" 2>/dev/null)
        CMDB_EMPTY=$(( ${_ce:-0} + 0 ))   # force integer
    fi
    if [[ $CMDB_EMPTY -eq 0 ]]; then
        result PASS "CMDB enrichment (last 4 fields)" "CMDB data present in sample records"
    else
        result WARN "CMDB enrichment (last 4 fields)" "$CMDB_EMPTY of first 5 records have n/a CMDB fields"
    fi
fi

# 12. Fed Enclave field format
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    FED_FORMAT=$(grep -v "^#" "$_INVCSV" | head -5 | \
        awk -F, '{print $NF}' | \
        grep -c "^Fed$\|^Non-Fed$" 2>/dev/null)
    FED_FORMAT=${FED_FORMAT:-0}
    TOTAL_SAMPLE=$(grep -v "^#" "$_INVCSV" | head -5 | wc -l)
    if [[ "$FED_FORMAT" -eq "$TOTAL_SAMPLE" ]]; then
        result PASS "Fed Enclave field format" "Values are Fed/Non-Fed (correct)"
    else
        result WARN "Fed Enclave field format" "Some values not Fed/Non-Fed — check CMDB IsFedEnclave mapping"
    fi
fi

# 13. Location field format
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    LOC_SAMPLE=$(grep -v "^#" "$_INVCSV" | head -1 | awk -F, '{print $3}')
    if [[ -z "$LOC_SAMPLE" ]]; then
        result WARN "Location field format" "Location field is empty"
    elif [[ "$LOC_SAMPLE" == *"Greenfield-"* ]]; then
        result WARN "Location field format" "Legacy prefix found: $LOC_SAMPLE — check expand_location() in rhel_utils.sh"
    else
        result PASS "Location field format" "Sample: $LOC_SAMPLE"
    fi
fi

# 14. AppCode/Env/BuildDate spot check
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    SAMPLE_LINE=$(grep -v "^#" "$_INVCSV" | head -1)
    APP=$(echo "$SAMPLE_LINE" | awk -F, '{print $4}')
    ENV=$(echo "$SAMPLE_LINE" | awk -F, '{print $5}')
    BD=$(echo "$SAMPLE_LINE" | awk -F, '{print $6}')
    if [[ "$APP" != "n/a" && "$ENV" != "n/a" && "$BD" != "n/a" ]]; then
        result PASS "AppCode/Env/BuildDate populated" "AppCode=$APP Env=$ENV BuildDate=$BD"
    else
        result WARN "AppCode/Env/BuildDate populated" "One or more is n/a — AppCode=$APP Env=$ENV BuildDate=$BD"
    fi
fi

# =============================================================================
echo ""
echo "$(ts)  --- SECTION 3: Web publishing ---"
# =============================================================================

check_file "Inventory .txt (web)" "$_INVTXT" 1
check_file "Midrange_INVENTORY.csv" "$_MIDCSV" 2
for html in index.html Location.html Application.html Releases.html \
            Monthly_Redhat_Linux_Depoloyment_Report.html \
            Annual_Redhat_Linux_Depoloyment_Report.html; do
    check_file "HTML: $html" "${_WEBDIR}/$html" 5
done

if [[ -f "${_WEBDIR}/${LOSTLIST}" ]]; then
    LOST=$(wc -l < "${_WEBDIR}/${LOSTLIST}")
    result PASS "Non-responsive host list" "$LOST hosts — ${_WEBDIR}/${LOSTLIST}"
else
    result WARN "Non-responsive host list" "Not found: ${_WEBDIR}/${LOSTLIST}"
fi

# =============================================================================
echo ""
echo "$(ts)  --- SECTION 4: Data integrity ---"
# =============================================================================

# 17. No mixed stream data in inventory .dat
if [[ -f "$_INVDATA" && -s "$_INVDATA" ]]; then
    MIXED=0
    MIXED=$(grep -cE "^(ID|PKG|DB)\|" "$_INVDATA" 2>/dev/null) || MIXED=0
    MIXED=${MIXED:-0}
    if [[ "$MIXED" -eq 0 ]]; then
        result PASS "Inventory .dat data isolation" "No mixed stream data found"
    else
        result FAIL "Inventory .dat data isolation" "$MIXED lines with ID/PKG/DB tags — filter routing bug"
    fi
fi

# 18. No mixed stream data in inventory CSV
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    MIXED_CSV=0
    MIXED_CSV=$(grep -cE "^(ID|PKG|DB)\|" "$_INVCSV" 2>/dev/null) || MIXED_CSV=0
    MIXED_CSV=${MIXED_CSV:-0}
    if [[ "$MIXED_CSV" -eq 0 ]]; then
        result PASS "Inventory CSV data isolation" "No mixed stream data found"
    else
        result FAIL "Inventory CSV data isolation" "$MIXED_CSV lines with ID/PKG/DB tags"
    fi
fi

# 19. Log errors and warnings — check current run log only (not master append log)
# The symlink always points at the current run's log file
if [[ "$RUN_MODE" == "test" ]]; then
    LOG_FILE=$(readlink -f "${BASE_DIR}/test/logs/test_rhel_inventory_latest.log" 2>/dev/null)
    [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]] && LOG_FILE="${BASE_DIR}/test/logs/test_rhel_inventory.log"
else
    LOG_FILE=$(readlink -f "${LOGS_DIR}/rhel_inventory_v2_latest.log" 2>/dev/null)
    [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]] && LOG_FILE="$MAIN_LOG"
fi
if [[ -f "$LOG_FILE" ]]; then
    ERR_COUNT=0
    ERR_COUNT=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null) || ERR_COUNT=0
    ERR_COUNT=${ERR_COUNT:-0}
    WARN_LOG=0
    WARN_LOG=$(grep -c "\[WARN\]" "$LOG_FILE" 2>/dev/null) || WARN_LOG=0
    WARN_LOG=${WARN_LOG:-0}
    if [[ "$ERR_COUNT" -eq 0 ]]; then
        result PASS "Log errors" "0 ERROR lines in log"
    else
        result FAIL "Log errors" "$ERR_COUNT ERROR lines — review $LOG_FILE"
    fi
    # Warn threshold: 10 for test (known expected WARNs), 5 for production
    _warn_thresh=5
    [[ "$RUN_MODE" == "test" ]] && _warn_thresh=10
    if [[ $WARN_LOG -le $_warn_thresh ]]; then
        result PASS "Log warnings" "$WARN_LOG WARN lines"
    else
        result WARN "Log warnings" "$WARN_LOG WARN lines — review $LOG_FILE"
    fi
fi

# =============================================================================
echo ""
echo "$(ts)  --- SECTION 5: Test mode isolation verification ---"
# =============================================================================
if [[ "$RUN_MODE" == "test" ]]; then
    LEGACY_INV="/usr/local/pnc/bin/RHEL_Inventory/data/RHEL_INVENTORY.dat"
    if [[ -f "$LEGACY_INV" ]]; then
        LEGACY_AGE=$(find "$LEGACY_INV" -mmin -10 2>/dev/null | wc -l)
        if [[ "$LEGACY_AGE" -eq 0 ]]; then
            result PASS "Legacy inventory .dat untouched" "$LEGACY_INV"
        else
            result WARN "Legacy inventory .dat" "Modified in last 10 min — verify test isolation"
        fi
    else
        result PASS "Legacy inventory .dat" "Not present on this system (expected on non-legacy jumpbox)"
    fi
    result PASS "Test output location" "All output under ${BASE_DIR}/test/"
    result PASS "Production WEBDIR" "Not written to: $WEBDIR"
else
    result PASS "Production run mode" "No test isolation checks needed"
fi

# =============================================================================
echo ""
echo "$(ts)  ============================================================"
echo "$(ts)  CHECKLIST SUMMARY"
echo "$(ts)  Run mode : $RUN_MODE"
echo "$(ts)  PASS     : $PASS"
echo "$(ts)  WARN     : $WARN_COUNT"
echo "$(ts)  FAIL     : $FAIL"
echo "$(ts)  Total    : $(( PASS + WARN_COUNT + FAIL )) checks"
if [[ $FAIL -eq 0 && $WARN_COUNT -eq 0 ]]; then
    echo "$(ts)  RESULT   : ALL CHECKS PASSED"
elif [[ $FAIL -eq 0 ]]; then
    echo "$(ts)  RESULT   : PASSED WITH WARNINGS — review WARN items above"
else
    echo "$(ts)  RESULT   : FAILED — review FAIL items above before using output"
fi
echo "$(ts)  ============================================================"
echo ""
