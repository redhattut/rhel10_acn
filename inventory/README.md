# RHEL Inventory v2

Nightly Linux host inventory collection and reporting system for PNC OS Engineering.
Collects system, package, user/group, and Oracle DB data from 22,000+ RHEL hosts
via parallel SSH, enriches results with CMDB data, and publishes CSV and HTML reports.

---

## Table of Contents

- [Directory Layout](#directory-layout)
- [Script Reference](#script-reference)
- [What Changed vs Legacy](#what-changed-vs-legacy)
- [Configuration](#configuration)
- [Running the Scripts](#running-the-scripts)
- [Test Mode](#test-mode)
- [Crontab Setup](#crontab-setup)
- [Parallel Operation with Legacy](#parallel-operation-with-legacy)
- [Cutover Checklist](#cutover-checklist)
- [Log Reference](#log-reference)
- [Output Files Reference](#output-files-reference)
- [Troubleshooting](#troubleshooting)

---

## Directory Layout

```
/usr/local/pnc/bin/RHEL_Inventory_v2/
│
├── rhel_inv.conf               # Central config — all tunable paths and settings
├── rhel_inv_run.sh             # Orchestrator — entry point for cron and manual runs
├── rhel_inv_collect.sh         # Main collection pipeline
├── rhel_remote_scan.sh         # Remote script — runs on each host via pssh
├── rhel_filter_scan.sh         # Jumpbox-side output filter and stream splitter
├── rhel_deploy_scan.sh         # New host detection and deployment record creation
├── rhel_inv_report.sh          # HTML report generator
├── rhel_pkginventory.sh        # Package inventory — runs from secondary jumpbox
├── rhel_filter_pkgs.sh         # Package-only output filter (used by above)
├── rhel_inv_consolidate.sh     # Midrange inventory consolidation
├── README.md                   # This file
│
├── data/                       # All runtime data files (auto-created)
│   ├── RHEL_INVENTORY_v2.dat   # Current inventory (space-delimited, authoritative)
│   ├── RHEL_INVENTORY_v2.csv   # Enriched CSV with CMDB columns
│   ├── RHEL_PACKAGES_v2.csv    # RPM package inventory
│   ├── RHEL_IDINVENTORY_v2.dat # User/group/netgroup data
│   ├── RHEL_DBINVENTORY_v2.dat # Oracle SID data
│   ├── RHEL_DEPLOYMENTS.dat    # Shared with legacy — append-only, never rewritten
│   ├── errdir.YYYYMMDD_HHMM/   # Per-run pssh error output (pruned after 7 days)
│   └── *.tmp                   # In-progress write targets (promoted atomically)
│
├── logs/                       # All log files (auto-created)
│   ├── rhel_inventory_v2.log           # Append-only master log (permanent history)
│   ├── rhel_inventory_v2_run.YYYYMMDD.log  # Per-run log (cron captures this)
│   ├── rhel_inventory_v2_latest.log    # Symlink to most recent run log
│   └── test/                           # Test run logs (isolated)
│
└── test/                       # Test mode output (auto-created on --test runs)
    ├── data/                   # TEST_ prefixed data files
    ├── logs/                   # Test run logs
    └── webdir/                 # Test web output
```

---

## Script Reference

### `rhel_inv.conf`
Central configuration file sourced by every script. Contains all tunable values:
pssh settings, file paths, retention counts, log paths. Edit once here — all
scripts pick up the change automatically.

### `rhel_inv_run.sh`
Entry point. Handles the hung-process watchdog, PID file management, and calls
the collection and report phases in order. Supports `--test` mode for isolated
test runs. This is what cron calls.

### `rhel_inv_collect.sh`
The main pipeline. Calls the deployment scan, launches the pssh sweep, splits
output into data files, rotates prior copies, enriches with CMDB data, and
publishes to the web directory.

### `rhel_remote_scan.sh`
Runs remotely on each host via `cat script | pssh -I ... bash`. Collects all
four data streams in a single SSH session and emits tagged output lines:
- `INV|` — system inventory record (OS, CPU, memory, hardware, IP, etc.)
- `ID|`  — users, groups, netgroups, AD groups from passwd/group/login-access.conf
- `DB|`  — Oracle SIDs from running ora_pmon_ processes
- `PKG|` — one line per installed RPM from `rpm -qa`

### `rhel_filter_scan.sh`
Reads the pssh stdout stream and routes lines to four separate output files
based on tag prefix. Strips pssh status noise (SUCCESS, FAILURE, numbering
lines). Logs FAILURE lines to a dated error file. Prints a summary count line
on completion.

### `rhel_deploy_scan.sh`
Checks every host in the master list against `RHEL_DEPLOYMENTS.dat`. For hosts
not yet seen, SSHes in individually to determine build date (using a priority
chain of methods) and appends a permanent record. In test mode, reads the
deployment file for lookups but does **not** append new records.

### `rhel_inv_report.sh`
Generates all HTML reports and the non-responsive host list from
`RHEL_INVENTORY.dat`. Produces identical file names and content to the legacy
`RHEL_versions_RPT.sh` so existing bookmarks continue to work.

### `rhel_pkginventory.sh`
Standalone package inventory runner for the secondary jumpbox. Reuses
`rhel_remote_scan.sh` and discards non-PKG output via `rhel_filter_pkgs.sh`.
Run this independently on its own cron schedule.

### `rhel_filter_pkgs.sh`
Package-only filter used by `rhel_pkginventory.sh`. Passes only `PKG|` lines
through to stdout. Sends its summary line to stderr so it appears in the
calling script's log without polluting the CSV data stream.

### `rhel_inv_consolidate.sh`
Reads `RHEL_INVENTORY.dat` and produces `Midrange_INVENTORY.csv` in the web
directory with the column layout expected by the midrange team.

---

## What Changed vs Legacy

### Architecture

| Area | Legacy | v2 |
|---|---|---|
| SSH hops per host | 3 separate pssh sweeps | 1 SSH connection per host |
| Remote scripts | 4 separate scripts | 1 unified `rhel_remote_scan.sh` |
| Filter scripts | 4 separate filter scripts | 1 `rhel_filter_scan.sh` + 1 `rhel_filter_pkgs.sh` |
| Config | Variables scattered across scripts | Single `rhel_inv.conf` |
| Logging | `echo "\`date\`: message"` inline | `log()` function with INFO/WARN/ERROR/SECTION levels |
| CSV write window | ~5 min incomplete file visible on web | Atomic — `.new` promoted in one copy operation |
| CMDB match stats | None | Logs matched vs missing count every run |
| Scan output counts | None | Logs line counts for all four data streams |
| Test mode | None | `--test [hostlist]` flag with fully isolated paths |
| Parallel with legacy | Not possible (same file names) | Yes — different directory and `_v2` file names |

### Files Replaced

| Legacy script | v2 replacement |
|---|---|
| `RHEL_update.sh` | `rhel_inv_run.sh` |
| `RHEL_inventory_refresh.sh` | `rhel_inv_collect.sh` |
| `RHEL_inventory_scan_script.sh` | `rhel_remote_scan.sh` (unified) |
| `RHEL_IDinventory_script.sh` | `rhel_remote_scan.sh` (unified) |
| `RHEL_DBinventory_script.sh` | `rhel_remote_scan.sh` (unified) |
| `RHEL_pkginventory_script.sh` | `rhel_remote_scan.sh` (unified) |
| `filter_inventory_scan.sh` | `rhel_filter_scan.sh` (unified) |
| `filter_IDinventory_scan.sh` | `rhel_filter_scan.sh` (unified) |
| `filter_DBinventory_scan.sh` | `rhel_filter_scan.sh` (unified) |
| `filter_pkginventory_scan.sh` | `rhel_filter_pkgs.sh` |
| `RHEL_deployment_scan.sh` | `rhel_deploy_scan.sh` |
| `RHEL_versions_RPT.sh` | `rhel_inv_report.sh` |
| `RHEL_pkginventory_refresh.sh` | `rhel_pkginventory.sh` |
| `Inventory_Consolidation.sh` | `rhel_inv_consolidate.sh` |

### What was intentionally kept the same

- All HTML report file names (`index.html`, `Location.html`, `Application.html`,
  `Releases.html`, `Monthly_Redhat_Linux_Depoloyment_Report.html`, etc.)
- HTML report content and structure (modernization is a separate later phase)
- `RHEL_DEPLOYMENTS.dat` format and append-only behavior
- CMDB enrichment column order in the CSV
- `RHEL_INVENTORY.dat` field order and space-delimited format
- pssh binary, batch size (75), and timeout (30s) settings
- `rotate.sh` and `keep_history.sh` helper scripts (unchanged, still used)

---

## Configuration

All settings live in `rhel_inv.conf`. The most commonly changed values:

```bash
# Switch to production paths after cutover (remove _v2 suffixes)
BASE_DIR="/usr/local/pnc/bin/RHEL_Inventory_v2"
WEBDIR="/usr/local/midweb/RHEL_v2"

# Tune pssh parallelism if needed
PSSH_BATCH=75        # hosts in parallel
PSSH_TIMEOUT=30      # seconds per host

# Override host list for a specific run (also settable via environment)
MASTERHOSTLIST="/usr/local/bin/hosts.linux.ssh.txt"

# CMDB file — auto-selects newest daily drop from xaascpau
CMDBDATAFILE="$(ls /home/xaascpau/20*cmdb_ci_linux_server.csv 2>/dev/null | tail -1)"
```

---

## Running the Scripts

### Normal production run

```bash
cd /usr/local/pnc/bin/RHEL_Inventory_v2
sudo ./rhel_inv_run.sh
```

### Manual run with log visible in terminal

```bash
cd /usr/local/pnc/bin/RHEL_Inventory_v2
log=logs/rhel_inventory_v2_run.$(date +%Y%m%d).log
sudo ./rhel_inv_run.sh 2>&1 | tee $log
```

### Run only the collection phase (skip reports)

```bash
sudo ./rhel_inv_collect.sh
```

### Run only the report phase against existing data

```bash
sudo ./rhel_inv_report.sh
```

### Run package inventory from secondary jumpbox

```bash
cd /usr/local/pnc/bin/RHEL_Inventory_v2
sudo ./rhel_pkginventory.sh
```

### Check what the latest run produced

```bash
# Summary counts from the last run
grep '\[INFO\]\|\[WARN\]\|\[ERROR\]' logs/rhel_inventory_v2_latest.log | tail -50

# Just errors and warnings
grep '\[WARN\]\|\[ERROR\]' logs/rhel_inventory_v2_latest.log

# Filter summary line (shows counts per data stream)
grep 'Filter summary' logs/rhel_inventory_v2_latest.log

# CMDB match stats
grep 'CMDB enrichment' logs/rhel_inventory_v2_latest.log

# Section markers only (quick run overview)
grep '===' logs/rhel_inventory_v2_latest.log
```

---

## Test Mode

Test mode runs the full pipeline against a specific host list and writes all
output to an isolated `test/` subdirectory. No production files are touched.

### Run a test against a specific host list

```bash
cd /usr/local/pnc/bin/RHEL_Inventory_v2
sudo ./rhel_inv_run.sh --test /path/to/test_hosts.txt
```

### Run a quick smoke test against one host

```bash
echo "yourhostname.pncint.net" > /tmp/one_host.txt
sudo ./rhel_inv_run.sh --test /tmp/one_host.txt
```

### Run a test with no host list (defaults to localhost)

```bash
sudo ./rhel_inv_run.sh --test
```

### Review test output

```bash
# Test data files
ls -lh test/data/

# Test logs
cat test/logs/test_rhel_inventory_latest.log

# Spot-check a few inventory records
head -5 test/data/TEST_RHEL_INVENTORY.dat

# Check package records collected
wc -l test/data/TEST_RHEL_PACKAGES.csv
head -5 test/data/TEST_RHEL_PACKAGES.csv
```

### Test mode behaviour differences

- All data files written under `test/data/` with `TEST_` prefix
- Logs written under `test/logs/` — separate from production logs
- Web output written under `test/webdir/`
- `RHEL_DEPLOYMENTS.dat` is **read** (to check for known hosts) but **not written**
  — test runs never append to the permanent deployment history
- Supplemental reports (Midrange Mod, RHEL89 Upgrade Checker) are skipped
- pssh settings, CMDB lookup, and all collection logic are identical to production

---

## Crontab Setup

### Main jumpbox — nightly inventory (replace legacy entry)

```crontab
# v2 — nightly RHEL inventory (run alongside legacy during validation period)
30 22 * * * cd /usr/local/pnc/bin/RHEL_Inventory_v2 ; log=logs/rhel_inventory_v2_run.$(date +"\%Y\%m\%d").log ; ./rhel_inv_run.sh >> ${log} 2>&1 ; ln -sf ${log} logs/rhel_inventory_v2_latest.log
```

Note: scheduled at 22:30 (legacy runs at 21:30) so both can run without
competing for pssh connections during the validation period.

### Secondary jumpbox — package inventory

```crontab
# v2 — nightly package inventory (weekdays)
00 01 * * 1-5 cd /usr/local/pnc/bin/RHEL_Inventory_v2 ; ./rhel_pkginventory.sh >> logs/rhel_pkginventory_v2.log 2>&1
```

---

## Parallel Operation with Legacy

During the validation period both v2 and legacy run nightly simultaneously.
They are isolated from each other by:

| Item | Legacy | v2 |
|---|---|---|
| Base directory | `RHEL_Inventory/` | `RHEL_Inventory_v2/` |
| PID file | `data/RHEL_INVENTORY.PID` | `data/RHEL_INV_V2.PID` |
| Inventory dat | `RHEL_INVENTORY.dat` | `RHEL_INVENTORY_v2.dat` |
| Inventory CSV | `RHEL_INVENTORY.csv` | `RHEL_INVENTORY_v2.csv` |
| Package CSV | `RHEL_PACKAGES.csv` | `RHEL_PACKAGES_v2.csv` |
| Web directory | `/usr/local/midweb/RHEL/` | `/usr/local/midweb/RHEL_v2/` |
| Cron time | 21:30 | 22:30 |
| Deployment dat | `RHEL_DEPLOYMENTS.dat` (writes) | `RHEL_DEPLOYMENTS.dat` (reads + appends only) |

The only shared resource is `RHEL_DEPLOYMENTS.dat` — v2 reads it to avoid
re-scanning known hosts and safely appends new host records. This is safe
because the legacy script also only appends to it and both scripts use the
same append-only format.

---

## Cutover Checklist

Once v2 has run successfully for at least one week and output has been validated:

1. **Stop legacy cron** — comment out the `RHEL_update.sh` and
   `RHEL_pkginventory_refresh.sh` crontab entries
2. **Update `rhel_inv.conf`**:
   - Set `BASE_DIR` to `/usr/local/pnc/bin/RHEL_Inventory`
   - Set `WEBDIR` to `/usr/local/midweb/RHEL`
   - Remove `_v2` suffixes from all data file names
   - Update `DEPLOYMENTDATA` to point at the local dat file
3. **Copy data files** — copy any `_v2.dat` files you want to preserve as
   the seed for the new location
4. **Update crontab** — change the v2 cron entry back to 21:30 and remove
   the legacy entries
5. **Update web server config** if needed to serve from the new WEBDIR
6. **Archive legacy scripts** — do not delete immediately; keep for 30 days

---

## Log Reference

### Log levels

| Level | Meaning |
|---|---|
| `[INFO]` | Normal progress — expected output |
| `[WARN]` | Something unexpected but non-fatal — worth reviewing |
| `[ERROR]` | Fatal condition — script exited or phase was skipped |
| `=== ... ===` | Section boundary marker |

### Key log lines to monitor

```bash
# Did the scan complete and how many hosts responded?
grep 'Filter summary' logs/rhel_inventory_v2_latest.log

# Were there SSH failures?
grep 'hosts had errors' logs/rhel_inventory_v2_latest.log

# Did CMDB enrichment work?
grep 'CMDB enrichment' logs/rhel_inventory_v2_latest.log

# Were there any errors?
grep '\[ERROR\]' logs/rhel_inventory_v2_latest.log

# Full section timeline
grep '===' logs/rhel_inventory_v2_latest.log
```

### Example healthy run output

```
2026-06-19 21:30:01  === Starting RHEL Inventory Orchestrator ===
2026-06-19 21:30:01  [INFO]    Mode       : production
2026-06-19 21:30:01  [INFO]    Host list  : /usr/local/bin/hosts.linux.ssh.txt
2026-06-19 21:30:01  [INFO]    CMDB file  : /home/xaascpau/20260619_180436_cmdb_ci_linux_server.csv

2026-06-19 21:30:02  === Phase 1 — Inventory Collection ===
2026-06-19 21:30:02  [INFO]    Deployment scan complete — new: 14  already known: 22467  SSH failures: 3
2026-06-19 21:30:04  [INFO]    Scanning 22481 hosts from /usr/local/bin/hosts.linux.ssh.txt
2026-06-19 23:44:11  [INFO]    Filter summary — INV: 21847  ID: 489234  DB: 312  PKG: 0  skipped: 42104  errors: 0
2026-06-19 23:44:11  [INFO]    RHEL_INVENTORY_v2.tmp: 21847 lines collected
2026-06-19 23:44:18  [INFO]    CMDB enrichment complete — matched: 20941  not in CMDB: 906

2026-06-19 23:44:21  === Phase 2 — Report Generation ===
2026-06-19 23:44:31  [INFO]    Report generation completed successfully

2026-06-19 23:44:31  === RHEL Inventory Orchestrator complete ===
```

---

## Output Files Reference

### `RHEL_INVENTORY_v2.dat` — space-delimited, one line per host

Fields in order:
```
Host PV Release Kernel Arch Memory CPU_Sockets CPU_Cores CPU_Threads
CPU_Type CPU_Speed HW_Vendor HW_Model HW_Serial Syslog-ng Uptime
VMToolsVer VMToolsRunning LastBackupDate IPAddr Location CIDevice
vCenter BuildType DBType
```

### `RHEL_INVENTORY_v2.csv` — CSV with CMDB enrichment

Same fields as above converted to CSV, plus four CMDB columns appended:
`CMDB Support Group, CMDB Install Status, CMDB Desired Operational State, Fed Enclave`

### `RHEL_PACKAGES_v2.csv`

```
Host,Package,Version,Release,Install date
```

One row per installed RPM per host. Typically several million rows.
Use `grep` to search across all hosts:

```bash
# Which hosts have a specific package and what version?
grep "^,openssl," data/RHEL_PACKAGES_v2.csv

# All packages on a specific host
grep "^hostname," data/RHEL_PACKAGES_v2.csv

# Which hosts have a vulnerable version of a package?
grep ",log4j," data/RHEL_PACKAGES_v2.csv | grep "2\.14\."
```

### `RHEL_DEPLOYMENTS.dat` — append-only, space-delimited

```
YYYY-MM-DD  hostname  Phys|Virt  RHEL_version
```

Permanent record going back to 2004. Never truncated or rewritten.

---

## Troubleshooting

### Scan produces very few records

Check pssh is reachable and the host list is correct:
```bash
head -5 /usr/local/bin/hosts.linux.ssh.txt
/usr/local/pssh/bin/pssh --version
```

Check the error directory from the last run:
```bash
ls -lt data/ | grep errdir | head -3
# then look at a sample error file
ls data/errdir.YYYYMMDD_HHMM/ | head -5
cat data/errdir.YYYYMMDD_HHMM/somehostname
```

### CMDB enrichment shows 0 matched

The daily file drop may not have arrived yet or the pattern changed:
```bash
ls -lh /home/xaascpau/20*cmdb_ci_linux_server.csv
```

If the file exists, check that the hostname format in the CMDB CSV matches
the hostnames in `RHEL_INVENTORY.dat` (short name vs FQDN).

### Hung-process watchdog fires unexpectedly

The prior run may have genuinely been still running, or the PID file is stale.
Check manually:
```bash
cat data/RHEL_INV_V2.PID
ps -p $(cat data/RHEL_INV_V2.PID)
```

If the process is not running, remove the PID file and re-run:
```bash
rm data/RHEL_INV_V2.PID
sudo ./rhel_inv_run.sh
```

### Test run shows no output

Confirm the test host is reachable from the jumpbox:
```bash
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@yourhostname uptime
```

If that works, run the remote scan manually against one host to see its raw output:
```bash
ssh root@yourhostname 'bash -s' < rhel_remote_scan.sh | head -20
```
