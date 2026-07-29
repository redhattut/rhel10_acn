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
#           PKG|  → RHEL_PACKAGES.tmp    (RPM package list, collected in Phase 3a)
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
# This happens once on fresh install — after that this process maintains its own copy.
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
rm -f "$MRGCSVTEMP" "$MRGJSONTMP" "$UPGRADETEMP"
log INFO "Cleared stale temp files"

# =============================================================================
log SECTION "Phase 3 -- Parallel SSH scan"
# =============================================================================
# THREE separate pssh calls -- one script per pass, no concatenation.
#
# Concatenating scripts causes bash 4.4 (RHEL 7) to fail with
# "unexpected end of file" at parse time. Each script runs cleanly alone.
#
# Phase 3a: INV + ID + DB + PKG  (rhel_remote_scan.sh -- single pass, no duplication)
# Phase 3b: MRG CSV + JSON        (RHEL_data_gather.sh only)
# Phase 3c: eliminated -- PKG now collected in Phase 3a alongside INV/ID/DB
# =============================================================================

LINES=$(grep -v "^#" "$MASTERHOSTLIST" | wc -l)
log INFO "Scanning $LINES hosts from $MASTERHOSTLIST"
log INFO "pssh batch size : $PSSH_BATCH"
log INFO "pssh timeout    : ${PSSH_TIMEOUT}s per host"
log INFO "pssh error dir  : $ERRDIR"
log INFO "Writing web data to: $WEBDIR"

# =============================================================================
log SECTION "Phase 3a -- INV / ID / DB scan"
# =============================================================================
log INFO "INV temp : $INVENTORYTEMP"
log INFO "ID temp  : $IDINVENTORYTEMP"
log INFO "DB temp  : $DBINVENTORYTEMP"
log INFO "PKG temp : $PACKAGETEMP"
log INFO "UPG temp : $UPGRADETEMP"

# Upgrade web directory
UPGRADE_WEB_DIR="${UPGRADE_WEB_DIR:-${WEBDIR}/Upgrade}"
mkdir -p "$UPGRADE_WEB_DIR" "${UPGRADE_WEB_DIR}/archive"

# Write PKG CSV header before pssh populates the file
echo "Host,Package,Version,Release,Install date" > "$PACKAGETEMP"

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
        "$PACKAGETEMP" \
        "/dev/null" \
        "/dev/null" \
        "$UPGRADETEMP"

SCAN_RC=$?
log INFO "Phase 3a completed (exit status: $SCAN_RC)"

if [[ -d "$ERRDIR" && "$ERRDIR" =~ errdir ]]; then
    find "$ERRDIR" -type f -size 0 | xargs rm -f 2>/dev/null
    ERRCOUNT=$(find "$ERRDIR" -type f | wc -l)
    log INFO "Error dir: $ERRCOUNT hosts had errors"
fi

for tmpfile in "$INVENTORYTEMP" "$IDINVENTORYTEMP"; do
    if [[ ! -s "$tmpfile" ]]; then
        log WARN "$(basename "$tmpfile"): empty or missing"
    else
        log INFO "$(basename "$tmpfile"): $(wc -l < "$tmpfile") lines collected"
    fi
done
if [[ -s "$DBINVENTORYTEMP" ]]; then
    log INFO "$(basename "$DBINVENTORYTEMP"): $(wc -l < "$DBINVENTORYTEMP") lines collected"
else
    log INFO "$(basename "$DBINVENTORYTEMP"): empty (no DB hosts or none found)"
fi

# =============================================================================
log SECTION "Phase 3b -- Midrange Mod / Compare JSON scan"
# =============================================================================
# RHEL_data_gather.sh runs alone -- confirmed working via pssh in testing.
# Produces MID_MOD_CSV: and COMPARE_JSON: tagged lines only.
# =============================================================================

_gather_script="${RHEL_DATA_GATHER:-${PGMDIR}/RHEL_data_gather.sh}"
if [[ -f "$_gather_script" ]]; then
    log INFO "MRG CSV temp : $MRGCSVTEMP"
    log INFO "MRG JSON tmp : $MRGJSONTMP"
    log INFO "Script       : $_gather_script"

    cat "$_gather_script" \
        | "$PSSH_BIN" $PSSH_OPTS \
            -e "$ERRDIR" \
            -h "$MASTERHOSTLIST" \
            -x "-q -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=30" \
            bash \
        | "${PGMDIR}/rhel_filter_scan.sh" \
            "/dev/null" \
            "/dev/null" \
            "/dev/null" \
            "/dev/null" \
            "$MRGCSVTEMP" \
            "$MRGJSONTMP" \
            "/dev/null"

    MRG_RC=$?
    log INFO "Phase 3b completed (exit status: $MRG_RC)"

    if [[ -s "$MRGCSVTEMP" ]]; then
        log INFO "$(basename "$MRGCSVTEMP"): $(wc -l < "$MRGCSVTEMP") lines collected"
    else
        log WARN "$(basename "$MRGCSVTEMP"): empty -- check RHEL_data_gather.sh"
    fi
else
    log WARN "RHEL_data_gather.sh not found at $_gather_script -- skipping Midrange Mod scan"
fi

log SECTION "Phase 3c -- Package inventory (collected in Phase 3a)"
# PKG lines are collected by rhel_remote_scan.sh in Phase 3a alongside INV/ID/DB.
# rhel_remote_scan.sh already runs rpm -qa -- routing PKG| lines to PACKAGETEMP
# in Phase 3a means zero duplicate collection and Phase 3c is no longer needed.
# This eliminates the 109-minute second pssh pass that was previously required.
log INFO "PKG collection: handled in Phase 3a (see PACKAGETEMP above)"
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
log SECTION "Phase 4.5 — Fed Enclave data merge"
# =============================================================================
# When running via AAP pipeline, AAP_FED_DIR points to the directory on
# lmrg34ja where the AAP playbook copied all four fed enclave output files
# fetched from lmrg34ba:
#
#   fed_enclave_raw.dat  — appended to INVENTORYDATA before Phase 7 enrichment
#   fed_enclave_id.dat   — appended to IDINVENTORYDATA (already promoted by Phase 4)
#   fed_enclave_db.dat   — appended to DBINVENTORYDATA (already promoted by Phase 4)
#   fed_enclave_pkg.csv  — appended to PACKAGEDATA with header dedup
#
# Fallback: for each file, if no fresh copy was provided, the previous run
# file already in DATA_DIR is used. This handles lmrg34ba being unreachable.
#
# Not applicable for test mode or normal cron runs (AAP_FED_DIR is empty).
# =============================================================================

# Helper function — merge a fed file into a target with fallback to DATA_DIR
# Usage: _fed_merge <label> <fed_file_in_dir> <fallback_in_data_dir> <target_file> <mode>
# mode: "dat" = space-delimited, filter $3!="?"; "csv" = CSV, skip header line on append
_fed_merge() {
    local label="$1"
    local fresh_src="$2"
    local fallback="$3"
    local target="$4"
    local mode="$5"
    local src=""

    if [[ -n "$fresh_src" && -f "$fresh_src" && -s "$fresh_src" ]]; then
        src="$fresh_src"
        # Save fresh copy to DATA_DIR as new fallback for next run
        cp -p "$src" "$fallback" 2>/dev/null
        log INFO "$label: fresh file from lmrg34ba — $src"
    elif [[ -f "$fallback" && -s "$fallback" ]]; then
        src="$fallback"
        log INFO "$label: using previous run file — $fallback"
    else
        log INFO "$label: no file available — skipping"
        return
    fi

    if [[ ! -f "$target" ]]; then
        log INFO "$label: target not yet created — skipping append (will be created this run)"
        return
    fi

    local before after merged skipped
    before=$(wc -l < "$target")

    if [[ "$mode" == "dat" ]]; then
        # Space-delimited dat — skip non-RHEL (OS field = "?")
        merged=$(awk '$3 != "?"' "$src" | tee -a "$target" | wc -l)
        skipped=$(( $(wc -l < "$src") - merged ))
        after=$(wc -l < "$target")
        log INFO "$label: appended $merged records to $(basename "$target") ($skipped non-RHEL skipped, total now $after)"
    elif [[ "$mode" == "csv" ]]; then
        # CSV — skip header row on append (first line of fed file)
        merged=$(tail -n +2 "$src" | tee -a "$target" | wc -l)
        after=$(wc -l < "$target")
        log INFO "$label: appended $merged records to $(basename "$target") (total now $after)"
    fi
}

# Determine source directory — use AAP_FED_DIR if set and valid
_FED_SRC_DIR=""
if [[ -n "${AAP_FED_DIR:-}" ]]; then
    if [[ -d "$AAP_FED_DIR" ]]; then
        _FED_SRC_DIR="$AAP_FED_DIR"
    else
        log WARN "AAP_FED_DIR specified but directory not found: $AAP_FED_DIR"
        log WARN "Falling back to previous run fed files in DATA_DIR"
    fi
fi

# Merge each file — fresh from AAP_FED_DIR if available, else fallback in DATA_DIR
_fed_merge \
    "Fed INV dat" \
    "${_FED_SRC_DIR:+${_FED_SRC_DIR}/fed_enclave_raw.dat}" \
    "${DATA_DIR}/fed_enclave_raw.dat" \
    "$INVENTORYDATA" \
    "dat"

_fed_merge \
    "Fed ID dat" \
    "${_FED_SRC_DIR:+${_FED_SRC_DIR}/fed_enclave_id.dat}" \
    "${DATA_DIR}/fed_enclave_id.dat" \
    "$IDINVENTORYDATA" \
    "dat"

_fed_merge \
    "Fed DB dat" \
    "${_FED_SRC_DIR:+${_FED_SRC_DIR}/fed_enclave_db.dat}" \
    "${DATA_DIR}/fed_enclave_db.dat" \
    "$DBINVENTORYDATA" \
    "dat"

_fed_merge \
    "Fed PKG csv" \
    "${_FED_SRC_DIR:+${_FED_SRC_DIR}/fed_enclave_pkg.csv}" \
    "${DATA_DIR}/fed_enclave_pkg.csv" \
    "$PACKAGEDATA" \
    "csv"

_fed_merge \
    "Fed MRG CSV" \
    "${_FED_SRC_DIR:+${_FED_SRC_DIR}/fed_enclave_midrange_mod.dat}" \
    "${DATA_DIR}/fed_enclave_midrange_mod.dat" \
    "$MRGCSVTEMP" \
    "csv"

# Fed Upgrade eligibility — append fed UPG rows into UPGRADETEMP
_FED_UPG_FRESH="${_FED_SRC_DIR:+${_FED_SRC_DIR}/fed_enclave_upgrade.dat}"
_FED_UPG_FALLBACK="${DATA_DIR}/fed_enclave_upgrade.dat"
_fed_upg_src=""
if [[ -n "$_FED_UPG_FRESH" && -f "$_FED_UPG_FRESH" && -s "$_FED_UPG_FRESH" ]]; then
    _fed_upg_src="$_FED_UPG_FRESH"
    cp -p "$_FED_UPG_FRESH" "$_FED_UPG_FALLBACK"
    log INFO "Fed Upgrade data: fresh from lmrg34ba — appending to UPGRADETEMP"
elif [[ -f "$_FED_UPG_FALLBACK" && -s "$_FED_UPG_FALLBACK" ]]; then
    _fed_upg_src="$_FED_UPG_FALLBACK"
    log INFO "Fed Upgrade data: using previous run file — $_FED_UPG_FALLBACK"
fi
if [[ -n "$_fed_upg_src" ]]; then
    cat "$_fed_upg_src" >> "$UPGRADETEMP"
    log INFO "Fed Upgrade data: $(wc -l < "$_fed_upg_src") records merged into UPGRADETEMP"
else
    log INFO "Fed Upgrade data: no file found — fed enclave excluded from upgrade report this run"
fi

# =============================================================================
log SECTION "Phase 4.55 -- Upgrade eligibility processing (main + fed combined)"
# =============================================================================
# Runs after Phase 4.5 so fed enclave data is appended to UPGRADETEMP first.
_UPG_DATE="$(date +%Y-%m-%d)"
_UPG_ARCHIVE="${UPGRADE_WEB_DIR}/archive/upgrade_eligibility_${_UPG_DATE}.csv"
_UPG_CSV="${UPGRADE_WEB_DIR}/RHEL8-9_Upgrade_Eligibility_Report.csv"
_UPG_JS="${UPGRADE_WEB_DIR}/upgrade_data.js"

if [[ -s "$UPGRADETEMP" ]]; then
    log INFO "UPG temp: $(wc -l < "$UPGRADETEMP") lines collected (main + fed)"

    cp "$UPGRADETEMP" "$_UPG_ARCHIVE"
    log INFO "Upgrade eligibility archived: $_UPG_ARCHIVE"

    _upg_pruned=$(find "${UPGRADE_WEB_DIR}/archive" -name "upgrade_eligibility_*.csv" \
        -type f -mtime +"${DAYS_TO_KEEP_MRG:-31}" -delete -print | wc -l)
    [[ $_upg_pruned -gt 0 ]] && \
        log INFO "Upgrade archive pruned: $_upg_pruned file(s) removed"

    # Carry-forward for UNKNOWN hosts using awk temp file (avoids shell escaping issues)
    _upg_cf_tmp=$(mktemp /tmp/rhel_upg_cf.XXXXXX)
    _upg_awk=$(mktemp /tmp/rhel_upg_awk.XXXXXX)
    echo "Host,Datacenter,Mnemonic,Environment,OS,Eligibility,Comments" > "$_upg_cf_tmp"

    cat > "$_upg_awk" << 'UPGAWK'
BEGIN { FS=","; OFS="," }
FILENAME == raw_file {
    host=$1; gsub(/^ +| +$/, "", host)
    today[host] = $0
    next
}
{
    host=$1; gsub(/^ +| +$/, "", host)
    elig=$6; gsub(/^ +| +$/, "", elig)
    if (elig != "UNKNOWN" && !(host in prior)) {
        prior[host] = $0
        prior_date[host] = FILENAME
    }
}
END {
    for (host in today) {
        split(today[host], f, ",")
        elig = f[6]; gsub(/^ +| +$/, "", elig)
        if (elig == "UNKNOWN" && (host in prior)) {
            split(prior[host], pf, ",")
            cd = prior_date[host]
            sub(/.*upgrade_eligibility_/, "", cd); sub(/\.csv$/, "", cd)
            note = "Last known: " pf[6] " as of " cd " — host unreachable tonight"
            print pf[1]","pf[2]","pf[3]","pf[4]","pf[5]","pf[6]","note
        } else {
            print today[host]
        }
    }
}
UPGAWK

    # Build list of prior archive files excluding today
    _prior_archives=$(ls -t "${UPGRADE_WEB_DIR}/archive"/upgrade_eligibility_*.csv 2>/dev/null \
        | grep -v "$_UPG_DATE" | tr '\n' ' ')

    awk -f "$_upg_awk" raw_file="$UPGRADETEMP" \
        "$UPGRADETEMP" $_prior_archives \
        >> "$_upg_cf_tmp" 2>/dev/null || true

    { head -1 "$_upg_cf_tmp"; tail -n +2 "$_upg_cf_tmp" | sort -t, -k1,1; } > "$_UPG_CSV"
    log INFO "Upgrade CSV written: $_UPG_CSV ($(( $(wc -l < "$_UPG_CSV") - 1 )) hosts)"
    rm -f "$_upg_cf_tmp"

    # Generate upgrade_data.js using awk script file (avoids backslash escaping issues)
    _js_awk=$(mktemp /tmp/rhel_upg_js.XXXXXX)
    cat > "$_js_awk" << 'JSAWK'
BEGIN { FS="," }
NR==1 { next }
{
    h=$1; dc=$2; mn=$3; ev=$4; os=$5; el=$6
    cm=$7; for(i=8;i<=NF;i++) cm=cm","$i
    gsub(/\\/, "\\\\", h);  gsub(/"/, "\\\"", h)
    gsub(/\\/, "\\\\", cm); gsub(/"/, "\\\"", cm)
    printf "  {\"Host\":\"%s\",\"Datacenter\":\"%s\",\"Mnemonic\":\"%s\",\"Environment\":\"%s\",\"OS\":\"%s\",\"Eligibility\":\"%s\",\"Comments\":\"%s\"},\n",
        h,dc,mn,ev,os,el,cm
}
JSAWK

    {
        echo "// RHEL 8->9 Upgrade Eligibility -- generated $(date '+%Y-%m-%d %H:%M:%S')"
        echo "// Fields: Host,Datacenter,Mnemonic,Environment,OS,Eligibility,Comments"
        echo "const serverData = ["
        awk -f "$_js_awk" "$_UPG_CSV"
        echo "];"
    } > "$_UPG_JS"
    rm -f "$_upg_awk" "$_js_awk"
    log INFO "Upgrade data JS written: $_UPG_JS"
else
    log WARN "UPGRADETEMP empty — upgrade eligibility files not updated this run"
fi
# Both files are JSON arrays. We strip the outer [ ] from the fed file
# and append its entries into the main array so the split step in Phase 4.6
# processes all hosts (main + fed) together.
_FED_MRG_JSON_FRESH="${_FED_SRC_DIR:+${_FED_SRC_DIR}/fed_enclave_compare_data.dat}"
_FED_MRG_JSON_FALLBACK="${DATA_DIR}/fed_enclave_compare_data.dat"

_fed_json_src=""
if [[ -n "$_FED_MRG_JSON_FRESH" && -f "$_FED_MRG_JSON_FRESH" && -s "$_FED_MRG_JSON_FRESH" ]]; then
    _fed_json_src="$_FED_MRG_JSON_FRESH"
    cp -p "$_FED_MRG_JSON_FRESH" "$_FED_MRG_JSON_FALLBACK"
    log INFO "Fed Compare JSON: fresh from lmrg34ba — merging into main JSON array"
elif [[ -f "$_FED_MRG_JSON_FALLBACK" && -s "$_FED_MRG_JSON_FALLBACK" ]]; then
    _fed_json_src="$_FED_MRG_JSON_FALLBACK"
    log INFO "Fed Compare JSON: using previous run file — $_FED_MRG_JSON_FALLBACK"
fi

if [[ -n "$_fed_json_src" && -s "${MRGJSONTMP:-}" ]]; then
    # Append fed entries into main JSON array using python
    python3 << PYEOF
import json, sys

main_file = "${MRGJSONTMP}"
fed_file  = "${_fed_json_src}"

try:
    with open(main_file) as f:
        main = json.load(f)
    with open(fed_file) as f:
        fed = json.load(f)
    combined = main + fed
    with open(main_file, "w") as f:
        json.dump(combined, f)
    print(f"Fed JSON merged: {len(fed)} entries added to main array (total {len(combined)})")
except Exception as e:
    print(f"ERROR merging fed JSON: {e}", file=sys.stderr)
PYEOF
fi

if [[ -z "${AAP_FED_DIR:-}" ]]; then
    log INFO "AAP_FED_DIR not set — normal cron/test run, Fed Enclave merge skipped"
fi

# =============================================================================
log SECTION "Phase 4.52 — Package data carry-forward for unreachable hosts"
# =============================================================================
# Hosts that were unreachable tonight (TIMEOUT/SSHFAIL stubs in the dat) have
# no PKG rows in tonight's PACKAGEDATA. Pull their rows from the newest
# archive generation that has them, walking .1.gz → .N.gz. Carried rows
# persist into subsequent archives, so coverage chains while the host stays
# in the host list.
#
# Decomm-safe: the missing-host set is derived from TONIGHT's dat stubs, and
# stubs only exist for hosts in the CMDB-filtered host list (Decomm /
# Pending-Decomm excluded upstream). A decommissioned host never gets a stub,
# so its packages can never be carried forward.
#
# Runs after Phase 4.5 so fed enclave PKG data (fresh or fallback) is already
# merged — fed hosts with data are not treated as missing.
# =============================================================================
if [[ "${TEST_MODE:-0}" -eq 0 && -s "$PACKAGEDATA" && -s "$INVENTORYDATA" ]]; then
    _pkg_miss=$(mktemp /tmp/rhel_pkg_miss.XXXXXX)

    # Stub hosts tonight, minus any that already have PKG rows (fed fallback etc.)
    awk 'FNR==NR {
             if ($2 == "TIMEOUT" || $2 == "SSHFAIL") miss[$1] = 1
             next
         }
         {
             ci = index($0, ",")
             if (ci > 1) have[substr($0, 1, ci-1)] = 1
         }
         END { for (h in miss) if (!(h in have)) print h }' \
        "$INVENTORYDATA" "$PACKAGEDATA" | sort > "$_pkg_miss"

    _PKG_MISS_COUNT=$(wc -l < "$_pkg_miss")
    if [[ $_PKG_MISS_COUNT -gt 0 ]]; then
        log INFO "PKG carry-forward: $_PKG_MISS_COUNT unreachable host(s) missing package rows"
        _PKG_CF_TOTAL=0
        for (( _g=1; _g<=${ROTATE_PACKAGES:-10}; _g++ )); do
            [[ -s "$_pkg_miss" ]] || break
            _arc="${PACKAGEDATA}.${_g}.gz"
            [[ -f "$_arc" ]] || continue
            _found=$(mktemp /tmp/rhel_pkg_found.XXXXXX)
            _rows=$(zcat "$_arc" 2>/dev/null \
                | awk -v miss_file="$_pkg_miss" -v found_file="$_found" '
                    BEGIN { while ((getline h < miss_file) > 0) miss[h] = 1 }
                    {
                        ci = index($0, ",")
                        if (ci > 1) {
                            h = substr($0, 1, ci-1)
                            if (h in miss) { print; found[h] = 1 }
                        }
                    }
                    END { for (h in found) print h > found_file }' \
                | tee -a "$PACKAGEDATA" | wc -l)
            if [[ -s "$_found" ]]; then
                _fh=$(wc -l < "$_found")
                log INFO "PKG carry-forward: gen ${_g} supplied $_rows row(s) for $_fh host(s)"
                _PKG_CF_TOTAL=$(( _PKG_CF_TOTAL + _rows ))
                sort "$_found" | comm -23 "$_pkg_miss" - > "${_pkg_miss}.new"
                mv "${_pkg_miss}.new" "$_pkg_miss"
            fi
            rm -f "$_found"
        done
        _PKG_STILL=$(wc -l < "$_pkg_miss")
        log INFO "PKG carry-forward: $_PKG_CF_TOTAL total row(s) carried; $_PKG_STILL host(s) not found in any archive"
        if [[ $_PKG_CF_TOTAL -gt 0 ]]; then
            cp -p "$PACKAGEDATA" "$WEBDIR/"
            log INFO "PKG carry-forward: refreshed web copy of $(basename "$PACKAGEDATA")"
        fi
    else
        log INFO "PKG carry-forward: no unreachable hosts missing package rows"
    fi
    rm -f "$_pkg_miss"
else
    [[ "${TEST_MODE:-0}" -eq 1 ]] && log INFO "PKG carry-forward: skipped in test mode"
fi

# =============================================================================
log SECTION "Phase 4.6 — Midrange Mod CSV and Compare JSON promotion"
# =============================================================================
# Promote MRGCSVTEMP → MRGCSVDATA, write MRG CSV header, archive CSV.
# Split MRGJSONTMP (combined JSON array) into per-host hostname.json files
# in COMPARE_DATA_DIR for the Server Compare Tool.
# =============================================================================

mkdir -p "$MRG_ARCHIVE_DIR" "$COMPARE_DATA_DIR"

# SELinux context so httpd can serve the JSON files
chcon -R -t httpd_sys_content_t "$COMPARE_DATA_DIR" 2>/dev/null || \
    restorecon -R "$COMPARE_DATA_DIR" 2>/dev/null || true

# --- Promote MRG CSV ---------------------------------------------------------
if [[ -s "$MRGCSVTEMP" ]]; then
    # The temp file is already named Midrange_Mod_Report_MM-DD-YYYY.csv.tmp
    # Strip .tmp to get the archive filename directly
    MRG_ARCHIVE_FILE="${MRG_ARCHIVE_DIR}/$(basename "${MRGCSVTEMP%.tmp}")"

    # Archive the RAW scan (with unreachable-host stubs) FIRST, so archives
    # always reflect what was actually collected each night. The published
    # CSV below then applies carry-forward — this mirrors the Upgrade
    # eligibility pattern and bounds carry-forward to the archive window.
    {
        echo "Host,Location,Mnemonic,Environment,OS Version,Authentication Method,OUD Query,AD Query,pnc_join_ad,Nsswitch,KRB5 Keytab,xqvsmlinauthscan Sudo,xqmrglineng Sudo,xqmrglinaap Sudo"
        grep -v "^[[:space:]]*$" "$MRGCSVTEMP"
    } > "$MRG_ARCHIVE_FILE"
    log INFO "MRG CSV archived (raw scan): $MRG_ARCHIVE_FILE"

    # Build the published CSV with carry-forward: unreachable hosts produce
    # stub rows (all n/a). Replace each stub with the host's newest non-stub
    # row from prior archives, walking newest → oldest.
    # Decomm-safe: only hosts present in TONIGHT's scan output (host list is
    # CMDB-filtered) are considered — prior-archive rows for hosts no longer
    # in the list are never emitted.
    _mrg_awk=$(mktemp /tmp/rhel_mrg_cf.XXXXXX)
    cat > "$_mrg_awk" << 'MRGAWK'
BEGIN { FS = ","; OFS = "," }
FILENAME == raw_file {
    h = $1; gsub(/^ +| +$/, "", h)
    if (h == "" || h == "Host") next
    if (!(h in today)) order[++n] = h
    today[h] = $0
    next
}
{
    h = $1; gsub(/^ +| +$/, "", h)
    if (h == "" || h == "Host") next
    # Non-stub row = real scan data (stub rows are all n/a after the host)
    if (!($2 == "n/a" && $3 == "n/a" && $4 == "n/a" && $5 == "n/a") && !(h in prior))
        prior[h] = $0
}
END {
    carried = 0
    for (i = 1; i <= n; i++) {
        h = order[i]
        split(today[h], f, ",")
        if (f[2] == "n/a" && f[3] == "n/a" && f[4] == "n/a" && f[5] == "n/a" && (h in prior)) {
            print prior[h]
            carried++
        } else {
            print today[h]
        }
    }
    print carried > "/dev/stderr"
}
MRGAWK

    # Prior archives newest → oldest, excluding tonight's file
    _mrg_prior=$(ls -t "${MRG_ARCHIVE_DIR}"/Midrange_Mod_Report_*.csv 2>/dev/null \
        | grep -v "$(basename "$MRG_ARCHIVE_FILE")" | tr '\n' ' ')

    echo "Host,Location,Mnemonic,Environment,OS Version,Authentication Method,OUD Query,AD Query,pnc_join_ad,Nsswitch,KRB5 Keytab,xqvsmlinauthscan Sudo,xqmrglineng Sudo,xqmrglinaap Sudo" > "$MRGCSVDATA"
    _mrg_carried=$(awk -f "$_mrg_awk" raw_file="$MRG_ARCHIVE_FILE" \
        "$MRG_ARCHIVE_FILE" $_mrg_prior 2>&1 >> "$MRGCSVDATA")
    rm -f "$_mrg_awk"

    MRG_ROW_COUNT=$(grep -vc "^Host," "$MRGCSVDATA" 2>/dev/null || echo 0)
    log INFO "MRG CSV promoted: $MRGCSVDATA ($MRG_ROW_COUNT rows, ${_mrg_carried:-0} carried forward from prior archives)"

    DELETED_MRG=$(find "$MRG_ARCHIVE_DIR" -name "Midrange_Mod_Report_*.csv" \
        -type f -mtime +"${DAYS_TO_KEEP_MRG:-31}" -delete -print | wc -l)
    [[ $DELETED_MRG -gt 0 ]] && \
        log INFO "MRG archive pruned: $DELETED_MRG file(s) older than ${DAYS_TO_KEEP_MRG:-31} days removed"
else
    log WARN "MRGCSVTEMP empty — Midrange Mod CSV not generated (check if RHEL_data_gather.sh ran)"
fi
rm -f "$MRGCSVTEMP"

# --- Split combined JSON array into per-host files ---------------------------
if [[ -s "$MRGJSONTMP" ]]; then
    log INFO "Compare JSON: splitting $MRGJSONTMP -> $COMPARE_DATA_DIR"
    _py_out=$(python3 2>&1 << PYEOF
import json, os, sys

json_file = "${MRGJSONTMP}"
out_dir   = "${COMPARE_DATA_DIR}"
os.makedirs(out_dir, exist_ok=True)

try:
    with open(json_file) as f:
        entries = json.load(f)
except Exception as e:
    print(f"ERROR parsing {json_file}: {e}", file=sys.stderr)
    print("0 0")
    sys.exit(0)

written   = 0
failed    = 0
preserved = 0
for entry in entries:
    host = entry.get("host", "")
    if not host:
        failed += 1
        continue
    dest = os.path.join(out_dir, f"{host}.json")

    # Carry-forward: if tonight's entry is an unreachable stub and a previous
    # good JSON exists for this host, keep the existing file. The Compare
    # Tool then keeps serving the host's last real data instead of losing it.
    if entry.get("reachable") is False and os.path.exists(dest):
        try:
            with open(dest) as f:
                old = json.load(f)
            if old.get("reachable") is not False:
                preserved += 1
                continue
        except Exception:
            pass  # existing file unreadable — fall through and overwrite

    try:
        with open(dest, "w") as f:
            json.dump(entry, f, indent=2)
        os.chmod(dest, 0o644)
        written += 1
    except Exception as e:
        print(f"ERROR writing {dest}: {e}", file=sys.stderr)
        failed += 1

print(f"{written} {failed} {preserved}")
PYEOF
)
    MRG_JSON_COUNT=$(echo "$_py_out" | tail -1 | awk '{print $1}')
    MRG_JSON_FAIL=$(echo "$_py_out" | tail -1 | awk '{print $2}')
    MRG_JSON_KEPT=$(echo "$_py_out" | tail -1 | awk '{print $3}')
    log INFO "Compare JSON split: $MRG_JSON_COUNT host files written to $COMPARE_DATA_DIR ($MRG_JSON_FAIL failed, ${MRG_JSON_KEPT:-0} unreachable hosts kept prior data)"
else
    log WARN "MRGJSONTMP empty — Compare JSON files not generated"
fi
rm -f "$MRGJSONTMP"

# --- Compare JSON nightly backup ---------------------------------------------
# The per-host JSON files are the Compare Tool's only data store — back the
# whole directory up nightly so a bad run or corruption is recoverable.
# Retention matches the MRG archive window.
if [[ "${TEST_MODE:-0}" -eq 0 && -d "$COMPARE_DATA_DIR" ]]; then
    _CMP_BACKUP_DIR="${COMPARE_BACKUP_DIR:-${DATA_DIR}/compare_json_backup}"
    mkdir -p "$_CMP_BACKUP_DIR"
    _CMP_TAR="${_CMP_BACKUP_DIR}/compare_data_$(date +%Y-%m-%d).tar.gz"
    if tar -czf "$_CMP_TAR" -C "$(dirname "$COMPARE_DATA_DIR")" \
            "$(basename "$COMPARE_DATA_DIR")" 2>/dev/null; then
        log INFO "Compare JSON backup: $_CMP_TAR ($(du -h "$_CMP_TAR" | awk '{print $1}'))"
        _CMP_PRUNED=$(find "$_CMP_BACKUP_DIR" -name "compare_data_*.tar.gz" \
            -type f -mtime +"${DAYS_TO_KEEP_MRG:-31}" -delete -print | wc -l)
        [[ $_CMP_PRUNED -gt 0 ]] && \
            log INFO "Compare JSON backup pruned: $_CMP_PRUNED file(s) older than ${DAYS_TO_KEEP_MRG:-31} days removed"
    else
        log WARN "Compare JSON backup failed — check space/permissions in $_CMP_BACKUP_DIR"
    fi
fi

# --- Compare JSON stale-host pruning -----------------------------------------
# Remove {host}.json files for hosts no longer in tonight's inventory (host
# list is CMDB-filtered, so Decomm / Pending-Decomm hosts drop out here the
# night after they leave the list). INVENTORYDATA at this point includes fed
# enclave hosts (Phase 4.5 merge, with fallback when lmrg34ba is unreachable),
# so fed hosts are never falsely pruned. Runs after the backup so any pruned
# file is still recoverable from tonight's tarball.
if [[ "${TEST_MODE:-0}" -eq 0 && -d "$COMPARE_DATA_DIR" && -s "$INVENTORYDATA" ]]; then
    _cmp_active=$(mktemp /tmp/rhel_cmp_active.XXXXXX)
    _cmp_have=$(mktemp /tmp/rhel_cmp_have.XXXXXX)
    awk '!/^#/ && NF >= 1 {print $1}' "$INVENTORYDATA" | sort -u > "$_cmp_active"
    ( cd "$COMPARE_DATA_DIR" && ls *.json 2>/dev/null | sed 's/\.json$//' | sort ) > "$_cmp_have"
    _CMP_STALE=0
    while read -r _stale_host; do
        [[ -z "$_stale_host" ]] && continue
        rm -f "${COMPARE_DATA_DIR}/${_stale_host}.json"
        _CMP_STALE=$(( _CMP_STALE + 1 ))
    done < <(comm -23 "$_cmp_have" "$_cmp_active")
    [[ $_CMP_STALE -gt 0 ]] && \
        log INFO "Compare JSON pruning: removed $_CMP_STALE stale host file(s) no longer in inventory (decomm cleanup)"
    rm -f "$_cmp_active" "$_cmp_have"
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

# Previous dat archives — used to carry forward last known data for hosts
# that were unreachable tonight (TIMEOUT/SSHFAIL stubs).
# Walks ALL available archive generations (.1.gz newest → .N.gz oldest), not
# just yesterday: a host unreachable for several consecutive days still
# carries its last real scan data. Generations are concatenated newest-first
# into one temp file; the awk pass keeps the FIRST record seen per host, so
# the newest generation always wins.
# Phase 4 has already rotated the dat so .1.gz is yesterday's run.
_PREV_DAT_FILE=""
_PREV_DAT_TMP=""
_PREV_GENS=0
_PREV_DAT_TMP=$(mktemp /tmp/rhel_prev_dat.XXXXXX)
for (( _g=1; _g<=${ROTATE_INVENTORY:-3}; _g++ )); do
    if [[ -f "${INVENTORYDATA}.${_g}.gz" ]]; then
        zcat "${INVENTORYDATA}.${_g}.gz" >> "$_PREV_DAT_TMP" 2>/dev/null \
            && _PREV_GENS=$(( _PREV_GENS + 1 ))
    elif [[ -f "${INVENTORYDATA}.${_g}" ]]; then
        cat "${INVENTORYDATA}.${_g}" >> "$_PREV_DAT_TMP" 2>/dev/null \
            && _PREV_GENS=$(( _PREV_GENS + 1 ))
    fi
done
if [[ -s "$_PREV_DAT_TMP" ]]; then
    _PREV_DAT_FILE="$_PREV_DAT_TMP"
    log INFO "Carry-forward: loaded $_PREV_GENS dat archive generation(s) for unreachable-host overlay"
else
    rm -f "$_PREV_DAT_TMP"
    _PREV_DAT_TMP=""
    log INFO "No previous dat archives found — unreachable hosts will show n/a for scan fields (first run?)"
fi

# Previous published CSV — FINAL fallback for hosts unreachable longer than
# all dat generations. Yesterday's CSV rows already contain carried-forward
# data, so this chains indefinitely while the host remains in the host list.
# Decomm-safe: the overlay is only applied to hosts stubbed in TONIGHT's dat,
# and stubs only exist for hosts in the CMDB-filtered host list (Decomm /
# Pending-Decomm already excluded upstream).
_PREV_CSV_FILE=""
_PREV_CSV_TMP=""
if [[ -f "${DATA_DIR}/${INVENTDATACSV}.1.gz" ]]; then
    _PREV_CSV_TMP=$(mktemp /tmp/rhel_prev_csv.XXXXXX)
    zcat "${DATA_DIR}/${INVENTDATACSV}.1.gz" > "$_PREV_CSV_TMP" 2>/dev/null \
        && _PREV_CSV_FILE="$_PREV_CSV_TMP" \
        || rm -f "$_PREV_CSV_TMP"
    [[ -n "$_PREV_CSV_FILE" ]] && \
        log INFO "Carry-forward: previous published CSV loaded as final fallback (${INVENTDATACSV}.1.gz)"
fi

if [[ $CMDB_AVAILABLE -eq 1 ]]; then
    log INFO "Enriching CSV with CMDB data from: $CMDBDATAFILE"
else
    log WARN "Generating CSV without CMDB enrichment (n/a for CMDB fields)"
fi

[[ -n "$_DEPLOY_FILE" ]] && \
    log INFO "BuildDate fallback: loading deployment records from $_DEPLOY_FILE"

# ---------------------------------------------------------------------------
# Single awk pass — up to five input files
#
# Pass 0  (PREV_DAT):       build prev[host] = full 28-field dat record from
#                           all archive generations (newest wins). Used to
#                           carry forward data for TIMEOUT/SSHFAIL hosts.
# Pass 0b (PREV_CSV):       build prevcsv[host] = yesterday published CSV row.
#                           Final fallback when host is unreachable longer
#                           than all dat generations (chains indefinitely).
# Pass 1  (DEPLOYMENTDATA): build deploy_date[normalised host] = date
# Pass 2  (CMDBDATAFILE):   build cmdb[host] = "sg,status,opstate,fed"
# Pass 3  (INVENTORYDATA):  join + emit 32-column CSV rows
#
# Location normalisation (mirrors expand_location() in rhel_utils.sh):
#   Strip "Greenfield-" prefix; all known codes pass through as-is.
#   Add new datacenters here when they come online.
# ---------------------------------------------------------------------------
awk -v prev_dat_file="$_PREV_DAT_FILE" \
    -v prev_csv_file="$_PREV_CSV_FILE" \
    -v deploy_file="$_DEPLOY_FILE" \
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
{ if (FILENAME != current_file) current_file = FILENAME }

# ============================================================
# Pass 0 — PREV_DAT: build prev[host] lookup from yesterday
# Stores the entire 28-field space-delimited record so TIMEOUT
# hosts can carry forward their previous scan real data.
# ============================================================
current_file == prev_dat_file && !/^#/ && NF >= 3 {
    # Store previous record for unreachable-host carry-forward.
    # Generations are concatenated newest-first, so keep the FIRST record
    # seen per host (newest generation wins).
    # Exclude bare TIMEOUT/SSHFAIL stubs (no real data) and header lines —
    # a stub in gen 1 falls through to real data in an older generation.
    if ($2 != "TIMEOUT" && $2 != "SSHFAIL" && $3 != "TIMEOUT" && $3 != "SSHFAIL") {
        if (!($1 in prev)) prev[$1] = $0
    }
    next
}

# ============================================================
# Pass 0b — PREV_CSV: yesterday published CSV, keyed by host.
# Final fallback when a host has been unreachable longer than
# all dat archive generations. Rows already carry forward, so
# the chain persists as long as the host stays in the host list.
# ============================================================
current_file == prev_csv_file && !/^#/ {
    ci = index($0, ",")
    if (ci > 1) {
        ch = substr($0, 1, ci - 1)
        if (!(ch in prevcsv)) prevcsv[ch] = $0
    }
    next
}

current_file == deploy_file && !/^#/ && NF >= 2 {
    # Harden the lookup against legacy-seeded record drift:
    #   - strip CR (records copied from files with DOS line endings)
    #   - normalise hostname key: lowercase + strip any domain suffix
    #     (dat hostnames are short lowercase; legacy deployment records
    #      may be FQDN and/or mixed case)
    #   - only accept records whose first word is a real YYYY-MM-DD date
    #     ("unknown" placeholder records must never mask a valid lookup)
    # Note: [0-9][0-9][0-9][0-9] instead of [0-9]{4} — mawk has no ERE
    # interval support and would silently never match.
    gsub(/\r/, "")
    if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
        dk = tolower($2)
        sub(/\..*$/, "", dk)
        if (dk != "") deploy_date[dk] = $1
    }
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
    typ  = $2

    # Skip non-RHEL hosts entirely — OS "?" means no /etc/redhat-release
    if ($3 == "?") { next }

    # For unreachable hosts (TIMEOUT or SSHFAIL stubs): overlay the newest
    # archived dat record so real scan data (kernel, CPU, memory etc.) is
    # preserved rather than showing n/a. Type becomes <STUB>_Virt / _Phys /
    # _Cloud based on the carried record.
    is_stub = (typ == "TIMEOUT" || typ == "SSHFAIL")
    if (is_stub && (host in prev)) {
        stub = typ
        n = split(prev[host], pf, " ")
        # Rebuild $2-$28 from the carried record
        for (i = 1; i <= n; i++) $i = pf[i]
        # Strip any stub prefix from prev type to avoid compounding
        # (TIMEOUT_Virt carried → Virt → TIMEOUT_Virt today, not TIMEOUT_TIMEOUT_Virt)
        prev_typ = pf[2]
        sub(/^TIMEOUT_/, "", prev_typ)
        sub(/^SSHFAIL_/, "", prev_typ)
        if (prev_typ == "Virt" || prev_typ == "Cloud" || prev_typ == "TIMEOUT" || prev_typ == "SSHFAIL") typ = stub "_Virt"
        else if (prev_typ == "Phys") typ = stub "_Phys"
        else typ = stub "_" prev_typ
        cf_dat++
    } else if (is_stub && (host in prevcsv)) {
        # Host unreachable longer than all dat generations — re-emit its
        # row from yesterday published CSV, forcing the type column to
        # reflect tonight stub state.
        nc = split(prevcsv[host], cf, ",")
        t2 = cf[2]
        sub(/^TIMEOUT_/, "", t2)
        sub(/^SSHFAIL_/, "", t2)
        if (t2 == "Virt" || t2 == "Phys" || t2 == "Cloud") cf[2] = typ "_" t2
        else cf[2] = typ "_Virt"
        out = cf[1]
        for (i = 2; i <= nc; i++) out = out "," cf[i]
        print out >> out_file
        cf_csv++
        if (cmdb_available == "1" && (host in cmdb)) matched++; else missing++
        next
    } else if (is_stub) {
        # No previous data anywhere — stub with n/a fields
        typ = typ "_Virt"
    }

    loc = expand_loc($21)

    # IP address in location field — repurposed server with duplicate config block
    if (loc ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) loc = "unknown"

    # Cloud datacenter — set type to Cloud or TIMEOUT_Cloud based on location
    if (loc == "AZCE" || loc == "AZE2") {
        if (typ ~ /^TIMEOUT/) typ = "TIMEOUT_Cloud"
        else typ = "Cloud"
    }

    # Derive AppCode from hostname if field is n/a (TIMEOUT stubs + some legacy)
    appcode = na($26)
    if (appcode == "n/a") {
        appcode = host
        sub(/^[a-z]/, "", appcode)
        match(appcode, /^[a-z]+/)
        appcode = (RLENGTH > 0) ? substr(appcode, 1, RLENGTH) : "n/a"
    }

    # BuildDate: prefer PROVISIONDATE from the live scan (field 28); fall
    # back to the deployments dat. Lookup key is normalised the same way as
    # the deploy pass (lowercase, domain stripped) so legacy-seeded records
    # match regardless of case or FQDN form.
    bdate = na($28)
    if (bdate == "n/a") {
        hk = tolower(host)
        sub(/\..*$/, "", hk)
        if (hk in deploy_date) {
            bdate = deploy_date[hk]
            fb_hit++
        } else {
            fb_miss++
        }
    }

    if (cmdb_available == "1" && (host in cmdb)) {
        split(cmdb[host], cv, ",")
        c1 = na(cv[1]); c2 = na(cv[2])
        c3 = na(cv[3]); c4 = na(cv[4])
        matched++
    } else {
        c1 = "n/a"; c2 = "n/a"; c3 = "n/a"; c4 = "n/a"
        missing++
    }

    print host "," typ "," loc "," appcode "," na($27) "," bdate "," \
          na($3) "," na($4) "," na($5) "," na($6) "," na($7) "," \
          na($8) "," na($9) "," na($10) "," na($11) "," na($12) "," \
          na($13) "," na($14) "," na($15) "," na($16) "," na($17) "," \
          na($18) "," na($19) "," na($20) "," na($22) "," na($23) "," \
          na($24) "," na($25) "," c1 "," c2 "," c3 "," c4 \
          >> out_file
    next
}

END {
    print matched+0 ":" missing+0 ":" fb_hit+0 ":" fb_miss+0 ":" cf_dat+0 ":" cf_csv+0 > stats_file
}
' \
    ${_PREV_DAT_FILE:+"$_PREV_DAT_FILE"} \
    ${_PREV_CSV_FILE:+"$_PREV_CSV_FILE"} \
    ${_DEPLOY_FILE:+"$_DEPLOY_FILE"} \
    ${_CMDB_FILE:+"$_CMDB_FILE"} \
    "$INVENTORYDATA"

# Clean up decompressed carry-forward temp files
[[ -n "$_PREV_DAT_TMP" && -f "$_PREV_DAT_TMP" ]] && rm -f "$_PREV_DAT_TMP"
[[ -n "$_PREV_CSV_TMP" && -f "$_PREV_CSV_TMP" ]] && rm -f "$_PREV_CSV_TMP"

# Read counts written by awk END block
# Format: matched:missing:builddate_filled:builddate_still_na:carried_from_dat:carried_from_csv
if [[ -f "${DATA_DIR}/${INVENTDATACSV}.stats" ]]; then
    IFS=':' read -r _CMDB_MATCHED _CMDB_MISSING _BD_HIT _BD_MISS _CF_DAT _CF_CSV \
        < "${DATA_DIR}/${INVENTDATACSV}.stats"
    rm -f "${DATA_DIR}/${INVENTDATACSV}.stats"
else
    _CMDB_MATCHED=0; _CMDB_MISSING=0; _BD_HIT=0; _BD_MISS=0; _CF_DAT=0; _CF_CSV=0
fi

log INFO "BuildDate fallback: ${_BD_HIT:-0} hosts filled from deployments dat, ${_BD_MISS:-0} still n/a (no record found)"
log INFO "Carry-forward: ${_CF_DAT:-0} unreachable hosts filled from dat archives, ${_CF_CSV:-0} from previous CSV"

if [[ $CMDB_AVAILABLE -eq 1 ]]; then
    log INFO "CMDB enrichment complete — matched: $_CMDB_MATCHED, not in CMDB: $_CMDB_MISSING"
else
    _TOTAL=$(grep -c "^[^#]" "${DATA_DIR}/${INVENTDATACSV}.new" 2>/dev/null || echo 0)
    log INFO "CSV generation complete — $_TOTAL records (no CMDB enrichment)"
fi

# Atomic promotion — sort by hostname (field 1) first so the CSV is
# consistent across runs and history diffs are clean.
# Header line (starts with #) is preserved at the top.
{
    grep "^#" "${DATA_DIR}/${INVENTDATACSV}.new"
    grep -v "^#" "${DATA_DIR}/${INVENTDATACSV}.new" | sort -t, -k1,1
} > "${DATA_DIR}/${INVENTDATACSV}.sorted"

mv "${DATA_DIR}/${INVENTDATACSV}.sorted" "${DATA_DIR}/$INVENTDATACSV"
cp "${DATA_DIR}/$INVENTDATACSV" "${WEBDIR}/$INVENTDATACSV"
rm -f "${DATA_DIR}/${INVENTDATACSV}.new"
log INFO "CSV published (sorted by hostname): $WEBDIR/$INVENTDATACSV"

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

mkdir -p "${WEBDIR}/historical_data"

if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    # Test mode — just overwrite, no rotation (saves disk space)
    cp "${WEBDIR}/$INVENTDATACSV" \
        "${WEBDIR}/historical_data/${INVENTDATACSV}" 2>/dev/null
    log INFO "TEST MODE — skipping CSV rotation (overwrite only)"
else
    # Production rotation order:
    #   1. Rotate existing copies UP first (old .1.csv → .2.csv etc.)
    #   2. Copy current CSV to .1.csv position via rotate_plain
    #   3. The live WEBDIR file stays as-is for the web server
    #
    # rotate_plain expects the BASE name without extension.
    # INVENTDATACSV = "RHEL_INVENTORY.csv" → base = "RHEL_INVENTORY"
    _CSV_BASE="${WEBDIR}/historical_data/${INVENTDATACSV%.csv}"

    # Copy current CSV into historical_data under its full name first
    # (rotate_plain will shift it to .1.csv)
    cp "${WEBDIR}/$INVENTDATACSV" \
        "${WEBDIR}/historical_data/$INVENTDATACSV" 2>/dev/null

    rotate_plain "$_CSV_BASE" "$ROTATE_INVENTORY_CSV" -e ".csv" \
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