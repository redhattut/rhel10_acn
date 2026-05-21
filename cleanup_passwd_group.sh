#!/bin/bash
# =============================================================================
# cleanup_passwd_group.sh — Legacy /etc/passwd and /etc/group cleanup
# =============================================================================
# Replaces: linuxfiles.ksh, groupandaccess.sh
#
# SSH design — one connection per server per batch:
#   A single remote script is built containing all user IDs and sent to each
#   server once via pssh. The remote script checks /etc/passwd and /etc/group
#   for every user in one pass. No reconnecting per user.
#
#   /etc/passwd: exact field-1 match (grep '^userid:')
#     -> userdel without -r (home already removed by cleanup_homes.sh)
#
#   /etc/group: user ID in member list field (grep -P field 4 word boundary)
#     -> cp /etc/group /etc/group.preremove.<userid>
#     -> sed removes ID from member list, all three positions handled:
#          ,userid   (middle/end)
#          userid,   (start)
#          :userid$  (sole member)
#
#   Output format from each host (one line per action):
#     PASSWD_REMOVED:userid
#     PASSWD_FAILED:userid
#     PASSWD_DRY_RUN:userid
#     GROUP_REMOVED:userid:groupname,groupname
#     GROUP_FAILED:userid
#     GROUP_DRY_RUN:userid:groupname,groupname
#
# PSSH verbosity:
#   -q flag suppresses pssh's own status lines. Per-host output is captured
#   to individual files and parsed by this script only.
#
# Usage:
#   cleanup_passwd_group.sh --mode terms|trans [--dry-run]
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG="${SCRIPT_DIR}/tti.conf"
[[ -f "${CONFIG}" ]] || { echo "[FATAL] Config not found: ${CONFIG}" >&2; exit 2; }
source "${CONFIG}"
# MAIN_LOG, LOG_PASSWD, LOG_HOSTS may be overridden by main.sh exports for dry-run.

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
    existing=$(ls "${DRYRUN_LOGS_DIR}/dryrun-files-${MODE}-"*"-${RUN_STAMP}" 2>/dev/null | wc -l || true)
    DRYRUN_NUM=$(( existing + 1 ))
    ARCHIVE_LOG="${DRYRUN_LOGS_DIR}/dryrun-files-${MODE}-${DRYRUN_NUM}-${RUN_STAMP}"
else
    ARCHIVE_LOG="${LOGS_DIR}/linuxfiles.${RUN_STAMP}"
fi

PSSH_TMP=$(mktemp -d /var/tmp/tti_pssh.XXXXXX)
trap 'rm -rf "${PSSH_TMP}"' EXIT

# --- Counters ----------------------------------------------------------------
declare -i CNT_USERS=0 CNT_SERVERS=0 CNT_UNREACHABLE=0 CNT_REACHED=0
declare -i CNT_PASSWD_REMOVED=0 CNT_PASSWD_FAILED=0 CNT_PASSWD_DRYRUN=0
declare -i CNT_GROUP_REMOVED=0  CNT_GROUP_FAILED=0  CNT_GROUP_DRYRUN=0

# --- Logging -----------------------------------------------------------------
_log() {
    local level="$1" msg="$2" ts line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    line=$(printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}")
    echo "${line}" >> "${LOG_PASSWD}"
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
        < "${LOG_PASSWD}" || true
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
#   Writes the remote shell script to SCRIPT_FILE.
#   Uses file + base64 encoding so pssh can pass it to ssh without
#   quoting or newline issues.
build_remote_script() {
    local -n _ids="$1"
    local dry="$2"
    local script_file="$3"

    local ids_literal=""
    for u in "${_ids[@]}"; do
        ids_literal+=" ${u}"
    done

    # Write the script body with a placeholder, then substitute IDs in
    if [[ "${dry}" == "true" ]]; then
        cat > "${script_file}" << 'ENDBODY'
for u in __IDS__; do
  grep -q "^${u}:" /etc/passwd 2>/dev/null && echo "PASSWD_DRY_RUN:${u}" || true
  groups=$(grep -P "^[^:]+:[^:]+:[^:]+:.*\b${u}\b" /etc/group 2>/dev/null | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
  [ -n "${groups}" ] && echo "GROUP_DRY_RUN:${u}:${groups}" || true
done
ENDBODY
    else
        cat > "${script_file}" << 'ENDBODY'
for u in __IDS__; do
  if grep -q "^${u}:" /etc/passwd 2>/dev/null; then
    userdel "${u}" 2>/dev/null && echo "PASSWD_REMOVED:${u}" || echo "PASSWD_FAILED:${u}"
  fi
  groups=$(grep -P "^[^:]+:[^:]+:[^:]+:.*\b${u}\b" /etc/group 2>/dev/null | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
  if [ -n "${groups}" ]; then
    cp /etc/group "/etc/group.preremove.${u}" && \
    sed -i -e "s/,${u}//g" -e "s/${u},//g" -e "s/:${u}\$//g" /etc/group && \
    echo "GROUP_REMOVED:${u}:${groups}" || echo "GROUP_FAILED:${u}"
  fi
done
ENDBODY
    fi
    # Substitute the actual IDs into the placeholder
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
#   Parses --inline-stdout output from pssh.
#   pssh status lines: [N] HH:MM:SS [SUCCESS|FAILURE] hostname
#   Command output lines: hostname: STATUS:data
parse_batch_output() {
    local out_file="$1"
    [[ -f "${out_file}" ]] || return

    declare -A host_status
    while IFS= read -r line; do
        if [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[(SUCCESS)\][[:space:]](.+)$ ]]; then
            host_status["${BASH_REMATCH[2]}"]="SUCCESS"
            (( CNT_REACHED++ )) || true
        elif [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[(FAILURE)\][[:space:]](.+)$ ]]; then
            host_status["${BASH_REMATCH[2]}"]="FAILURE"
            log_unreachable "${BASH_REMATCH[2]}"
        fi
    done < "${out_file}"

    while IFS= read -r line; do
        [[ "${line}" =~ ^\[[0-9]+ ]] && continue

        local host result_part status rest userid groups
        host="${line%%:*}"
        result_part="${line#*: }"
        status="${result_part%%:*}"
        rest="${result_part#*:}"      # userid  or  userid:groups

        [[ "${host_status[${host}]:-}" == "SUCCESS" ]] || continue
        [[ -z "${rest}" || "${rest}" == "${status}" ]] && continue

        userid="${rest%%:*}"
        groups="${rest#*:}"
        [[ "${groups}" == "${userid}" ]] && groups=""

        case "${status}" in
            PASSWD_REMOVED)
                log_success "${userid}: Removed local account from /etc/passwd on ${host}"
                (( CNT_PASSWD_REMOVED++ )) || true
                ;;
            PASSWD_FAILED)
                log_failure "${userid}: Failed to remove local account from /etc/passwd on ${host}"
                (( CNT_PASSWD_FAILED++ )) || true
                ;;
            PASSWD_DRY_RUN)
                log_dry_run "${userid}: Would run userdel ${userid} on ${host}"
                (( CNT_PASSWD_DRYRUN++ )) || true
                ;;
            GROUP_REMOVED)
                log_success "${userid}: Removed from [${groups}] in /etc/group on ${host} (backup: /etc/group.preremove.${userid})"
                (( CNT_GROUP_REMOVED++ )) || true
                ;;
            GROUP_FAILED)
                log_failure "${userid}: Failed to remove from /etc/group on ${host}"
                (( CNT_GROUP_FAILED++ )) || true
                ;;
            GROUP_DRY_RUN)
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

: > "${LOG_PASSWD}"

log_info "================================================================"
log_info "cleanup_passwd_group.sh start — mode=${MODE}$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
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

REMOTE_SCRIPT_FILE="${PSSH_TMP}/remote_passwd_group.sh"
build_remote_script USER_IDS "${DRY_RUN}" "${REMOTE_SCRIPT_FILE}"

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
log_summary "cleanup_passwd_group complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_summary "Mode                    : ${MODE} (${EVENT_TYPE})"
log_summary "User IDs                : ${CNT_USERS}"
log_summary "Servers in scope        : ${CNT_SERVERS}"
log_summary "Hosts reached           : ${CNT_REACHED}"
log_summary "Unreachable hosts       : ${CNT_UNREACHABLE}"
if ${DRY_RUN}; then
    log_summary "/etc/passwd would remove : ${CNT_PASSWD_DRYRUN}"
    log_summary "/etc/group  would remove : ${CNT_GROUP_DRYRUN}"
else
    log_summary "/etc/passwd entries removed : ${CNT_PASSWD_REMOVED}"
    log_summary "/etc/passwd removals failed : ${CNT_PASSWD_FAILED}"
    log_summary "/etc/group  entries removed : ${CNT_GROUP_REMOVED}"
    log_summary "/etc/group  removals failed : ${CNT_GROUP_FAILED}"
fi
log_info "================================================================"

cp "${LOG_PASSWD}" "${ARCHIVE_LOG}"
log_info "Log archived -> ${ARCHIVE_LOG##*/}"

total_issues=$(( CNT_PASSWD_REMOVED + CNT_GROUP_REMOVED + CNT_PASSWD_FAILED + CNT_GROUP_FAILED + CNT_PASSWD_DRYRUN + CNT_GROUP_DRYRUN ))
if [[ ${total_issues} -gt 0 ]]; then
    local_subject="TTI passwd/group cleanup (${MODE})"
    ${DRY_RUN} \
        && local_subject+=" [DRY-RUN] — passwd=${CNT_PASSWD_DRYRUN} group=${CNT_GROUP_DRYRUN} would be cleaned" \
        || local_subject+=" — passwd_removed=${CNT_PASSWD_REMOVED} group_removed=${CNT_GROUP_REMOVED} failed=$(( CNT_PASSWD_FAILED + CNT_GROUP_FAILED ))"
    /usr/bin/mail -s "${local_subject}" "${NOTIFY}" < "${LOG_PASSWD}" || true
fi

exit 0
