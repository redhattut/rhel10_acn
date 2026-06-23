#!/bin/bash
# =============================================================================
# rhel_fed_scan.sh — Fed Enclave host pssh scan (runs on lmrg34ba)
# =============================================================================
# Standalone script that runs on the Fed Enclave jumpbox (lmrg34ba).
# Called by AAP Task 2 after the fed host list has been written locally.
#
# Usage:
#   ./rhel_fed_scan.sh <fed_hosts_file>
#
# Arguments:
#   fed_hosts_file  — path to a file containing one hostname per line
#                     (written by AAP from the fed_host_list variable)
#
# Output:
#   /usr/local/pnc/bin/data/fed_enclave_raw.dat
#
# The output is a raw space-delimited INV dat file (same format as
# RHEL_INVENTORY_v2.dat) containing only the Fed Enclave hosts.
# CMDB enrichment is NOT done here — that happens on lmrg34ja in Phase 7
# after this file is fetched back by AAP and merged into the main dat.
#
# This script requires alongside it (in the same directory):
#   rhel_remote_scan.sh   — the remote scan script piped into pssh
#   rhel_filter_scan.sh   — the pssh output filter / stream splitter
#
# Exit codes:
#   0  — scan completed (even if some hosts timed out — they get TIMEOUT stubs)
#   1  — prerequisites missing
#   2  — host file missing or empty
#   3  — pssh scan produced no output at all
# =============================================================================

cd "$(dirname "$0")" || exit 1

PGMDIR="$(pwd)"
FED_HOSTS_FILE="$1"

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# --- Validate arguments ------------------------------------------------------
if [[ -z "$FED_HOSTS_FILE" ]]; then
    log ERROR "Usage: $0 <fed_hosts_file>"
    exit 1
fi

if [[ ! -f "$FED_HOSTS_FILE" ]]; then
    log ERROR "Fed hosts file not found: $FED_HOSTS_FILE"
    exit 2
fi

FED_COUNT=$(grep -vc "^#" "$FED_HOSTS_FILE" 2>/dev/null || echo 0)
if [[ $FED_COUNT -eq 0 ]]; then
    log ERROR "Fed hosts file is empty: $FED_HOSTS_FILE"
    exit 2
fi

# --- Validate prerequisites --------------------------------------------------
PSSH_BIN="/usr/local/pssh/bin/pssh"
if [[ ! -x "$PSSH_BIN" ]]; then
    log ERROR "pssh not found or not executable: $PSSH_BIN"
    exit 1
fi

if [[ ! -f "${PGMDIR}/rhel_remote_scan.sh" ]]; then
    log ERROR "rhel_remote_scan.sh not found in ${PGMDIR}"
    exit 1
fi

if [[ ! -x "${PGMDIR}/rhel_filter_scan.sh" ]]; then
    log ERROR "rhel_filter_scan.sh not found or not executable in ${PGMDIR}"
    exit 1
fi

# --- Paths -------------------------------------------------------------------
DATA_DIR="${PGMDIR}/data"
mkdir -p "$DATA_DIR"

FED_DAT_OUT="${DATA_DIR}/fed_enclave_raw.dat"
FED_ID_TMP="${DATA_DIR}/fed_enclave_id.tmp"
FED_DB_TMP="${DATA_DIR}/fed_enclave_db.tmp"
FED_PKG_TMP="${DATA_DIR}/fed_enclave_pkg.tmp"
ERRDIR="${DATA_DIR}/errdir_fed.$(date +%Y%m%d_%H%M)"
mkdir -p "$ERRDIR"

# Temp dat file — promoted atomically at end
FED_DAT_TMP="${DATA_DIR}/fed_enclave_raw.tmp"
rm -f "$FED_DAT_TMP" "$FED_ID_TMP" "$FED_DB_TMP" "$FED_PKG_TMP"

# pssh settings — same as main scan
PSSH_BATCH=75
PSSH_TIMEOUT=30
PSSH_LOGIN="root"
PSSH_OPTS="-I --inline-stdout -p ${PSSH_BATCH} -t ${PSSH_TIMEOUT} -l ${PSSH_LOGIN}"

log INFO "=== Fed Enclave Scan starting ==="
log INFO "Host file  : $FED_HOSTS_FILE ($FED_COUNT hosts)"
log INFO "Output     : $FED_DAT_OUT"
log INFO "pssh       : batch=$PSSH_BATCH timeout=${PSSH_TIMEOUT}s"

# --- Run pssh scan -----------------------------------------------------------
log INFO "Launching pssh scan against Fed Enclave hosts..."

START_TIME=$(date +%s)

cat "${PGMDIR}/rhel_remote_scan.sh" \
    | "$PSSH_BIN" $PSSH_OPTS \
        -e "$ERRDIR" \
        -h "$FED_HOSTS_FILE" \
        -x "-q -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=30" \
        bash \
    | "${PGMDIR}/rhel_filter_scan.sh" \
        "$FED_DAT_TMP" \
        "$FED_ID_TMP" \
        "$FED_DB_TMP" \
        "$FED_PKG_TMP"

SCAN_RC=$?
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
log INFO "pssh scan completed in ${ELAPSED}s (exit status: $SCAN_RC)"

# Remove zero-size error files
if [[ -d "$ERRDIR" && "$ERRDIR" =~ errdir ]]; then
    ERRCOUNT_BEFORE=$(find "$ERRDIR" -type f | wc -l)
    find "$ERRDIR" -type f -size 0 | xargs rm -f 2>/dev/null
    ERRCOUNT_AFTER=$(find "$ERRDIR" -type f | wc -l)
    TIMEOUT_COUNT=$(( ERRCOUNT_BEFORE - ERRCOUNT_AFTER ))
    log INFO "Scan results: $TIMEOUT_COUNT hosts had errors/timeouts, $ERRCOUNT_AFTER error files kept"
fi

# --- Validate output ---------------------------------------------------------
if [[ ! -s "$FED_DAT_TMP" ]]; then
    log ERROR "Fed scan produced no output — aborting"
    exit 3
fi

INV_COUNT=$(wc -l < "$FED_DAT_TMP")
log INFO "Collected $INV_COUNT INV records from Fed Enclave hosts"

# --- Promote output ----------------------------------------------------------
mv "$FED_DAT_TMP" "$FED_DAT_OUT"
log INFO "Fed Enclave dat promoted: $FED_DAT_OUT"

# Clean up temp files — ID/DB/PKG data not used from fed scan
rm -f "$FED_ID_TMP" "$FED_DB_TMP" "$FED_PKG_TMP"

# Clean up stale error directories older than 7 days
find "$PGMDIR" -type d -name "errdir_fed*" -mtime +7 \
    -exec rm -rf '{}' \; 2>/dev/null

log INFO "=== Fed Enclave Scan complete ==="
log INFO "Output ready for AAP fetch: $FED_DAT_OUT"

exit 0
