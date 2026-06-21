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

# Auto-seed RHEL_DEPLOYMENTS.dat from legacy location if not present
# This happens once on fresh install — after that v2 maintains its own copy.
# In test mode we also auto-seed so deployment history is available for
# BuildDate fallback lookups (we still never append to it in test mode).
LEGACY_DEPLOY="/usr/local/pnc/bin/RHEL_Inventory/data/RHEL_DEPLOYMENTS.dat"
if [[ ! -f "$DEPLOYMENTDATA" ]]; then
    if [[ -f "$LEGACY_DEPLOY" ]]; then
        mkdir -p "$(dirname "$DEPLOYMENTDATA")"
        cp "$LEGACY_DEPLOY" "$DEPLOYMENTDATA"
        DEPCOUNT=$(wc -l < "$DEPLOYMENTDATA")
        log INFO "Auto-seeded RHEL_DEPLOYMENTS.dat from legacy ($DEPCOUNT records): $DEPLOYMENTDATA"
    else
        log WARN "DEPLOYMENTDATA not found and legacy source not available: $LEGACY_DEPLOY"
        log WARN "BuildDate fallback for legacy hosts will be n/a until manually seeded"
    fi
fi

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

# style.css is written by rhel_inv_run.sh Phase 0 before this script runs.
# No action needed here.

# The remote script outputs tagged lines:
#   INV|...   system inventory record
#   PKG|...   one line per installed RPM
#   DB|...    Oracle SID list
#   ID|...    user/group/netgroup records
#
# rhel_filter_scan.sh strips pssh status noise then splits by tag into
# the four temp files.

log INFO "Launching pssh scan..."
log INFO "INV temp  : $INVENTORYTEMP"
log INFO "ID temp   : $IDINVENTORYTEMP"
log INFO "DB temp   : $DBINVENTORYTEMP"
log INFO "PKG temp  : $PACKAGETEMP"

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
for tmpfile in "$INVENTORYTEMP" "$IDINVENTORYTEMP"; do
    if [[ ! -s "$tmpfile" ]]; then
        log WARN "Output file is empty or missing: $tmpfile"
    else
        COUNT=$(wc -l < "$tmpfile")
        log INFO "$(basename "$tmpfile"): $COUNT lines collected"
    fi
done
# DB is optional — empty is normal when no database hosts are in the scan list
if [[ -s "$DBINVENTORYTEMP" ]]; then
    COUNT=$(wc -l < "$DBINVENTORYTEMP")
    log INFO "$(basename "$DBINVENTORYTEMP"): $COUNT lines collected"
else
    log INFO "$(basename "$DBINVENTORYTEMP"): empty — normal if no DB hosts in host list"
fi
# Package temp — only warn if RUN_PACKAGES_ON_MAIN=1 and it is empty
if [[ "${RUN_PACKAGES_ON_MAIN:-1}" -eq 1 ]]; then
    if [[ -s "$PACKAGETEMP" ]]; then
        COUNT=$(wc -l < "$PACKAGETEMP")
        log INFO "$(basename "$PACKAGETEMP"): $COUNT lines collected"
    else
        log WARN "$(basename "$PACKAGETEMP"): empty — package scan may have failed (check pssh errors)"
    fi
else
    log INFO "$(basename "$PACKAGETEMP"): package scan runs from secondary jumpbox (RUN_PACKAGES_ON_MAIN=0)"
fi

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
if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    # Test mode — overwrite directly, no rotation, no wasted disk space
    [[ -s "$INVENTORYTEMP" ]] && mv "$INVENTORYTEMP" "$INVENTORYDATA" || log WARN "INVENTORYTEMP empty — skipping promote"
else
    rotate_compressed "$INVENTORYDATA" "$ROTATE_INVENTORY"
    [[ -s "$INVENTORYTEMP" ]] && mv "$INVENTORYTEMP" "$INVENTORYDATA" || log WARN "INVENTORYTEMP empty — skipping promote"
fi
log INFO "INVENTORYDATA updated"

log INFO "Rotating RHEL_DBINVENTORY.dat (keeping $ROTATE_DBINVENTORY copies)"
if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    [[ -s "$DBINVENTORYTEMP" ]] && mv "$DBINVENTORYTEMP" "$DBINVENTORYDATA" || log INFO "DBINVENTORYTEMP empty — skipping promote (normal if no Oracle hosts in test list)"
else
    rotate_compressed "$DBINVENTORYDATA" "$ROTATE_DBINVENTORY"
    [[ -s "$DBINVENTORYTEMP" ]] && mv "$DBINVENTORYTEMP" "$DBINVENTORYDATA" || log INFO "DBINVENTORYTEMP empty — skipping promote"
fi
log INFO "DBINVENTORYDATA updated"

# ID inventory: keep 3 compressed copies for the discovery process
log INFO "Rotating RHEL_IDINVENTORY.dat (keeping $ROTATE_IDINVENTORY copies)"
if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    [[ -s "$IDINVENTORYTEMP" ]] && mv "$IDINVENTORYTEMP" "$IDINVENTORYDATA" || log WARN "IDINVENTORYTEMP empty — skipping promote"
else
    rotate_compressed "$IDINVENTORYDATA" "$ROTATE_IDINVENTORY"
    [[ -s "$IDINVENTORYTEMP" ]] && mv "$IDINVENTORYTEMP" "$IDINVENTORYDATA" || log WARN "IDINVENTORYTEMP empty — skipping promote"
fi
log INFO "IDINVENTORYDATA updated"

# Package inventory
if [[ "${RUN_PACKAGES_ON_MAIN:-1}" -eq 1 ]]; then
    log INFO "Rotating RHEL_PACKAGES.csv (keeping $ROTATE_PACKAGES copies)"
    if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
        if [[ -s "$PACKAGETEMP" ]]; then
            mv "$PACKAGETEMP" "$PACKAGEDATA"
            cp -p "$PACKAGEDATA" "$WEBDIR/"
            PKG_COUNT=$(wc -l < "$PACKAGEDATA")
            log INFO "PACKAGEDATA updated — $PKG_COUNT package records published to $WEBDIR"
        else
            log WARN "PACKAGETEMP empty — package data not collected (check pssh scan)"
        fi
    else
        rotate_compressed "$PACKAGEDATA" "$ROTATE_PACKAGES"
        if [[ -s "$PACKAGETEMP" ]]; then
            mv "$PACKAGETEMP" "$PACKAGEDATA"
            cp -p "$PACKAGEDATA" "$WEBDIR/"
            PKG_COUNT=$(wc -l < "$PACKAGEDATA")
            log INFO "PACKAGEDATA updated — $PKG_COUNT package records published to $WEBDIR"
        else
            log WARN "PACKAGETEMP empty — package data not collected (check pssh scan)"
        fi
    fi
else
    log INFO "RUN_PACKAGES_ON_MAIN=0 — package inventory handled by secondary jumpbox"
    rm -f "$PACKAGETEMP"
fi

# =============================================================================
log SECTION "Phase 5 — Collect UIDs and GIDs"
# =============================================================================

if [[ -x "${PGMDIR}/rhel_id_collect.sh" ]]; then
    log INFO "Collecting UID/GID data"
    "${PGMDIR}/rhel_id_collect.sh"
    log INFO "UID/GID collection complete"
else
    log WARN "rhel_id_collect.sh not found — skipping UID/GID collection"
fi

# =============================================================================
log SECTION "Phase 6 — Convert inventory to text and HTML"
# =============================================================================

cp -p "$INVENTORYDATA" "$WEBDIR/$INVENTDATATEXT"
log INFO "Text copy published: $WEBDIR/$INVENTDATATEXT"

# HTML table generation moved to after Phase 7 — needs the enriched CSV

# =============================================================================
log SECTION "Phase 7 — CMDB enrichment and CSV generation"
# =============================================================================
# Replaced per-host bash loop (616k awk forks + 22k grep scans) with a single
# awk pass.  awk reads all three input files once:
#   FNR==NR on DEPLOYMENTDATA  → build deploy_date["hostname"] lookup map
#   FNR==NR on CMDBDATAFILE    → build cmdb["hostname"] lookup map
#   main pass on INVENTORYDATA → join and emit CSV rows
# Runtime: ~5-15 seconds vs 60+ minutes for 22k hosts.
# =============================================================================

# CSV header — matches original column order exactly
CSV_HEADER="#Host (Inventory Run complete $(date)),Type,Location,App Code,Environment,Build Date,OS,Kernel,Architecture,Memory(MB),CPU Sockets,CPU Cores,CPU Threads,CPU Type,CPU Speed,Server Vendor,Server Model,Serial Num,Syslog-ng,Uptime(days),VMToolsVer,VMToolsRun,LastBackupDate,IP Address,CI Device,vCenter server,BuildType,DBType,CMDB Support Group,CMDB Install Status,CMDB Desired Operational State,Fed Enclave"

echo "$CSV_HEADER" > "${DATA_DIR}/${INVENTDATACSV}.new"

# Resolve paths for awk — use empty string when file absent so awk skips it
_DEPLOY_FILE=""
[[ -f "$DEPLOYMENTDATA" ]] && _DEPLOY_FILE="$DEPLOYMENTDATA"

_CMDB_FILE=""
[[ $CMDB_AVAILABLE -eq 1 ]] && _CMDB_FILE="$CMDBDATAFILE"

if [[ $CMDB_AVAILABLE -eq 1 ]]; then
    log INFO "Enriching CSV with CMDB data from: $CMDBDATAFILE"
else
    log WARN "Generating CSV without CMDB enrichment (n/a for CMDB fields)"
fi

[[ -n "$_DEPLOY_FILE" ]] && \
    log INFO "BuildDate fallback: loading deployment records from $_DEPLOY_FILE"

# ---------------------------------------------------------------------------
# Single awk pass — three input files
#
# Pass 1 (DEPLOYMENTDATA):  build deploy_date[host] = date
# Pass 2 (CMDBDATAFILE):    build cmdb[host] = "sg,status,opstate,fed"
# Pass 3 (INVENTORYDATA):   join + emit 32-column CSV rows
#
# Location normalisation (mirrors expand_location() in rhel_utils.sh):
#   Strip "Greenfield-" prefix; all known codes pass through as-is.
#   Add new datacenters here when they come online.
# ---------------------------------------------------------------------------
awk -v deploy_file="$_DEPLOY_FILE" \
    -v cmdb_file="$_CMDB_FILE" \
    -v inv_file="$INVENTORYDATA" \
    -v out_file="${DATA_DIR}/${INVENTDATACSV}.new" \
    -v stats_file="${DATA_DIR}/${INVENTDATACSV}.stats" \
    -v cmdb_available="$CMDB_AVAILABLE" \
'
# ---- Helper: strip Greenfield- prefix and return short code ----
function expand_loc(loc,    l) {
    l = loc
    sub(/^Greenfield-/, "", l)
    return (l == "" ? "n/a" : l)
}

# ---- Helper: return n/a if value is empty or literal "n/a" ----
function na(v) { return (v == "" || v == "n/a") ? "n/a" : v }

# ============================================================
# Pass 1 — DEPLOYMENTDATA: build deploy_date[host] lookup
# Format: YYYY-MM-DD hostname Virt|Phys OSver
# ============================================================
BEGINFILE { current_file = FILENAME }

current_file == deploy_file && !/^#/ && NF >= 2 {
    deploy_date[$2] = $1
    next
}

# ============================================================
# Pass 2 — CMDBDATAFILE: build cmdb[host] lookup
# Format: hostname,SupportGroup,InstallStatus,DesiredOpState,IsFedEnclave,...
# ============================================================
current_file == cmdb_file && !/^#/ {
    gsub(/\r/, "")
    n = split($0, f, ",")
    if (n >= 5) {
        fed = f[5]
        if (fed ~ /^[Tt]rue$/)  fed = "Fed"
        else if (fed ~ /^[Ff]alse$/) fed = "Non-Fed"
        else if (fed == "")     fed = "n/a"
        cmdb[f[1]] = f[2] "," f[3] "," f[4] "," fed
    }
    next
}

# ============================================================
# Pass 3 — INVENTORYDATA: join and emit 32-column CSV rows
# .dat fields (space-delimited, 28 total):
#  1=Host  2=Type  3=OS  4=Kernel  5=Arch  6=Memory
#  7=CPUSockets  8=CPUCores  9=CPUThreads  10=CPUType  11=CPUSpeed
#  12=HWVendor  13=HWModel  14=Serial  15=Syslog  16=Uptime
#  17=VMToolsVer  18=VMToolsRun  19=LastBackup  20=IP
#  21=Location  22=CIDevice  23=vCenter  24=BuildType  25=DBType
#  26=AppCode  27=Environment  28=BuildDate(PROVISIONDATE)
# ============================================================
current_file == inv_file && !/^#/ && NF >= 1 {
    host = $1
    loc  = expand_loc($21)

    bdate = na($28)
    if (bdate == "n/a" && (host in deploy_date))
        bdate = deploy_date[host]

    if (cmdb_available == "1" && (host in cmdb)) {
        split(cmdb[host], cv, ",")
        c1 = na(cv[1]); c2 = na(cv[2])
        c3 = na(cv[3]); c4 = na(cv[4])
        matched++
    } else {
        c1 = "n/a"; c2 = "n/a"; c3 = "n/a"; c4 = "n/a"
        missing++
    }

    print host "," $2 "," loc "," na($26) "," na($27) "," bdate "," \
          na($3) "," na($4) "," na($5) "," na($6) "," na($7) "," \
          na($8) "," na($9) "," na($10) "," na($11) "," na($12) "," \
          na($13) "," na($14) "," na($15) "," na($16) "," na($17) "," \
          na($18) "," na($19) "," na($20) "," na($22) "," na($23) "," \
          na($24) "," na($25) "," c1 "," c2 "," c3 "," c4 \
          >> out_file
    next
}

END {
    print matched+0 ":" missing+0 > stats_file
}
' \
    ${_DEPLOY_FILE:+"$_DEPLOY_FILE"} \
    ${_CMDB_FILE:+"$_CMDB_FILE"} \
    "$INVENTORYDATA"

# Read counts written by awk END block
if [[ -f "${DATA_DIR}/${INVENTDATACSV}.stats" ]]; then
    _stats=$(cat "${DATA_DIR}/${INVENTDATACSV}.stats")
    _CMDB_MATCHED="${_stats%%:*}"
    _CMDB_MISSING="${_stats##*:}"
    rm -f "${DATA_DIR}/${INVENTDATACSV}.stats"
else
    _CMDB_MATCHED=0; _CMDB_MISSING=0
fi

if [[ $CMDB_AVAILABLE -eq 1 ]]; then
    log INFO "CMDB enrichment complete — matched: $_CMDB_MATCHED, not in CMDB: $_CMDB_MISSING"
else
    _TOTAL=$(grep -c "^[^#]" "${DATA_DIR}/${INVENTDATACSV}.new" 2>/dev/null || echo 0)
    log INFO "CSV generation complete — $_TOTAL records (no CMDB enrichment)"
fi

# Atomic promotion — eliminates the window where the CSV is incomplete
# (the previous approach had a 5-minute window of incomplete file)
cp "${DATA_DIR}/${INVENTDATACSV}.new" "${DATA_DIR}/$INVENTDATACSV"
cp "${DATA_DIR}/${INVENTDATACSV}.new" "${WEBDIR}/$INVENTDATACSV"
rm -f "${DATA_DIR}/${INVENTDATACSV}.new"
log INFO "CSV published: $WEBDIR/$INVENTDATACSV"

# Generate HTML table from enriched CSV — must be after CSV is written
if [[ -x "${PGMDIR}/rhel_convert_html.sh" ]]; then
    cat "${DATA_DIR}/$INVENTDATACSV" \
        | "${PGMDIR}/rhel_convert_html.sh" "$WEBDIR/$INVENTDATAHTML"
    log INFO "HTML table published: $WEBDIR/$INVENTDATAHTML"
else
    log WARN "rhel_convert_html.sh not found — skipping HTML conversion"
fi

# =============================================================================
log SECTION "Phase 8 — Rotate historical CSV copies"
# =============================================================================

# Keep 14 copies in webdir historical_data (2 weeks)
mkdir -p "${WEBDIR}/historical_data"
cp "${WEBDIR}/$INVENTDATACSV" \
    "${WEBDIR}/historical_data/${INVENTDATACSV}" 2>/dev/null
if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    # Test mode — no rotation, files simply overwrite each run to save space
    # RHEL_PACKAGES.csv can be 1.3GB — rotating compressed copies on every
    # test run would exhaust disk space quickly
    log INFO "TEST MODE — skipping CSV rotation (overwrite only)"
else
    rotate_plain "${WEBDIR}/historical_data/RHEL_INVENTORY" "$ROTATE_INVENTORY_CSV" -e ".csv" \
        && log INFO "Historical CSV rotation complete (keeping $ROTATE_INVENTORY_CSV copies)"
    rotate_compressed "${DATA_DIR}/$INVENTDATACSV" "$ROTATE_INVENTORY_CSV" \
        && log INFO "Local CSV rotation complete (keeping $ROTATE_INVENTORY_CSV copies)"
fi

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
