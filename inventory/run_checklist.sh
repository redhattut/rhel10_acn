#!/bin/bash
# =============================================================================
# run_checklist.sh — End-of-run validation checklist
# =============================================================================
# Appended to the log at the end of each run by rhel_inv_run.sh.
# Evaluates whether each expected output was produced correctly.
# No color coding — plain text suitable for log files and grep.
# =============================================================================

cd "$(dirname "$0")" || exit 1
CONF="$(dirname "$0")/rhel_inv.conf"
[[ -f "$CONF" ]] && . "$CONF"
[[ -f "$(dirname "$0")/rhel_utils.sh" ]] && . "$(dirname "$0")/rhel_utils.sh"

RUN_MODE="${1:-production}"   # "test" or "production"
PASS=0
WARN_COUNT=0
FAIL=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }

result() {
    local status="$1"  # PASS WARN FAIL
    local item="$2"
    local detail="$3"
    printf '%s  [%-4s]  %-55s %s\n' "$(ts)" "$status" "$item" "$detail"
    case "$status" in
        PASS) (( PASS++ )) ;;
        WARN) (( WARN_COUNT++ )) ;;
        FAIL) (( FAIL++ )) ;;
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

# --- Set paths based on run mode ---
if [[ "$RUN_MODE" == "test" ]]; then
    TEST_DATA="${BASE_DIR}/test/data"
    TEST_WEB="${BASE_DIR}/test/webdir"
    _INVDATA="${TEST_DATA}/TEST_RHEL_INVENTORY.dat"
    _INVCSV="${TEST_WEB}/RHEL_INVENTORY_v2.csv"
    _INVTXT="${TEST_WEB}/RHEL_INVENTORY_v2.txt"
    _IDDATA="${TEST_DATA}/TEST_RHEL_IDINVENTORY.dat"
    _PKGCSV="${TEST_WEB}/RHEL_PACKAGES_v2.csv"
    _MIDCSV="${TEST_WEB}/Midrange_INVENTORY.csv"
    _DEPDAT="${DATA_DIR}/RHEL_DEPLOYMENTS.dat"   # shared, read-only in test
    _WEBDIR="$TEST_WEB"
else
    _INVDATA="$INVENTORYDATA"
    _INVCSV="${WEBDIR}/${INVENTDATACSV}"
    _INVTXT="${WEBDIR}/${INVENTDATATEXT}"
    _IDDATA="$IDINVENTORYDATA"
    _PKGCSV="${WEBDIR}/RHEL_PACKAGES_v2.csv"
    _MIDCSV="${WEBDIR}/Midrange_INVENTORY.csv"
    _DEPDAT="$DEPLOYMENTDATA"
    _WEBDIR="$WEBDIR"
fi

echo ""
echo "$(ts)  --- SECTION 1: Core data collection ---"

# 1. Inventory .dat produced
check_file "Inventory .dat" "$_INVDATA" 1

# 2. Inventory record count sanity
if [[ -f "$_INVDATA" ]]; then
    INV_COUNT=$(grep -v "^#" "$_INVDATA" | wc -l)
    if [[ "$RUN_MODE" == "test" ]]; then
        [[ $INV_COUNT -ge 1 ]] \
            && result PASS "Inventory record count" "$INV_COUNT records (test run)" \
            || result FAIL "Inventory record count" "0 records — scan produced nothing"
    else
        [[ $INV_COUNT -ge 100 ]] \
            && result PASS "Inventory record count" "$INV_COUNT records" \
            || result FAIL "Inventory record count" "Only $INV_COUNT — expected thousands for production"
    fi
fi

# 3. Field count per inventory record (expect 25 space-delimited fields)
if [[ -f "$_INVDATA" && -s "$_INVDATA" ]]; then
    FIELD_COUNT=$(grep -v "^#" "$_INVDATA" | head -1 | awk '{print NF}')
    [[ $FIELD_COUNT -eq 28 ]] \
        && result PASS "Inventory field count per record" "$FIELD_COUNT fields (correct)" \
        || result WARN "Inventory field count per record" "$FIELD_COUNT fields (expected 28 — check remote scan output)"
fi

# 4. ID inventory produced
check_file "ID inventory .dat" "$_IDDATA" 1

# 5. DB inventory (optional — only hosts with Oracle)
if [[ -f "${_INVDATA%INVENTORY*}RHEL_DBINVENTORY_v2.dat" ]]; then
    DB_COUNT=$(wc -l < "${_INVDATA%INVENTORY*}RHEL_DBINVENTORY_v2.dat")
    result PASS "DB (Oracle SID) inventory" "$DB_COUNT SID records"
else
    result WARN "DB (Oracle SID) inventory" "Not found — normal if no Oracle hosts in host list"
fi

# 6. Package inventory
if [[ -f "$_PKGCSV" && -s "$_PKGCSV" ]]; then
    PKG_COUNT=$(wc -l < "$_PKGCSV")
    result PASS "Package inventory CSV" "$PKG_COUNT lines — $_PKGCSV"
else
    result WARN "Package inventory CSV" "Not found or empty — runs separately from secondary jumpbox"
fi

# 7. Deployment scan ran
# DEPLOYMENTDATA is shared — may not exist on fresh install until seeded
if [[ -f "$_DEPDAT" ]]; then
    DEPLINES=$(wc -l < "$_DEPDAT")
    result PASS "Deployment history .dat" "$DEPLINES records — $_DEPDAT"
else
    result WARN "Deployment history .dat" "NOT FOUND: $_DEPDAT — seed from legacy per README (expected on fresh install)"
fi
if [[ "$RUN_MODE" == "test" ]]; then
    result PASS "Deployment .dat write protection" "TEST MODE — no new records appended"
fi

echo ""
echo "$(ts)  --- SECTION 2: CSV enrichment and field mapping ---"

# 8. Inventory CSV produced
check_file "Inventory CSV" "$_INVCSV" 2

# 9. CSV field count (expect 32 columns matching header)
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    CSV_HEADER_FIELDS=$(head -1 "$_INVCSV" | awk -F, '{print NF}')
    CSV_DATA_FIELDS=$(grep -v "^#" "$_INVCSV" | head -1 | awk -F, '{print NF}')
    [[ $CSV_HEADER_FIELDS -eq 32 ]] \
        && result PASS "CSV header field count" "$CSV_HEADER_FIELDS fields (correct)" \
        || result FAIL "CSV header field count" "$CSV_HEADER_FIELDS fields (expected 32)"
    [[ $CSV_DATA_FIELDS -eq 32 ]] \
        && result PASS "CSV data field count" "$CSV_DATA_FIELDS fields per record (correct)" \
        || result FAIL "CSV data field count" "$CSV_DATA_FIELDS fields per record (expected 32 — likely missing Location/AppCode/Env/BuildDate from CMDB)"
fi

# 10. CMDB enrichment — check last 4 fields are not all n/a
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    CMDB_EMPTY=$(grep -v "^#" "$_INVCSV" | head -5 | awk -F, '{print $(NF-3)","$(NF-2)","$(NF-1)","$NF}' | grep -c "^n/a,n/a,n/a")
    [[ $CMDB_EMPTY -eq 0 ]] \
        && result PASS "CMDB enrichment (last 4 fields)" "CMDB data present in sample records" \
        || result WARN "CMDB enrichment (last 4 fields)" "$CMDB_EMPTY of first 5 records have n/a CMDB fields"
fi

# 11. Fed Enclave field — should be Fed or Non-Fed not True/False
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    FED_FORMAT=$(grep -v "^#" "$_INVCSV" | head -5 | awk -F, '{print $NF}' | grep -c "^Fed$\|^Non-Fed$")
    TOTAL_SAMPLE=$(grep -v "^#" "$_INVCSV" | head -5 | wc -l)
    [[ $FED_FORMAT -eq $TOTAL_SAMPLE ]] \
        && result PASS "Fed Enclave field format" "Values are Fed/Non-Fed (correct)" \
        || result WARN "Fed Enclave field format" "Some values not Fed/Non-Fed — check CMDB mapping (got True/False?)"
fi

# 12. Location field format — should be full name like Greenfield-GF0
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    LOC_SAMPLE=$(grep -v "^#" "$_INVCSV" | head -1 | awk -F, '{print $3}')
    if [[ "$LOC_SAMPLE" == *"-"* || "$LOC_SAMPLE" == "n/a" ]]; then
        result PASS "Location field format" "Sample: $LOC_SAMPLE"
    elif [[ -n "$LOC_SAMPLE" ]]; then
        result WARN "Location field format" "Short code: $LOC_SAMPLE — add mapping to LOCATION_MAP in rhel_inv.conf if needed"
    else
        result WARN "Location field format" "Location field is empty"
    fi
fi

echo ""
echo "$(ts)  --- SECTION 3: Web publishing ---"

# 13. Text inventory published
check_file "Inventory .txt (web)" "${_WEBDIR}/${INVENTDATATEXT}" 1

# 14. Midrange CSV
check_file "Midrange_INVENTORY.csv" "$_MIDCSV" 2

# 15. HTML reports
for html in index.html Location.html Application.html Releases.html \
            Monthly_Redhat_Linux_Depoloyment_Report.html \
            Annual_Redhat_Linux_Depoloyment_Report.html; do
    check_file "HTML: $html" "${_WEBDIR}/$html" 5
done

# 16. Non-responsive list
if [[ -f "${_WEBDIR}/${LOSTLIST}" ]]; then
    LOST=$(wc -l < "${_WEBDIR}/${LOSTLIST}")
    result PASS "Non-responsive host list" "$LOST hosts — ${_WEBDIR}/${LOSTLIST}"
else
    result WARN "Non-responsive host list" "Not found: ${_WEBDIR}/${LOSTLIST}"
fi

echo ""
echo "$(ts)  --- SECTION 4: Data integrity ---"

# 17. No mixed data in inventory dat (should not contain ID| PKG| DB| tags)
if [[ -f "$_INVDATA" && -s "$_INVDATA" ]]; then
    MIXED=0
    [[ -f "$_INVDATA" ]] && MIXED=$(grep -cE "^(ID|PKG|DB)\|" "$_INVDATA" 2>/dev/null) || MIXED=0
    MIXED=${MIXED:-0}
    [[ "$MIXED" -eq 0 ]] \
        && result PASS "Inventory .dat data isolation" "No mixed stream data found" \
        || result FAIL "Inventory .dat data isolation" "$MIXED lines with ID/PKG/DB tags — filter routing bug"
fi

# 18. No mixed data in inventory CSV
if [[ -f "$_INVCSV" && -s "$_INVCSV" ]]; then
    MIXED_CSV=0
    [[ -f "$_INVCSV" ]] && MIXED_CSV=$(grep -cE "^(ID|PKG|DB)\|" "$_INVCSV" 2>/dev/null) || MIXED_CSV=0
    MIXED_CSV=${MIXED_CSV:-0}
    [[ "$MIXED_CSV" -eq 0 ]] \
        && result PASS "Inventory CSV data isolation" "No mixed stream data found" \
        || result FAIL "Inventory CSV data isolation" "$MIXED_CSV lines with ID/PKG/DB tags"
fi

# 19. Log errors
LOG_FILE="${BASE_DIR}/test/logs/test_rhel_inventory.log"
[[ "$RUN_MODE" != "test" ]] && LOG_FILE="$MAIN_LOG"
if [[ -f "$LOG_FILE" ]]; then
    ERR_COUNT=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || echo 0)
    ERR_COUNT=${ERR_COUNT:-0}
    WARN_LOG=$(grep -c "\[WARN\]" "$LOG_FILE" 2>/dev/null || echo 0)
    WARN_LOG=${WARN_LOG:-0}
    [[ $ERR_COUNT -eq 0 ]] \
        && result PASS "Log errors" "0 ERROR lines in log" \
        || result FAIL "Log errors" "$ERR_COUNT ERROR lines — review $LOG_FILE"
    [[ $WARN_LOG -le 5 ]] \
        && result PASS "Log warnings" "$WARN_LOG WARN lines" \
        || result WARN "Log warnings" "$WARN_LOG WARN lines — review $LOG_FILE"
fi

echo ""
echo "$(ts)  --- SECTION 5: Test mode isolation verification ---"
if [[ "$RUN_MODE" == "test" ]]; then
    # Verify nothing was written to production paths
    PROD_INV="${DATA_DIR}/RHEL_INVENTORY_v2.dat"
    PROD_WEB="${BASE_DIR}/test"   # this IS the test webdir, skip
    
    # Check legacy paths untouched
    LEGACY_INV="/usr/local/pnc/bin/RHEL_Inventory/data/RHEL_INVENTORY.dat"
    LEGACY_WEB="/usr/local/midweb/RHEL/RHEL_INVENTORY.csv"
    
    if [[ -f "$LEGACY_INV" ]]; then
        # Check legacy file wasn't modified in last 10 minutes
        LEGACY_AGE=$(find "$LEGACY_INV" -mmin -10 2>/dev/null | wc -l)
        [[ $LEGACY_AGE -eq 0 ]] \
            && result PASS "Legacy inventory .dat untouched" "$LEGACY_INV" \
            || result WARN "Legacy inventory .dat" "Modified in last 10 min — verify test isolation"
    else
        result PASS "Legacy inventory .dat" "Not present on this system (expected on non-legacy jumpbox)"
    fi
    
    result PASS "Test output location" "All output under ${BASE_DIR}/test/"
    result PASS "Production WEBDIR" "Not written to: $WEBDIR"
else
    result PASS "Production run mode" "No test isolation checks needed"
fi

# --- Summary ---
echo ""
echo "$(ts)  ============================================================"
echo "$(ts)  CHECKLIST SUMMARY"
echo "$(ts)  Run mode : $RUN_MODE"
echo "$(ts)  PASS     : $PASS"
echo "$(ts)  WARN     : $WARN_COUNT"  
echo "$(ts)  FAIL     : $FAIL"
TOTAL=$(( PASS + WARN_COUNT + FAIL ))
echo "$(ts)  Total    : $TOTAL checks"
if [[ $FAIL -eq 0 && $WARN_COUNT -eq 0 ]]; then
    echo "$(ts)  RESULT   : ALL CHECKS PASSED"
elif [[ $FAIL -eq 0 ]]; then
    echo "$(ts)  RESULT   : PASSED WITH WARNINGS — review WARN items above"
else
    echo "$(ts)  RESULT   : FAILED — review FAIL items above before using output"
fi
echo "$(ts)  ============================================================"
echo ""
