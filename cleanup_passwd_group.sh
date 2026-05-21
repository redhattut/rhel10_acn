#!/bin/bash
# =============================================================================
# cleanup_passwd_group.sh — Legacy /etc/passwd and /etc/group cleanup
# =============================================================================
# Replaces: linuxfiles.ksh, groupandaccess.sh
#
# Why this exists:
#   Even though accounts are now managed in LDAP/OUD + AD, some servers may
#   still carry local entries in /etc/passwd from before the LDAP migration,
#   or have user IDs embedded in /etc/group lines (e.g. sudoers, ops groups).
#   This script finds and cleans both.
#
# /etc/passwd cleanup:
#   - Checks each server for a local account matching the user ID (field 1 exact)
#   - If found: runs userdel without -r (home dir already handled by
#     cleanup_homes.sh, which runs before this script in main.sh)
#
# /etc/group cleanup:
#   - Checks each server for the user ID in any group's member list (field 4)
#   - If found:
#       1. Backs up /etc/group -> /etc/group.preremove.<userid>
#       2. Removes the user ID from the member list using sed, leaving all
#          other members untouched regardless of position in the list
#   - Example: efg_sudoers:x:4044:sa50229,sa31825,sa32360
#     After removal of sa31825: efg_sudoers:x:4044:sa50229,sa32360
#
# Usage:
#   cleanup_passwd_group.sh --mode terms|trans [--dry-run]
#
# --dry-run behaviour:
#   - pssh is used only to CHECK (read-only grep/test commands)
#   - userdel and sed/cp are NOT called
#   - DRY_RUN log lines describe what would have been done
#   - Logs archived to logs/dryrun/dryrun-N-YYMMDDHHMM (not linuxfiles.*)
#
# Live archived log:
#   logs/linuxfiles.YYMMDDHHMM
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

if ${DRY_RUN}; then
    mkdir -p "${DRYRUN_LOGS_DIR}"
    existing=$(ls "${DRYRUN_LOGS_DIR}/dryrun-"*"-${RUN_STAMP}" 2>/dev/null | wc -l || true)
    DRYRUN_NUM=$(( existing + 1 ))
    ARCHIVE_LOG="${DRYRUN_LOGS_DIR}/dryrun-${DRYRUN_NUM}-${RUN_STAMP}"
else
    ARCHIVE_LOG="${LOGS_DIR}/linuxfiles.${RUN_STAMP}"
fi

PSSH_TMP=$(mktemp -d /var/tmp/tti_pssh.XXXXXX)
trap 'rm -rf "${PSSH_TMP}"' EXIT

# --- Counters ----------------------------------------------------------------
declare -i CNT_USERS=0 CNT_SERVERS=0 CNT_UNREACHABLE=0
declare -i CNT_PASSWD_FOUND=0 CNT_PASSWD_REMOVED=0 CNT_PASSWD_FAILED=0
declare -i CNT_GROUP_FOUND=0  CNT_GROUP_REMOVED=0  CNT_GROUP_FAILED=0

# --- Logging -----------------------------------------------------------------

_log() {
    local level="$1" msg="$2" ts line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    line=$(printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}")
    echo "${line}" >> "${LOG_PASSWD}"             # always write to working log
    ${DRY_RUN} || echo "${line}" >> "${MAIN_LOG}" # live only — never touch master log during dry-run
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
        < "${LOG_PASSWD}" || true
    exit 2
}
log_unreachable() {
    local host="$1" ts line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    line=$(printf "[%s] [%-9s] [%s] Host not responding: %s\n" \
        "${ts}" "WARN" "${SCRIPT_NAME}" "${host}")
    echo "${line}" >> "${LOG_HOSTS}"
    ${DRY_RUN} || echo "${line}" >> "${MAIN_LOG}"
    (( CNT_UNREACHABLE++ )) || true
}

# --- PSSH helpers ------------------------------------------------------------

build_host_file() {
    local outfile="$1"; shift
    printf '%s\n' "$@" > "${outfile}"
}

# pssh_run_cmd HOST_FILE CMD OUT_DIR ERR_DIR
#   Runs CMD on all hosts via pssh. Stores per-host stdout/stderr.
pssh_run_cmd() {
    local host_file="$1" cmd="$2" out_dir="$3" err_dir="$4"
    mkdir -p "${out_dir}" "${err_dir}"
    rm -rf "${out_dir:?}/"* "${err_dir:?}/"* 2>/dev/null || true
    # shellcheck disable=SC2086
    "${PSSH_BIN}" ${PSSH_OPTS} \
        -h "${host_file}" \
        -o "${out_dir}" \
        -e "${err_dir}" \
        "${cmd}" \
        2>/dev/null || true
}

# hosts_with_output OUT_DIR PATTERN
#   Returns hostnames whose stdout file matches PATTERN.
hosts_with_output() {
    local out_dir="$1" pattern="$2"
    for f in "${out_dir}"/*; do
        [[ -f "${f}" ]] || continue
        grep -q "${pattern}" "${f}" 2>/dev/null && basename "${f}"
    done
}

# record_unreachable OUT_DIR ERR_DIR
#   Hosts with stderr but no stdout = unreachable. Only in live mode.
record_unreachable() {
    local out_dir="$1" err_dir="$2"
    ${DRY_RUN} && return
    for err_file in "${err_dir}"/*; do
        [[ -s "${err_file}" ]] || continue
        local host
        host=$(basename "${err_file}")
        [[ ! -f "${out_dir}/${host}" ]] && log_unreachable "${host}"
    done
}

# =============================================================================
# /etc/passwd cleanup
# =============================================================================

process_passwd() {
    local user="$1"
    local total=${#ALL_SERVERS[@]} i=0 batch_num=0

    while [[ ${i} -lt ${total} ]]; do
        local -a batch=("${ALL_SERVERS[@]:${i}:${PSSH_BATCH}}")
        (( batch_num++ )) || true
        (( i += PSSH_BATCH )) || true

        local batch_file="${PSSH_TMP}/pw_b${batch_num}.txt"
        local out_dir="${PSSH_TMP}/pw_out_b${batch_num}"
        local err_dir="${PSSH_TMP}/pw_err_b${batch_num}"
        build_host_file "${batch_file}" "${batch[@]}"

        # READ-ONLY check: exact match on username field (field 1 of /etc/passwd)
        pssh_run_cmd "${batch_file}" \
            "grep -q '^${user}:' /etc/passwd && echo EXISTS || true" \
            "${out_dir}" "${err_dir}"

        record_unreachable "${out_dir}" "${err_dir}"

        local -a found_servers=()
        mapfile -t found_servers < <(hosts_with_output "${out_dir}" "^EXISTS")
        [[ ${#found_servers[@]} -eq 0 ]] && continue

        for srv in "${found_servers[@]}"; do
            log_found "${user}: local account in /etc/passwd on ${srv}"
            (( CNT_PASSWD_FOUND++ )) || true
        done

        # DRY-RUN: report only, no userdel
        if ${DRY_RUN}; then
            for srv in "${found_servers[@]}"; do
                log_dry_run "${user}: Would run userdel ${user} on ${srv}"
            done
            continue
        fi

        # LIVE: run userdel (no -r; home already removed by cleanup_homes.sh)
        local found_file="${PSSH_TMP}/pw_found_b${batch_num}.txt"
        local del_out="${PSSH_TMP}/pw_del_out_b${batch_num}"
        local del_err="${PSSH_TMP}/pw_del_err_b${batch_num}"
        build_host_file "${found_file}" "${found_servers[@]}"

        pssh_run_cmd "${found_file}" \
            "userdel '${user}' && echo REMOVED || echo FAILED" \
            "${del_out}" "${del_err}"

        for srv in "${found_servers[@]}"; do
            if grep -q "^REMOVED" "${del_out}/${srv}" 2>/dev/null; then
                log_success "${user}: Removed local account from /etc/passwd on ${srv}"
                (( CNT_PASSWD_REMOVED++ )) || true
            else
                log_failure "${user}: Failed to remove local account from /etc/passwd on ${srv}"
                (( CNT_PASSWD_FAILED++ )) || true
            fi
        done
    done
}

# =============================================================================
# /etc/group cleanup
# =============================================================================

process_group() {
    local user="$1"
    local total=${#ALL_SERVERS[@]} i=0 batch_num=0

    while [[ ${i} -lt ${total} ]]; do
        local -a batch=("${ALL_SERVERS[@]:${i}:${PSSH_BATCH}}")
        (( batch_num++ )) || true
        (( i += PSSH_BATCH )) || true

        local batch_file="${PSSH_TMP}/grp_b${batch_num}.txt"
        local out_dir="${PSSH_TMP}/grp_out_b${batch_num}"
        local err_dir="${PSSH_TMP}/grp_err_b${batch_num}"
        build_host_file "${batch_file}" "${batch[@]}"

        # READ-ONLY check: user in member field (field 4) of any /etc/group line
        pssh_run_cmd "${batch_file}" \
            "grep -qP '^[^:]+:[^:]+:[^:]+:.*\b${user}\b' /etc/group && echo EXISTS || true" \
            "${out_dir}" "${err_dir}"

        record_unreachable "${out_dir}" "${err_dir}"

        local -a found_servers=()
        mapfile -t found_servers < <(hosts_with_output "${out_dir}" "^EXISTS")
        [[ ${#found_servers[@]} -eq 0 ]] && continue

        # READ-ONLY: identify which groups the user belongs to on each server
        local grp_out="${PSSH_TMP}/grp_names_b${batch_num}"
        local grp_err="${PSSH_TMP}/grp_names_err_b${batch_num}"
        local found_file="${PSSH_TMP}/grp_found_b${batch_num}.txt"
        build_host_file "${found_file}" "${found_servers[@]}"

        pssh_run_cmd "${found_file}" \
            "grep -P '^[^:]+:[^:]+:[^:]+:.*\b${user}\b' /etc/group | cut -d: -f1" \
            "${grp_out}" "${grp_err}"

        for srv in "${found_servers[@]}"; do
            local groups_str=""
            [[ -f "${grp_out}/${srv}" ]] && \
                groups_str=$(tr '\n' ',' < "${grp_out}/${srv}" | sed 's/,$//')
            log_found "${user}: member of [${groups_str}] in /etc/group on ${srv}"
            (( CNT_GROUP_FOUND++ )) || true
        done

        # DRY-RUN: report what backup + sed would do, do nothing
        if ${DRY_RUN}; then
            for srv in "${found_servers[@]}"; do
                local groups_str=""
                [[ -f "${grp_out}/${srv}" ]] && \
                    groups_str=$(tr '\n' ',' < "${grp_out}/${srv}" | sed 's/,$//')
                log_dry_run "${user}: Would remove from [${groups_str}] in /etc/group on ${srv}"
                log_dry_run "${user}: Would create backup /etc/group.preremove.${user} on ${srv}"
            done
            continue
        fi

        # LIVE: backup then remove ID from member lists
        # sed handles all three positions: middle/end (,user), start (user,), sole (:user$)
        local sed_cmd
        sed_cmd="cp /etc/group /etc/group.preremove.${user} && \
sed -i \
    -e 's/,${user}//g' \
    -e 's/${user},//g' \
    -e 's/:${user}\$//g' \
    /etc/group && echo REMOVED || echo FAILED"

        local rm_out="${PSSH_TMP}/grp_rm_out_b${batch_num}"
        local rm_err="${PSSH_TMP}/grp_rm_err_b${batch_num}"
        pssh_run_cmd "${found_file}" "${sed_cmd}" "${rm_out}" "${rm_err}"

        for srv in "${found_servers[@]}"; do
            local groups_str=""
            [[ -f "${grp_out}/${srv}" ]] && \
                groups_str=$(tr '\n' ',' < "${grp_out}/${srv}" | sed 's/,$//')
            if grep -q "^REMOVED" "${rm_out}/${srv}" 2>/dev/null; then
                log_success "${user}: Removed from [${groups_str}] in /etc/group on ${srv} (backup: /etc/group.preremove.${user})"
                (( CNT_GROUP_REMOVED++ )) || true
            else
                log_failure "${user}: Failed to remove from /etc/group on ${srv}"
                (( CNT_GROUP_FAILED++ )) || true
            fi
        done
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
    process_passwd "${USER}"
    process_group  "${USER}"
done

# --- Summary -----------------------------------------------------------------
log_info "================================================================"
log_summary "cleanup_passwd_group complete$( ${DRY_RUN} && echo ' [DRY-RUN]' || true )"
log_summary "Mode                    : ${MODE} (${EVENT_TYPE})"
log_summary "User IDs                : ${CNT_USERS}"
log_summary "Servers in scope        : ${CNT_SERVERS}"
log_summary "Unreachable hosts       : ${CNT_UNREACHABLE}"
log_summary "/etc/passwd entries found   : ${CNT_PASSWD_FOUND}"
if ${DRY_RUN}; then
    log_summary "/etc/passwd removals skipped: ${CNT_PASSWD_FOUND}  (dry-run)"
    log_summary "/etc/group  entries found   : ${CNT_GROUP_FOUND}"
    log_summary "/etc/group  removals skipped: ${CNT_GROUP_FOUND}   (dry-run)"
else
    log_summary "/etc/passwd entries removed : ${CNT_PASSWD_REMOVED}"
    log_summary "/etc/passwd removals failed : ${CNT_PASSWD_FAILED}"
    log_summary "/etc/group  entries found   : ${CNT_GROUP_FOUND}"
    log_summary "/etc/group  entries removed : ${CNT_GROUP_REMOVED}"
    log_summary "/etc/group  removals failed : ${CNT_GROUP_FAILED}"
fi
log_info "================================================================"

cp "${LOG_PASSWD}" "${ARCHIVE_LOG}"
if ${DRY_RUN}; then
    log_info "Dry-run log archived -> dryrun/${ARCHIVE_LOG##*/}"
else
    log_info "Log archived -> ${ARCHIVE_LOG##*/}"
fi

total_issues=$(( CNT_PASSWD_FOUND + CNT_GROUP_FOUND + CNT_PASSWD_FAILED + CNT_GROUP_FAILED ))
if [[ ${total_issues} -gt 0 ]]; then
    local_subject="TTI passwd/group cleanup (${MODE})"
    ${DRY_RUN} \
        && local_subject+=" [DRY-RUN] — passwd=${CNT_PASSWD_FOUND} group=${CNT_GROUP_FOUND} would be cleaned" \
        || local_subject+=" — passwd_removed=${CNT_PASSWD_REMOVED} group_removed=${CNT_GROUP_REMOVED} failed=$(( CNT_PASSWD_FAILED + CNT_GROUP_FAILED ))"
    /usr/bin/mail -s "${local_subject}" "${NOTIFY}" < "${LOG_PASSWD}" || true
fi

exit 0
