#!/bin/bash
# =============================================================================
# nfs_remount.sh — Detect and recover hung NFS mounts after a network outage
# =============================================================================
#
# BACKGROUND:
#   During switch upgrades, a brief network outage (30–60s) leaves servers with
#   stale NFS connections. Servers that had NFS traffic in-flight at the time
#   end up with hung mounts — stat/ls on the mountpoint hangs indefinitely.
#   This script detects hung mounts and recovers them via lazy force unmount,
#   handling both /etc/fstab mounts and systemd .mount unit files.
#
# HOW IT WORKS:
#   1. Reads a server list (one hostname per line)
#   2. Uses pssh to run a remote detection/recovery script on all servers in
#      parallel (same pattern as TTI cleanup jobs)
#   3. Remote script tags every output line with STATUS:data tokens
#   4. This script parses those tokens, logs results, and prints a summary
#
# REMOTE SCRIPT OUTPUT TOKENS (one line per event):
#   HOST:<hostname>               — self-identification (required for parsing)
#   NFS_NONE                      — no NFS mounts found on this server
#   MOUNT_OK:<path>               — mount is responsive, no action needed
#   MOUNT_HUNG:<path>:<method>    — hung mount detected (method=fstab|systemd|unknown)
#   MOUNT_DRY:<path>:<method>     — dry-run: would attempt recovery
#   RECOVERED:<path>:<method>     — mount successfully recovered
#   STILL_HUNG:<path>:<method>    — recovery attempted but mount still hung
#   SKIPPED:<path>                — hung but method unknown, manual action needed
#
# USAGE:
#   nfs_remount.sh --hosts /path/to/hosts.txt [OPTIONS]
#
# OPTIONS:
#   --hosts   /path/file    Server list (one hostname per line) [REQUIRED]
#   --dry-run               Detect only — report what is hung, make no changes
#   --timeout N             Seconds to wait for stat() before declaring hung (default: 5)
#   --batch   N             pssh parallel batch size (default: 75)
#
# OUTPUT FILES (written to same directory as this script):
#   nfs_remount.YYMMDDHHNN       Full timestamped log of this run
#   nfs_remount_hung.YYMMDDHHNN  Only servers with hung mounts (for follow-up)
#
# EXAMPLES:
#   Dry run against weekend change list — see what's hung, touch nothing:
#     ./nfs_remount.sh --hosts /tmp/weekend_servers.txt --dry-run
#
#   Live recovery run:
#     ./nfs_remount.sh --hosts /tmp/weekend_servers.txt
#
#   Tighter stat timeout for fast networks:
#     ./nfs_remount.sh --hosts /tmp/weekend_servers.txt --timeout 3
#
#   After recovery, re-run dry-run to confirm nothing is still hung:
#     ./nfs_remount.sh --hosts /tmp/weekend_servers.txt --dry-run
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- pssh settings (matches TTI pattern) -------------------------------------
PSSH_BIN="/usr/local/pssh/bin/pssh"
PSSH_LOGIN="root"
PSSH_BATCH=75
PSSH_TIMEOUT=60        # per-host SSH timeout — longer than stat_timeout to allow
                       # time for detection + recovery + post-check on each host

# --- Defaults ----------------------------------------------------------------
HOSTS_FILE=""
DRY_RUN=false
STAT_TIMEOUT=5
LOG_DIR="${SCRIPT_DIR}"
RUN_STAMP=$(date +%y%m%d%H%M)

# --- Colors (stdout only — log file gets plain text) -------------------------

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat >&2 << USAGE

${SCRIPT_NAME} — NFS hung mount detector and recovery tool

USAGE:
  ${SCRIPT_NAME} --hosts /path/to/hosts.txt [OPTIONS]

REQUIRED:
  --hosts  /path/file     Server list (one hostname per line)

OPTIONS:
  --dry-run               Detect only, make no changes
  --timeout N             Seconds before a mount is declared hung (default: 5)
  --batch   N             pssh parallel batch size (default: 75)
  --help                  Show this message

EXAMPLES:
  # See what is hung before making any changes
  ${SCRIPT_NAME} --hosts /tmp/weekend_servers.txt --dry-run

  # Recover all hung mounts
  ${SCRIPT_NAME} --hosts /tmp/weekend_servers.txt

  # Confirm everything is recovered (re-run dry-run after live run)
  ${SCRIPT_NAME} --hosts /tmp/weekend_servers.txt --dry-run

USAGE
    exit 1
}

# =============================================================================
# Argument parsing
# =============================================================================

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts)    HOSTS_FILE="$2";   shift 2 ;;
        --dry-run)  DRY_RUN=true;      shift   ;;
        --timeout)  STAT_TIMEOUT="$2"; shift 2 ;;
        --batch)    PSSH_BATCH="$2";   shift 2 ;;
        --help|-h)  usage ;;
        *)          echo "[ERROR] Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "${HOSTS_FILE}" ]]  || { echo "[ERROR] --hosts is required" >&2; usage; }
[[ -f "${HOSTS_FILE}" ]]  || { echo "[ERROR] Hosts file not found: ${HOSTS_FILE}" >&2; exit 2; }
[[ -x "${PSSH_BIN}" ]]    || { echo "[ERROR] pssh not found or not executable: ${PSSH_BIN}" >&2; exit 2; }

# =============================================================================
# Log setup
# =============================================================================
# Logs are written to the same directory as the script.
# No subdirectory needed — drop the script anywhere and run it.

if ${DRY_RUN}; then
    LOG_FILE="${LOG_DIR}/nfs_remount_dryrun.${RUN_STAMP}"
else
    LOG_FILE="${LOG_DIR}/nfs_remount.${RUN_STAMP}"
fi
HUNG_LOG="${LOG_DIR}/nfs_remount_hung.${RUN_STAMP}"

: > "${LOG_FILE}"
: > "${HUNG_LOG}"

# =============================================================================
# Logging helpers
# =============================================================================
# Log file gets plain timestamped lines.
# Terminal output.

_ts() { date +"%Y-%m-%d %H:%M:%S"; }

_log_file() {
    local level="$1" msg="$2"
    printf "[%s] [%-10s] %s\n" "$(_ts)" "${level}" "${msg}" >> "${LOG_FILE}"
}

log_info()      { _log_file "INFO"      "$1"; }
log_ok()        { _log_file "OK"        "$1"; }
log_hung()      { _log_file "HUNG"      "$1"; _log_hung_file "$1"; }
log_dryrun()    { _log_file "DRY_RUN"   "$1"; }
log_recovered() { _log_file "RECOVERED" "$1"; }
log_failed()    { _log_file "FAILED"    "$1"; _log_hung_file "$1"; }
log_skipped()   { _log_file "SKIPPED"   "$1"; }
log_warn()      { _log_file "WARN"      "$1"; }
log_summary()   { _log_file "SUMMARY"   "$1"; }

_log_hung_file() {
    # Mirrors hung/still-hung entries to the dedicated hung log
    printf "%s\n" "$1" >> "${HUNG_LOG}"
}

# Terminal print helpers — these go to stdout, not the log file
print_header() {
    echo "$1"
}
print_ok()        { echo "  [OK]        $1"; }
print_hung()      { echo "  [HUNG]      $1"; }
print_dryrun()    { echo "  [DRY-RUN]   $1"; }
print_recovered() { echo "  [RECOVERED] $1"; }
print_failed()    { echo "  [FAILED]    $1"; }
print_skipped()   { echo "  [SKIPPED]   $1"; }
print_warn()      { echo "  [WARN]      $1"; }
print_info()      { echo "  $1"; }
print_div()       { echo "------------------------------------------------------------"; }

# =============================================================================
# Temp dir + cleanup
# =============================================================================

PSSH_TMP=$(mktemp -d /var/tmp/nfs_remount.XXXXXX)
trap 'rm -rf "${PSSH_TMP}"' EXIT

# =============================================================================
# Counters
# =============================================================================

declare -i CNT_SERVERS=0 CNT_REACHED=0 CNT_UNREACHABLE=0
declare -i CNT_NO_NFS=0
declare -i CNT_OK=0
declare -i CNT_HUNG=0
declare -i CNT_RECOVERED=0 CNT_STILL_HUNG=0 CNT_SKIPPED=0

# =============================================================================
# Remote script builder
# =============================================================================
# Writes the script that runs on each remote server.
# Kept as a single heredoc so it's easy to audit.
# DRY_RUN and STAT_TIMEOUT are baked in at build time.

build_remote_script() {
    local script_file="$1"
    local dry="${DRY_RUN}"
    local timeout="${STAT_TIMEOUT}"

    cat > "${script_file}" << REMOTE_SCRIPT
#!/bin/bash
# Remote NFS detection/recovery script
# Generated by ${SCRIPT_NAME} at $(_ts)
# dry_run=${dry}  stat_timeout=${timeout}s

set -uo pipefail

STAT_TIMEOUT=${timeout}
DRY_RUN=${dry}

echo "HOST:\$(hostname)"

# findmnt reads kernel mount tables — never hangs, even when NFS is hung.
# Write to a temp file so we can check if it is empty before looping.
TMPFILE="\$(mktemp)"
trap 'rm -f "\$TMPFILE"' EXIT

findmnt -rn -t nfs,nfs4 -o TARGET,SOURCE,FSTYPE,OPTIONS > "\$TMPFILE"

if [ ! -s "\$TMPFILE" ]; then
    echo "NFS_NONE"
    exit 0
fi

while IFS= read -r line; do
    [ -z "\$line" ] && continue

    MOUNTPOINT="\$(awk '{print \$1}' <<< "\$line")"
    SOURCE="\$(awk '{print \$2}' <<< "\$line")"
    UNIT="\$(systemd-escape -p --suffix=mount "\$MOUNTPOINT")"

    # stat() with a hard timeout — returns fast if mount is alive,
    # times out after STAT_TIMEOUT seconds if the mount is hung.
    if timeout "\$STAT_TIMEOUT" stat -- "\$MOUNTPOINT" >/dev/null 2>&1; then
        echo "MOUNT_OK:\${MOUNTPOINT}"
        continue
    fi

    # Mount did not respond — determine recovery method.
    LOAD_STATE="\$(systemctl show -p LoadState --value "\$UNIT" 2>/dev/null || echo not-found)"

    if findmnt -rn --fstab --target "\$MOUNTPOINT" >/dev/null 2>&1; then
        METHOD="fstab"
    elif [ "\$LOAD_STATE" = "loaded" ]; then
        METHOD="systemd"
    else
        METHOD="unknown"
    fi

    if [ "\$DRY_RUN" = "true" ]; then
        echo "MOUNT_DRY:\${MOUNTPOINT}:\${METHOD}"
        continue
    fi

    echo "MOUNT_HUNG:\${MOUNTPOINT}:\${METHOD}"

    # Recovery — straight to lazy force unmount, no graceful stop.
    # systemctl stop blocks if the unit is hung; skip it entirely.
    case "\$METHOD" in
        fstab)
            umount -lf -- "\$MOUNTPOINT" >/dev/null 2>&1 || true
            mount "\$MOUNTPOINT" >/dev/null 2>&1 || true
            ;;
        systemd)
            umount -lf -- "\$MOUNTPOINT" >/dev/null 2>&1 || true
            systemctl start "\$UNIT" >/dev/null 2>&1 || true
            ;;
        unknown)
            echo "SKIPPED:\${MOUNTPOINT}"
            continue
            ;;
    esac

    # Verify recovery.
    if timeout "\$STAT_TIMEOUT" stat -- "\$MOUNTPOINT" >/dev/null 2>&1; then
        echo "RECOVERED:\${MOUNTPOINT}:\${METHOD}"
    else
        echo "STILL_HUNG:\${MOUNTPOINT}:\${METHOD}"
    fi

done < "\$TMPFILE"

exit 0
REMOTE_SCRIPT

    chmod +x "${script_file}"
}

# =============================================================================
# pssh runner
# =============================================================================

run_pssh_batch() {
    local host_file="$1"
    local script_file="$2"
    local out_file="$3"

    local pssh_opts="-I --inline-stdout -p ${PSSH_BATCH} -t ${PSSH_TIMEOUT} -l ${PSSH_LOGIN}"

    # pssh -I reads the script from stdin and pipes it to bash on each host.
    # --inline-stdout merges all host output into one stream with pssh status
    # headers interspersed. We parse both below.
    cat "${script_file}" | "${PSSH_BIN}" ${pssh_opts} \
        -h "${host_file}" \
        bash \
        > "${out_file}" 2>/dev/null || true
}

# =============================================================================
# Output parser
# =============================================================================
# Parses combined pssh --inline-stdout output.
#
# pssh status lines:
#   [N] HH:MM:SS [SUCCESS] hostname
#   [N] HH:MM:SS [FAILURE] hostname
#
# Remote script output lines (no pssh prefix — we use HOST: for context):
#   HOST:hostname
#   NFS_NONE
#   MOUNT_OK:/mnt/path
#   MOUNT_HUNG:/mnt/path:fstab
#   MOUNT_DRY:/mnt/path:systemd
#   RECOVERED:/mnt/path:fstab
#   STILL_HUNG:/mnt/path:systemd
#   SKIPPED:/mnt/path

parse_pssh_output() {
    local out_file="$1"
    [[ -f "${out_file}" ]] || return

    local current_host=""
    declare -A seen_failure

    while IFS= read -r line; do

        # pssh FAILURE — SSH never connected
        if [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[FAILURE\][[:space:]](.+)$ ]]; then
            local fhost="${BASH_REMATCH[1]}"
            if [[ -z "${seen_failure[${fhost}]:-}" ]]; then
                seen_failure["${fhost}"]="1"
                log_warn "Unreachable: ${fhost}"
                print_warn "${fhost} — unreachable (SSH failed)"
                (( CNT_UNREACHABLE++ )) || true
            fi
            continue
        fi

        # pssh SUCCESS — SSH connected
        if [[ "${line}" =~ ^\[[0-9]+\][[:space:]][0-9:]+[[:space:]]\[SUCCESS\][[:space:]](.+)$ ]]; then
            (( CNT_REACHED++ )) || true
            continue
        fi

        # HOST: self-identification from remote script
        if [[ "${line}" =~ ^HOST:(.+)$ ]]; then
            current_host="${BASH_REMATCH[1]}"
            continue
        fi

        # Skip lines with no host context or unrecognized format
        [[ -z "${current_host}" ]] && continue
        [[ "${line}" =~ ^(NFS_NONE|MOUNT_OK|MOUNT_HUNG|MOUNT_DRY|RECOVERED|STILL_HUNG|SKIPPED): ]] || continue

        local token="${line%%:*}"
        local data="${line#*:}"   # everything after first colon

        case "${token}" in

            NFS_NONE)
                log_info "${current_host}: no NFS mounts"
                (( CNT_NO_NFS++ )) || true
                ;;

            MOUNT_OK)
                local mp="${data}"
                log_ok "${current_host}: ${mp} — responsive"
                print_ok "${current_host}  ${mp}"
                (( CNT_OK++ )) || true
                ;;

            MOUNT_DRY)
                # data = mountpoint:method
                local mp="${data%%:*}"
                local method="${data##*:}"
                log_dryrun "${current_host}: ${mp} is HUNG (method=${method}) — would recover"
                print_dryrun "${current_host}  ${mp}  [${method}]  → would unmount + remount"
                (( CNT_HUNG++ )) || true
                ;;

            MOUNT_HUNG)
                local mp="${data%%:*}"
                local method="${data##*:}"
                log_hung "${current_host}: ${mp} is HUNG (method=${method}) — attempting recovery"
                print_hung "${current_host}  ${mp}  [${method}]"
                (( CNT_HUNG++ )) || true
                ;;

            RECOVERED)
                local mp="${data%%:*}"
                local method="${data##*:}"
                log_recovered "${current_host}: ${mp} RECOVERED (method=${method})"
                print_recovered "${current_host}  ${mp}  [${method}]"
                (( CNT_RECOVERED++ )) || true
                ;;

            STILL_HUNG)
                local mp="${data%%:*}"
                local method="${data##*:}"
                log_failed "${current_host}: ${mp} STILL HUNG after recovery attempt (method=${method})"
                print_failed "${current_host}  ${mp}  [${method}]  → manual action required"
                (( CNT_STILL_HUNG++ )) || true
                ;;

            SKIPPED)
                local mp="${data}"
                log_skipped "${current_host}: ${mp} — method unknown (not in fstab, no systemd unit)"
                print_skipped "${current_host}  ${mp}  → not in fstab and no systemd unit, check manually"
                (( CNT_SKIPPED++ )) || true
                ;;

        esac

    done < "${out_file}"
}

# =============================================================================
# Main
# =============================================================================

mapfile -t ALL_SERVERS < <(grep -v '^\s*$\|^\s*#' "${HOSTS_FILE}")
CNT_SERVERS=${#ALL_SERVERS[@]}

# --- Header ------------------------------------------------------------------

print_div
print_header " NFS Hung Mount Recovery"
print_div
if ${DRY_RUN}; then
    echo "  MODE     : DRY RUN — detection only, no changes will be made"
else
    echo "  MODE     : LIVE — hung mounts will be recovered"
fi
echo    "  Hosts    : ${CNT_SERVERS}  (${HOSTS_FILE})"
echo    "  Timeout  : ${STAT_TIMEOUT}s per mount stat check"
echo    "  Batch    : ${PSSH_BATCH} hosts in parallel"
echo    "  Log      : ${LOG_FILE}"print_div
echo

log_info "========================================================"
log_info "${SCRIPT_NAME} start  dry_run=${DRY_RUN}  stat_timeout=${STAT_TIMEOUT}s"
log_info "Hosts file : ${HOSTS_FILE}  (${CNT_SERVERS} servers)"
log_info "pssh batch : ${PSSH_BATCH}  timeout : ${PSSH_TIMEOUT}s"
log_info "========================================================"

# --- Build remote script once ------------------------------------------------

REMOTE_SCRIPT="${PSSH_TMP}/nfs_check.sh"
build_remote_script "${REMOTE_SCRIPT}"

# --- Fan out via pssh --------------------------------------------------------

print_header " Scanning servers..."
echo

batch_num=0
i=0
total=${#ALL_SERVERS[@]}

while [[ ${i} -lt ${total} ]]; do
    batch=("${ALL_SERVERS[@]:${i}:${PSSH_BATCH}}")
    (( batch_num++ )) || true
    (( i += PSSH_BATCH )) || true

    batch_host_file="${PSSH_TMP}/hosts_b${batch_num}.txt"
    out_file="${PSSH_TMP}/out_b${batch_num}.log"

    printf '%s\n' "${batch[@]}" > "${batch_host_file}"
    run_pssh_batch  "${batch_host_file}" "${REMOTE_SCRIPT}" "${out_file}"
    parse_pssh_output "${out_file}"
done

# --- Summary -----------------------------------------------------------------

echo
print_div
print_header " Summary"
print_div

if ${DRY_RUN}; then
    echo "  DRY RUN — no changes were made"
    echo
fi

printf "  %-28s %s\n" "Servers in scope:"    "${CNT_SERVERS}"
printf "  %-28s %s\n" "Reached via SSH:"     "${CNT_REACHED}"
printf "  %-28s %s\n" "Unreachable:"         "${CNT_UNREACHABLE}"
printf "  %-28s %s\n" "No NFS mounts:"       "${CNT_NO_NFS}"
printf "  %-28s %s\n" "Mounts responsive:"   "${CNT_OK}"
echo

if ${DRY_RUN}; then
    if [[ ${CNT_HUNG} -eq 0 ]]; then
        echo "  No hung mounts detected. All NFS mounts are responsive."
    else
        echo "  Hung mounts detected: ${CNT_HUNG}"
        echo    "  Re-run without --dry-run to recover them."
    fi
else
    printf "  %-28s %s\n" "Hung mounts found:"    "${CNT_HUNG}"

    if [[ ${CNT_RECOVERED} -gt 0 ]]; then
        echo "  $(printf '%-28s' 'Successfully recovered:')${CNT_RECOVERED}"
    else
        printf "  %-28s %s\n" "Successfully recovered:" "${CNT_RECOVERED}"
    fi

    if [[ ${CNT_STILL_HUNG} -gt 0 ]]; then
        echo "  $(printf '%-28s' 'Still hung after recovery:')${CNT_STILL_HUNG} — manual action required"
    else
        printf "  %-28s %s\n" "Still hung after recovery:" "${CNT_STILL_HUNG}"
    fi

    if [[ ${CNT_SKIPPED} -gt 0 ]]; then
        echo "  $(printf '%-28s' 'Skipped (unknown method):')${CNT_SKIPPED}"
    fi

    echo
    if [[ ${CNT_HUNG} -eq 0 ]]; then
        echo "  No hung mounts detected. All NFS mounts are responsive."
    elif [[ ${CNT_STILL_HUNG} -eq 0 && ${CNT_SKIPPED} -eq 0 ]]; then
        echo "  All hung mounts recovered successfully."
    elif [[ ${CNT_STILL_HUNG} -gt 0 ]]; then
        echo "  Some mounts could not be recovered automatically."
        echo    "  See: ${HUNG_LOG}"
        echo    "  Manual steps per server:"
        echo    "    fstab mount:  umount -lf /mountpoint && mount /mountpoint"
        echo    "    systemd unit: umount -lf /mountpoint && systemctl start mnt-path.mount"
    fi
fi

print_div

# Log summary
log_summary "========================================================"
log_summary "Servers in scope      : ${CNT_SERVERS}"
log_summary "Reached via SSH       : ${CNT_REACHED}"
log_summary "Unreachable           : ${CNT_UNREACHABLE}"
log_summary "No NFS mounts         : ${CNT_NO_NFS}"
log_summary "Mounts responsive     : ${CNT_OK}"
if ${DRY_RUN}; then
    log_summary "Hung detected (dry)   : ${CNT_HUNG}"
else
    log_summary "Hung mounts found     : ${CNT_HUNG}"
    log_summary "Recovered             : ${CNT_RECOVERED}"
    log_summary "Still hung            : ${CNT_STILL_HUNG}"
    log_summary "Skipped               : ${CNT_SKIPPED}"
fi
log_summary "Full log              : ${LOG_FILE}"
[[ ${CNT_STILL_HUNG} -gt 0 || ( ${DRY_RUN} == true && ${CNT_HUNG} -gt 0 ) ]] && \
    log_summary "Hung server log       : ${HUNG_LOG}"
log_summary "========================================================"

echo
echo    "  Full log : ${LOG_FILE}"
[[ -s "${HUNG_LOG}" ]] && echo "  Hung log : ${HUNG_LOG}" || rm -f "${HUNG_LOG}"
echo

# Exit non-zero if anything is still hung so callers (cron, AAP) can detect it
if [[ ${CNT_STILL_HUNG} -gt 0 ]]; then
    exit 1
fi

exit 0
