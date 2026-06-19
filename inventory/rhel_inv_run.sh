#!/bin/bash
# =============================================================================
# rhel_inv_run.sh — Orchestrator for the nightly RHEL Inventory process
# =============================================================================
# Replaces: RHEL_update.sh
#
# Usage:
#   Normal run (called by cron):
#     ./rhel_inv_run.sh
#
#   Test run against a specific host list:
#     ./rhel_inv_run.sh --test /path/to/test_hosts.txt
#
#   Test run uses isolated output paths under BASE_DIR/test/ and prefixes
#   all data files with TEST_ so nothing overlaps with normal run output.
#   Test logs go to logs/test/ separately from production logs.
#
# Crontab example:
#   30 21 * * * cd /usr/local/pnc/bin/RHEL_Inventory_v2 ; \
#     log=logs/rhel_inventory_v2_run.$(date +"%Y%m%d").log ; \
#     ./rhel_inv_run.sh >> ${log} 2>&1 ; \
#     ln -sf ${log} logs/rhel_inventory_v2_latest.log
# =============================================================================

cd "$(dirname "$0")" || exit 1

# =============================================================================
# Argument parsing
# =============================================================================

TEST_MODE=0
TEST_HOSTLIST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            TEST_MODE=1
            if [[ -n "$2" && "$2" != --* ]]; then
                TEST_HOSTLIST="$2"
                shift
            fi
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--test [hostlist]]"
            echo ""
            echo "  Normal run:   $0"
            echo "  Test run:     $0 --test /path/to/hosts.txt"
            echo ""
            echo "  --test        Run in test mode with isolated output paths."
            echo "                All data files written under BASE_DIR/test/"
            echo "                prefixed with TEST_ — never touches production files."
            echo "  hostlist      Optional path to a custom host list for the test run."
            echo "                Defaults to a single localhost entry if not specified."
            exit 0
            ;;
        *)
            echo "Unknown option: $1  (use --help for usage)" >&2
            exit 1
            ;;
    esac
done

# --- Source config -----------------------------------------------------------
CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found at ${CONF}" >&2
    exit 1
fi
. "$CONF"

# =============================================================================
# Test mode path overrides
# All production variables are overridden AFTER sourcing the config so the
# config still supplies pssh settings, retention values, etc.
# =============================================================================

if [[ $TEST_MODE -eq 1 ]]; then
    TEST_DIR="${BASE_DIR}/test"
    TEST_LOGS="${TEST_DIR}/logs"
    TEST_DATA="${TEST_DIR}/data"
    TEST_WEBDIR="${TEST_DIR}/webdir"

    mkdir -p "$TEST_DIR" "$TEST_LOGS" "$TEST_DATA" "$TEST_WEBDIR"

    # Override host list
    if [[ -n "$TEST_HOSTLIST" ]]; then
        if [[ ! -f "$TEST_HOSTLIST" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   Test host list not found: $TEST_HOSTLIST" >&2
            exit 1
        fi
        MASTERHOSTLIST="$TEST_HOSTLIST"
    else
        # Default test host list — localhost only as a smoke test
        echo "localhost" > "${TEST_DIR}/test_hosts_default.txt"
        MASTERHOSTLIST="${TEST_DIR}/test_hosts_default.txt"
    fi

    # Override all output paths with TEST_ prefix
    PIDFILE="${TEST_DATA}/TEST_RHEL_INV.PID"
    INVENTORYTEMP="${TEST_DATA}/TEST_RHEL_INVENTORY.tmp"
    INVENTORYDATA="${TEST_DATA}/TEST_RHEL_INVENTORY.dat"
    INVENTDATATEXT="TEST_RHEL_INVENTORY.txt"
    INVENTDATAHTML="TEST_RHEL_INVENTORY.html"
    INVENTDATACSV="TEST_RHEL_INVENTORY.csv"
    IDINVENTORYTEMP="${TEST_DATA}/TEST_RHEL_IDINVENTORY.tmp"
    IDINVENTORYDATA="${TEST_DATA}/TEST_RHEL_IDINVENTORY.dat"
    DBINVENTORYTEMP="${TEST_DATA}/TEST_RHEL_DBINVENTORY.tmp"
    DBINVENTORYDATA="${TEST_DATA}/TEST_RHEL_DBINVENTORY.dat"
    PACKAGETEMP="${TEST_DATA}/TEST_RHEL_PACKAGES.tmp"
    PACKAGEDATA="${TEST_DATA}/TEST_RHEL_PACKAGES.csv"
    DEPLOYDATACSV="${TEST_WEBDIR}/TEST_RHEL_DEPLOYMENTS.csv"
    APPDATAPLAT="${TEST_DATA}/TEST_check_RHEL_versions_MNEMONIC_PLATFORM.dat"
    APPDATAREL="${TEST_DATA}/TEST_check_RHEL_versions_MNEMONIC_RELEASES.dat"
    LOCDATAPLAT="${TEST_DATA}/TEST_check_RHEL_versions_LOCATION_PLATFORM.dat"
    LOCDATAREL="${TEST_DATA}/TEST_check_RHEL_versions_LOCATION_RELEASES.dat"
    LOSTLIST="TEST_RHEL_nonresponsive.txt"
    ERRDIR="${TEST_DATA}/errdir_test.$(date +%Y%m%d_%H%M)"
    WEBDIR="$TEST_WEBDIR"

    # Test logs are separate from production logs
    MAIN_LOG="${TEST_LOGS}/test_rhel_inventory.log"
    RUN_LOG="${TEST_LOGS}/test_rhel_inventory_run.$(date +%Y%m%d_%H%M%S).log"
    LATEST_LOG="${TEST_LOGS}/test_rhel_inventory_latest.log"

    # DEPLOYMENTDATA intentionally NOT overridden for test runs —
    # we still read it to check for known hosts but we do NOT append to it.
    # rhel_deploy_scan.sh checks TEST_MODE via exported env var.
    export TEST_MODE
fi

# Export overridden variables so child scripts inherit them
export MASTERHOSTLIST PIDFILE WEBDIR ERRDIR MAIN_LOG
export INVENTORYTEMP INVENTORYDATA INVENTDATATEXT INVENTDATAHTML INVENTDATACSV
export IDINVENTORYTEMP IDINVENTORYDATA
export DBINVENTORYTEMP DBINVENTORYDATA
export PACKAGETEMP PACKAGEDATA DEPLOYDATACSV
export APPDATAPLAT APPDATAREL LOCDATAPLAT LOCDATAREL LOSTLIST

# =============================================================================
# Logging
# =============================================================================

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$level" in
        SECTION) printf '\n%s  === %s ===\n'   "$ts" "$msg" ;;
        INFO)    printf '%s  [INFO]    %s\n'   "$ts" "$msg" ;;
        WARN)    printf '%s  [WARN]    %s\n'   "$ts" "$msg" ;;
        ERROR)   printf '%s  [ERROR]   %s\n'   "$ts" "$msg" ;;
        *)       printf '%s  [INFO]    %s\n'   "$ts" "$msg" ;;
    esac
}

mkdir -p "$(dirname "$MAIN_LOG")" "$(dirname "$RUN_LOG")"
exec > >(tee -a "$MAIN_LOG") 2>&1

# =============================================================================
log SECTION "Starting RHEL Inventory Orchestrator"
# =============================================================================

if [[ $TEST_MODE -eq 1 ]]; then
    log INFO "*** TEST MODE ACTIVE — all output isolated under ${TEST_DIR} ***"
    log INFO "Test host list : $MASTERHOSTLIST ($(wc -l < "$MASTERHOSTLIST") hosts)"
else
    log INFO "Mode       : production"
fi

log INFO "Base dir   : $BASE_DIR"
log INFO "Host list  : $MASTERHOSTLIST"
log INFO "CMDB file  : ${CMDBDATAFILE:-NOT FOUND}"
log INFO "Web dir    : $WEBDIR"
log INFO "Main log   : $MAIN_LOG"

# =============================================================================
# Hung-process watchdog
# =============================================================================

if [[ -f "$PIDFILE" ]]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$OLD_PID" ]]; then
        log INFO "PID file found — checking for running process $OLD_PID"
        if ps --no-headers -p "$OLD_PID" > /dev/null 2>&1; then
            log WARN "Process $OLD_PID is alive — watching for progress for ${WATCHDOG_WAIT}s"
            FSTAT=$(ls -l "$INVENTORYTEMP" 2>/dev/null)
            for (( i=WATCHDOG_WAIT; i>1; i=i-1 )); do
                printf '%s  [WARN]    Watchdog: %d seconds remaining...\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "$i"
                FSTATNEW=$(ls -l "$INVENTORYTEMP" 2>/dev/null)
                if [[ "$FSTATNEW" != "$FSTAT" ]]; then
                    log WARN "Inventory temp file is still changing — prior run still active"
                    exit 1
                fi
                sleep 1
            done
            log WARN "Watchdog timeout — sending SIGKILL to PID $OLD_PID"
            kill -9 "$OLD_PID"
            sleep "$WATCHDOG_WAIT"
        else
            log INFO "PID $OLD_PID no longer running — stale PID file, continuing"
        fi
    fi
fi

echo $$ > "$PIDFILE"
trap 'log INFO "Cleaning up PID file"; rm -f "$PIDFILE"' EXIT
log INFO "PID $$ written to $PIDFILE"

# =============================================================================
log SECTION "Phase 1 — Inventory Collection"
# =============================================================================

if [[ ! -x "${BASE_DIR}/rhel_inv_collect.sh" ]]; then
    log ERROR "rhel_inv_collect.sh not found or not executable in ${BASE_DIR}"
    exit 1
fi

"${BASE_DIR}/rhel_inv_collect.sh"
COLLECT_RC=$?

if [[ $COLLECT_RC -ne 0 ]]; then
    log ERROR "rhel_inv_collect.sh exited with status $COLLECT_RC"
    exit $COLLECT_RC
fi
log INFO "Collection phase completed successfully"

# =============================================================================
log SECTION "Phase 2 — Report Generation"
# =============================================================================

if [[ ! -x "${BASE_DIR}/rhel_inv_report.sh" ]]; then
    log WARN "rhel_inv_report.sh not found — skipping reports"
else
    "${BASE_DIR}/rhel_inv_report.sh"
    REPORT_RC=$?
    if [[ $REPORT_RC -ne 0 ]]; then
        log WARN "rhel_inv_report.sh exited with status $REPORT_RC"
    else
        log INFO "Report generation completed successfully"
    fi
fi

# =============================================================================
log SECTION "Phase 3 — Supplemental Reports"
# =============================================================================

if [[ $TEST_MODE -eq 0 ]]; then
    # Supplemental scripts only run in production — they are separately
    # maintained and not part of this rewrite
    if [[ -x "${DATA_DIR}/MRGeng/Midrange_Mod_Report/Midrange_Mod_Report.sh" ]]; then
        log INFO "Generating Midrange Mod Report"
        "${DATA_DIR}/MRGeng/Midrange_Mod_Report/Midrange_Mod_Report.sh"
    fi
    if [[ -x "${DATA_DIR}/MRGeng/RHEL8-9_Upgrade_Eligiblity/RHEL8-9_Upgrade_Checker.sh" ]]; then
        log INFO "Generating RHEL 8-to-9 Upgrade Eligibility Report"
        "${DATA_DIR}/MRGeng/RHEL8-9_Upgrade_Eligiblity/RHEL8-9_Upgrade_Checker.sh"
    fi
else
    log INFO "TEST MODE — supplemental reports skipped"
fi

# =============================================================================
log SECTION "RHEL Inventory Orchestrator complete"
# =============================================================================

if [[ $TEST_MODE -eq 1 ]]; then
    log INFO "Test output written to: $TEST_DIR"
    log INFO "Review results before promoting to production"
fi

ln -sf "$RUN_LOG" "$LATEST_LOG" 2>/dev/null

exit 0
