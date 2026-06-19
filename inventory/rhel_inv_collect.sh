#!/bin/bash
# =============================================================================
# rhel_inv_collect.sh — Main RHEL Inventory collection pipeline
# =============================================================================
# Replaces: RHEL_inventory_refresh.sh
#
# Pipeline overview:
#   1.  Source config and set up logging
#   2.  Run deployment scan for newly seen hosts (rhel_deploy_scan.sh)
#   3.  Clean up temp files from any prior incomplete run
#   4.  Single pssh sweep across all hosts via rhel_remote_scan.sh
#       — one SSH connection per host, tagged output lines split into:
#           INV|  → RHEL_INVENTORY.tmp      (system inventory)
#           ID|   → RHEL_IDINVENTORY.tmp    (users/groups/netgroups)
#           DB|   → RHEL_DBINVENTORY.tmp    (Oracle SIDs)
#           PKG|  → RHEL_PACKAGES.tmp       (RPM package list)
#   5.  Strip pssh status lines via rhel_filter_scan.sh
#   6.  Rotate prior data files, promote temps to current
#   7.  Collect UIDs/GIDs
#   8.  Enrich inventory CSV with CMDB fields
#   9.  Publish to web directory
#   10. Convert inventory to HTML table
#   11. Rotate historical CSV copies
#   12. Clean up stale error directories
# =============================================================================

cd "$(dirname "$0")" || exit 1

# --- Source config -----------------------------------------------------------
CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found at ${CONF}" >&2
    exit 1
fi
. "$CONF"

# --- Source utility library -------------------------------------------------
UTILS="$(dirname "$0")/rhel_utils.sh"
if [[ ! -f "$UTILS" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_utils.sh not found at ${UTILS}" >&2
    exit 1
fi
. "$UTILS"

# --- Logging (mirrors rhel_inv_run.sh log function) --------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$level" in
        SECTION) printf '\n%s  === %s ===\n'   "$ts" "$msg" ;;
        INFO)    printf '%s  [INFO]    %s\n'   "$ts" "$msg" ;;
        WARN)    printf '%s  [WARN]    %s\n'   "$ts" "$msg" ;;
        ERROR)   printf '%s  [ERROR]   %s\n'   "$ts" "$msg" ;;
        *)       printf '%s  [INFO]    %s\n'   "$ts" "$msg" ;;
    esac
}

export PGMDIR
PGMDIR="$(pwd)"
export PATH=/usr/local/bin:$PATH
umask 0002

# --- Validate prerequisites --------------------------------------------------
log SECTION "Pre-flight checks"

if [[ ! -f "$MASTERHOSTLIST" ]]; then
    log ERROR "Host list not found: $MASTERHOSTLIST"
    exit 1
fi

HOSTCOUNT=$(grep -v "^#" "$MASTERHOSTLIST" | wc -l)
log INFO "Host list  : $MASTERHOSTLIST ($HOSTCOUNT hosts)"

if [[ -z "$CMDBDATAFILE" || ! -f "$CMDBDATAFILE" ]]; then
    log WARN "CMDB data file not found — CSV will be generated without CMDB enrichment"
    log WARN "Expected pattern: /home/xaascpau/20*cmdb_ci_linux_server.csv"
    CMDB_AVAILABLE=0
else
    log INFO "CMDB file  : $CMDBDATAFILE ($(wc -l < "$CMDBDATAFILE") records)"
    CMDB_AVAILABLE=1
fi

if [[ ! -x "$PSSH_BIN" ]]; then
    log ERROR "pssh binary not found or not executable: $PSSH_BIN"
    exit 1
fi

mkdir -p "$DATA_DIR" "$ERRDIR"
log INFO "Error log dir: $ERRDIR"

# =============================================================================
log SECTION "Phase 1 — Deployment scan (new host detection)"
# =============================================================================

if [[ -x "${PGMDIR}/rhel_deploy_scan.sh" ]]; then
    log INFO "Starting deployment scan"
    "${PGMDIR}/rhel_deploy_scan.sh"
    DEPLOY_RC=$?
    if [[ $DEPLOY_RC -ne 0 ]]; then
        log WARN "Deployment scan exited with status $DEPLOY_RC — continuing"
    else
        log INFO "Deployment scan complete"
    fi
else
    log WARN "rhel_deploy_scan.sh not found — skipping new host detection"
fi

# Build the deployment CSV for the web (sorted, unknown entries stripped)
if [[ -f "$DEPLOYMENTDATA" ]]; then
    echo "Date Deployed,Host,Type,OS" > "$DEPLOYDATACSV"
    sort "$DEPLOYMENTDATA" \
        | grep -v "^unknown" \
        | sed 's/ /,/g' \
        >> "$DEPLOYDATACSV"
    log INFO "Deployment CSV updated: $DEPLOYDATACSV"
fi

# =============================================================================
log SECTION "Phase 2 — Cleanup before scan"
# =============================================================================

rm -f "$INVENTORYTEMP" "$DBINVENTORYTEMP" "$IDINVENTORYTEMP" "$PACKAGETEMP"
log INFO "Cleared stale temp files"

# =============================================================================
log SECTION "Phase 3 — Parallel SSH scan (single hop, all data streams)"
# =============================================================================

LINES=$(grep -v "^#" "$MASTERHOSTLIST" | wc -l)
log INFO "Scanning $LINES hosts from $MASTERHOSTLIST"
log INFO "pssh batch size : $PSSH_BATCH"
log INFO "pssh timeout    : ${PSSH_TIMEOUT}s per host"
log INFO "pssh error dir  : $ERRDIR"
log INFO "Writing web data to: $WEBDIR"

# The remote script outputs tagged lines:
#   INV|...   system inventory record
#   PKG|...   one line per installed RPM
#   DB|...    Oracle SID list
#   ID|...    user/group/netgroup records
#
# rhel_filter_scan.sh strips pssh status noise then splits by tag into
# the four temp files.

log INFO "Launching pssh scan..."

cat "${PGMDIR}/rhel_remote_scan.sh" \
    | "$PSSH_BIN" $PSSH_OPTS \
        -e "$ERRDIR" \
        -h "$MASTERHOSTLIST" \
        -x "-q -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=30" \
        bash \
    | "${PGMDIR}/rhel_filter_scan.sh" \
        "$INVENTORYTEMP" \
        "$IDINVENTORYTEMP" \
        "$DBINVENTORYTEMP" \
        "$PACKAGETEMP"

SCAN_RC=$?
log INFO "pssh scan completed (exit status: $SCAN_RC)"

# Remove zero-size error files — only keep hosts that actually had errors
if [[ -d "$ERRDIR" && "$ERRDIR" =~ errdir ]]; then
    ERRCOUNT_BEFORE=$(find "$ERRDIR" -type f | wc -l)
    find "$ERRDIR" -type f -size 0 | xargs rm -f
    ERRCOUNT_AFTER=$(find "$ERRDIR" -type f | wc -l)
    log INFO "Error dir cleanup: removed $((ERRCOUNT_BEFORE - ERRCOUNT_AFTER)) empty files, $ERRCOUNT_AFTER hosts had errors"
fi

log INFO "Scan complete"

# Validate we actually got output
for tmpfile in "$INVENTORYTEMP" "$IDINVENTORYTEMP" "$DBINVENTORYTEMP" "$PACKAGETEMP"; do
    if [[ ! -s "$tmpfile" ]]; then
        log WARN "Output file is empty or missing: $tmpfile"
    else
        COUNT=$(wc -l < "$tmpfile")
        log INFO "$(basename "$tmpfile"): $COUNT lines collected"
    fi
done

# --- Delta check — compare new inventory count against prior run -------------
# Warns if the number of responding hosts drops by more than INV_DELTA_WARN_PCT
# percent versus the previous dat file. Catches partial scan failures, pssh
# misconfigurations, or mass SSH outages before the bad data is promoted.
# Set INV_DELTA_WARN_PCT in rhel_inv.conf to tune the threshold (default 5%).

INV_DELTA_WARN_PCT="${INV_DELTA_WARN_PCT:-5}"

if [[ -f "$INVENTORYDATA" && -s "$INVENTORYDATA" ]]; then
    PREV_COUNT=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
    NEW_COUNT=$(wc -l < "$INVENTORYTEMP")

    if [[ $PREV_COUNT -gt 0 && $NEW_COUNT -gt 0 ]]; then
        # Calculate percentage drop using integer arithmetic (bash has no float)
        # DROP_PCT = ((PREV - NEW) * 100) / PREV
        DIFF=$(( PREV_COUNT - NEW_COUNT ))

        if [[ $DIFF -gt 0 ]]; then
            DROP_PCT=$(( (DIFF * 100) / PREV_COUNT ))
            if [[ $DROP_PCT -ge $INV_DELTA_WARN_PCT ]]; then
                log WARN "Inventory count dropped ${DROP_PCT}% vs prior run — previous: ${PREV_COUNT}  new: ${NEW_COUNT}  delta: -${DIFF}"
                log WARN "Threshold is ${INV_DELTA_WARN_PCT}% — verify scan health before trusting this run's output"
                log WARN "Check error dir: $ERRDIR"
            else
                log INFO "Inventory delta check passed — previous: ${PREV_COUNT}  new: ${NEW_COUNT}  delta: -${DIFF} (${DROP_PCT}% drop, within ${INV_DELTA_WARN_PCT}% threshold)"
            fi
        elif [[ $DIFF -lt 0 ]]; then
            # Count went up — new hosts added, always fine
            log INFO "Inventory delta check — previous: ${PREV_COUNT}  new: ${NEW_COUNT}  delta: +$(( NEW_COUNT - PREV_COUNT )) (growth)"
        else
            log INFO "Inventory delta check — count unchanged at ${NEW_COUNT}"
        fi
    fi
else
    log INFO "No prior inventory data found — skipping delta check (first run)"
fi

# =============================================================================
log SECTION "Phase 4 — Rotate prior data files, promote temps"
# =============================================================================

# Rotate the previous inventory data (keeps compressed history for discovery)
log INFO "Rotating RHEL_INVENTORY.dat (keeping $ROTATE_INVENTORY copies)"
rotate_compressed "$INVENTORYDATA" "$ROTATE_INVENTORY"
mv "$INVENTORYTEMP" "$INVENTORYDATA"
log INFO "INVENTORYDATA updated"

log INFO "Rotating RHEL_DBINVENTORY.dat (keeping $ROTATE_DBINVENTORY copies)"
rotate_compressed "$DBINVENTORYDATA" "$ROTATE_DBINVENTORY"
mv "$DBINVENTORYTEMP" "$DBINVENTORYDATA"
log INFO "DBINVENTORYDATA updated"

# ID inventory: keep 3 compressed copies for the discovery process
log INFO "Rotating RHEL_IDINVENTORY.dat (keeping $ROTATE_IDINVENTORY copies)"
rotate_compressed "$IDINVENTORYDATA" "$ROTATE_IDINVENTORY"
mv "$IDINVENTORYTEMP" "$IDINVENTORYDATA"
log INFO "IDINVENTORYDATA updated"

# Package inventory: keep more copies since it's used for grep searches
log INFO "Rotating RHEL_PACKAGES.csv (keeping $ROTATE_PACKAGES copies)"
rotate_compressed "$PACKAGEDATA" "$ROTATE_PACKAGES"
mv "$PACKAGETEMP" "$PACKAGEDATA"
cp -p "$PACKAGEDATA" "$WEBDIR/"
log INFO "PACKAGEDATA updated and published to $WEBDIR"

# =============================================================================
log SECTION "Phase 5 — Collect UIDs and GIDs"
# =============================================================================

if [[ -x "${PGMDIR}/RHEL_ID_Collect_uids.sh" ]]; then
    log INFO "Collecting UID/GID data"
    "${PGMDIR}/RHEL_ID_Collect_uids.sh"
    # Publish UID/GID data to web
    cp -p data/RHEL_UIDINVENTORY.dat "$WEBDIR/RHEL_UIDINVENTORY.dat"
    cp -p data/RHEL_GIDINVENTORY.dat "$WEBDIR/RHEL_GIDINVENTORY.dat"
    # Publish ID inventory CSV for discovery
    cp -p "$IDINVENTORYDATA" "$WEBDIR/RHEL_IDINVENTORY.csv"
    log INFO "UID/GID data collected and published"
else
    log WARN "RHEL_ID_Collect_uids.sh not found — skipping UID/GID collection"
fi

# =============================================================================
log SECTION "Phase 6 — Convert inventory to text and HTML"
# =============================================================================

cp -p "$INVENTORYDATA" "$WEBDIR/$INVENTDATATEXT"
log INFO "Text copy published: $WEBDIR/$INVENTDATATEXT"

if [[ -x "${PGMDIR}/convert_text_to_html_table.sh" ]]; then
    cat "$INVENTORYDATA" \
        | "${PGMDIR}/convert_text_to_html_table.sh" \
        > "$WEBDIR/$INVENTDATAHTML"
    log INFO "HTML table published: $WEBDIR/$INVENTDATAHTML"
else
    log WARN "convert_text_to_html_table.sh not found — skipping HTML conversion"
fi

# =============================================================================
log SECTION "Phase 7 — CMDB enrichment and CSV generation"
# =============================================================================

# CSV header — matches original column order exactly
CSV_HEADER="#Host (Inventory Run complete $(date)),Type,Location,App Code,Environment,Build Date,OS,Kernel,Architecture,Memory(MB),CPU Sockets,CPU Cores,CPU Threads,CPU Type,CPU Speed,Server Vendor,Server Model,Serial Num,Syslog-ng,Uptime(days),VMToolsVer,VMToolsRun,LastBackupDate,IP Address,CI Device,vCenter server,BuildType,DBType,CMDB Support Group,CMDB Install Status,CMDB Desired Operational State,Fed Enclave"

echo "$CSV_HEADER" > "${DATA_DIR}/${INVENTDATACSV}.new"

if [[ $CMDB_AVAILABLE -eq 1 ]]; then
    log INFO "Enriching CSV with CMDB data from: $CMDBDATAFILE"
    CMDB_MATCHED=0
    CMDB_MISSING=0

    while read -r line; do
        # Replace spaces with commas (inventory dat is space-delimited)
        newline=$(echo "$line" | sed 's/ /,/g')

        # Extract hostname (first field)
        h=$(echo "$line" | awk '{print $1}')

        # Look up this host in the CMDB extract
        # CMDB CSV format: col2=Support Group, col3=Install Status,
        #                  col4=Desired Operational State, col5=Fed Enclave
        CMDBinfo=$(grep "^${h}," "$CMDBDATAFILE" \
            | sed 's/\r$//' \
            | awk -F, '{print $2","$3","$4","$5}')

        # Default all four fields to n/a if host not in CMDB
        CMDBinfo="${CMDBinfo:-n/a,n/a,n/a,n/a}"

        C1=$(echo "$CMDBinfo" | awk -F, '{print $1}'); C1="${C1:-n/a}"
        C2=$(echo "$CMDBinfo" | awk -F, '{print $2}'); C2="${C2:-n/a}"
        C3=$(echo "$CMDBinfo" | awk -F, '{print $3}'); C3="${C3:-n/a}"
        C4=$(echo "$CMDBinfo" | awk -F, '{print $4}'); C4="${C4:-n/a}"

        if [[ "$CMDBinfo" == "n/a,n/a,n/a,n/a" ]]; then
            (( CMDB_MISSING++ ))
        else
            (( CMDB_MATCHED++ ))
        fi

        echo "${newline},${C1},${C2},${C3},${C4}" >> "${DATA_DIR}/${INVENTDATACSV}.new"
    done < "$INVENTORYDATA"

    log INFO "CMDB enrichment complete — matched: $CMDB_MATCHED, not in CMDB: $CMDB_MISSING"
else
    # No CMDB data — write CSV with n/a for all four CMDB columns
    log WARN "Generating CSV without CMDB enrichment (n/a for all CMDB fields)"
    while read -r line; do
        newline=$(echo "$line" | sed 's/ /,/g')
        echo "${newline},n/a,n/a,n/a,n/a" >> "${DATA_DIR}/${INVENTDATACSV}.new"
    done < "$INVENTORYDATA"
fi

# Atomic promotion — eliminates the window where the CSV is incomplete
# (the previous approach had a 5-minute window of incomplete file)
cp "${DATA_DIR}/${INVENTDATACSV}.new" "${DATA_DIR}/$INVENTDATACSV"
cp "${DATA_DIR}/${INVENTDATACSV}.new" "${WEBDIR}/$INVENTDATACSV"
rm -f "${DATA_DIR}/${INVENTDATACSV}.new"
log INFO "CSV published: $WEBDIR/$INVENTDATACSV"

# =============================================================================
log SECTION "Phase 8 — Rotate historical CSV copies"
# =============================================================================

# Keep 14 copies in webdir historical_data (2 weeks)
mkdir -p "${WEBDIR}/historical_data"
cp "${WEBDIR}/$INVENTDATACSV" \
    "${WEBDIR}/historical_data/${INVENTDATACSV}" 2>/dev/null
rotate_plain "${WEBDIR}/historical_data/RHEL_INVENTORY" "$ROTATE_INVENTORY_CSV" -e ".csv" \
    && log INFO "Historical CSV rotation complete (keeping $ROTATE_INVENTORY_CSV copies)"

# Keep 3 compressed local copies for discovery scans
rotate_compressed "${DATA_DIR}/$INVENTDATACSV" "$ROTATE_INVENTORY_CSV" \
    && log INFO "Local CSV rotation complete (keeping $ROTATE_INVENTORY_CSV copies)"

# =============================================================================
log SECTION "Phase 9 — Inventory Consolidation (Midrange)"
# =============================================================================

if [[ -x "${PGMDIR}/rhel_inv_consolidate.sh" ]]; then
    log INFO "Generating Midrange inventory consolidation"
    "${PGMDIR}/rhel_inv_consolidate.sh"
    log INFO "Consolidation complete"
else
    log WARN "rhel_inv_consolidate.sh not found — skipping"
fi

# =============================================================================
log SECTION "Phase 10 — Stale error directory cleanup"
# =============================================================================

# Remove errdir directories older than ERRDIR_RETAIN_DAYS
CLEANED=$(find "$PGMDIR" \
    -type d \
    -name "errdir*" \
    -mtime +"$ERRDIR_RETAIN_DAYS" \
    -ls \
    -exec rm -rf '{}' \; 2>/dev/null | wc -l)
log INFO "Removed $CLEANED stale error directories older than ${ERRDIR_RETAIN_DAYS} days"

# Clean up stale CMDB files — keep only the last 7 days
CMDB_CLEANED=$(find /home/xaascpau \
    -name "20*cmdb_ci_linux_server.csv" \
    -mtime +7 \
    2>/dev/null | wc -l)
find /home/xaascpau \
    -name "20*cmdb_ci_linux_server.csv" \
    -mtime +7 \
    -delete 2>/dev/null
log INFO "Removed $CMDB_CLEANED stale CMDB extract files older than 7 days"

# =============================================================================
log SECTION "rhel_inv_collect.sh complete"
# =============================================================================

exit 0
