#!/bin/bash
# =============================================================================
# cleanup_homes.sh — Parallel home directory cleanup for termed/transferred users
# =============================================================================
# Replaces: linuxterms.ksh (home dir portion), linuxtrans.ksh (home dir portion)
#
# SSH design — one connection per server per batch:
#   The remote command receives the full user ID list and checks + removes
#   both /home/<userid> and /home/<useridOUD> for every user in a single
#   SSH session. This means pssh connects to each server exactly once
#   regardless of how many users are in the list or how many home patterns
#   exist. Previously the script reconnected once per user per pattern.
#
#   Remote command structure (sent as a single heredoc-style inline script):
#     for each userid in USER_LIST:
#       test /home/userid    -> if exists, rm -rf it, echo result
#       test /home/useridOUD -> if exists, rm -rf it, echo result
#
#   Output format from each host (one line per action taken):
#     REMOVED:/home/userid
#     REMOVED:/home/useridOUD
#     FAILED:/home/userid
#     DRY_RUN:/home/userid       (dry-run mode only — no removal attempted)
#
#   No output line is emitted for paths that do not exist.
#   This keeps the log signal-only — zero lines for users with no homes.
#
# PSSH verbosity:
#   pssh's own status lines ([N] HH:MM:SS [SUCCESS]) are suppressed by
#   redirecting pssh stderr to /dev/null and never using tee on pssh output.
#   Per-host stdout is captured to individual files in a temp dir and
#   parsed by this script. Unreachable hosts are identified by the absence
#   of a stdout file combined with a non-empty stderr file.
#
# Usage:
#   cleanup_homes.sh --mode terms|trans [--dry-run]
#
# Log variables (set by main.sh, possibly overridden for dry-run):
#   LOG_CLEANUP  — working log, archived as linuxterms/linuxtrans.STAMP
#   LOG_HOSTS    — unreachable hosts
#   MAIN_LOG     — master process log (points to dryrun/ during dry-run)
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG="${SCRIPT_DIR}/tti.conf"
[[ -f "${CONFIG}" ]] || { echo "[FATAL] Config not found: ${CONFIG}" >&2; exit 2; }
source "${CONFIG}"
# Note: MAIN_LOG, LOG_CLEANUP, LOG_HOSTS may already be overridden by main.sh
# exports for dry-run mode. source tti.conf sets defaults; exports win.

# --- Argument parsing --------------------------------------------------------
MODE=""
DRY_RUN=false
DEBUG_MODE=false

usage() { echo "Usage: ${SCRIPT_NAME} --mode terms|trans [--dry-run] [--debug]" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)    MODE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --debug)   DEBUG_MODE=true; shift ;;
        *)         usage ;;
    esac
done
[[ "${MODE}" == "terms" || "${MODE}" == "trans" ]] || usage

# --- Derived settings --------------------------------------------------------
IDS_FILE="${DATA_DIR}/${MODE}.ids"
EVENT_TYPE="$( [[ "${MODE}" == "terms" ]] && echo "Terminated" || echo "Transferred" )"
RUN_STAMP=$(date +%y%m%d%H%M)

if ${DRY_RUN}; then
    mkdir -p "${DRYRUN_LOGS_DIR}"
    existing=$(ls "${DRYRUN_LOGS_DIR}/dryrun-${MODE}-"*"-${RUN_STAMP}" 2>/dev/null | wc -l || true)
    DRYRUN_NUM=$(( existing + 1 ))
    ARCHIVE_LOG="${DRYRUN_LOGS_DIR}/dryrun-${MODE}-${DRYRUN_NUM}-${RUN_STAMP}"
elif [[ "${MODE}" == "terms" ]]; then
    ARCHIVE_LOG="${LOGS_DIR}/linuxterms.${RUN_STAMP}"
else
    ARCHIVE_LOG="${LOGS_DIR}/linuxtrans.${RUN_STAMP}"
fi

PSSH_TMP=$(mktemp -d /var/tmp/tti_pssh.XXXXXX)
trap 'rm -rf "${PSSH_TMP}"' EXIT

# --- Counters ----------------------------------------------------------------
declare -i CNT_USERS=0 CNT_SERVERS=0
declare -i CNT_REMOVED=0 CNT_FAILED=0 CNT_DRYRUN=0 CNT_UNREACHABLE=0 CNT_REACHED=0

# --- Logging -----------------------------------------------------------------
_log() {
    local level="$1" msg="$2" ts line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    line=$(printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}")
    echo "${line}" >> "${LOG_CLEANUP}"
    echo "${line}" >> "${MAIN_LOG}"
}
log_info()    { _log "INFO"    "$1"; }
log_success() { _log "SUCCESS" "$1"; }
log_failure() { _log "FAILURE" "$1"; }
log_dry_run() { _log "DRY_RUN" "$1"; }
log_warn()    { _log "WARN"    "$1"; }
log_summary() { _log "SUMMARY" "$1"; }
log_fatal()   {
    _log "FATAL" "$1"
    /usr/bin/mail -s "FATAL: ${SCRIPT_NAME} on $(hostname)" "${NOTIFY}" \
        < "${LOG_CLEANUP}" || true
    exit 2
}

log_unreachable() {
    local host="$1" ts line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    line=$(printf "[%s] [%-9s] [%s] Host not responding: %s\n" \
        "${ts}" "WARN" "${SCRIPT_NAME}" "${host}")
    echo "${line}" >> "${LOG_HOSTS}"
    (( CNT_UNREACHABLE++ )) || true
}

# --- PSSH helpers ------------------------------------------------------------

# build_host_file OUTFILE HOST [HOST ...]
build_host_file() {
    local outfile="$1"; shift
    printf '%s\n' "$@" > "${outfile}"
}

# build_remote_script USER_IDS_ARRAY DRY_RUN SCRIPT_FILE
#   Writes the remote shell script to SCRIPT_FILE on the local host.
#   The script iterates all user IDs and checks/removes both home patterns
#   in a single pass — one SSH session handles all users on that server.
#
#   Output per line (only emitted when a path exists):
#     REMOVED:/home/userid
#     REMOVED:/home/useridOUD
#     FAILED:/home/userid
#     DRY_RUN:/home/userid
#
#   Uses file + base64 encoding so pssh can pass it to ssh as a clean
#   single-line string — no quoting or newline issues with any user list size.
build_remote_script() {
    local -n _ids="$1"
    local dry="$2"
    local script_file="$3"

    local ids_literal=""
    for u in "${_ids[@]}"; do
        ids_literal+=" ${u}"
    done

    if [[ "${dry}" == "true" ]]; then
        cat > "${script_file}" << 'ENDBODY'
for u in __IDS__; do
  for p in "/home/${u}" "/home/${u}OUD"; do
    [ -e "${p}" ] && echo "DRY_RUN:${p}" || true
  done
done
ENDBODY
    else
        cat > "${script_file}" << 'ENDBODY'
for u in __IDS__; do
  for p in "/home/${u}" "/home/${u}OUD"; do
    if [ -e "${p}" ]; then
      rm -rf "${p}" && echo "REMOVED:${p}" || echo "FAILED:${p}"
    fi
  done
done
ENDBODY
    fi
    sed -i "s/__IDS__/${ids_literal}/" "${script_file}"
}

# run_pssh_batch HOST_FILE SCRIPT_FILE OUT_FILE
#   Pipes SCRIPT_FILE to pssh via stdin (-I flag) so the script reaches each
#   remote host without any command-line quoting or encoding involved.
#   --inline-stdout writes all host output to a single file with lines prefixed:
#     [N] HH:MM:SS [SUCCESS] hostname
#     [N] HH:MM:SS [FAILURE] hostname        <- SSH failed / timeout
#     hostname: <stdout line from remote>
#
#   We capture the combined output to OUT_FILE and parse it ourselves.
#   MOTD/banner lines that appear in stderr do NOT affect SUCCESS/FAILURE
#   detection — pssh reports SUCCESS if the SSH connection was made and the
#   remote command exited 0, regardless of stderr on the remote.
run_pssh_batch() {
    local host_file="$1" script_file="$2" out_file="$3"

    if ${DEBUG_MODE}; then
        log_info "DEBUG: Script file contents:"
        while IFS= read -r dbg_line; do
            log_info "DEBUG:   ${dbg_line}"
        done < "${script_file}"
        log_info "DEBUG: Host file: ${host_file} ($(wc -l < "${host_file}") hosts)"
        log_info "DEBUG: PSSH_BIN=${PSSH_BIN}"
        log_info "DEBUG: PSSH_OPTS=${PSSH_OPTS}"
        log_info "DEBUG: pssh version: $(${PSSH_BIN} --version 2>&1 | head -1 || echo unknown)"
        log_info "DEBUG: Running pssh..."
    fi

    local pssh_rc=0
    # shellcheck disable=SC2086
    cat "${script_file}" | "${PSSH_BIN}" ${PSSH_OPTS} \
        -h "${host_file}" \
        bash \
        > "${out_file}" 2>/dev/null || pssh_rc=$?

    if ${DEBUG_MODE}; then
        log_info "DEBUG: pssh exit code: ${pssh_rc}"
        log_info "DEBUG: output lines: $(wc -l < "${out_file}" 2>/dev/null || echo 0)"
        log_info "DEBUG: first 5 output lines:"
        head -5 "${out_file}" 2>/dev/null | while IFS= read -r l; do
            log_info "DEBUG:   ${l}"
        done
    fi
}



# parse_batch_output OUT_FILE
#   Parses --inline-stdout output. Line format from pssh:
#     [N] HH:MM:SS [SUCCESS] hostname   <- host connected, command ran
#     [N] HH:MM:SS [FAILURE] hostname   <- SSH failed or timed out
#     hostname: <remote stdout line>    <- actual command output
#
#   We track which hosts reported SUCCESS/FAILURE from the pssh status lines,
#   then map command output lines back to their host using "hostname: " prefix.
#   MOTD/banner noise arrives on remote stderr, which pssh does not include in
#   --inline-stdout output, so it never contaminates our parsing.
parse_batch_output() {
    local out_file="$1"
    [[ -f "${out_file}" ]] || return

    # First pass: collect SUCCESS and FAILURE host sets from pssh status lines
    declare -A host_status
    while IFS= read -r line; do
        # pssh status line: [N] HH:MM:SS [SUCCESS] hostname
        if [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[(SUCCESS)\][[:space:]](.+)$ ]]; then
            host_status["${BASH_REMATCH[2]}"]="SUCCESS"
            (( CNT_REACHED++ )) || true
        elif [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[(FAILURE)\][[:space:]](.+)$ ]]; then
            host_status["${BASH_REMATCH[2]}"]="FAILURE"
            log_unreachable "${BASH_REMATCH[2]}"
        fi
    done < "${out_file}"

    # Second pass: parse command output lines "hostname: RESULT:/path"
    while IFS= read -r line; do
        # Skip pssh status lines
        [[ "${line}" =~ ^\[[0-9]+ ]] && continue

        # Output line format: "hostname: STATUS:/path"
        local host result_part status path userid
        host="${line%%:*}"
        result_part="${line#*: }"
        status="${result_part%%:*}"
        path="${result_part#*:}"

        # Only process lines from hosts that connected successfully
        [[ "${host_status[${host}]:-}" == "SUCCESS" ]] || continue
        [[ -z "${path}" || "${path}" == "${status}" ]] && continue

        userid=$(basename "${path}" | sed 's/OUD$//')

        case "${status}" in
            REMOVED)
                log_success "${userid}: Removed ${path} on ${host}"
                (( CNT_REMOVED++ )) || true
                ;;
            FAILED)
                log_failure "${userid}: Failed to remove ${path} on ${host}"
                (( CNT_FAILED++ )) || true
                ;;
            DRY_RUN)
                log_dry_run "${userid}: Would remove ${path} on ${host}"
                (( CNT_DRYRUN++ )) || true
                ;;
        esac
    done < "${out_file}"
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
log_info "================================================================"

[[ -s "${IDS_FILE}" ]]    || { log_warn "IDs file empty or missing — nothing to do."; exit 0; }
[[ -f "${SERVER_LIST}" ]] || log_fatal "Server list not found: ${SERVER_LIST}"
[[ -x "${PSSH_BIN}" ]]    || log_fatal "pssh not found or not executable: ${PSSH_BIN}"

mapfile -t ALL_SERVERS < <(grep -v '^\s*$\|^\s*#' "${SERVER_LIST}")
mapfile -t USER_IDS    < <(grep -v '^\s*$' "${IDS_FILE}")

CNT_SERVERS=${#ALL_SERVERS[@]}
CNT_USERS=${#USER_IDS[@]}
log_info "Loaded ${CNT_SERVERS} servers, ${CNT_USERS} user IDs"

# Write the remote script once to a temp file, encode it once.
# Every batch reuses the same encoded script — no rebuilding per batch.
REMOTE_SCRIPT_FILE="${PSSH_TMP}/remote_homes.sh"
build_remote_script USER_IDS "${DRY_RUN}" "${REMOTE_SCRIPT_FILE}"

# Fan out in batches of PSSH_BATCH
batch_num=0
i=0
total=${#ALL_SERVERS[@]}

while [[ ${i} -lt ${total} ]]; do
    batch=("${ALL_SERVERS[@]:${i}:${PSSH_BATCH}}")
    (( batch_num++ )) || true
    (( i += PSSH_BATCH )) || true

    batch_host_file="${PSSH_TMP}/hosts_b${batch_num}.txt"
    out_file="${PSSH_TMP}/out_b${batch_num}.log"

    build_host_file "${batch_host_file}" "${batch[@]}"
    run_pssh_batch  "${batch_host_file}" "${REMOTE_SCRIPT_FILE}" "${out_file}"
    parse_batch_output "${out_file}"
done

# --- Summary -----------------------------------------------------------------
log_info "================================================================"
log_summary "cleanup_homes complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_summary "Mode              : ${MODE} (${EVENT_TYPE})"
log_summary "User IDs          : ${CNT_USERS}"
log_summary "Servers in scope  : ${CNT_SERVERS}"
log_summary "Hosts reached     : ${CNT_REACHED}"
log_summary "Unreachable hosts : ${CNT_UNREACHABLE}"
if ${DRY_RUN}; then
    log_summary "Home dirs found   : ${CNT_DRYRUN}  (would be removed)"
else
    log_summary "Home dirs removed : ${CNT_REMOVED}"
    log_summary "Removals failed   : ${CNT_FAILED}"
fi
log_info "================================================================"

cp "${LOG_CLEANUP}" "${ARCHIVE_LOG}"
log_info "Log archived -> ${ARCHIVE_LOG##*/}"

total_issues=$(( CNT_REMOVED + CNT_FAILED + CNT_DRYRUN ))
if [[ ${total_issues} -gt 0 || ${CNT_FAILED} -gt 0 ]]; then
    local_subject="TTI home cleanup (${MODE})"
    ${DRY_RUN} \
        && local_subject+=" [DRY-RUN] — ${CNT_DRYRUN} would be removed" \
        || local_subject+=" — removed=${CNT_REMOVED} failed=${CNT_FAILED}"
    /usr/bin/mail -s "${local_subject}" "${NOTIFY}" < "${LOG_CLEANUP}" || true
fi

exit 0
