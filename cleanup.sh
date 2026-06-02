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
DEBUG_PSSH=false
CUSTOM_IDS_FILE=""
CUSTOM_HOSTS_FILE=""
SEND_EMAIL=true

usage() {
    cat >&2 << 'USAGE'
Usage: cleanup.sh --mode terms|trans [OPTIONS]

Required:
  --mode terms|trans        Which ID list to use (terms.ids or trans.ids)

Run options:
  --dry-run                 Check only, no changes made on servers
  --ids-file  /path/file    Override ID file (one lowercase userid per line)
                            Useful for testing against a specific set of users
  --hosts-file /path/file   Override server list (one hostname per line)
                            Useful for testing against specific servers

Debug options:
  --debug                   Verbose pssh diagnostics per batch
  --debug-pssh              Single plain-ssh test against first server, then exit

Email options:
  --no-email                Skip completion email (default: email is sent)
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        MODE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --no-email)    SEND_EMAIL=false; shift ;;
        --ids-file)    CUSTOM_IDS_FILE="$2"; shift 2 ;;
        --hosts-file)  CUSTOM_HOSTS_FILE="$2"; shift 2 ;;
        --debug)       DEBUG_MODE=true; shift ;;
        --debug-pssh)  DEBUG_MODE=true; DEBUG_PSSH=true; shift ;;
        --help|-h)     usage ;;
        *)             usage ;;
    esac
done
[[ "${MODE}" == "terms" || "${MODE}" == "trans" ]] || usage

# --- Derived settings --------------------------------------------------------
# IDS_FILE: use custom override if provided, otherwise default to data/MODE.ids
if [[ -n "${CUSTOM_IDS_FILE}" ]]; then
    [[ -f "${CUSTOM_IDS_FILE}" ]] || { echo "[FATAL] --ids-file not found: ${CUSTOM_IDS_FILE}" >&2; exit 2; }
    IDS_FILE=$(mktemp /var/tmp/tti_ids.XXXXXX)
    # Auto-detect file format:
    #   Tilde-delimited OIM raw format: "2026-05-29~SA78728~Aldrich, Jazmin~..."
    #     -> extract field 2 (the user ID), same as getdata.sh normalize_ids
    #   Plain ID list: one ID per line (sa78728, SA78728, etc.)
    #     -> use as-is after lowercasing
    if grep -q '~' "${CUSTOM_IDS_FILE}" 2>/dev/null; then
        # OIM raw format — extract field 2
        awk -F'~' 'NF>=2 && length($2)>0 { print tolower($2) }'             "${CUSTOM_IDS_FILE}" | grep -v '^\s*$' | sort -u > "${IDS_FILE}"
    else
        # Plain ID list — just lowercase and deduplicate
        tr '[:upper:]' '[:lower:]' < "${CUSTOM_IDS_FILE}"             | grep -v '^\s*$' | sort -u > "${IDS_FILE}"
    fi
else
    IDS_FILE="${DATA_DIR}/${MODE}.ids"
fi

# SERVER_LIST: use custom override if provided, otherwise default from conf
if [[ -n "${CUSTOM_HOSTS_FILE}" ]]; then
    SERVER_LIST="${CUSTOM_HOSTS_FILE}"
    [[ -f "${SERVER_LIST}" ]] || { echo "[FATAL] --hosts-file not found: ${SERVER_LIST}" >&2; exit 2; }
fi

EVENT_TYPE="$( [[ "${MODE}" == "terms" ]] && echo "Terminated" || echo "Transferred" )"
RUN_STAMP=$(date +%y%m%d%H%M)

# Archive log destination — dry-run always goes to dryrun/ regardless of
# whether custom files were used, so live logs are never contaminated.
if ${DRY_RUN}; then
    mkdir -p "${DRYRUN_LOGS_DIR}"
    if [[ "${MODE}" == "terms" ]]; then
        ARCHIVE_LOG="${DRYRUN_LOGS_DIR}/dryrun_linuxterms.${RUN_STAMP}"
    else
        ARCHIVE_LOG="${DRYRUN_LOGS_DIR}/dryrun_linuxtrans.${RUN_STAMP}"
    fi
elif [[ "${MODE}" == "terms" ]]; then
    ARCHIVE_LOG="${LOGS_DIR}/linuxterms.${RUN_STAMP}"
else
    ARCHIVE_LOG="${LOGS_DIR}/linuxtrans.${RUN_STAMP}"
fi

PSSH_TMP=$(mktemp -d /var/tmp/tti_pssh.XXXXXX)

# Single EXIT trap cleans up ALL temp files.
# Using a function avoids the trap-overwrite problem where each new
# trap 'cmd' EXIT replaces the previous one.
_cleanup_tmpfiles() {
    rm -rf "${PSSH_TMP}"
    [[ -n "${CUSTOM_IDS_FILE}" && -f "${IDS_FILE:-}" ]] && rm -f "${IDS_FILE}"
}
trap '_cleanup_tmpfiles' EXIT

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
#   Writes a remote script that:
#     - Prints its own hostname as a marker line: "HOST:hostname"
#       This is the only reliable way to know which host produced which output,
#       since pssh --inline-stdout output lines have no hostname prefix.
#     - For each user: checks home dirs, /etc/passwd, /etc/group
#     - Prints one result line per action found, format: STATUS:data
#
#   Full output from one host looks like:
#     HOST:lnxapp0044.pncbank.com
#     HOME_DRY_RUN:/home/pn15145
#     PASSWD_DRY_RUN:pn15145
#     GROUP_DRY_RUN:pn15145:efg_sudoers
#
#   If nothing is found for any user, only the HOST: line is printed.
#   The parser reads HOST: lines to know the current host context, then
#   maps subsequent result lines to that host until the next HOST: line.
build_remote_script() {
    local -n _ids="$1"
    local dry="$2"
    local script_file="$3"

    local ids_literal=""
    for u in "${_ids[@]}"; do
        # Always lowercase — OIM files use uppercase, custom --ids-file may too.
        # Home dirs and passwd entries are lowercase on Linux servers.
        ids_literal+=" ${u,,}"
    done

    if [[ "${dry}" == "true" ]]; then
        cat > "${script_file}" << 'ENDBODY'
echo "HOST:$(hostname)"
for u in __IDS__; do
  # Check home dirs in both lowercase and uppercase.
  # IDs are normalized to lowercase before the script runs, but some legacy
  # home dirs may have been created with uppercase. Check all four variants
  # and report only the first one found — never report the same user twice.
  ul=$(echo "${u}" | tr '[:upper:]' '[:lower:]')
  uu=$(echo "${u}" | tr '[:lower:]' '[:upper:]')
  home_found=0
  for p in "/home/${ul}" "/home/${ul}OUD" "/home/${uu}" "/home/${uu}OUD"; do
    if [ -e "${p}" ] && [ "${home_found}" -eq 0 ]; then
      echo "HOME_DRY_RUN:${p}"
      home_found=1
    fi
  done
  grep -q "^${ul}:" /etc/passwd 2>/dev/null && echo "PASSWD_DRY_RUN:${ul}" || true
  groups=$(grep -P "^[^:]+:[^:]+:[^:]+:.*${ul}" /etc/group 2>/dev/null     | cut -d: -f1 | tr '
' ',' | sed 's/,$//')
  [ -n "${groups}" ] && echo "GROUP_DRY_RUN:${ul}:${groups}" || true
done
ENDBODY
    else
        cat > "${script_file}" << 'ENDBODY'
echo "HOST:$(hostname)"
for u in __IDS__; do
  ul=$(echo "${u}" | tr '[:upper:]' '[:lower:]')
  uu=$(echo "${u}" | tr '[:lower:]' '[:upper:]')
  home_found=0
  for p in "/home/${ul}" "/home/${ul}OUD" "/home/${uu}" "/home/${uu}OUD"; do
    if [ -e "${p}" ] && [ "${home_found}" -eq 0 ]; then
      rm -rf "${p}" && echo "HOME_REMOVED:${p}" || echo "HOME_FAILED:${p}"
      home_found=1
    fi
  done
  if grep -q "^${ul}:" /etc/passwd 2>/dev/null; then
    userdel "${ul}" 2>/dev/null && echo "PASSWD_REMOVED:${ul}" || echo "PASSWD_FAILED:${ul}"
  fi
  groups=$(grep -P "^[^:]+:[^:]+:[^:]+:.*${ul}" /etc/group 2>/dev/null     | cut -d: -f1 | tr '
' ',' | sed 's/,$//')
  if [ -n "${groups}" ]; then
    cp /etc/group "/etc/group.preremove.${ul}" &&     sed -i -e "s/,${ul}//g" -e "s/${ul},//g" -e "s/:${ul}\$//g" /etc/group &&     echo "GROUP_REMOVED:${ul}:${groups}" || echo "GROUP_FAILED:${ul}"
  fi
done
ENDBODY
    fi

    # Replace __IDS__ placeholder with the actual ID list.
    # Using Python instead of sed because:
    #   1. sed uses / as delimiter — any / in ids_literal breaks s/__IDS__/.../ 
    #   2. Very long substitution strings (300+ IDs) can exceed sed limits
    #   3. Python handles arbitrary string content safely with no delimiter issues
    python3 -c "
import sys
with open(sys.argv[1], 'r') as f:
    data = f.read()
data = data.replace('__IDS__', sys.argv[2])
with open(sys.argv[1], 'w') as f:
    f.write(data)
" "${script_file}" "${ids_literal}"
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
        -x "${PSSH_SSH_OPTS}" \
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
#   Parses combined pssh --inline-stdout output.
#
#   pssh status lines (used only for FAILURE detection):
#     [N] HH:MM:SS [SUCCESS] hostname
#     [N] HH:MM:SS [FAILURE] hostname  <- SSH connect failed, log as unreachable
#
#   Remote script output lines (no hostname prefix from pssh):
#     HOST:hostname          <- the remote host identifying itself via $(hostname)
#     HOME_DRY_RUN:/home/u   <- result lines follow until next HOST: line
#     PASSWD_REMOVED:userid
#     GROUP_DRY_RUN:userid:groups
#
#   We track current_host from HOST: lines, and log FAILURE hosts as unreachable.
#   All result lines are attributed to current_host.
parse_batch_output() {
    local out_file="$1"
    [[ -f "${out_file}" ]] || return

    local current_host=""
    declare -A seen_failure

    while IFS= read -r line; do
        # pssh FAILURE status line — SSH never connected
        if [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[FAILURE\][[:space:]](.+)$ ]]; then
            local fhost="${BASH_REMATCH[1]}"
            if [[ -z "${seen_failure[${fhost}]:-}" ]]; then
                seen_failure["${fhost}"]="1"
                log_unreachable "${fhost}"
            fi
            continue
        fi

        # pssh SUCCESS status line — SSH connected, count it
        if [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[SUCCESS\][[:space:]](.+)$ ]]; then
            (( CNT_REACHED++ )) || true
            continue
        fi

        # Remote script HOST: marker — sets context for following result lines
        if [[ "${line}" =~ ^HOST:(.+)$ ]]; then
            current_host="${BASH_REMATCH[1]}"
            continue
        fi

        # Skip any other non-result lines (blank, pssh noise)
        [[ -z "${current_host}" ]] && continue
        [[ "${line}" =~ ^(HOME_|PASSWD_|GROUP_) ]] || continue

        # Parse STATUS:data
        local status data userid groups
        status="${line%%:*}"
        data="${line#*:}"

        case "${status}" in
            HOME_REMOVED)
                userid=$(basename "${data}" | sed 's/OUD$//')
                log_success "${userid}: Removed ${data} on ${current_host}"
                (( CNT_HOME_REMOVED++ )) || true
                ;;
            HOME_FAILED)
                userid=$(basename "${data}" | sed 's/OUD$//')
                log_failure "${userid}: Failed to remove ${data} on ${current_host}"
                (( CNT_HOME_FAILED++ )) || true
                ;;
            HOME_DRY_RUN)
                userid=$(basename "${data}" | sed 's/OUD$//')
                log_dry_run "${userid}: Would remove ${data} on ${current_host}"
                (( CNT_HOME_DRYRUN++ )) || true
                ;;
            PASSWD_REMOVED)
                log_success "${data}: Removed local account from /etc/passwd on ${current_host}"
                (( CNT_PASSWD_REMOVED++ )) || true
                ;;
            PASSWD_FAILED)
                log_failure "${data}: Failed to remove local account from /etc/passwd on ${current_host}"
                (( CNT_PASSWD_FAILED++ )) || true
                ;;
            PASSWD_DRY_RUN)
                log_dry_run "${data}: Would run userdel ${data} on ${current_host}"
                (( CNT_PASSWD_DRYRUN++ )) || true
                ;;
            GROUP_REMOVED)
                userid="${data%%:*}"
                groups="${data#*:}"
                log_success "${userid}: Removed from [${groups}] in /etc/group on ${current_host} (backup: /etc/group.preremove.${userid})"
                (( CNT_GROUP_REMOVED++ )) || true
                ;;
            GROUP_FAILED)
                log_failure "${data}: Failed to remove from /etc/group on ${current_host}"
                (( CNT_GROUP_FAILED++ )) || true
                ;;
            GROUP_DRY_RUN)
                userid="${data%%:*}"
                groups="${data#*:}"
                log_dry_run "${userid}: Would remove from [${groups}] in /etc/group on ${current_host}"
                log_dry_run "${userid}: Would create /etc/group.preremove.${userid} on ${current_host}"
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
log_info "IDs file : ${IDS_FILE}$( [[ -n "${CUSTOM_IDS_FILE}" ]] && echo ' [CUSTOM]' || true )"
log_info "Servers  : ${SERVER_LIST}$( [[ -n "${CUSTOM_HOSTS_FILE}" ]] && echo ' [CUSTOM]' || true )"
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

# --- debug-pssh: single plain SSH against first server only -----------------
# Run with --debug-pssh to verify remote script execution without pssh.
# Tests one server via plain ssh and logs the raw output byte-for-byte.
if ${DEBUG_PSSH}; then
    first_server="${ALL_SERVERS[0]}"
    log_info "DEBUG-PSSH: Testing remote script via plain ssh against: ${first_server}"
    log_info "DEBUG-PSSH: Script file contents:"
    while IFS= read -r dline; do
        log_info "DEBUG-PSSH:   ${dline}"
    done < "${REMOTE_SCRIPT_FILE}"

    log_info "DEBUG-PSSH: Running: ssh ${SSH_OPTS} -l ${PSSH_LOGIN} ${first_server} bash -s < script"
    ssh_out=$( ssh ${SSH_OPTS} -i "${PSSH_IDENTITY}" -l "${PSSH_LOGIN}" "${first_server}" 'bash -s'                < "${REMOTE_SCRIPT_FILE}" 2>&1 ) || true
    ssh_rc=$?
    log_info "DEBUG-PSSH: ssh exit code: ${ssh_rc}"
    log_info "DEBUG-PSSH: Raw output (every line):"
    if [[ -z "${ssh_out}" ]]; then
        log_info "DEBUG-PSSH:   (empty — no output returned)"
    else
        while IFS= read -r oline; do
            log_info "DEBUG-PSSH:   |${oline}|"
        done <<< "${ssh_out}"
    fi
    log_info "DEBUG-PSSH: Done. Exiting — remove --debug-pssh to run full job."

    # Extra verification: directly list /home/ on the server and check which
    # of our user IDs appear there, regardless of the remote script output.
    log_info "DEBUG-PSSH: Checking /home/ listing on ${first_server}:"
    home_list=$( ssh ${SSH_OPTS} -i "${PSSH_IDENTITY}" -l "${PSSH_LOGIN}" "${first_server}"         'ls /home/ 2>/dev/null' 2>&1 ) || true
    if [[ -z "${home_list}" ]]; then
        log_info "DEBUG-PSSH:   /home/ is empty or not readable"
    else
        log_info "DEBUG-PSSH:   /home/ contents: ${home_list}"
        # Cross-check against our user ID list
        local matches=0
        for uid in "${USER_IDS[@]}"; do
            if echo "${home_list}" | grep -qE "^${uid}$|^${uid}OUD$"; then
                log_info "DEBUG-PSSH:   MATCH FOUND: ${uid} has a home dir on ${first_server}"
                (( matches++ )) || true
            fi
        done
        [[ ${matches} -eq 0 ]] && log_info "DEBUG-PSSH:   No matches — none of the 52 users have homes on ${first_server}"
    fi

    # Also verify /etc/passwd for any of our users
    log_info "DEBUG-PSSH: Checking /etc/passwd on ${first_server} for any of our users:"
    passwd_matches=$( ssh ${SSH_OPTS} -i "${PSSH_IDENTITY}" -l "${PSSH_LOGIN}" "${first_server}"         "grep -E '^($(IFS='|'; echo "${USER_IDS[*]}"|sed 's/ /|/g')):' /etc/passwd 2>/dev/null || true"         2>&1 ) || true
    if [[ -z "${passwd_matches}" ]]; then
        log_info "DEBUG-PSSH:   No local /etc/passwd entries found for any of our users"
    else
        log_info "DEBUG-PSSH:   /etc/passwd matches: ${passwd_matches}"
    fi

    exit 0
fi

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

exit 0
