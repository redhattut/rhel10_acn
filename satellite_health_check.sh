#!/bin/bash
#
# satellite_health_check.sh
#
# Runs a health check against the Satellite server and its capsules via SSH
# from a central jump host, and produces a single consolidated plain-text
# report (terminal / email / log friendly - no ANSI color codes).
#
# Checks per host:
#   - satellite-maintain service status -b   (parsed down to non-OK services
#     plus the final "All services are running" line)
#   - /var/log disk usage (free-space based thresholds)
#   - /var/lib/pulp disk usage (free-space based thresholds)
#   - CPU utilization %
#   - memory usage
#
# Usage: ./satellite_health_check.sh [-o /path/to/output.txt]
#
set -uo pipefail

# ---------------------------------------------------------------------------
# CONFIG - edit hosts and thresholds here
# ---------------------------------------------------------------------------

# Format: "hostname|role"   role = HEAD or CAPSULE
HOSTS=(
    "lmrg10aa|HEAD"
    "lmrg10ba|CAPSULE"
    "lmrg10bb|CAPSULE"
)

SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"

# Disk thresholds are based on FREE space remaining, not used space.
#   WARN when free space drops below DISK_WARN_FREE_PCT
#   CRITICAL when free space drops below DISK_CRIT_FREE_PCT
DISK_WARN_FREE_PCT=10
DISK_CRIT_FREE_PCT=5

# CPU utilization thresholds (%)
CPU_WARN_PCT=80
CPU_CRIT_PCT=95

MEM_WARN_PCT=85
MEM_CRIT_PCT=95

OUTFILE=""
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---------------------------------------------------------------------------
# ARG PARSING
# ---------------------------------------------------------------------------
while getopts "o:h" opt; do
    case "$opt" in
        o) OUTFILE="$OPTARG" ;;
        h)
            echo "Usage: $0 [-o output_file]"
            exit 0
            ;;
        *) echo "Usage: $0 [-o output_file]"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# COUNTERS
# ---------------------------------------------------------------------------
TOTAL_HOSTS=0
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
CRIT_COUNT=0
declare -a ACTION_ITEMS=()

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

hr() { printf -- '------------------------------------------------------------------------\n'; }
dhr() { printf '==========================================================================\n'; }

pad_line() {
    # pad_line "label text" "status"  -> dot-fills between label and bracketed status
    local label="$1" status="$2"
    local width=60
    local len=${#label}
    local dots=$(( width - len ))
    (( dots < 3 )) && dots=3
    printf "  %s " "$label"
    printf '.%.0s' $(seq 1 "$dots")
    printf " [ %s ]\n" "$status"
}

ssh_run() {
    local host="$1" cmd="$2"
    ssh $SSH_OPTS "${host}" "$cmd" 2>/dev/null
}

# Some sudoers configs set "Defaults requiretty", which makes sudo refuse to
# run at all over a plain non-interactive SSH exec (fails with "sorry, you
# must have a tty to run sudo"). Forcing a pseudo-terminal with -tt works
# around that. Only used for the sudo satellite-maintain call - other checks
# (df, free, /proc/stat) don't need sudo and stay on the plain ssh_run above.
ssh_run_tty() {
    local host="$1" cmd="$2"
    ssh -tt $SSH_OPTS "${host}" "$cmd" </dev/null 2>&1 | tr -d '\r'
}

# ---------------------------------------------------------------------------
# Parse `satellite-maintain service status -b` output.
#
# Expected lines look like (leading tree-character varies: - | \ /):
#   - displaying pulpcore-content                          [OK]
#   \ All services are running                              [OK]
#
# We only want to print services that are NOT [OK], plus the final
# "All services are running" line (whatever its status is).
#
# Sets globals: SVC_OVERALL_STATUS, SVC_NONOK_LINES (array), SVC_FINAL_LINE
# ---------------------------------------------------------------------------
parse_service_status() {
    local raw="$1"
    SVC_NONOK_LINES=()
    SVC_FINAL_LINE=""
    SVC_OVERALL_STATUS="UNKNOWN"

    local clean svc status
    while IFS= read -r line; do
        # strip leading tree-drawing character (-, |, \, /) and whitespace
        clean="$(echo "$line" | sed -E 's/^[[:space:]]*[-|\\/][[:space:]]*//')"

        if [[ "$clean" =~ ^[Aa]ll[[:space:]]services[[:space:]]are[[:space:]]running[[:space:]]+\[([A-Za-z]+)\]$ ]]; then
            SVC_OVERALL_STATUS="${BASH_REMATCH[1]}"
            SVC_FINAL_LINE="All services are running"
        elif [[ "$clean" =~ ^displaying[[:space:]]+(.+[^[:space:]])[[:space:]]+\[([A-Za-z]+)\]$ ]]; then
            svc="${BASH_REMATCH[1]}"
            status="${BASH_REMATCH[2]}"
            if [[ "$status" != "OK" ]]; then
                SVC_NONOK_LINES+=("${svc}|${status}")
            fi
        fi
    done <<< "$raw"

    # If we never matched a final line, we couldn't parse the output at all -
    # this means the command didn't run as expected (SSH/sudo/tty/permission
    # issue, unexpected output format, etc.). This is NOT the same as Satellite
    # reporting an actual failure, so it must never be labeled FAIL - mark it
    # UNKNOWN and let the caller surface the raw output for troubleshooting.
    if [[ "$SVC_FINAL_LINE" == "" ]]; then
        SVC_OVERALL_STATUS="UNKNOWN"
        SVC_FINAL_LINE=""
    fi
}

# Given a used/total pair, compute free % and return WARN/CRITICAL/OK
disk_status_from_pct() {
    local used_pct="$1"
    local free_pct=$(( 100 - used_pct ))
    if (( free_pct < DISK_CRIT_FREE_PCT )); then
        echo "CRITICAL|${free_pct}"
    elif (( free_pct < DISK_WARN_FREE_PCT )); then
        echo "WARN|${free_pct}"
    else
        echo "OK|${free_pct}"
    fi
}

# ---------------------------------------------------------------------------
# MAIN CHECK PER HOST
# ---------------------------------------------------------------------------
check_host() {
    local host="$1" role="$2"

    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
    local host_had_fail=0
    local host_had_warn=0
    local host_had_crit=0

    hr
    printf " HOST: %s  [ROLE: %s]\n" "$host" "$([[ "$role" == "HEAD" ]] && echo "Satellite Server" || echo "Capsule")"
    hr

    # --- reachability check first ---
    if ! ssh_run "$host" "echo ok" >/dev/null; then
        pad_line "SSH Connectivity" "UNREACHABLE"
        printf "\n"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        ACTION_ITEMS+=("$host - unreachable via SSH, all checks skipped")
        return
    fi

    # --- satellite-maintain service status (merged health/service block) ---
    local svc_raw
    svc_raw="$(ssh_run_tty "$host" "sudo satellite-maintain service status -b 2>&1")"
    parse_service_status "$svc_raw"

    pad_line "Satellite Service Status" "$SVC_OVERALL_STATUS"

    if [[ "$SVC_OVERALL_STATUS" == "UNKNOWN" ]]; then
        host_had_fail=1
        printf "    - Could not parse satellite-maintain output (SSH/sudo/permission issue?)\n"
        printf "    - Raw output from host:\n"
        echo "$svc_raw" | sed 's/^/        /'
        ACTION_ITEMS+=("$host - could not parse satellite-maintain output, see raw output in report")
    else
        if [[ "$SVC_OVERALL_STATUS" != "OK" ]]; then
            host_had_fail=1
            ACTION_ITEMS+=("$host - satellite-maintain reports overall status $SVC_OVERALL_STATUS")
        fi

        for entry in "${SVC_NONOK_LINES[@]:-}"; do
            [[ -z "$entry" ]] && continue
            IFS='|' read -r svc status <<< "$entry"
            printf "    - %-48s [%s]\n" "$svc" "$status"
            ACTION_ITEMS+=("$host - service $svc reported [$status]")
        done
        printf "    - %-48s [%s]\n" "$SVC_FINAL_LINE" "$SVC_OVERALL_STATUS"
    fi

    # --- disk: /var/log and /var/lib/pulp ---
    printf "\n  Disk Space\n"
    for mount in "/var/log" "/var/lib/pulp"; do
        local disk_line used size pct result status free_pct
        disk_line="$(ssh_run "$host" "df -h $mount --output=used,size,pcent | tail -1")"
        used=$(echo "$disk_line" | awk '{print $1}')
        size=$(echo "$disk_line" | awk '{print $2}')
        pct=$(echo "$disk_line" | awk '{print $3}' | tr -d '%')

        if [[ -z "$pct" ]]; then
            printf "    %-14s %s\n" "$mount" "[ UNKNOWN - mount not found or unreachable ]"
            continue
        fi

        result="$(disk_status_from_pct "$pct")"
        status="${result%%|*}"
        free_pct="${result##*|}"

        if [[ "$status" == "CRITICAL" ]]; then
            host_had_crit=1
            ACTION_ITEMS+=("$host - $mount at ${free_pct}% free (CRITICAL)")
        elif [[ "$status" == "WARN" ]]; then
            host_had_warn=1
            ACTION_ITEMS+=("$host - $mount at ${free_pct}% free (WARN)")
        fi

        printf "%-74s[ %s ]\n" "$(printf "    %-14s %s / %s  (%s%% used, %s%% free)" "$mount" "$used" "$size" "$pct" "$free_pct")" "$status"
    done

    # --- CPU utilization % ---
    local cpu_pct cpu_status
    # Two snapshots of /proc/stat ~1s apart, compute utilization from deltas
    cpu_pct="$(ssh_run "$host" "read cpu a1 b1 c1 idle1 rest1 < /proc/stat; sleep 1; read cpu a2 b2 c2 idle2 rest2 < /proc/stat; total1=\$((a1+b1+c1+idle1)); total2=\$((a2+b2+c2+idle2)); dtotal=\$((total2-total1)); didle=\$((idle2-idle1)); awk -v dt=\$dtotal -v di=\$didle 'BEGIN{ if (dt>0) printf \"%.0f\", (1-(di/dt))*100; else print \"0\" }'")"

    cpu_status="OK"
    if [[ -n "$cpu_pct" ]]; then
        if (( cpu_pct >= CPU_CRIT_PCT )); then
            cpu_status="CRITICAL"; host_had_crit=1
            ACTION_ITEMS+=("$host - CPU utilization at ${cpu_pct}%")
        elif (( cpu_pct >= CPU_WARN_PCT )); then
            cpu_status="WARN"; host_had_warn=1
        fi
    else
        cpu_pct="?"
        cpu_status="UNKNOWN"
    fi
    printf "\n%-74s[ %s ]\n" "$(printf "  CPU Utilization      %s%%" "$cpu_pct")" "$cpu_status"

    # --- memory ---
    local mem_raw mem_used mem_total mem_pct mem_status
    mem_raw="$(ssh_run "$host" "free -m | awk '/Mem:/ {print \$3, \$2}'")"
    mem_used=$(echo "$mem_raw" | awk '{print $1}')
    mem_total=$(echo "$mem_raw" | awk '{print $2}')
    mem_status="OK"
    if [[ -n "$mem_used" && -n "$mem_total" && "$mem_total" -gt 0 ]]; then
        mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.0f", (u/t)*100}')
        if (( mem_pct >= MEM_CRIT_PCT )); then
            mem_status="CRITICAL"; host_had_crit=1
            ACTION_ITEMS+=("$host - memory at ${mem_pct}% used")
        elif (( mem_pct >= MEM_WARN_PCT )); then
            mem_status="WARN"; host_had_warn=1
        fi
    else
        mem_pct="?"
        mem_status="UNKNOWN"
    fi
    printf "%-74s[ %s ]\n\n" "$(printf "  Memory Usage         %sM / %sM used (%s%%)" "$mem_used" "$mem_total" "$mem_pct")" "$mem_status"

    # --- tally host-level pass/fail ---
    if [[ "$host_had_fail" -eq 1 ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
    [[ "$host_had_warn" -eq 1 ]] && WARN_COUNT=$((WARN_COUNT + 1))
    [[ "$host_had_crit" -eq 1 ]] && CRIT_COUNT=$((CRIT_COUNT + 1))
}

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
generate_report() {
    dhr
    printf "          SATELLITE INFRASTRUCTURE HEALTH CHECK REPORT\n"
    printf "                  Generated: %s\n" "$TIMESTAMP"
    dhr
    printf "\n"

    for entry in "${HOSTS[@]}"; do
        IFS='|' read -r host role <<< "$entry"
        check_host "$host" "$role"
    done

    dhr
    printf " SUMMARY\n"
    dhr
    printf "  Total Hosts Checked ......... %d\n" "$TOTAL_HOSTS"
    printf "  Passed ....................... %d\n" "$PASS_COUNT"
    printf "  Failed ....................... %d\n" "$FAIL_COUNT"
    printf "  Hosts with Warnings .......... %d\n" "$WARN_COUNT"
    printf "  Hosts with Critical Issues ... %d\n" "$CRIT_COUNT"
    dhr

    if [[ ${#ACTION_ITEMS[@]} -gt 0 ]]; then
        printf "\n  ACTION NEEDED:\n"
        for item in "${ACTION_ITEMS[@]}"; do
            printf "   - %s\n" "$item"
        done
    else
        printf "\n  No action items. All hosts healthy.\n"
    fi
    printf "\n"
}

# ---------------------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------------------
if [[ -n "$OUTFILE" ]]; then
    generate_report | tee "$OUTFILE"
else
    generate_report
fi
