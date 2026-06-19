#!/bin/bash
# =============================================================================
# rhel_pkginventory.sh — RHEL package inventory collector
# =============================================================================
# Replaces: RHEL_pkginventory_refresh.sh
#
# Runs from the secondary jumpbox (not the main inventory jumpbox) due to
# the additional time this scan takes across 22k+ hosts.
#
# The package collection itself is handled by rhel_remote_scan.sh which
# already emits PKG| tagged lines as part of the unified single-hop scan.
# This script is the standalone entry point for running ONLY the package
# inventory from the secondary jumpbox, producing RHEL_PACKAGES.csv
# independently of the main inventory run.
#
# If this script is run on the same jumpbox as the main inventory, it will
# produce a fresh RHEL_PACKAGES.csv using its own pssh sweep — the PKG|
# lines from rhel_remote_scan.sh are reused but the INV|/ID|/DB| output
# is discarded by the filter.
#
# Output: RHEL_PACKAGES.csv
#   Header: Host,Package,Version,Release,Install date
#   One row per installed RPM per host, sorted by host then package name.
#
# Published to:
#   $PACKAGEDATA  (local data dir)
#   $WEBDIR/RHEL_PACKAGES.csv
#
# Crontab example (secondary jumpbox, weekdays at 1am):
#   00 01 * * 1-5 cd /usr/local/pnc/bin/RHEL_Inventory && \
#     ./rhel_pkginventory.sh >> logs/rhel_pkginventory.log 2>&1
# =============================================================================

cd "$(dirname "$0")" || exit 1

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

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# Also tee into the append-only master log
exec > >(tee -a "$MAIN_LOG") 2>&1

export PGMDIR
PGMDIR="$(pwd)"
export PATH=/usr/local/pssh/bin:/usr/local/bin:$PATH

# =============================================================================
log SECTION "Starting RHEL Package Inventory"
# =============================================================================

log INFO "Host list  : $MASTERHOSTLIST"
log INFO "Output     : $PACKAGEDATA"
log INFO "Web dir    : $WEBDIR"
log INFO "pssh batch : $PSSH_BATCH  timeout: ${PSSH_TIMEOUT}s"

# --- Validate prerequisites --------------------------------------------------
if [[ ! -f "$MASTERHOSTLIST" ]]; then
    log ERROR "Host list not found: $MASTERHOSTLIST"
    exit 1
fi

if [[ ! -x "$PSSH_BIN" ]]; then
    log ERROR "pssh binary not found or not executable: $PSSH_BIN"
    exit 1
fi

if [[ ! -x "${PGMDIR}/rhel_remote_scan.sh" ]]; then
    log ERROR "rhel_remote_scan.sh not found in ${PGMDIR}"
    exit 1
fi

if [[ ! -x "${PGMDIR}/rhel_filter_pkgs.sh" ]]; then
    log ERROR "rhel_filter_pkgs.sh not found in ${PGMDIR}"
    exit 1
fi

HOSTCOUNT=$(grep -v "^#" "$MASTERHOSTLIST" | wc -l)
log INFO "Scanning $HOSTCOUNT hosts"

mkdir -p "$DATA_DIR" "$WEBDIR"

# Error directory for this run
PKG_ERRDIR="${DATA_DIR}/errdir_pkgs.$(date +%Y%m%d_%H%M)"
mkdir -p "$PKG_ERRDIR"
log INFO "pssh error dir: $PKG_ERRDIR"

# =============================================================================
log SECTION "Phase 1 — Cleanup"
# =============================================================================

rm -f "$PACKAGETEMP"
log INFO "Cleared stale package temp file"

# Write CSV header
echo "Host,Package,Version,Release,Install date" > "$PACKAGETEMP"
log INFO "Package temp initialised: $PACKAGETEMP"

# =============================================================================
log SECTION "Phase 2 — Parallel SSH package scan"
# =============================================================================

# rhel_remote_scan.sh emits all four tag types (INV|, ID|, DB|, PKG|).
# rhel_filter_pkgs.sh passes only PKG| lines through, discarding the rest.
# This avoids a separate per-host script just for packages while keeping
# the single-hop design intact.

log INFO "Launching pssh scan..."

START_TIME=$(date +%s)

cat "${PGMDIR}/rhel_remote_scan.sh" \
    | "$PSSH_BIN" $PSSH_OPTS \
        -e "$PKG_ERRDIR" \
        -h "$MASTERHOSTLIST" \
        -x "-q -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=30" \
        bash \
    | "${PGMDIR}/rhel_filter_pkgs.sh" >> "$PACKAGETEMP"

SCAN_RC=$?
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

log INFO "pssh scan completed in ${ELAPSED_MIN}m ${ELAPSED_SEC}s (exit status: $SCAN_RC)"

# Remove zero-size error files
if [[ -d "$PKG_ERRDIR" && "$PKG_ERRDIR" =~ errdir ]]; then
    ERRCOUNT_BEFORE=$(find "$PKG_ERRDIR" -type f | wc -l)
    find "$PKG_ERRDIR" -type f -size 0 | xargs rm -f
    ERRCOUNT_AFTER=$(find "$PKG_ERRDIR" -type f | wc -l)
    log INFO "Error dir: removed $((ERRCOUNT_BEFORE - ERRCOUNT_AFTER)) empty files, $ERRCOUNT_AFTER hosts had errors"
fi

# Validate output
if [[ ! -s "$PACKAGETEMP" ]]; then
    log ERROR "Package temp file is empty after scan — aborting promotion"
    exit 1
fi

PKG_LINES=$(wc -l < "$PACKAGETEMP")
# Subtract 1 for the header line
PKG_RECORDS=$(( PKG_LINES - 1 ))
log INFO "Collected $PKG_RECORDS package records across $HOSTCOUNT hosts"

# Sanity check — warn if record count looks suspiciously low
# A healthy scan of 22k hosts typically yields several million rows
EXPECTED_MIN=$(( HOSTCOUNT * 50 ))
if [[ $PKG_RECORDS -lt $EXPECTED_MIN ]]; then
    log WARN "Record count ($PKG_RECORDS) is below expected minimum ($EXPECTED_MIN) — scan may be incomplete"
fi

# =============================================================================
log SECTION "Phase 3 — Rotate and promote"
# =============================================================================

log INFO "Rotating $PACKAGEDATA (keeping $ROTATE_PACKAGES copies)"
rotate_compressed "$PACKAGEDATA" "$ROTATE_PACKAGES"

mv "$PACKAGETEMP" "$PACKAGEDATA"
log INFO "Package data promoted: $PACKAGEDATA"

cp -p "$PACKAGEDATA" "$WEBDIR/RHEL_PACKAGES.csv"
log INFO "Package data published: $WEBDIR/RHEL_PACKAGES.csv"

# =============================================================================
log SECTION "Phase 4 — Stale error directory cleanup"
# =============================================================================

CLEANED=$(find "$PGMDIR" \
    -type d \
    -name "errdir_pkgs*" \
    -mtime +"$ERRDIR_RETAIN_DAYS" \
    -ls \
    -exec rm -rf '{}' \; 2>/dev/null | wc -l)
log INFO "Removed $CLEANED stale package error directories older than ${ERRDIR_RETAIN_DAYS} days"

# =============================================================================
log SECTION "rhel_pkginventory.sh complete"
# =============================================================================

FINAL_SIZE=$(du -sh "$PACKAGEDATA" | cut -f1)
log INFO "Final package data file size: $FINAL_SIZE"
log INFO "Published to: $WEBDIR/RHEL_PACKAGES.csv"

exit 0
