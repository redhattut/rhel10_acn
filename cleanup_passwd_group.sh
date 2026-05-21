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
declare -i CNT_USERS=0 CNT_SERVERS=0 CNT_UNREACHABLE=0
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

# build_remote_cmd USER_IDS_ARRAY DRY_RUN
#   Builds a single remote shell script that processes all users in one SSH session.
#
#   /etc/passwd section: for each user, grep field 1. If found:
#     dry-run  -> echo PASSWD_DRY_RUN:userid
#     live     -> userdel; echo PASSWD_REMOVED or PASSWD_FAILED
#
#   /etc/group section: for each user, grep field 4. If found:
#     Collects affected group names (comma-joined).
#     dry-run  -> echo GROUP_DRY_RUN:userid:groups
#     live     -> cp backup, sed remove, echo GROUP_REMOVED:userid:groups or GROUP_FAILED:userid
build_remote_cmd() {
    local -n _ids="$1"
    local dry="$2"

    local ids_literal=""
    for u in "${_ids[@]}"; do
        ids_literal+=" ${u}"
    done

    if [[ "${dry}" == "true" ]]; then
        cat <<REMOTESCRIPT
for u in${ids_literal}; do
  grep -q "^\${u}:" /etc/passwd 2>/dev/null && echo "PASSWD_DRY_RUN:\${u}" || true
  groups=\$(grep -P "^[^:]+:[^:]+:[^:]+:.*\b\${u}\b" /etc/group 2>/dev/null | cut -d: -f1 | tr '\n' ',' | sed 's/,\$//')
  [ -n "\${groups}" ] && echo "GROUP_DRY_RUN:\${u}:\${groups}" || true
done
REMOTESCRIPT
    else
        cat <<REMOTESCRIPT
for u in${ids_literal}; do
  if grep -q "^\${u}:" /etc/passwd 2>/dev/null; then
    userdel "\${u}" 2>/dev/null && echo "PASSWD_REMOVED:\${u}" || echo "PASSWD_FAILED:\${u}"
  fi
  groups=\$(grep -P "^[^:]+:[^:]+:[^:]+:.*\b\${u}\b" /etc/group 2>/dev/null | cut -d: -f1 | tr '\n' ',' | sed 's/,\$//')
  if [ -n "\${groups}" ]; then
    cp /etc/group /etc/group.preremove.\${u} && \
    sed -i -e "s/,\${u}//g" -e "s/\${u},//g" -e "s/:\${u}\$//g" /etc/group && \
    echo "GROUP_REMOVED:\${u}:\${groups}" || echo "GROUP_FAILED:\${u}"
  fi
done
REMOTESCRIPT
    fi
}

# run_pssh_batch HOST_FILE REMOTE_CMD OUT_DIR ERR_DIR
run_pssh_batch() {
    local host_file="$1" remote_cmd="$2" out_dir="$3" err_dir="$4"
    mkdir -p "${out_dir}" "${err_dir}"
    # shellcheck disable=SC2086
    "${PSSH_BIN}" ${PSSH_OPTS} -q \
        -h "${host_file}" \
        -o "${out_dir}" \
        -e "${err_dir}" \
        "${remote_cmd}" \
        2>/dev/null || true
}

# parse_batch_output OUT_DIR ERR_DIR
parse_batch_output() {
    local out_dir="$1" err_dir="$2"

    for result_file in "${out_dir}"/*; do
        [[ -f "${result_file}" ]] || continue
        local host
        host=$(basename "${result_file}")

        while IFS= read -r result_line; do
            [[ -z "${result_line}" ]] && continue
            local status rest userid groups
            status="${result_line%%:*}"
            rest="${result_line#*:}"       # userid  or  userid:groups
            userid="${rest%%:*}"
            groups="${rest#*:}"
            [[ "${groups}" == "${userid}" ]] && groups=""  # no groups field present

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
        done < "${result_file}"
    done

    # Unreachable: stderr exists, no stdout file
    for err_file in "${err_dir}"/*; do
        [[ -s "${err_file}" ]] || continue
        local host
        host=$(basename "${err_file}")
        [[ ! -f "${out_dir}/${host}" ]] && log_unreachable "${host}"
    done
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

REMOTE_CMD=$(build_remote_cmd USER_IDS "${DRY_RUN}")

batch_num=0
i=0
total=${#ALL_SERVERS[@]}

while [[ ${i} -lt ${total} ]]; do
    batch=("${ALL_SERVERS[@]:${i}:${PSSH_BATCH}}")
    (( batch_num++ )) || true
    (( i += PSSH_BATCH )) || true

    batch_host_file="${PSSH_TMP}/hosts_b${batch_num}.txt"
    out_dir="${PSSH_TMP}/out_b${batch_num}"
    err_dir="${PSSH_TMP}/err_b${batch_num}"

    build_host_file "${batch_host_file}" "${batch[@]}"
    run_pssh_batch  "${batch_host_file}" "${REMOTE_CMD}" "${out_dir}" "${err_dir}"
    parse_batch_output "${out_dir}" "${err_dir}"
done

# --- Summary -----------------------------------------------------------------
log_info "================================================================"
log_summary "cleanup_passwd_group complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_summary "Mode                    : ${MODE} (${EVENT_TYPE})"
log_summary "User IDs                : ${CNT_USERS}"
log_summary "Servers in scope        : ${CNT_SERVERS}"
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
