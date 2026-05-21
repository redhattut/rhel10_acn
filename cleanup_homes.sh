#!/bin/bash
# =============================================================================
# cleanup_homes.sh — Parallel home directory cleanup for termed/transferred users
# =============================================================================
# Replaces: linuxterms.ksh (home dir portion), linuxtrans.ksh (home dir portion)
#
# What it does:
#   For each user ID, fans out across all 22k+ servers via pssh in batches of
#   PSSH_BATCH. Checks for /home/<userid> (AD-style) and /home/<useridOUD>
#   (OUD-style). Removes any that exist. Logs only real outcomes — FOUND,
#   SUCCESS, FAILURE, DRY_RUN. Silent for users with no homes anywhere.
#
#   Unreachable hosts are logged to LOG_HOSTS (archived as linux.YYMMDDHHMM).
#
# Usage:
#   cleanup_homes.sh --mode terms|trans [--dry-run]
#
# --dry-run behaviour:
#   - pssh is used to CHECK whether paths exist (read-only, same as live mode)
#   - pssh is NOT called to remove anything
#   - All DRY_RUN log lines describe what would have been removed
#   - Logs are written to DRYRUN_LOGS_DIR/dryrun-N-YYMMDDHHMM
#     where N is auto-incremented for each dry-run on the same day
#   - Live log files (linuxterms.*, linuxtrans.*) are NOT written
#   - The master tti_process.log IS written (dry-run runs are part of history)
#
# Live archived logs:
#   logs/linuxterms.YYMMDDHHMM
#   logs/linuxtrans.YYMMDDHHMM
#   logs/linux.YYMMDDHHMM   (unreachable hosts)
#
# Dry-run archived logs:
#   logs/dryrun/dryrun-N-YYMMDDHHMM
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG="${SCRIPT_DIR}/tti.conf"
[[ -f "${CONFIG}" ]] || { echo "[FATAL] Config not found: ${CONFIG}" >&2; exit 2; }
source "${CONFIG}"

# --- Argument parsing --------------------------------------------------------
MODE=""
DRY_RUN=false

usage() { echo "Usage: ${SCRIPT_NAME} --mode terms|trans [--dry-run]" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)    MODE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *)         usage ;;
    esac
done
[[ "${MODE}" == "terms" || "${MODE}" == "trans" ]] || usage

# --- Derived settings --------------------------------------------------------
IDS_FILE="${DATA_DIR}/${MODE}.ids"
EVENT_TYPE="$( [[ "${MODE}" == "terms" ]] && echo "Terminated" || echo "Transferred" )"
RUN_STAMP=$(date +%y%m%d%H%M)

# Determine archive log path.
# Live runs  -> logs/linuxterms.STAMP or logs/linuxtrans.STAMP
# Dry runs   -> logs/dryrun/dryrun-N-STAMP
#   N is determined by counting existing dryrun files for this stamp prefix.
if ${DRY_RUN}; then
    mkdir -p "${DRYRUN_LOGS_DIR}"
    # Count existing dryrun files for today's stamp to get the next run number
    existing=$(ls "${DRYRUN_LOGS_DIR}/dryrun-"*"-${RUN_STAMP}" 2>/dev/null | wc -l || true)
    DRYRUN_NUM=$(( existing + 1 ))
    ARCHIVE_LOG="${DRYRUN_LOGS_DIR}/dryrun-${DRYRUN_NUM}-${RUN_STAMP}"
else
    if [[ "${MODE}" == "terms" ]]; then
        ARCHIVE_LOG="${LOGS_DIR}/linuxterms.${RUN_STAMP}"
    else
        ARCHIVE_LOG="${LOGS_DIR}/linuxtrans.${RUN_STAMP}"
    fi
fi

PSSH_TMP=$(mktemp -d /var/tmp/tti_pssh.XXXXXX)
trap 'rm -rf "${PSSH_TMP}"' EXIT

# --- Counters ----------------------------------------------------------------
declare -i CNT_USERS=0 CNT_SERVERS=0
declare -i CNT_FOUND=0 CNT_REMOVED=0 CNT_FAILED=0 CNT_UNREACHABLE=0

# --- Logging -----------------------------------------------------------------
# All log lines go to the working log AND the master tti_process.log.
# The working log is later archived to the appropriate location above.

_log() {
    local level="$1" msg="$2" ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}" \
        | tee -a "${LOG_CLEANUP}" >> "${MAIN_LOG}"
}
log_info()    { _log "INFO"    "$1"; }
log_found()   { _log "FOUND"   "$1"; }
log_success() { _log "SUCCESS" "$1"; }
log_failure() { _log "FAILURE" "$1"; }
log_dry_run() { _log "DRY_RUN" "$1"; }
log_warn()    { _log "WARN"    "$1"; }
log_error()   { _log "ERROR"   "$1"; }
log_summary() { _log "SUMMARY" "$1"; }
log_fatal()   {
    _log "FATAL" "$1"
    /usr/bin/mail -s "FATAL: ${SCRIPT_NAME} on $(hostname)" "${NOTIFY}" \
        < "${LOG_CLEANUP}" || true
    exit 2
}

# Unreachable hosts go to LOG_HOSTS (linux.STAMP) and MAIN_LOG.
# Not written during dry-runs since no removal is attempted.
log_unreachable() {
    local host="$1" ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] [%-9s] [%s] Host not responding: %s\n" \
        "${ts}" "WARN" "${SCRIPT_NAME}" "${host}" \
        | tee -a "${LOG_HOSTS}" >> "${MAIN_LOG}"
    (( CNT_UNREACHABLE++ )) || true
}

# --- PSSH helpers ------------------------------------------------------------

build_host_file() {
    local outfile="$1"; shift
    printf '%s\n' "$@" > "${outfile}"
}

# pssh_check_path HOST_FILE PATH
#   READ-ONLY. Checks whether PATH exists on each host in parallel.
#   Returns only the hostnames where the path was found.
#   Called in both live and dry-run modes — checking is always safe.
pssh_check_path() {
    local host_file="$1" path="$2"
    local out_dir="${PSSH_TMP}/chk_out" err_dir="${PSSH_TMP}/chk_err"
    mkdir -p "${out_dir}" "${err_dir}"
    rm -rf "${out_dir:?}/"* "${err_dir:?}/"* 2>/dev/null || true

    # shellcheck disable=SC2086
    "${PSSH_BIN}" ${PSSH_OPTS} \
        -h "${host_file}" \
        -o "${out_dir}" \
        -e "${err_dir}" \
        "test -e '${path}' && echo EXISTS || true" \
        2>/dev/null || true

    for result_file in "${out_dir}"/*; do
        [[ -f "${result_file}" ]] || continue
        if grep -q "^EXISTS" "${result_file}" 2>/dev/null; then
            basename "${result_file}"
        fi
    done

    # Hosts with stderr and no stdout = unreachable (only log in live mode)
    if ! ${DRY_RUN}; then
        for err_file in "${err_dir}"/*; do
            [[ -s "${err_file}" ]] || continue
            local host
            host=$(basename "${err_file}")
            [[ ! -f "${out_dir}/${host}" ]] && log_unreachable "${host}"
        done
    fi
}

# pssh_remove_path HOST_FILE PATH
#   WRITE operation. Only called in live mode — never during dry-run.
#   Populates REMOVED_HOSTS and FAILED_HOSTS arrays.
REMOVED_HOSTS=()
FAILED_HOSTS=()
pssh_remove_path() {
    local host_file="$1" path="$2"
    local out_dir="${PSSH_TMP}/rm_out" err_dir="${PSSH_TMP}/rm_err"
    mkdir -p "${out_dir}" "${err_dir}"
    rm -rf "${out_dir:?}/"* "${err_dir:?}/"* 2>/dev/null || true
    REMOVED_HOSTS=(); FAILED_HOSTS=()

    # shellcheck disable=SC2086
    "${PSSH_BIN}" ${PSSH_OPTS} \
        -h "${host_file}" \
        -o "${out_dir}" \
        -e "${err_dir}" \
        "rm -rf '${path}' && echo REMOVED || echo FAILED" \
        2>/dev/null || true

    for result_file in "${out_dir}"/*; do
        [[ -f "${result_file}" ]] || continue
        local host
        host=$(basename "${result_file}")
        if grep -q "^REMOVED" "${result_file}" 2>/dev/null; then
            REMOVED_HOSTS+=("${host}")
        else
            FAILED_HOSTS+=("${host}")
        fi
    done
}

# process_home_path USER HOME_PATH
#   Fans out across ALL_SERVERS in batches of PSSH_BATCH.
#   In dry-run mode: checks only, logs DRY_RUN per found server, no removal.
#   In live mode:    checks, then removes on servers where path was found.
#   Zero log lines emitted when user has no homes anywhere.
process_home_path() {
    local user="$1" home_path="$2"
    local total=${#ALL_SERVERS[@]} i=0 batch_num=0

    while [[ ${i} -lt ${total} ]]; do
        local -a batch=("${ALL_SERVERS[@]:${i}:${PSSH_BATCH}}")
        (( batch_num++ )) || true
        (( i += PSSH_BATCH )) || true

        local batch_host_file="${PSSH_TMP}/hosts_b${batch_num}.txt"
        build_host_file "${batch_host_file}" "${batch[@]}"

        local -a found_servers=()
        mapfile -t found_servers < <(pssh_check_path "${batch_host_file}" "${home_path}")
        [[ ${#found_servers[@]} -eq 0 ]] && continue

        # Log FOUND for each server that has the path
        for srv in "${found_servers[@]}"; do
            log_found "${user}: ${home_path} on ${srv}"
            (( CNT_FOUND++ )) || true
        done

        # DRY-RUN: report what would happen, do nothing
        if ${DRY_RUN}; then
            for srv in "${found_servers[@]}"; do
                log_dry_run "${user}: Would remove ${home_path} on ${srv}"
            done
            continue
        fi

        # LIVE: remove on servers where path exists
        local found_host_file="${PSSH_TMP}/found_b${batch_num}.txt"
        build_host_file "${found_host_file}" "${found_servers[@]}"
        pssh_remove_path "${found_host_file}" "${home_path}" || true

        for srv in "${REMOVED_HOSTS[@]+"${REMOVED_HOSTS[@]}"}"; do
            log_success "${user}: Removed ${home_path} on ${srv}"
            (( CNT_REMOVED++ )) || true
        done
        for srv in "${FAILED_HOSTS[@]+"${FAILED_HOSTS[@]}"}"; do
            log_failure "${user}: Failed to remove ${home_path} on ${srv}"
            (( CNT_FAILED++ )) || true
        done
    done
}

# =============================================================================
# Main
# =============================================================================

: > "${LOG_CLEANUP}"

log_info "================================================================"
log_info "cleanup_homes.sh start — mode=${MODE}$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_info "IDs file : ${IDS_FILE}"
log_info "Servers  : ${SERVER_LIST}"
log_info "PSSH     : batch=${PSSH_BATCH}, timeout=${PSSH_TIMEOUT}s"
${DRY_RUN} && log_info "Dry-run log -> ${ARCHIVE_LOG}"
log_info "================================================================"

[[ -s "${IDS_FILE}" ]]    || { log_warn "IDs file empty or missing — nothing to do."; exit 0; }
[[ -f "${SERVER_LIST}" ]] || log_fatal "Server list not found: ${SERVER_LIST}"
[[ -x "${PSSH_BIN}" ]]    || log_fatal "pssh not found or not executable: ${PSSH_BIN}"

mapfile -t ALL_SERVERS < <(grep -v '^\s*$\|^\s*#' "${SERVER_LIST}")
CNT_SERVERS=${#ALL_SERVERS[@]}
mapfile -t USER_IDS < "${IDS_FILE}"
CNT_USERS=${#USER_IDS[@]}
log_info "Loaded ${CNT_SERVERS} servers, ${CNT_USERS} user IDs"

for USER in "${USER_IDS[@]}"; do
    [[ -z "${USER}" ]] && continue
    process_home_path "${USER}" "$(printf "${AD_HOME_PATTERN}"  "${USER}")"
    process_home_path "${USER}" "$(printf "${OUD_HOME_PATTERN}" "${USER}")"
done

# --- Summary -----------------------------------------------------------------
log_info "================================================================"
log_summary "cleanup_homes complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_summary "Mode              : ${MODE} (${EVENT_TYPE})"
log_summary "User IDs          : ${CNT_USERS}"
log_summary "Servers in scope  : ${CNT_SERVERS}"
if ${DRY_RUN}; then
    log_summary "Home dirs found   : ${CNT_FOUND}"
    log_summary "Home dirs skipped : ${CNT_FOUND}  (dry-run — no changes made)"
else
    log_summary "Unreachable hosts : ${CNT_UNREACHABLE}"
    log_summary "Home dirs found   : ${CNT_FOUND}"
    log_summary "Home dirs removed : ${CNT_REMOVED}"
    log_summary "Removals failed   : ${CNT_FAILED}"
fi
log_info "================================================================"

# Archive this run's working log
cp "${LOG_CLEANUP}" "${ARCHIVE_LOG}"
if ${DRY_RUN}; then
    log_info "Dry-run log archived -> dryrun/${ARCHIVE_LOG##*/}"
else
    log_info "Log archived -> ${ARCHIVE_LOG##*/}"
fi

# Email notification (both live and dry-run when something was found)
if [[ ${CNT_FOUND} -gt 0 || ${CNT_FAILED} -gt 0 ]]; then
    local_subject="TTI home cleanup (${MODE})"
    ${DRY_RUN} \
        && local_subject+=" [DRY-RUN] — ${CNT_FOUND} would be removed" \
        || local_subject+=" — removed=${CNT_REMOVED} failed=${CNT_FAILED}"
    /usr/bin/mail -s "${local_subject}" "${NOTIFY}" < "${LOG_CLEANUP}" || true
fi

exit 0
