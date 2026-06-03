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
NOTIFY_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; DRY_RUN_FLAG="--dry-run"; shift ;;
        --no-email)   SEND_EMAIL=false; NO_EMAIL_FLAG="--no-email"; shift ;;
        --notify)     NOTIFY_OVERRIDE="$2"; shift 2 ;;
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
# Mail is sent as the Unix user running this script (root via sudo).
#
# Email format:
#   Subject : TTI EAR Cleanup Report — hostname — date [DRY-RUN if applicable]
#   Body    : Short human-readable summary (counts from SUMMARY log lines)
#   Attachment: full tti_cleanup.log (or dryrun equivalent)
#
# Using mailx -a for attachment. If tti_cleanup.log is empty (no terms/trans
# today), the body explains that clearly and no attachment is sent.

# build_email_body OUTPUT_FILE
#   Writes a short summary to OUTPUT_FILE.
#   Parses SUMMARY lines from LOG_CLEANUP for counts.
#   Falls back to a "nothing to process" message if log is empty.
build_email_body() {
    local out="$1"
    local run_date host_name mode_tag
    run_date=$(date '+%Y-%m-%d %H:%M')
    host_name=$(hostname)
    mode_tag="$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"

    {
        echo "TTI EAR Cleanup Report${mode_tag}"
        echo "Host     : ${host_name}"
        echo "Date     : ${run_date}"
        echo "========================================="
        echo ""

        # Check if cleanup.log has any content
        if [[ ! -s "${LOG_CLEANUP}" ]]; then
            echo "No terminations or transfers to process today."
            echo "OIM files were empty for this run."
            echo ""
            echo "No cleanup log to attach."
            return
        fi

        # Extract SUMMARY lines per mode and format them
        local terms_lines trans_lines
        terms_lines=$(grep "\[SUMMARY\].*cleanup complete\|cleanup_homes\|cleanup complete"             "${LOG_CLEANUP}" 2>/dev/null || true)

        # Parse each SUMMARY line from the log into readable output
        # Two-pass approach:
        # Pass 1 — collect all SUMMARY lines stripped of their log prefix.
        # Pass 2 — walk the stripped lines to build the section output.
        # This avoids ordering issues where "cleanup complete" appears before "Mode".
        local stripped_file
        stripped_file=$(mktemp /var/tmp/tti_summary.XXXXXX)
        grep "\[SUMMARY" "${LOG_CLEANUP}" |             sed 's/^\[.*\] \[SUMMARY *\] \[.*\] //' > "${stripped_file}"

        local in_terms=false in_trans=false
        while IFS= read -r msg; do
            if echo "${msg}" | grep -q "Mode.*:.*terms"; then
                in_terms=true; in_trans=false
                echo "Terminations:"
                continue
            elif echo "${msg}" | grep -q "Mode.*:.*trans"; then
                in_terms=false; in_trans=true
                echo ""; echo "Transfers:"
                continue
            fi
            # Skip the "cleanup complete" header line
            echo "${msg}" | grep -q "^cleanup complete" && continue
            # Print all other SUMMARY fields indented
            if ${in_terms} || ${in_trans}; then
                echo "  ${msg}"
            fi
        done < "${stripped_file}"
        rm -f "${stripped_file}"

        # Add placeholder sections for any mode that had no cleanup run
        if ! grep -q "Mode.*:.*terms" "${LOG_CLEANUP}" 2>/dev/null; then
            echo "Terminations:"
            echo "  No terminations to process today."
        fi
        if ! grep -q "Mode.*:.*trans" "${LOG_CLEANUP}" 2>/dev/null; then
            echo ""; echo "Transfers:"
            echo "  No transfers to process today."
        fi

        echo ""
        echo "========================================="
        echo "Full cleanup log attached."
    } > "${out}"
}

send_completion_email() {
    if ! ${SEND_EMAIL}; then
        log_info "Email notification skipped (--no-email)."
        return
    fi

    # --notify flag overrides NOTIFY alias — useful for testing to a single address
    local send_to="${NOTIFY_OVERRIDE:-${NOTIFY}}"

    local subject="TTI EAR Cleanup Report$( ${DRY_RUN} && echo ' [DRY-RUN]' || true ) — $(hostname) — $(date '+%Y-%m-%d %H:%M')"
    local body_file
    body_file=$(mktemp /var/tmp/tti_email_body.XXXXXX)

    build_email_body "${body_file}"

    if [[ -s "${LOG_CLEANUP}" ]]; then
        /usr/bin/mailx -s "${subject}"               -a "${LOG_CLEANUP}"               "${send_to}" < "${body_file}" || true
        log_info "Completion email sent to ${send_to} (with ${LOG_CLEANUP##*/} attached)."
    else
        /usr/bin/mailx -s "${subject}"               "${send_to}" < "${body_file}" || true
        log_info "Completion email sent to ${send_to} (no attachment — nothing processed)."
    fi

    rm -f "${body_file}"
}

# =============================================================================
# Main
# =============================================================================

log_info "================================================================"
log_info "main.sh start — $(hostname)$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
if ! ${SEND_EMAIL}; then
    log_info "Send email  : no (--no-email)"
elif [[ -n "${NOTIFY_OVERRIDE}" ]]; then
    log_info "Send email  : yes (${NOTIFY_OVERRIDE}) [--notify override]"
else
    log_info "Send email  : yes (${NOTIFY})"
fi
log_info "================================================================"

acquire_lock

# ------------------------------------------------------------------
# Step 1 — Fetch OIM data (skipped when --ids-file is provided)
# ------------------------------------------------------------------
if [[ -n "${IDS_FILE_FLAG}" ]]; then
    # Custom ID file supplied — skip getdata.sh entirely.
    # The caller already knows which users to process; no OIM fetch needed.
    log_info "--- Step 1: getdata.sh SKIPPED (--ids-file provided) ---"
    log_info "Using custom ID file: ${IDS_FILE_FLAG#--ids-file }"
else
    log_info "--- Step 1: getdata.sh ---"
    getdata_rc=0
    "${SCRIPT_DIR}/getdata.sh" || getdata_rc=$?

    case "${getdata_rc}" in
        0) log_success "OIM data fetched — proceeding with cleanup." ;;
        1) log_info "No OIM data to process today — both terms.ids and trans.ids are empty."
           send_completion_email
           trap - ERR EXIT; release_lock; exit 0 ;;
        *) log_fatal "getdata.sh returned exit code ${getdata_rc}." ;;
    esac
fi

# ------------------------------------------------------------------
# Step 2 — Combined cleanup: home dirs + /etc/passwd + /etc/group
# ------------------------------------------------------------------
# When --ids-file is used, cleanup.sh runs for terms mode only
# (the custom file is the ID source; trans is not applicable).
if [[ -n "${IDS_FILE_FLAG}" ]]; then
    log_info "--- Step 2: cleanup.sh terms (custom IDs) ---"
    # shellcheck disable=SC2086
    "${SCRIPT_DIR}/cleanup.sh" --mode terms ${DRY_RUN_FLAG} ${NO_EMAIL_FLAG} ${DEBUG_FLAG} ${IDS_FILE_FLAG} ${HOSTS_FILE_FLAG} || true
    log_success "Cleanup (terms) complete."
else
    log_info "--- Step 2: cleanup.sh terms ---"
    if [[ -s "${DATA_DIR}/terms.ids" ]]; then
        # shellcheck disable=SC2086
        "${SCRIPT_DIR}/cleanup.sh" --mode terms ${DRY_RUN_FLAG} ${NO_EMAIL_FLAG} ${DEBUG_FLAG} ${HOSTS_FILE_FLAG} || true
        log_success "Cleanup (terms) complete."
    else
        log_warn "terms.ids empty — skipping cleanup for terms."
    fi

    log_info "--- Step 3: cleanup.sh trans ---"
    if [[ -s "${DATA_DIR}/trans.ids" ]]; then
        # shellcheck disable=SC2086
        "${SCRIPT_DIR}/cleanup.sh" --mode trans ${DRY_RUN_FLAG} ${NO_EMAIL_FLAG} ${DEBUG_FLAG} ${HOSTS_FILE_FLAG} || true
        log_success "Cleanup (trans) complete."
    else
        log_info "trans.ids empty — no cleanup needed for trans."
    fi
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
