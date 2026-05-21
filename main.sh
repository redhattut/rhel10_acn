#!/bin/bash
# =============================================================================
# main.sh — TTI EAR termination/transfer orchestrator
# =============================================================================
# Replaces: main.ksh
#
# Flow per run:
#   1. Acquire lock
#   2. getdata.sh        — fetch OIM files, build terms.ids / trans.ids
#   3. cleanup_homes.sh  --mode terms  — remove /home/userid + /home/useridOUD
#   4. cleanup_homes.sh  --mode trans  — same for transferred users
#   5. cleanup_passwd_group.sh --mode terms — /etc/passwd + /etc/group cleanup
#   6. cleanup_passwd_group.sh --mode trans — same for transferred users
#   7. Archive linux.STAMP (unreachable hosts log)
#   8. Release lock
#
# Options:
#   --dry-run    Passed to all cleanup scripts; no changes made on servers
#
# Cron (daily 11:20):
#   20 11 * * * /export/home/xamrgpti/scripts/main.sh >> /dev/null 2>&1
#
# Retention cron (daily 23:00):
#   0 23 * * * find /export/home/xamrgpti/data/terms -type f -mtime +365 -delete
#   0 23 * * * find /export/home/xamrgpti/data/trans -type f -mtime +365 -delete
#   0 23 * * * find /export/home/xamrgpti/logs       -type f -mtime +365 -delete
#   0 23 * * * find /export/home/xamrgpti/data/ids        -type f -mtime +730 -delete
#   0 23 * * * find /export/home/xamrgpti/logs/dryrun    -type f -mtime +90  -delete
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG="${SCRIPT_DIR}/tti.conf"
[[ -f "${CONFIG}" ]] || { echo "[FATAL] Config not found: ${CONFIG}" >&2; exit 1; }
source "${CONFIG}"

# --- Arguments ---------------------------------------------------------------
DRY_RUN=false
DRY_RUN_FLAG=""
for arg in "$@"; do
    if [[ "${arg}" == "--dry-run" ]]; then
        DRY_RUN=true
        DRY_RUN_FLAG="--dry-run"
    fi
done

RUN_STAMP=$(date +%y%m%d%H%M)

# Dry-run runs must not touch tti_process.log — all output goes to dryrun/ only.
# Compute a dryrun-specific log path now so main.sh's own log lines also land there.
if ${DRY_RUN}; then
    mkdir -p "${DRYRUN_LOGS_DIR}"
    existing=$(ls "${DRYRUN_LOGS_DIR}/dryrun-main-"*"-${RUN_STAMP}" 2>/dev/null | wc -l || true)
    DRYRUN_NUM=$(( existing + 1 ))
    DRYRUN_MAIN_LOG="${DRYRUN_LOGS_DIR}/dryrun-main-${DRYRUN_NUM}-${RUN_STAMP}"
fi

# --- Logging -----------------------------------------------------------------
_log() {
    local level="$1" msg="$2" ts line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    line=$(printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}")
    if ${DRY_RUN}; then
        # Dry-run: write only to dryrun log, never touch tti_process.log
        echo "${line}" >> "${DRYRUN_MAIN_LOG}"
    else
        # Live: write to tti_process.log and also print to stdout for cron capture
        echo "${line}" | tee -a "${MAIN_LOG}"
    fi
}
log_info()    { _log "INFO"    "$1"; }
log_success() { _log "SUCCESS" "$1"; }
log_warn()    { _log "WARN"    "$1"; }
log_error()   { _log "ERROR"   "$1"; }
log_summary() { _log "SUMMARY" "$1"; }
log_fatal()   { _log "FATAL"   "$1"; exit 1; }

# --- Lock --------------------------------------------------------------------
acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        log_warn "Lock file present: ${LOCK_FILE} — another run may be active."
        echo "TTI EAR blocked — lock file present on $(hostname)" \
            | /usr/bin/mail -s "TTI lock conflict on $(hostname)" "${NOTIFY}" || true
        exit 1
    fi
    touch "${LOCK_FILE}"
    log_info "Lock acquired."
}

release_lock() {
    rm -f "${LOCK_FILE}"
    log_info "Lock released."
}

trap 'release_lock; log_error "main.sh exited unexpectedly."' ERR EXIT

# =============================================================================
# Main
# =============================================================================

mkdir -p "${LOGS_DIR}" "${DRYRUN_LOGS_DIR}" "${DATA_DIR}" "${IDS_DIR}" \
         "${TERMS_ARCHIVE_DIR}" "${TRANS_ARCHIVE_DIR}"

# Fresh unreachable-hosts log for this run
: > "${LOG_HOSTS}"

log_info "================================================================"
log_info "main.sh start — $(hostname)$( [[ -n "${DRY_RUN_FLAG}" ]] && echo ' [DRY-RUN]' || true )"
log_info "================================================================"

acquire_lock

# ------------------------------------------------------------------
# Step 1 — Fetch OIM data
# ------------------------------------------------------------------
log_info "--- Step 1: getdata.sh ---"
getdata_rc=0
"${SCRIPT_DIR}/getdata.sh" || getdata_rc=$?

case "${getdata_rc}" in
    0) log_success "New terms data available — proceeding." ;;
    1) log_info "Terms unchanged — nothing to do."
       trap - ERR EXIT; release_lock; exit 0 ;;
    *) log_fatal "getdata.sh returned exit code ${getdata_rc}." ;;
esac

# ------------------------------------------------------------------
# Step 2 — Home directory cleanup
# ------------------------------------------------------------------
log_info "--- Step 2: cleanup_homes.sh terms ---"
if [[ -s "${DATA_DIR}/terms.ids" ]]; then
    # shellcheck disable=SC2086
    "${SCRIPT_DIR}/cleanup_homes.sh" --mode terms ${DRY_RUN_FLAG}
    log_success "Home cleanup (terms) complete."
else
    log_warn "terms.ids empty — skipping home cleanup for terms."
fi

log_info "--- Step 3: cleanup_homes.sh trans ---"
if [[ -s "${DATA_DIR}/trans.ids" ]]; then
    # shellcheck disable=SC2086
    "${SCRIPT_DIR}/cleanup_homes.sh" --mode trans ${DRY_RUN_FLAG}
    log_success "Home cleanup (trans) complete."
else
    log_info "trans.ids empty — no home cleanup needed for trans."
fi

# ------------------------------------------------------------------
# Step 3 — /etc/passwd and /etc/group cleanup
# ------------------------------------------------------------------
log_info "--- Step 4: cleanup_passwd_group.sh terms ---"
if [[ -s "${DATA_DIR}/terms.ids" ]]; then
    # shellcheck disable=SC2086
    "${SCRIPT_DIR}/cleanup_passwd_group.sh" --mode terms ${DRY_RUN_FLAG}
    log_success "passwd/group cleanup (terms) complete."
else
    log_warn "terms.ids empty — skipping passwd/group cleanup for terms."
fi

log_info "--- Step 5: cleanup_passwd_group.sh trans ---"
if [[ -s "${DATA_DIR}/trans.ids" ]]; then
    # shellcheck disable=SC2086
    "${SCRIPT_DIR}/cleanup_passwd_group.sh" --mode trans ${DRY_RUN_FLAG}
    log_success "passwd/group cleanup (trans) complete."
else
    log_info "trans.ids empty — no passwd/group cleanup needed for trans."
fi

# ------------------------------------------------------------------
# Step 4 — Archive unreachable hosts log
# ------------------------------------------------------------------
log_info "--- Step 6: Archive unreachable hosts log ---"
if [[ -s "${LOG_HOSTS}" ]]; then
    cp "${LOG_HOSTS}" "${LOGS_DIR}/linux.${RUN_STAMP}"
    log_info "Unreachable hosts archived -> linux.${RUN_STAMP}"
else
    log_info "No unreachable hosts recorded this run."
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
log_info "================================================================"
log_summary "main.sh complete$( [[ -n "${DRY_RUN_FLAG}" ]] && echo ' [DRY-RUN]' || true )"
log_info "================================================================"

trap - ERR EXIT
release_lock
exit 0
