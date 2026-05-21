#!/bin/bash
# =============================================================================
# cleanup.sh — Combined home dir, /etc/passwd, and /etc/group cleanup
# =============================================================================
# Replaces: cleanup_homes.sh + cleanup_passwd_group.sh
#
# All three cleanup tasks run in a SINGLE SSH session per server per batch.
# One pssh invocation handles every user's home dirs, passwd entry, and group
# memberships simultaneously — no repeated connections.
#
# Remote script output format (one line per action, only when something found):
#   HOME_REMOVED:/home/userid
#   HOME_REMOVED:/home/useridOUD
#   HOME_FAILED:/home/userid
#   HOME_DRY_RUN:/home/userid
#   PASSWD_REMOVED:userid
#   PASSWD_FAILED:userid
#   PASSWD_DRY_RUN:userid
#   GROUP_REMOVED:userid:group1,group2
#   GROUP_FAILED:userid
#   GROUP_DRY_RUN:userid:group1,group2
#
# PSSH --inline-stdout prefixes each output line with the hostname:
#   hostname: HOME_DRY_RUN:/home/pn15145
#   hostname: PASSWD_DRY_RUN:pn15145
#
# Usage:
#   cleanup.sh --mode terms|trans [--dry-run] [--debug]
#
# Log variables set by main.sh (possibly overridden for dry-run before source):
#   LOG_CLEANUP, LOG_HOSTS, MAIN_LOG
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source config — but preserve any log path overrides exported by main.sh
# by saving them before sourcing and restoring them after.
CONFIG="${SCRIPT_DIR}/tti.conf"
[[ -f "${CONFIG}" ]] || { echo "[FATAL] Config not found: ${CONFIG}" >&2; exit 2; }

# Save exported log overrides before source resets them
_PRE_MAIN_LOG="${MAIN_LOG:-}"
_PRE_LOG_CLEANUP="${LOG_CLEANUP:-}"
_PRE_LOG_HOSTS="${LOG_HOSTS:-}"

source "${CONFIG}"

# Restore overrides if they were set by main.sh
[[ -n "${_PRE_MAIN_LOG}"    ]] && MAIN_LOG="${_PRE_MAIN_LOG}"
[[ -n "${_PRE_LOG_CLEANUP}" ]] && LOG_CLEANUP="${_PRE_LOG_CLEANUP}"
[[ -n "${_PRE_LOG_HOSTS}"   ]] && LOG_HOSTS="${_PRE_LOG_HOSTS}"

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
declare -i CNT_USERS=0 CNT_SERVERS=0 CNT_REACHED=0 CNT_UNREACHABLE=0
declare -i CNT_HOME_REMOVED=0  CNT_HOME_FAILED=0  CNT_HOME_DRYRUN=0
declare -i CNT_PASSWD_REMOVED=0 CNT_PASSWD_FAILED=0 CNT_PASSWD_DRYRUN=0
declare -i CNT_GROUP_REMOVED=0  CNT_GROUP_FAILED=0  CNT_GROUP_DRYRUN=0

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

build_host_file() {
    local outfile="$1"; shift
    printf '%s\n' "$@" > "${outfile}"
}

# build_remote_script USER_IDS_ARRAY DRY_RUN SCRIPT_FILE
#   Writes a single remote script that does ALL three cleanup tasks per user:
#     1. Home directory check + remove (both AD and OUD paths)
#     2. /etc/passwd local account check + userdel
#     3. /etc/group membership check + sed removal with backup
#
#   Uses 'ENDBODY' heredoc (single-quoted) so variable names like ${u} are
#   written literally into the script file — they expand on the REMOTE host.
#   IDs are substituted via sed after the file is written.
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
    [ -e "${p}" ] && echo "HOME_DRY_RUN:${p}" || true
  done
  grep -q "^${u}:" /etc/passwd 2>/dev/null && echo "PASSWD_DRY_RUN:${u}" || true
  groups=$(grep -P "^[^:]+:[^:]+:[^:]+:.*\b${u}\b" /etc/group 2>/dev/null \
    | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
  [ -n "${groups}" ] && echo "GROUP_DRY_RUN:${u}:${groups}" || true
done
ENDBODY
    else
        cat > "${script_file}" << 'ENDBODY'
for u in __IDS__; do
  for p in "/home/${u}" "/home/${u}OUD"; do
    if [ -e "${p}" ]; then
      rm -rf "${p}" && echo "HOME_REMOVED:${p}" || echo "HOME_FAILED:${p}"
    fi
  done
  if grep -q "^${u}:" /etc/passwd 2>/dev/null; then
    userdel "${u}" 2>/dev/null && echo "PASSWD_REMOVED:${u}" || echo "PASSWD_FAILED:${u}"
  fi
  groups=$(grep -P "^[^:]+:[^:]+:[^:]+:.*\b${u}\b" /etc/group 2>/dev/null \
    | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
  if [ -n "${groups}" ]; then
    cp /etc/group "/etc/group.preremove.${u}" && \
    sed -i -e "s/,${u}//g" -e "s/${u},//g" -e "s/:${u}\$//g" /etc/group && \
    echo "GROUP_REMOVED:${u}:${groups}" || echo "GROUP_FAILED:${u}"
  fi
done
ENDBODY
    fi

    # Substitute the IDs placeholder
    sed -i "s/__IDS__/${ids_literal}/" "${script_file}"
}

# run_pssh_batch HOST_FILE SCRIPT_FILE OUT_FILE
#   Pipes the script to pssh via stdin (-I flag).
#   --inline-stdout collects all host output into OUT_FILE with format:
#     [N] HH:MM:SS [SUCCESS] hostname
#     [N] HH:MM:SS [FAILURE] hostname
#     hostname: <remote stdout line>
run_pssh_batch() {
    local host_file="$1" script_file="$2" out_file="$3"

    if ${DEBUG_MODE}; then
        log_info "DEBUG: Script contents:"
        while IFS= read -r dbg_line; do
            log_info "DEBUG:   ${dbg_line}"
        done < "${script_file}"
        log_info "DEBUG: Host file: ${host_file} ($(wc -l < "${host_file}") hosts)"
        log_info "DEBUG: PSSH_BIN=${PSSH_BIN} PSSH_OPTS=${PSSH_OPTS}"
    fi

    local pssh_rc=0
    # shellcheck disable=SC2086
    cat "${script_file}" | "${PSSH_BIN}" ${PSSH_OPTS} \
        -h "${host_file}" \
        bash \
        > "${out_file}" 2>/dev/null || pssh_rc=$?

    if ${DEBUG_MODE}; then
        log_info "DEBUG: pssh exit=${pssh_rc}, output lines=$(wc -l < "${out_file}" 2>/dev/null || echo 0)"
        log_info "DEBUG: first 5 lines of pssh output:"
        head -5 "${out_file}" 2>/dev/null | while IFS= read -r l; do
            log_info "DEBUG:   ${l}"
        done
    fi
}

# parse_batch_output OUT_FILE
#   Parses --inline-stdout output. Two-pass approach:
#   Pass 1: read pssh status lines to determine which hosts connected (SUCCESS)
#           vs failed to connect (FAILURE). Only FAILURE = unreachable.
#           MOTD/banner on stderr never appears in --inline-stdout output.
#   Pass 2: read command output lines "hostname: STATUS:data" and log results.
#           Lines from FAILURE hosts are skipped.
#
#   NOTE on hostname parsing: pssh --inline-stdout prefixes each stdout line
#   with "hostname: ". The hostname used is exactly what appears in the host
#   file. We split on ": " (colon-space) not just ":" to avoid colliding with
#   the colon in STATUS:data.
parse_batch_output() {
    local out_file="$1"
    [[ -f "${out_file}" ]] || return

    # Pass 1: build host status map
    declare -A host_status
    while IFS= read -r line; do
        if [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[SUCCESS\][[:space:]](.+)$ ]]; then
            host_status["${BASH_REMATCH[1]}"]="SUCCESS"
            (( CNT_REACHED++ )) || true
        elif [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[FAILURE\][[:space:]](.+)$ ]]; then
            host_status["${BASH_REMATCH[1]}"]="FAILURE"
            log_unreachable "${BASH_REMATCH[1]}"
        fi
    done < "${out_file}"

    # Pass 2: parse command output lines
    while IFS= read -r line; do
        # Skip pssh status lines
        [[ "${line}" =~ ^\[[0-9]+ ]] && continue

        # Split on first ": " to get hostname and the rest
        # Format: "hostname: STATUS:data"
        local host remainder
        if [[ "${line}" =~ ^([^:]+):[[:space:]](.+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            remainder="${BASH_REMATCH[2]}"
        else
            continue
        fi

        # Only process output from hosts that connected
        [[ "${host_status[${host}]:-}" == "SUCCESS" ]] || continue

        # Parse STATUS:data from remainder
        local status data
        status="${remainder%%:*}"
        data="${remainder#*:}"
        # If no colon in remainder, data == status — skip
        [[ "${data}" == "${status}" ]] && continue

        local userid groups
        case "${status}" in
            HOME_REMOVED)
                userid=$(basename "${data}" | sed 's/OUD$//')
                log_success "${userid}: Removed ${data} on ${host}"
                (( CNT_HOME_REMOVED++ )) || true
                ;;
            HOME_FAILED)
                userid=$(basename "${data}" | sed 's/OUD$//')
                log_failure "${userid}: Failed to remove ${data} on ${host}"
                (( CNT_HOME_FAILED++ )) || true
                ;;
            HOME_DRY_RUN)
                userid=$(basename "${data}" | sed 's/OUD$//')
                log_dry_run "${userid}: Would remove ${data} on ${host}"
                (( CNT_HOME_DRYRUN++ )) || true
                ;;
            PASSWD_REMOVED)
                log_success "${data}: Removed local account from /etc/passwd on ${host}"
                (( CNT_PASSWD_REMOVED++ )) || true
                ;;
            PASSWD_FAILED)
                log_failure "${data}: Failed to remove local account from /etc/passwd on ${host}"
                (( CNT_PASSWD_FAILED++ )) || true
                ;;
            PASSWD_DRY_RUN)
                log_dry_run "${data}: Would run userdel ${data} on ${host}"
                (( CNT_PASSWD_DRYRUN++ )) || true
                ;;
            GROUP_REMOVED)
                userid="${data%%:*}"
                groups="${data#*:}"
                log_success "${userid}: Removed from [${groups}] in /etc/group on ${host} (backup: /etc/group.preremove.${userid})"
                (( CNT_GROUP_REMOVED++ )) || true
                ;;
            GROUP_FAILED)
                log_failure "${data}: Failed to remove from /etc/group on ${host}"
                (( CNT_GROUP_FAILED++ )) || true
                ;;
            GROUP_DRY_RUN)
                userid="${data%%:*}"
                groups="${data#*:}"
                log_dry_run "${userid}: Would remove from [${groups}] in /etc/group on ${host}"
                log_dry_run "${userid}: Would create /etc/group.preremove.${userid} on ${host}"
                (( CNT_GROUP_DRYRUN++ )) || true
                ;;
        esac
    done < "${out_file}"
}

# =============================================================================
# Main
# =============================================================================

: > "${LOG_CLEANUP}"

log_info "================================================================"
log_info "cleanup.sh start — mode=${MODE}$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_info "IDs file : ${IDS_FILE}"
log_info "Servers  : ${SERVER_LIST}"
log_info "PSSH     : batch=${PSSH_BATCH}, timeout=${PSSH_TIMEOUT}s, login=${PSSH_LOGIN}"
log_info "================================================================"

[[ -s "${IDS_FILE}" ]]    || { log_warn "IDs file empty or missing — nothing to do."; exit 0; }
[[ -f "${SERVER_LIST}" ]] || log_fatal "Server list not found: ${SERVER_LIST}"
[[ -x "${PSSH_BIN}" ]]    || log_fatal "pssh not found or not executable: ${PSSH_BIN}"

mapfile -t ALL_SERVERS < <(grep -v '^\s*$\|^\s*#' "${SERVER_LIST}")
mapfile -t USER_IDS    < <(grep -v '^\s*$' "${IDS_FILE}")

CNT_SERVERS=${#ALL_SERVERS[@]}
CNT_USERS=${#USER_IDS[@]}
log_info "Loaded ${CNT_SERVERS} servers, ${CNT_USERS} user IDs"

# Build the remote script once — reused across all batches
REMOTE_SCRIPT_FILE="${PSSH_TMP}/remote_cleanup.sh"
build_remote_script USER_IDS "${DRY_RUN}" "${REMOTE_SCRIPT_FILE}"

# Fan out in batches of PSSH_BATCH — one SSH per server covers all tasks
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
log_summary "cleanup complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_summary "Mode              : ${MODE} (${EVENT_TYPE})"
log_summary "User IDs          : ${CNT_USERS}"
log_summary "Servers in scope  : ${CNT_SERVERS}"
log_summary "Hosts reached     : ${CNT_REACHED}"
log_summary "Unreachable hosts : ${CNT_UNREACHABLE}"
if ${DRY_RUN}; then
    log_summary "Home dirs found   : ${CNT_HOME_DRYRUN}  (would be removed)"
    log_summary "/etc/passwd found : ${CNT_PASSWD_DRYRUN}  (would run userdel)"
    log_summary "/etc/group  found : ${CNT_GROUP_DRYRUN}  (would be cleaned)"
else
    log_summary "Home dirs removed : ${CNT_HOME_REMOVED}"
    log_summary "Home dirs failed  : ${CNT_HOME_FAILED}"
    log_summary "/etc/passwd removed : ${CNT_PASSWD_REMOVED}"
    log_summary "/etc/passwd failed  : ${CNT_PASSWD_FAILED}"
    log_summary "/etc/group  removed : ${CNT_GROUP_REMOVED}"
    log_summary "/etc/group  failed  : ${CNT_GROUP_FAILED}"
fi
log_info "================================================================"

cp "${LOG_CLEANUP}" "${ARCHIVE_LOG}"
log_info "Log archived -> ${ARCHIVE_LOG##*/}"

total_issues=$(( CNT_HOME_REMOVED + CNT_HOME_FAILED + CNT_HOME_DRYRUN +
                 CNT_PASSWD_REMOVED + CNT_PASSWD_FAILED + CNT_PASSWD_DRYRUN +
                 CNT_GROUP_REMOVED + CNT_GROUP_FAILED + CNT_GROUP_DRYRUN ))
if [[ ${total_issues} -gt 0 ]]; then
    local_subject="TTI cleanup (${MODE})"
    ${DRY_RUN} \
        && local_subject+=" [DRY-RUN] — homes=${CNT_HOME_DRYRUN} passwd=${CNT_PASSWD_DRYRUN} group=${CNT_GROUP_DRYRUN}" \
        || local_subject+=" — homes_removed=${CNT_HOME_REMOVED} passwd_removed=${CNT_PASSWD_REMOVED} group_removed=${CNT_GROUP_REMOVED} failed=$(( CNT_HOME_FAILED + CNT_PASSWD_FAILED + CNT_GROUP_FAILED ))"
    /usr/bin/mail -s "${local_subject}" "${NOTIFY}" < "${LOG_CLEANUP}" || true
fi

exit 0
