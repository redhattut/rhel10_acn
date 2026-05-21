#!/bin/bash
# =============================================================================
# main.sh — TTI EAR termination/transfer orchestrator
# =============================================================================
# Replaces: main.ksh
#
# Flow per run:
#   1. Truncate all working logs (fresh start every run)
#   2. Acquire lock
#   3. getdata.sh     — fetch OIM files, build terms.ids / trans.ids
#   4. cleanup.sh --mode terms — home dirs + /etc/passwd + /etc/group (one SSH)
#   5. cleanup.sh --mode trans — same for transferred users
#   6. Archive unreachable hosts log with timestamp
#   7. Send completion email (tti_cleanup.log body)
#   8. Release lock
#
# Log file behaviour:
#   logs/tti_process.log      — overwritten at start of every run
#   logs/tti_cleanup.log      — overwritten at start of every run
#   logs/tti_getdata.log      — overwritten at start of every run
#   logs/tti_unreachable.log  — overwritten at start of every run
#   logs/linuxterms.STAMP     — timestamped archive, never overwritten
#   logs/linuxtrans.STAMP     — timestamped archive, never overwritten
#   logs/linux.STAMP          — timestamped unreachable archive
#
# Dry-run equivalents in logs/dryrun/:
#   dryrun_tti_process.log      — overwritten each dry-run
#   dryrun_tti_cleanup.log      — overwritten each dry-run
#   dryrun_tti_getdata.log      — overwritten each dry-run
#   dryrun_tti_unreachable.log  — overwritten each dry-run
#   dryrun_linuxterms.STAMP     — timestamped archive
#   dryrun_linuxtrans.STAMP     — timestamped archive
#
# Email notification:
#   Sent at completion via /usr/bin/mail to the NOTIFY alias (ttinotify).
#   ttinotify is a local mail alias in /etc/aliases — run 'newaliases' after
#   editing. Mail is sent as the user running the script (typically root).
#   Use --no-email to suppress notification (useful for manual/test runs).
#
# Options:
#   --dry-run      No changes on servers; logs go to logs/dryrun/
#   --no-email     Skip completion email
#   --debug        Verbose pssh diagnostics per batch
#   --debug-pssh   Single plain-ssh test against first server, then exit
#   --ids-file     Override ID file passed through to cleanup.sh
#   --hosts-file   Override server list passed through to cleanup.sh
#
# Cron (daily 11:20):
#   20 11 * * * /export/home/xamrgpti/scripts/main.sh >> /dev/null 2>&1
#
# Retention cron (daily 23:00):
#   0 23 * * * find /export/home/xamrgpti/data/terms  -type f -mtime +365 -delete
#   0 23 * * * find /export/home/xamrgpti/data/trans  -type f -mtime +365 -delete
#   0 23 * * * find /export/home/xamrgpti/logs        -maxdepth 1 -type f -mtime +365 -delete
#   0 23 * * * find /export/home/xamrgpti/data/ids    -type f -mtime +730 -delete
#   0 23 * * * find /export/home/xamrgpti/logs/dryrun -type f -mtime +90  -delete
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
DEBUG_FLAG=""
IDS_FILE_FLAG=""
HOSTS_FILE_FLAG=""
NO_EMAIL_FLAG=""
SEND_EMAIL=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; DRY_RUN_FLAG="--dry-run"; shift ;;
        --no-email)   SEND_EMAIL=false; NO_EMAIL_FLAG="--no-email"; shift ;;
        --debug)      DEBUG_FLAG="--debug"; shift ;;
        --debug-pssh) DEBUG_FLAG="--debug-pssh"; shift ;;
        --ids-file)   IDS_FILE_FLAG="--ids-file $2"; shift 2 ;;
        --hosts-file) HOSTS_FILE_FLAG="--hosts-file $2"; shift 2 ;;
        *) shift ;;
    esac
done

RUN_STAMP=$(date +%y%m%d%H%M)

# --- Log path setup ----------------------------------------------------------
# All working logs are truncated (overwritten) at the start of each run.
# Dry-run: all logs redirect to logs/dryrun/ with dryrun_ prefix.
# Live:    logs stay in logs/.
mkdir -p "${LOGS_DIR}" "${DRYRUN_LOGS_DIR}" "${DATA_DIR}" "${IDS_DIR}" \
         "${TERMS_ARCHIVE_DIR}" "${TRANS_ARCHIVE_DIR}"

if ${DRY_RUN}; then
    MAIN_LOG="${DRYRUN_LOGS_DIR}/dryrun_tti_process.log"
    LOG_GETDATA="${DRYRUN_LOGS_DIR}/dryrun_tti_getdata.log"
    LOG_CLEANUP="${DRYRUN_LOGS_DIR}/dryrun_tti_cleanup.log"
    LOG_HOSTS="${DRYRUN_LOGS_DIR}/dryrun_tti_unreachable.log"
fi

# Truncate all working logs — fresh start for this run
: > "${MAIN_LOG}"
: > "${LOG_GETDATA}"
: > "${LOG_CLEANUP}"
: > "${LOG_HOSTS}"

# Export so child scripts inherit the correct paths after sourcing tti.conf
export MAIN_LOG LOG_GETDATA LOG_CLEANUP LOG_HOSTS

# --- Logging -----------------------------------------------------------------
_log() {
    local level="$1" msg="$2" ts line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    line=$(printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}")
    echo "${line}" | tee -a "${MAIN_LOG}"
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

# --- Email -------------------------------------------------------------------
# ttinotify is a local mail alias defined in /etc/aliases.
# It maps to one or more real email addresses. Run 'newaliases' after editing.
# Mail is sent as the Unix user running this script (typically root).
# The body is tti_cleanup.log (or its dryrun equivalent), sent at completion.
send_completion_email() {
    if ! ${SEND_EMAIL}; then
        log_info "Email notification skipped (--no-email)."
        return
    fi
    local subject="TTI EAR cleanup complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true ) — $(hostname) $(date '+%Y-%m-%d %H:%M')"
    /usr/bin/mail -s "${subject}" "${NOTIFY}" < "${LOG_CLEANUP}" || true
    log_info "Completion email sent to ${NOTIFY}."
}

# =============================================================================
# Main
# =============================================================================

log_info "================================================================"
log_info "main.sh start — $(hostname)$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_info "Send email  : $( ${SEND_EMAIL} && echo "yes (${NOTIFY})" || echo "no (--no-email)" )"
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
       send_completion_email
       trap - ERR EXIT; release_lock; exit 0 ;;
    *) log_fatal "getdata.sh returned exit code ${getdata_rc}." ;;
esac

# ------------------------------------------------------------------
# Step 2 — Combined cleanup: home dirs + /etc/passwd + /etc/group
# ------------------------------------------------------------------
log_info "--- Step 2: cleanup.sh terms ---"
if [[ -s "${DATA_DIR}/terms.ids" ]]; then
    # shellcheck disable=SC2086
    "${SCRIPT_DIR}/cleanup.sh" --mode terms ${DRY_RUN_FLAG} ${NO_EMAIL_FLAG} ${DEBUG_FLAG} ${IDS_FILE_FLAG} ${HOSTS_FILE_FLAG}
    log_success "Cleanup (terms) complete."
else
    log_warn "terms.ids empty — skipping cleanup for terms."
fi

log_info "--- Step 3: cleanup.sh trans ---"
if [[ -s "${DATA_DIR}/trans.ids" ]]; then
    # shellcheck disable=SC2086
    "${SCRIPT_DIR}/cleanup.sh" --mode trans ${DRY_RUN_FLAG} ${NO_EMAIL_FLAG} ${DEBUG_FLAG} ${IDS_FILE_FLAG} ${HOSTS_FILE_FLAG}
    log_success "Cleanup (trans) complete."
else
    log_info "trans.ids empty — no cleanup needed for trans."
fi

# ------------------------------------------------------------------
# Step 3 — Archive unreachable hosts log
# ------------------------------------------------------------------
log_info "--- Step 4: Archive unreachable hosts log ---"
if [[ -s "${LOG_HOSTS}" ]]; then
    if ${DRY_RUN}; then
        cp "${LOG_HOSTS}" "${DRYRUN_LOGS_DIR}/dryrun_linux.${RUN_STAMP}"
        log_info "Dry-run unreachable hosts archived -> dryrun_linux.${RUN_STAMP}"
    else
        cp "${LOG_HOSTS}" "${LOGS_DIR}/linux.${RUN_STAMP}"
        log_info "Unreachable hosts archived -> linux.${RUN_STAMP}"
    fi
else
    log_info "No unreachable hosts recorded this run."
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
log_info "================================================================"
log_summary "main.sh complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_info "================================================================"

trap - ERR EXIT
release_lock

send_completion_email

exit 0
