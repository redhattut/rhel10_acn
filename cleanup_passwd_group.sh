#!/bin/bash
# =============================================================================
# cleanup_passwd_group.sh — Legacy /etc/passwd and /etc/group cleanup
# =============================================================================
# Replaces: linuxfiles.ksh, groupandaccess.sh
#
# Why this exists:
#   Even though accounts are now managed in LDAP/OUD + AD, some servers may
#   still have local entries in /etc/passwd (created before the migration) or
#   may have user IDs embedded inside /etc/group lines (e.g. as sudoers members).
#   This script finds and cleans both.
#
# What it does for /etc/passwd:
#   - Checks each server for a local account matching the user ID
#   - If found: runs userdel (no -r; home dir cleanup is handled separately
#     by cleanup_homes.sh which already ran before this script)
#   - Logs FOUND, SUCCESS, FAILURE per server
#
# What it does for /etc/group:
#   - Checks each server for any /etc/group line containing the user ID
#   - If found:
#       1. Creates a backup: /etc/group.preremove.<userid>
#       2. Removes the user ID from any group line(s) it appears in,
#          leaving all other members untouched
#       3. Logs which group(s) the ID was removed from on which server
#   - The approach:
#       sed -i.preremove.<userid> to do an in-place edit with backup in one step,
#       removing ",<userid>" or "<userid>," or a sole member "<userid>" cleanly.
#
# Usage:
#   cleanup_passwd_group.sh --mode terms|trans [--dry-run]
#
# Archived log written to:
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
ARCHIVE_LOG="${LOGS_DIR}/linuxfiles.${RUN_STAMP}"

PSSH_TMP=$(mktemp -d /var/tmp/tti_pssh.XXXXXX)
trap 'rm -rf "${PSSH_TMP}"' EXIT

# --- Counters ----------------------------------------------------------------
declare -i CNT_USERS=0 CNT_SERVERS=0
declare -i CNT_PASSWD_FOUND=0 CNT_PASSWD_REMOVED=0 CNT_PASSWD_FAILED=0
declare -i CNT_GROUP_FOUND=0  CNT_GROUP_REMOVED=0  CNT_GROUP_FAILED=0
declare -i CNT_UNREACHABLE=0

# --- Logging -----------------------------------------------------------------

_log() {
    local level="$1" msg="$2" ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}" \
        | tee -a "${LOG_PASSWD}" >> "${MAIN_LOG}"
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

# pssh_run_cmd HOST_FILE CMD OUT_DIR ERR_DIR
#   Runs CMD on all hosts via pssh. Stores per-host output in OUT_DIR/ERR_DIR.
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
#   Returns hostnames whose output file matches PATTERN.
hosts_with_output() {
    local out_dir="$1" pattern="$2"
    for f in "${out_dir}"/*; do
        [[ -f "${f}" ]] || continue
        if grep -q "${pattern}" "${f}" 2>/dev/null; then
            basename "${f}"
        fi
    done
}

# record_unreachable OUT_DIR ERR_DIR
#   Hosts with error output but no stdout file are treated as unreachable.
record_unreachable() {
    local out_dir="$1" err_dir="$2"
    for err_file in "${err_dir}"/*; do
        [[ -s "${err_file}" ]] || continue
        local host
        host=$(basename "${err_file}")
        if [[ ! -f "${out_dir}/${host}" ]]; then
            log_unreachable "${host}"
        fi
    done
}

# =============================================================================
# /etc/passwd cleanup
# =============================================================================

# process_passwd USER
#   Checks all servers for a local /etc/passwd entry matching USER.
#   If found, removes via userdel (no -r; home already cleaned by cleanup_homes.sh).
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

        # Check for exact match on username field in /etc/passwd
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

        if ${DRY_RUN}; then
            for srv in "${found_servers[@]}"; do
                log_dry_run "${user}: Would run userdel on ${srv}"
            done
            continue
        fi

        local found_file="${PSSH_TMP}/pw_found_b${batch_num}.txt"
        local del_out="${PSSH_TMP}/pw_del_out_b${batch_num}"
        local del_err="${PSSH_TMP}/pw_del_err_b${batch_num}"
        build_host_file "${found_file}" "${found_servers[@]}"

        # userdel without -r: home dir already handled by cleanup_homes.sh
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

# process_group USER
#   Checks all servers for USER appearing in any /etc/group line.
#   If found, removes just the user ID from the group member list,
#   leaving all other members intact. Creates backup before editing.
#
#   Examples of what the sed handles:
#     efg_sudoers:x:4044:sa50229,sa31825,sa32360  -> sa31825 removed, others kept
#     wheel:x:10:sa31825                           -> sa31825 removed, line becomes wheel:x:10:
#     ops:x:200:sa31825,sa99999                   -> becomes ops:x:200:sa99999
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

        # Check: does this user appear anywhere in /etc/group member fields?
        # Match only in the member list (field 4), not in the group name itself.
        pssh_run_cmd "${batch_file}" \
            "grep -qP '^[^:]+:[^:]+:[^:]+:.*\b${user}\b' /etc/group && echo EXISTS || true" \
            "${out_dir}" "${err_dir}"

        record_unreachable "${out_dir}" "${err_dir}"

        local -a found_servers=()
        mapfile -t found_servers < <(hosts_with_output "${out_dir}" "^EXISTS")
        [[ ${#found_servers[@]} -eq 0 ]] && continue

        # Identify which group(s) the user appears in on each server
        local grp_out="${PSSH_TMP}/grp_names_b${batch_num}"
        local grp_err="${PSSH_TMP}/grp_names_err_b${batch_num}"
        local found_file="${PSSH_TMP}/grp_found_b${batch_num}.txt"
        build_host_file "${found_file}" "${found_servers[@]}"

        pssh_run_cmd "${found_file}" \
            "grep -P '^[^:]+:[^:]+:[^:]+:.*\b${user}\b' /etc/group | cut -d: -f1" \
            "${grp_out}" "${grp_err}"

        for srv in "${found_servers[@]}"; do
            local groups_str=""
            [[ -f "${grp_out}/${srv}" ]] && groups_str=$(tr '\n' ',' < "${grp_out}/${srv}" | sed 's/,$//')
            log_found "${user}: member of group(s) [${groups_str}] in /etc/group on ${srv}"
            (( CNT_GROUP_FOUND++ )) || true
        done

        if ${DRY_RUN}; then
            for srv in "${found_servers[@]}"; do
                log_dry_run "${user}: Would remove from /etc/group on ${srv} (backup: /etc/group.preremove.${user})"
            done
            continue
        fi

        # Build the remote sed command:
        #   1. Back up /etc/group -> /etc/group.preremove.<user>
        #   2. Remove ",user" (user in middle/end of list)
        #   3. Remove "user," (user at start of list)
        #   4. Remove "user"  (sole member)
        # All three patterns needed to handle every position cleanly.
        local sed_cmd
        sed_cmd="cp /etc/group /etc/group.preremove.${user} && \
sed -i \
    -e 's/,${user}//g' \
    -e 's/${user},//g' \
    -e 's/:${user}$//g' \
    /etc/group && echo REMOVED || echo FAILED"

        local rm_out="${PSSH_TMP}/grp_rm_out_b${batch_num}"
        local rm_err="${PSSH_TMP}/grp_rm_err_b${batch_num}"
        pssh_run_cmd "${found_file}" "${sed_cmd}" "${rm_out}" "${rm_err}"

        for srv in "${found_servers[@]}"; do
            if grep -q "^REMOVED" "${rm_out}/${srv}" 2>/dev/null; then
                local groups_str=""
                [[ -f "${grp_out}/${srv}" ]] && groups_str=$(tr '\n' ',' < "${grp_out}/${srv}" | sed 's/,$//')
                log_success "${user}: Removed from group(s) [${groups_str}] in /etc/group on ${srv} (backup: /etc/group.preremove.${user})"
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
log_info "Log archived -> ${ARCHIVE_LOG##*/}"

if [[ $(( CNT_PASSWD_FOUND + CNT_GROUP_FOUND + CNT_PASSWD_FAILED + CNT_GROUP_FAILED )) -gt 0 ]]; then
    local subject="TTI passwd/group cleanup (${MODE})"
    ${DRY_RUN} && subject+=" [DRY-RUN]" \
               || subject+=" — passwd_removed=${CNT_PASSWD_REMOVED} group_removed=${CNT_GROUP_REMOVED} failed=$(( CNT_PASSWD_FAILED + CNT_GROUP_FAILED ))"
    /usr/bin/mail -s "${subject}" "${NOTIFY}" < "${LOG_PASSWD}" || true
fi

exit 0
