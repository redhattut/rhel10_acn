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
# Web assets:
#   style.css and app.js are static files that live alongside these scripts
#   in BASE_DIR.  They are copied to WEBDIR (or TEST_WEBDIR) at the start
#   of every run so the web directory always has the current versions.
#   config.js is generated fresh each run by rhel_inv_report.sh from live
#   inventory data — it is NOT a static asset and must not be pre-staged.
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
log SECTION "Phase 0 — Web asset staging"
# =============================================================================
# style.css and app.js are both embedded directly in this script and written
# to WEBDIR on every run — no files need to exist on disk, works identically
# for test and production runs.
# config.js is NOT staged here — generated fresh by rhel_inv_report.sh.
# =============================================================================

mkdir -p "$WEBDIR"

# --- Write style.css from embedded content -----------------------------------
log INFO "Writing style.css → ${WEBDIR}/style.css"
cat > "${WEBDIR}/style.css" << 'STYLE_EOF'
/* =============================================================================
   RHEL Fleet Dashboard — style.css
   Light, friendly, presentable. Self-contained: no external fonts/CDN/JS libs.
   Linked by every page:  <link rel="stylesheet" href="style.css">
   ============================================================================= */

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

:root {
  /* surfaces */
  --bg:        #f3f6fc;
  --bg-soft:   #fbfcff;
  --card:      #ffffff;
  --line:      #e7edf6;
  --line-soft: #eef2f9;

  /* text */
  --ink:    #1d2840;   /* headings */
  --text:   #46546e;   /* body */
  --muted:  #8693ab;   /* secondary */
  --faint:  #aab5c8;

  /* brand + status */
  --blue:   #3b6ef0;
  --indigo: #5b6ef5;
  --violet: #8b5cf6;
  --teal:   #14b3a6;
  --green:  #21b573;
  --amber:  #f5a623;
  --red:    #ec4055;

  /* RHEL major-version scale (consistent everywhere) */
  --v7: #f5a623;   /* amber — aging */
  --v8: #14b3a6;   /* teal  — the stable bulk */
  --v9: #3b6ef0;   /* blue  — newest */

  --radius:    16px;
  --radius-md: 12px;
  --radius-sm: 9px;

  --shadow:    0 1px 2px rgba(17,28,53,.04), 0 6px 20px rgba(17,28,53,.06);
  --shadow-sm: 0 1px 2px rgba(17,28,53,.05), 0 2px 8px rgba(17,28,53,.05);

  --sans: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue",
          Arial, "Noto Sans", sans-serif;
}

body {
  font-family: var(--sans);
  font-size: 14px;
  line-height: 1.55;
  color: var(--text);
  background: var(--bg);
  -webkit-font-smoothing: antialiased;
}
a { color: inherit; }

/* =============================================================================
   Layout
   ============================================================================= */
.page { max-width: 1280px; margin: 0 auto; padding: 2rem 1.75rem 3rem; }
.page-head { margin-bottom: 1.6rem; }
.page-head h1 { font-size: 1.7rem; font-weight: 750; color: var(--ink); letter-spacing: -.02em; }
.page-head p { color: var(--muted); font-size: .92rem; margin-top: .3rem; }

/* generic card */
.card {
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  padding: 1.4rem 1.5rem;
}
.card-head { display: flex; align-items: center; gap: .7rem; margin-bottom: 1.15rem; }
.card-head .chip {
  width: 34px; height: 34px; border-radius: 10px;
  display: grid; place-items: center; flex: 0 0 auto;
}
.card-head .chip svg { width: 18px; height: 18px; }
.card-head h2 { font-size: 1.02rem; font-weight: 700; color: var(--ink); }
.card-head .sub { font-size: .78rem; color: var(--muted); margin-left: auto; }

.chip-blue   { background: #e9f0fe; color: var(--blue); }
.chip-teal   { background: #e3f7f4; color: var(--teal); }
.chip-violet { background: #f1ecfe; color: var(--violet); }
.chip-amber  { background: #fdf2dd; color: #c9821a; }
.chip-green  { background: #e4f7ee; color: var(--green); }

/* =============================================================================
   KPI tiles
   ============================================================================= */
.kpis {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 1rem;
  margin-bottom: 1.4rem;
}
.kpi {
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  box-shadow: var(--shadow-sm);
  padding: 1.2rem 1.3rem;
  display: flex; align-items: center; gap: 1rem;
}
.kpi .ic {
  width: 46px; height: 46px; border-radius: 13px;
  display: grid; place-items: center; flex: 0 0 auto;
}
.kpi .ic svg { width: 23px; height: 23px; }
.kpi .meta { min-width: 0; display: flex; flex-direction: column; }
.kpi .num { display: block; font-size: 1.7rem; font-weight: 750; color: var(--ink); line-height: 1.05; letter-spacing: -.02em; }
.kpi .lab { display: block; font-size: .8rem; color: var(--muted); margin-top: .15rem; }
.kpi.alert .num { color: var(--red); }

.ic-blue   { background: #e9f0fe; color: var(--blue); }
.ic-violet { background: #f1ecfe; color: var(--violet); }
.ic-teal   { background: #e3f7f4; color: var(--teal); }
.ic-red    { background: #fdebee; color: var(--red); }

/* =============================================================================
   Grid helpers
   ============================================================================= */
.row { display: grid; gap: 1.4rem; margin-bottom: 1.4rem; align-items: start; }
.row.split { grid-template-columns: 420px 1fr; }
.row.halves { grid-template-columns: 1fr 1fr; }

/* =============================================================================
   Donut (fleet composition) — pure CSS conic-gradient
   ============================================================================= */
.donut-wrap { display: flex; align-items: center; gap: 1.6rem; }
.donut {
  --d: 156px;
  width: var(--d); height: var(--d); border-radius: 50%;
  flex: 0 0 auto; position: relative;
  background: conic-gradient(
    var(--v7) 0 1.92%,
    var(--v8) 1.92% 85.76%,
    var(--v9) 85.76% 100%
  );
}
.donut::after {
  content: ""; position: absolute; inset: 26px;
  background: var(--card); border-radius: 50%;
  box-shadow: inset 0 1px 4px rgba(17,28,53,.06);
}
.donut-center {
  position: absolute; inset: 0; display: grid; place-content: center; text-align: center;
}
.donut-center .big { font-size: 1.4rem; font-weight: 750; color: var(--ink); line-height: 1; letter-spacing: -.02em; }
.donut-center .cap { font-size: .68rem; color: var(--muted); margin-top: .25rem; }

.donut-legend { display: flex; flex-direction: column; gap: .8rem; flex: 1 1 auto; min-width: 0; }
.dl-item { display: flex; align-items: center; gap: .6rem; white-space: nowrap; }
.dl-item .sw { width: 12px; height: 12px; border-radius: 4px; flex: 0 0 auto; }
.dl-item .name { font-weight: 600; color: var(--ink); font-size: .9rem; }
.dl-item .val { color: var(--muted); font-size: .82rem; margin-left: auto; font-variant-numeric: tabular-nums; }
.dl-item .pct {
  font-size: .74rem; font-weight: 700; color: var(--text);
  background: var(--bg); border-radius: 999px; padding: .15rem .55rem;
}

/* =============================================================================
   Bar rows (OS / environment / location)
   ============================================================================= */
.bars { display: flex; flex-direction: column; gap: .9rem; min-height: 180px; }
.bar {
  display: grid;
  grid-template-columns: 84px 1fr 56px;
  align-items: center; gap: .9rem;
}
.bar .name { font-size: .86rem; font-weight: 600; color: var(--ink); }
.bar .track {
  height: 10px; border-radius: 999px; background: #eef2f8; overflow: hidden;
}
.bar .fill { display: block; height: 100%; border-radius: 999px; min-width: 6px; }
.bar .val { text-align: right; font-size: .86rem; font-weight: 700; color: var(--text); }
.bar .val.zero { color: var(--faint); font-weight: 500; }

.fill.v7  { background: linear-gradient(90deg, #f7b94a, var(--v7)); }
.fill.v8  { background: linear-gradient(90deg, #3fc8bb, var(--v8)); }
.fill.v9  { background: linear-gradient(90deg, #6f93f6, var(--v9)); }
.fill.env { background: linear-gradient(90deg, #8b9bf8, var(--indigo)); }
.fill.loc { background: linear-gradient(90deg, #41d0c2, var(--teal)); }
.fill.flat-zero { background: transparent; }

/* =============================================================================
   Resources (friendly link tiles)
   ============================================================================= */
.res-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: 1.4rem;
}
.res-col h3 { font-size: .82rem; font-weight: 700; color: var(--ink); margin-bottom: .65rem; }
.res-col h4 { font-size: .72rem; font-weight: 600; color: var(--muted); margin: .85rem 0 .45rem; text-transform: uppercase; letter-spacing: .04em; }
.res-list { list-style: none; display: flex; flex-direction: column; gap: .3rem; }
.res-list a {
  display: flex; align-items: center; gap: .55rem;
  padding: .5rem .65rem; border-radius: var(--radius-sm);
  font-size: .85rem; color: var(--text); text-decoration: none;
  border: 1px solid transparent;
  transition: background .12s ease, border-color .12s ease, color .12s ease;
}
.res-list a .ar { margin-left: auto; color: var(--faint); transition: transform .12s ease, color .12s; }
.res-list a:hover { background: #f4f8ff; border-color: #e2ebfd; color: var(--blue); }
.res-list a:hover .ar { color: var(--blue); transform: translateX(2px); }
.res-list a .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--teal); flex: 0 0 auto; }

/* =============================================================================
   Deployments — bar chart + month cards
   ============================================================================= */
.chart {
  display: grid; grid-template-columns: repeat(3, 1fr);
  gap: 1.5rem; align-items: end;
  height: 220px; padding: 0 1rem 0;
}
.col { display: flex; flex-direction: column; align-items: center; gap: .7rem; height: 100%; justify-content: flex-end; }
.col .colbar-wrap { width: 100%; max-width: 110px; flex: 1 1 auto; display: flex; align-items: flex-end; }
.col .colbar {
  width: 100%; border-radius: 12px 12px 4px 4px;
  background: linear-gradient(180deg, var(--blue), #6f93f6);
  position: relative; min-height: 10px;
  box-shadow: 0 6px 14px rgba(59,110,240,.22);
}
.col.peak .colbar { background: linear-gradient(180deg, var(--teal), #3fc8bb); box-shadow: 0 6px 14px rgba(20,179,166,.25); }
.col .colval { position: absolute; top: -1.7rem; left: 0; right: 0; text-align: center; font-weight: 750; color: var(--ink); font-size: 1.05rem; }
.col .collabel { font-size: .82rem; color: var(--muted); font-weight: 500; }

.months { display: flex; flex-direction: column; gap: 1.4rem; }
.month-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 1.2rem; }
.month-head h2 { font-size: 1.15rem; font-weight: 750; color: var(--ink); }
.month-head .total {
  display: inline-flex; align-items: baseline; gap: .4rem;
  background: #eaf0fe; color: var(--blue);
  font-weight: 600; font-size: .82rem;
  padding: .4rem .85rem; border-radius: 999px;
}
.month-head .total b { font-size: 1rem; font-weight: 750; }
.month-grid { display: grid; grid-template-columns: 1fr 1.3fr; gap: 2rem; }
.month-grid h3 { font-size: .76rem; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; margin-bottom: .85rem; }
.dlist { display: flex; flex-direction: column; gap: .85rem; }
.drow-top { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: .35rem; }
.drow-top .nm { font-size: .88rem; font-weight: 600; color: var(--ink); }
.drow-top .ct { font-size: .88rem; font-weight: 700; color: var(--text); }
.drow .track { height: 8px; border-radius: 999px; background: #eef2f8; overflow: hidden; }
.drow .track span { display: block; height: 100%; border-radius: 999px; }

/* =============================================================================
   Inventory table
   ============================================================================= */
.statline { display: flex; flex-wrap: wrap; gap: .7rem; margin-bottom: 1.2rem; }
.chip-stat {
  display: inline-flex; align-items: baseline; gap: .5rem;
  background: var(--card); border: 1px solid var(--line);
  box-shadow: var(--shadow-sm);
  border-radius: 999px; padding: .5rem 1rem; font-size: .82rem; color: var(--muted);
}
.chip-stat b { font-size: 1rem; font-weight: 750; color: var(--ink); }
.chip-stat.warn b { color: var(--red); }

.controls { display: flex; flex-wrap: wrap; gap: .6rem; align-items: center; margin-bottom: 1.1rem; }
.controls input, .controls select {
  padding: .6rem .85rem; font-size: .85rem; font-family: inherit;
  color: var(--ink); background: var(--card);
  border: 1px solid var(--line); border-radius: var(--radius-sm);
  outline: none; box-shadow: var(--shadow-sm);
  transition: border-color .12s ease, box-shadow .12s ease;
}
.controls input::placeholder { color: var(--faint); }
.controls input:focus, .controls select:focus {
  border-color: var(--blue); box-shadow: 0 0 0 3px rgba(59,110,240,.15);
}
.count-badge { margin-left: auto; font-size: .82rem; color: var(--muted); }
.count-badge b { color: var(--ink); }

.tbl-card {
  background: var(--card); border: 1px solid var(--line);
  border-radius: var(--radius); box-shadow: var(--shadow); overflow: hidden;
}
.tbl-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: .84rem; }

thead th {
  position: sticky; top: 0; z-index: 2;
  text-align: left; padding: .8rem .9rem;
  font-size: .72rem; font-weight: 600; color: var(--muted);
  text-transform: uppercase; letter-spacing: .03em;
  white-space: nowrap; background: #f6f9fe;
  border-bottom: 1px solid var(--line);
}
thead th:first-child { position: sticky; left: 0; z-index: 3; }

tbody td {
  padding: .7rem .9rem; white-space: nowrap; color: var(--text);
  border-bottom: 1px solid var(--line-soft); vertical-align: middle;
}
tbody td:first-child {
  position: sticky; left: 0; z-index: 1; background: var(--card);
  font-weight: 650; color: var(--ink);
}
tbody tr:hover td { background: #f6f9ff; }
tbody tr:hover td:first-child { background: #f6f9ff; }
tbody tr:last-child td { border-bottom: none; }
.sub { color: var(--muted); font-size: .78rem; }

/* OS badge */
.osb { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: .74rem; font-weight: 700; }
.osb.v7 { background: #fdf2dd; color: #b3781a; }
.osb.v8 { background: #e1f6f3; color: #0f8f85; }
.osb.v9 { background: #e9f0fe; color: #2f5bd0; }

/* pills */
.pill { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: .72rem; font-weight: 600; }
.pill-virt   { background: #e9f0fe; color: #2f5bd0; }
.pill-phys   { background: #f1ecfe; color: #6d44c9; }
.pill-prod   { background: #e4f7ee; color: #1a8f5a; }
.pill-uat,
.pill-qa     { background: #fdf2dd; color: #b3781a; }
.pill-rnd    { background: #eef1f7; color: #66748c; }
.pill-fed    { background: #fdebee; color: #cf3247; }
.pill-nonfed { background: #eef1f7; color: #66748c; }

/* status */
.st { display: inline-flex; align-items: center; gap: .4rem; padding: 3px 10px 3px 8px; border-radius: 999px; font-size: .74rem; font-weight: 600; }
.st::before { content: ""; width: 7px; height: 7px; border-radius: 50%; }
.st-ok   { background: #e4f7ee; color: #1a8f5a; }
.st-ok::before { background: var(--green); }
.st-fail { background: #fdebee; color: #cf3247; }
.st-fail::before { background: var(--red); }
.st-unk  { background: #eef1f7; color: #66748c; }
.st-unk::before { background: var(--faint); }

/* =============================================================================
   Footer
   ============================================================================= */
.foot {
  max-width: 1280px; margin: 0 auto; padding: 1.5rem 1.75rem 2.5rem;
  display: flex; justify-content: space-between; flex-wrap: wrap; gap: .5rem;
  font-size: .8rem; color: var(--muted);
}
.foot a { color: var(--blue); text-decoration: none; }
.foot a:hover { text-decoration: underline; }

/* =============================================================================
   Left-sidebar application shell
   ============================================================================= */
body { min-height: 100vh; }
.app-shell { min-height: 100vh; display: flex; }
.sidebar { position: fixed; inset: 0 auto 0 0; width: 272px; background: var(--card); border-right: 1px solid var(--line); display: flex; flex-direction: column; padding: 1.15rem 1rem; z-index: 30; }
.side-brand { display:flex; align-items:center; gap:.75rem; padding:.2rem .45rem 1.25rem; border-bottom:1px solid var(--line); }
.side-brand .brand-mark { width:42px; height:42px; border-radius:11px; background:linear-gradient(135deg,var(--blue),var(--violet)); display:grid; place-items:center; flex:0 0 auto; box-shadow:0 4px 12px rgba(91,110,245,.35); }
.side-brand .brand-mark svg { width:21px; height:21px; display:block; }
.side-brand .brand-text { line-height:1.15; }
.side-brand .brand-text b { display:block; font-size:1rem; font-weight:700; color:var(--ink); }
.side-brand .brand-text span { font-size:.74rem; color:var(--muted); }
.side-nav { padding-top:1rem; overflow-y:auto; }
.nav-group { margin-bottom:1.25rem; }
.nav-label { padding:.25rem .65rem .45rem; font-size:.68rem; font-weight:750; color:var(--muted); text-transform:uppercase; letter-spacing:.08em; }
.side-link { display:flex; align-items:center; gap:.7rem; width:100%; padding:.65rem .72rem; margin:.13rem 0; border-radius:10px; color:var(--text); text-decoration:none; font-size:.84rem; font-weight:550; transition:.14s ease; }
.side-link svg { width:17px; height:17px; flex:0 0 auto; }
.side-link .nav-icon { width:17px; text-align:center; color:var(--muted); }
.side-link:hover { background:#f1f5fd; color:var(--ink); }
.side-link.active { background:#eaf0fe; color:var(--blue); font-weight:700; }
.side-link.external { font-size:.8rem; }
.side-bottom { margin-top:auto; padding-top:1rem; border-top:1px solid var(--line); }
.side-status { margin:.8rem .65rem 0; display:flex; align-items:center; gap:.45rem; font-size:.7rem; color:var(--muted); }
.side-status .dot { width:7px; height:7px; border-radius:50%; background:var(--green); box-shadow:0 0 0 3px rgba(33,181,115,.14); }
.content-shell { width:calc(100% - 272px); margin-left:272px; min-width:0; }
.page { max-width:1440px; }
.foot { max-width:1440px; }

.notice-card { display:flex; align-items:center; justify-content:space-between; gap:1rem; }
.notice-card h2 { color:var(--ink); font-size:1rem; }
.notice-card p { color:var(--muted); margin-top:.25rem; }
.notice-actions, .inventory-actions { display:flex; align-items:center; gap:.65rem; }
.button { display:inline-flex; align-items:center; justify-content:center; padding:.62rem .9rem; border:1px solid var(--line); border-radius:9px; background:var(--card); color:var(--text); text-decoration:none; font-size:.82rem; font-weight:650; white-space:nowrap; box-shadow:var(--shadow-sm); }
.button:hover { border-color:#cdd9f5; color:var(--blue); background:#f7f9ff; }
.button.primary { background:var(--blue); color:white; border-color:var(--blue); }
.button.compact { padding:.52rem .78rem; }
.inventory-actions { margin-left:auto; }
.inventory-actions .count-badge { margin-left:0; }

.history-note { background:var(--bg); border:1px solid var(--line); border-radius:10px; padding:.75rem .9rem; margin-bottom:1rem; color:var(--muted); font-size:.82rem; }
.history-wrap { overflow-x:auto; }
.history-table { min-width:760px; }
.history-table .filename { color:var(--ink); font-weight:650; font-family:ui-monospace,SFMono-Regular,Consolas,monospace; font-size:.8rem; }
.latest-tag { display:inline-block; padding:3px 9px; border-radius:999px; background:#e4f7ee; color:#1a8f5a; font-size:.7rem; font-weight:700; }
.download-link { color:var(--blue); font-weight:650; text-decoration:none; }
.download-link:hover { text-decoration:underline; }

/* =============================================================================
   Responsive
   ============================================================================= */
@media (max-width: 920px) {
  .row.split, .row.halves { grid-template-columns: 1fr; }
  .month-grid { grid-template-columns: 1fr; gap: 1.3rem; }
}
@media (max-width: 840px) {
  .sidebar { position:static; width:100%; min-height:auto; }
  .app-shell { display:block; }
  .content-shell { width:100%; margin-left:0; }
  .side-nav { display:grid; grid-template-columns:1fr 1fr; gap:.5rem; }
  .side-bottom { margin-top:0; }
  .notice-card { align-items:flex-start; flex-direction:column; }
}
@media (max-width: 680px) {
  .page { padding: 1.4rem 1.1rem 2.5rem; }
  .donut-wrap { flex-direction: column; align-items: flex-start; }
}
@media (max-width: 560px) {
  .side-nav { grid-template-columns:1fr; }
  .inventory-actions { width:100%; margin-left:0; justify-content:space-between; }
}

/* =============================================================================
   Accessibility
   ============================================================================= */
a:focus-visible, input:focus-visible, select:focus-visible {
  outline: 2px solid var(--blue); outline-offset: 2px; border-radius: 6px;
}
@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
STYLE_EOF

if [[ $? -eq 0 ]]; then
    log INFO "style.css written ($(wc -c < "${WEBDIR}/style.css") bytes)"
else
    log ERROR "Failed to write style.css to ${WEBDIR}"
fi

# --- Write app.js from embedded content --------------------------------------
log INFO "Writing app.js → ${WEBDIR}/app.js"
cat > "${WEBDIR}/app.js" << 'APPJS_EOF'
(function () {
  const cfg = window.RHEL_CONFIG;
  if (!cfg) return;

  const fmt = n => Number(n || 0).toLocaleString('en-US');
  const pct = (value, total) => total > 0 ? Math.min(100, Math.max(0, value / total * 100)) : 0;

  document.querySelectorAll('[data-site-title]').forEach(el => el.textContent = cfg.site.title);
  document.querySelectorAll('[data-site-subtitle]').forEach(el => el.textContent = cfg.site.subtitle);
  document.querySelectorAll('[data-site-org]').forEach(el => el.textContent = cfg.site.organization);
  document.querySelectorAll('[data-site-updated]').forEach(el => el.textContent = `Updated ${cfg.site.updated}`);

  const external = document.querySelector('[data-external-links]');
  if (external) {
    external.innerHTML = cfg.externalLinks.map(item => `
      <a class="side-link external" href="${item.href}" target="_blank" rel="noopener">
        <span class="nav-icon">↗</span><span>${item.label}</span>
      </a>`).join('');
  }

  const set = (selector, value) => {
    const el = document.querySelector(selector);
    if (el) el.textContent = value;
  };
  set('[data-kpi="virtual"]', fmt(cfg.totals.virtual));
  set('[data-kpi="physical"]', fmt(cfg.totals.physical));
  set('[data-kpi="cloud"]', fmt(cfg.totals.cloud));
  set('[data-kpi="ssh"]', fmt(cfg.totals.sshFailures));

  const majorTotals = cfg.rhelVersions.reduce((acc, item) => {
    acc[item.major] = (acc[item.major] || 0) + item.count;
    return acc;
  }, {});
  const classifiedTotal = Object.values(majorTotals).reduce((a,b) => a+b, 0);

  const donut = document.querySelector('[data-rhel-donut]');
  if (donut) {
    const p8 = pct(majorTotals[8] || 0, classifiedTotal);
    donut.style.background = `conic-gradient(var(--v8) 0 ${p8}%, var(--v9) ${p8}% 100%)`;
    set('[data-classified-total]', fmt(classifiedTotal));
    const legend = document.querySelector('[data-rhel-major-legend]');
    if (legend) legend.innerHTML = [8,9].map(major => `
      <div class="dl-item"><span class="sw" style="background:var(--v${major})"></span>
        <span class="name">RHEL ${major}.x</span>
        <span class="pct">${pct(majorTotals[major] || 0, classifiedTotal).toFixed(1)}%</span>
        <span class="val">${fmt(majorTotals[major] || 0)}</span>
      </div>`).join('');
  }

  function renderBars(selector, rows, total, colorClass, labelPrefix='') {
    const target = document.querySelector(selector);
    if (!target) return;
    target.innerHTML = rows.map(item => `
      <div class="bar">
        <span class="name">${labelPrefix}${item.version || item.name}</span>
        <span class="track"><span class="fill ${item.major ? 'v'+item.major : colorClass}" style="width:${pct(item.count,total).toFixed(2)}%"></span></span>
        <span class="val${item.count === 0 ? ' zero' : ''}">${fmt(item.count)}</span>
      </div>`).join('');
  }

  renderBars('[data-minor-versions]', cfg.rhelVersions, classifiedTotal, '', 'RHEL ');
  renderBars('[data-environments]', cfg.environments, cfg.totals.totalHosts, 'env');
  renderBars('[data-locations]', cfg.locations, cfg.totals.totalHosts, 'loc');

  document.querySelectorAll('[data-latest-inventory]').forEach(a => a.href = cfg.downloads.latestInventoryCsv);
  const history = document.querySelector('[data-history-rows]');
  if (history) {
    history.innerHTML = cfg.historicalFiles.map((f, i) => `
      <tr><td>${i === 0 ? '<span class="latest-tag">Latest</span>' : ''}</td><td class="filename">${f.filename}</td><td>${f.timestamp}</td><td>${f.size}</td><td><a class="download-link" href="${f.href}" download>Download CSV</a></td></tr>`).join('');
  }

  // NOTE: Host inventory search, filter, sort, and pagination are handled
  // entirely by the inline script in the generated inventory HTML page.
  // app.js does not define window.ft — doing so would override the data-driven
  // implementation in rhel_convert_html.sh that works against RHEL_INV_DATA.

})();
APPJS_EOF

if [[ $? -eq 0 ]]; then
    log INFO "app.js written ($(wc -c < "${WEBDIR}/app.js") bytes)"
else
    log ERROR "Failed to write app.js to ${WEBDIR}"
fi

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
    log INFO "Web assets staged to:   $WEBDIR"
    log INFO "Review results before promoting to production"
fi

ln -sf "$RUN_LOG" "$LATEST_LOG" 2>/dev/null

# =============================================================================
log SECTION "End-of-run Checklist"
# =============================================================================

if [[ -x "${BASE_DIR}/run_checklist.sh" ]]; then
    if [[ $TEST_MODE -eq 1 ]]; then
        "${BASE_DIR}/run_checklist.sh" test
    else
        "${BASE_DIR}/run_checklist.sh" production
    fi
else
    log WARN "run_checklist.sh not found — skipping validation checklist"
fi

exit 0
