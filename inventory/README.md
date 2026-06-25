# RHEL Inventory v2

Nightly Linux host inventory collection and reporting system for PNC OS Engineering.
Collects system, package, user/group, Oracle DB, Midrange Mod, and Server Compare
data from 22,500+ RHEL hosts via parallel SSH, enriches results with CMDB data,
and publishes CSV and HTML reports.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Jumpbox Setup](#jumpbox-setup)
- [Directory Layout](#directory-layout)
- [Script Reference](#script-reference)
- [Collection Pipeline Detail](#collection-pipeline-detail)
- [Fed Enclave Pipeline](#fed-enclave-pipeline)
- [Host Type Classification](#host-type-classification)
- [Timeout and Carry-Forward Behavior](#timeout-and-carry-forward-behavior)
- [Configuration](#configuration)
- [Running the Scripts](#running-the-scripts)
- [Test Mode](#test-mode)
- [Crontab Setup](#crontab-setup)
- [What Changed vs Legacy](#what-changed-vs-legacy)
- [Parallel Operation with Legacy](#parallel-operation-with-legacy)
- [Cutover Checklist](#cutover-checklist)
- [Log Reference](#log-reference)
- [Output Files Reference](#output-files-reference)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

The pipeline runs two separate pssh passes per nightly cycle, each doing a
distinct job with no overlap:

```
Phase 3a  cat rhel_remote_scan.sh | pssh ... bash
          Collects: INV + ID + DB + PKG
          Output:   RHEL_INVENTORY_v2.tmp
                    RHEL_IDINVENTORY_v2.tmp
                    RHEL_DBINVENTORY_v2.tmp
                    RHEL_PACKAGES_v2.tmp

Phase 3b  cat RHEL_data_gather.sh | pssh ... bash
          Collects: Midrange Mod CSV + Server Compare JSON
          Output:   Midrange_Mod_Report_MM-DD-YYYY.csv.tmp
                    compare_data_MM-DD-YYYY.json.tmp
```

Phase 3a is one SSH connection per host. `rhel_remote_scan.sh` already runs
`rpm -qa` to collect package data, so INV, ID, DB, and PKG all come out of
that single connection. There is no separate package collection pass.

Phase 3b runs `RHEL_data_gather.sh` independently. It is kept separate because
concatenating scripts for piping to bash causes bash 4.4 (RHEL 7) to fail with
a parse error. Each script runs cleanly on its own.

The Fed Enclave runs separately on a second jumpbox via AAP (Ansible Automation
Platform), which fetches the results back and stages them for Phase 4.5 merge.

---

## Jumpbox Setup

| Jumpbox | Hostname | User | Role |
|---|---|---|---|
| Main | lmrg34ja | sa04910OUD | Runs main scan, all phases, reports |
| Fed Enclave | lmrg34ba | xqmrglinaap | Runs fed-only scan via AAP |

The two jumpboxes cannot SCP directly to each other. AAP is the relay:
lmrg34ba runs the fed scan, AAP fetches the output files to the controller,
then copies them to lmrg34ja's `fed_stage/` directory.

---

## Directory Layout

```
/usr/local/pnc/bin/RHEL_Inventory_v2/
|
+-- rhel_inv.conf               Central config -- all tunable paths and settings
+-- rhel_inv_run.sh             Orchestrator -- entry point for cron and manual runs
+-- rhel_inv_collect.sh         Main collection pipeline (Phases 1-10)
+-- rhel_remote_scan.sh         Remote script -- INV/ID/DB/PKG via pssh Phase 3a
+-- RHEL_data_gather.sh         Remote script -- Midrange Mod + Compare JSON Phase 3b
+-- rhel_filter_scan.sh         Jumpbox-side pssh output filter (6 output streams)
+-- rhel_filter_pkgs.sh         Package-only filter (used by standalone pkginventory)
+-- rhel_deploy_scan.sh         New host detection and deployment record creation
+-- rhel_split_hosts.sh         Splits CMDB CSV into fed/non-fed host lists
+-- rhel_fed_scan.sh            Fed Enclave scan -- runs on lmrg34ba via AAP
+-- rhel_pkginventory.sh        Standalone package inventory (not called by main pipeline)
+-- rhel_inv_report.sh          HTML report generator
+-- rhel_inv_consolidate.sh     Midrange inventory consolidation
+-- rhel_inventory_v2.yml       AAP playbook -- Fed Enclave data relay
+-- README.md                   This file
|
+-- data/                       All runtime data files (auto-created)
|   +-- RHEL_INVENTORY_v2.dat         Current inventory (space-delimited, authoritative)
|   +-- RHEL_INVENTORY_v2.csv         Enriched CSV with CMDB columns
|   +-- RHEL_PACKAGES_v2.csv          RPM package inventory
|   +-- RHEL_IDINVENTORY_v2.dat       User/group/netgroup data
|   +-- RHEL_DBINVENTORY_v2.dat       Oracle SID data
|   +-- RHEL_DEPLOYMENTS.dat          Shared with legacy -- append-only, never rewritten
|   +-- non_fed_hosts.txt             CMDB-derived non-fed host list (refreshed per run)
|   +-- fed_hosts.txt                 CMDB-derived fed enclave host list
|   +-- fed_stage/                    AAP drops fed output files here for Phase 4.5 merge
|   +-- fed_enclave_raw.dat           Fed Enclave INV data (from lmrg34ba)
|   +-- fed_enclave_id.dat            Fed Enclave ID data
|   +-- fed_enclave_db.dat            Fed Enclave DB data
|   +-- fed_enclave_pkg.csv           Fed Enclave package data
|   +-- fed_enclave_midrange_mod.dat  Fed Enclave Midrange Mod CSV rows
|   +-- fed_enclave_compare_data.dat  Fed Enclave combined JSON (split into host files)
|   +-- errdir.YYYYMMDD_HHMM/         Per-run pssh error output (pruned after 7 days)
|   +-- errdir_pkgs.YYYYMMDD_HHMM/    Package scan error dir (standalone pkginventory)
|   `-- *.tmp                         In-progress write targets (promoted atomically)
|
+-- logs/                       All log files (auto-created)
|   +-- rhel_inventory_v2.log           Append-only master log (permanent history)
|   +-- rhel_inventory_v2_run.*.log     Per-run timestamped log
|   +-- rhel_inventory_v2_latest.log    Symlink to most recent run log
|   `-- test/                           Test run logs (isolated)
|
`-- test/                       Test mode output (auto-created on --test runs)
    +-- data/                   TEST_ prefixed data files
    +-- logs/                   Test run logs
    `-- webdir/                 Test web output


/usr/local/midweb/RHEL_v2/             Web output root
+-- RHEL_INVENTORY_v2.csv              Enriched inventory CSV (web copy)
+-- RHEL_INVENTORY_v2.txt              Plain text inventory
+-- RHEL_INVENTORY_v2.html             HTML table (generated by rhel_convert_html.sh)
+-- RHEL_PACKAGES.csv                  Package inventory (web copy, no _v2 suffix)
+-- Midrange_INVENTORY.csv             Midrange team CSV view
+-- Midrange_Mod_Report.csv            Current Midrange Mod report (undated, latest run)
+-- Midrange_Mod/
|   +-- index.html                     Archive index page (generated by rhel_inv_report.sh)
|   `-- archive/
|       `-- Midrange_Mod_Report_MM-DD-YYYY.csv   Dated archives, 31 days retained
+-- historical_data/
|   `-- RHEL_INVENTORY_v2.N.csv        Last 14 CSV snapshots (rotated each run)
+-- RHEL_DEPLOYMENTS_v2.csv            Deployment history CSV (web copy)
+-- index.html                         Main dashboard
+-- style.css / app.js                 UI assets (written fresh each run)
`-- *.html                             Report pages (Location, Application, Releases, etc.)


/usr/local/midweb/RHEL/compare/data/
`-- hostname.json                      Server Compare Tool data, one file per host
                                       Always overwritten -- no archive kept
```

---

## Script Reference

### `rhel_inv.conf`
Central configuration sourced by every script. Contains all tunable values:
pssh settings, file paths, retention counts, OS version arrays, location codes.
Edit once here -- all scripts pick up the change automatically.

### `rhel_inv_run.sh`
Entry point. Manages PID file, hung-process watchdog, log setup, and test mode
path isolation. Calls `rhel_inv_collect.sh` then `rhel_inv_report.sh` in order.
This is what cron calls. Supports `--test [hostlist]` for isolated test runs.

### `rhel_inv_collect.sh`
Main pipeline. Runs the deployment scan, two pssh phases, enrichment, promotion,
Fed Enclave merge, UID/GID collection, consolidation, and cleanup. All ten
numbered phases live here.

### `rhel_remote_scan.sh`
Runs remotely on each host in Phase 3a via `cat script | pssh -I bash`.
Emits four tagged output streams in one SSH connection:

```
INV|host field1 field2 ...    System inventory (28 fields)
ID|host-USER-...              Users from /etc/passwd
ID|host-GROUP-...             Groups from /etc/group
ID|host-NETGROUP-...          Netgroups from getent
ID|host-ADGROUP-...           AD groups from getent
DB|host sid1 sid2             Oracle SIDs from ora_pmon_ processes
PKG|host,name,ver,rel,date    One line per installed RPM from rpm -qa
```

### `RHEL_data_gather.sh`
Runs remotely on each host in Phase 3b via `cat script | pssh -I bash`.
Kept as a separate script (not concatenated with rhel_remote_scan.sh) because
bash 4.4 on RHEL 7 hosts fails to parse concatenated scripts at startup.
Emits two tagged output streams:

```
MID_MOD_CSV:host:host,location,mnemonic,...    Midrange Mod CSV row (13 fields)
COMPARE_JSON:host:{...}                        Single-line JSON for Server Compare Tool
```

Collects: RHEL release, SSSD config, auth method (OUD/AD), netgroup membership,
AD group membership, pnc_join_ad package, nsswitch symlink, KRB5 keytab,
sudo access for service accounts, hardware, kernel, volumes, resolv.conf,
NFS/CIFS counts, service status (sssd, sshd).

### `rhel_filter_scan.sh`
Reads the pssh `--inline-stdout` stream and routes lines to six output files
based on tag prefix. Routing is fully stateless -- one line in, one line out.
Takes 6 positional arguments:

```
$1  INVENTORYTEMP    destination for INV| lines
$2  IDINVENTORYTEMP  destination for ID|  lines
$3  DBINVENTORYTEMP  destination for DB|  lines
$4  PACKAGETEMP      destination for PKG| lines
$5  MRGCSVTEMP       destination for MID_MOD_CSV: lines
$6  MRGJSONTMP       destination for COMPARE_JSON: lines (JSON array)
```

Pass `/dev/null` for any stream you want to suppress. Phase 3a passes
`/dev/null` for args 5 and 6 (MRG not collected that pass). Phase 3b passes
`/dev/null` for args 1-4 (INV/ID/DB/PKG not collected that pass).

FAILURE hosts get stubs written to all active (non-/dev/null) output streams.
Prints a summary count line on completion.

### `rhel_split_hosts.sh`
Reads the daily CMDB CSV extract (`/home/xaascpau/20*cmdb_ci_linux_server.csv`),
filters out decommissioned hosts and any non-`l`-prefixed hostnames (IPs, etc.),
and splits into two host lists:
- `data/non_fed_hosts.txt` -- hosts where FedEnclave column = False
- `data/fed_hosts.txt` -- hosts where FedEnclave column = True

### `rhel_fed_scan.sh`
Runs on lmrg34ba (Fed Enclave jumpbox) via AAP Task 2. Runs the same two-pass
pssh collection as the main pipeline but against the fed host list. Produces
six output files staged in `/usr/local/pnc/bin/data/` on lmrg34ba for AAP to fetch.

### `rhel_inventory_v2.yml`
AAP playbook that orchestrates the Fed Enclave data relay:
- Task 1: Split hosts and generate fed host list on lmrg34ja
- Task 2: Stage scripts on lmrg34ba, run `rhel_fed_scan.sh`
- Task 3: Fetch six fed output files from lmrg34ba to AAP controller,
  copy to `fed_stage/` on lmrg34ja
- Task 4: Run `rhel_inv_run.sh` on lmrg34ja with `--fed-dir fed_stage/`

### `rhel_deploy_scan.sh`
Checks every host in the master list against `RHEL_DEPLOYMENTS.dat`. For hosts
not yet seen, SSHes in individually to determine build date (PROVISIONDATE from
PNC_PROVISION_CONFIG, fallback to OS install date). Appends permanent records.
In test mode reads the deployment file for lookups but does not write new records.

### `rhel_inv_report.sh`
Generates all HTML reports from `RHEL_INVENTORY_v2.dat`. Also generates the
Midrange Mod archive index page (`Midrange_Mod/index.html`) which lists all
dated CSV files available for download.

### `rhel_pkginventory.sh`
Standalone package inventory runner. **Not called by the main pipeline** --
Phase 3a collects PKG data as part of `rhel_remote_scan.sh`. This script is
kept as a standalone fallback in case package data needs to be refreshed
independently without running the full inventory cycle.

### `rhel_inv_consolidate.sh`
Reads `RHEL_INVENTORY_v2.dat` and produces `Midrange_INVENTORY.csv` with the
column layout expected by the midrange team.

---

## Collection Pipeline Detail

```
Phase 0   Web asset staging (style.css, app.js)

Phase 1   Deployment scan -- new host detection, RHEL_DEPLOYMENTS.dat update

Phase 2   Cleanup -- remove stale temp files from previous run

Phase 3a  pssh: cat rhel_remote_scan.sh | pssh -I bash
          rhel_filter_scan.sh routes to:
            INVENTORYTEMP  (INV| lines)
            IDINVENTORYTEMP (ID| lines)
            DBINVENTORYTEMP (DB| lines)
            PACKAGETEMP    (PKG| lines)
            /dev/null      (MRG -- not this pass)
            /dev/null      (JSON -- not this pass)

Phase 3b  pssh: cat RHEL_data_gather.sh | pssh -I bash
          rhel_filter_scan.sh routes to:
            /dev/null      (INV -- not this pass)
            /dev/null      (ID  -- not this pass)
            /dev/null      (DB  -- not this pass)
            /dev/null      (PKG -- not this pass)
            MRGCSVTEMP     (MID_MOD_CSV: lines)
            MRGJSONTMP     (COMPARE_JSON: lines -> JSON array)

Phase 3c  (eliminated -- PKG collected in Phase 3a)

Phase 4   Rotate prior dat files, promote temps to dat
          PACKAGETEMP promoted, header prepended, published to WEBDIR

Phase 4.5 Fed Enclave merge -- appends fed_stage/ files to main dat files

Phase 4.6 Midrange Mod promotion:
          MRGCSVTEMP -> MRGCSVDATA (with header) -> archived to Midrange_Mod/archive/
          MRGJSONTMP -> Python3 splits into hostname.json per host -> COMPARE_DATA_DIR

Phase 5   UID/GID collection from IDINVENTORYDATA

Phase 6   Convert inventory to text and HTML

Phase 7   CMDB enrichment and CSV generation
          TIMEOUT carry-forward: overlay yesterday's dat for unreachable hosts

Phase 8   Rotate historical CSV copies (14 kept)

Phase 9   Inventory consolidation (Midrange_INVENTORY.csv)

Phase 10  Stale error directory cleanup (7 days)
```

---

## Fed Enclave Pipeline

Fed Enclave hosts cannot be reached from lmrg34ja. The collection is relayed
through lmrg34ba using AAP:

```
lmrg34ja                    AAP Controller              lmrg34ba
--------                    --------------              --------
Task 1: split hosts    -->
                            Task 2: stage scripts  -->  run rhel_fed_scan.sh
                                                        (two pssh passes)
                                                        produces 6 .dat/.csv files
                       <--  Task 3: fetch files    <--
copy to fed_stage/
Task 4: rhel_inv_run.sh
        --fed-dir fed_stage/
        Phase 4.5 merges
        fed data into main
```

The six files transferred from lmrg34ba:

| File | Content |
|---|---|
| `fed_enclave_raw.dat` | INV records for fed hosts |
| `fed_enclave_id.dat` | ID records for fed hosts |
| `fed_enclave_db.dat` | DB records for fed hosts |
| `fed_enclave_pkg.csv` | Package records for fed hosts |
| `fed_enclave_midrange_mod.dat` | Midrange Mod CSV rows for fed hosts |
| `fed_enclave_compare_data.dat` | Combined JSON array for all fed hosts |

`fed_enclave_compare_data.dat` is a JSON array (`[{host1...},{host2...}]`).
Phase 4.6 merges it with the main JSON array before splitting into individual
`hostname.json` files.

---

## Host Type Classification

The `Type` field in the inventory is set by Phase 7 enrichment:

| Type | Meaning |
|---|---|
| `Virt` | Virtual machine, reachable this run |
| `Phys` | Physical server, reachable this run |
| `Cloud` | Azure VM (location AZCE or AZE2), reachable this run |
| `TIMEOUT_Virt` | Virtual machine, unreachable this run -- carry-forward data |
| `TIMEOUT_Phys` | Physical server, unreachable this run -- carry-forward data |
| `TIMEOUT_Cloud` | Azure VM, unreachable this run -- carry-forward data |

`BUILDTYPE=Cloud` comes from `/boot/PNC_PROVISION_CONFIG` on each host.
Location-based Cloud detection (AZCE/AZE2) applies even to TIMEOUT hosts as
long as their location is known from carry-forward data.

---

## Timeout and Carry-Forward Behavior

When a host fails to respond (pssh FAILURE or timeout), it gets a TIMEOUT stub
record in the current run's output. Phase 7 enrichment then overlays the
previous run's data from `RHEL_INVENTORY_v2.dat.1.gz` so the host continues
to show its last known kernel, memory, location, BUILDTYPE, CMDB data, etc.

Key behaviors:

- **Multi-day chains persist.** A host unreachable for 3+ consecutive days
  still shows its last good data. The type stays `TIMEOUT_Virt` (not
  `TIMEOUT_TIMEOUT_Virt`) regardless of how many consecutive runs it has missed.

- **Cloud classification is preserved.** An Azure host (AZCE/AZE2) that is
  unreachable becomes `TIMEOUT_Cloud`, not `TIMEOUT_Virt`, as long as its
  location was captured in a previous run.

- **Chain breaks if host is absent from host list.** If a host is removed from
  `hosts.linux.ssh.txt` (decommissioned), it no longer appears in any output.
  The carry-forward only applies to hosts still being scanned.

- **Midrange Mod CSV for TIMEOUT hosts.** Phase 3b's failure stubs write
  `n/a` rows for unreachable hosts. Unlike the inventory, there is no
  carry-forward for Midrange Mod data -- only the most recent scan data
  is valid for Midrange Mod purposes.

- **Server Compare JSON for TIMEOUT hosts.** Hosts unreachable in Phase 3b
  get a `reachable: false` stub JSON. Python3 overwrites any previous
  `hostname.json` with the stub, so the Server Compare Tool accurately
  reflects current reachability.

---

## Configuration

All settings live in `rhel_inv.conf`. The most commonly changed values:

```bash
# Base directory
BASE_DIR="/usr/local/pnc/bin/RHEL_Inventory_v2"
WEBDIR="/usr/local/midweb/RHEL_v2"

# pssh settings
PSSH_BATCH=75        # hosts in parallel
PSSH_TIMEOUT=90      # seconds per host (covers rhel_remote_scan.sh + RHEL_data_gather.sh)
PSSH_LOGIN="root"

# Host list -- CMDB-derived, refreshed by rhel_split_hosts.sh before each run
MASTERHOSTLIST="${DATA_DIR}/non_fed_hosts.txt"

# CMDB file -- auto-selects newest daily drop
CMDBDATAFILE="$(ls /home/xaascpau/20*cmdb_ci_linux_server.csv 2>/dev/null | tail -1)"

# Midrange Mod archive retention (days)
DAYS_TO_KEEP_MRG=31

# Server Compare Tool JSON destination (external tool, path shared with legacy)
COMPARE_DATA_DIR="/usr/local/midweb/RHEL/compare/data"

# OS version tracking
OS_VERSIONS=(8.8 8.10 9.7 9.8)
OS_SERIES=(8 9)
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
log=logs/rhel_inventory_v2_run.$(date +%Y%m%d_%H%M%S).log
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

### Refresh host lists from CMDB manually

```bash
sudo ./rhel_split_hosts.sh
wc -l data/non_fed_hosts.txt data/fed_hosts.txt
```

### Run standalone package inventory (not normally needed)

```bash
# Only if RHEL_PACKAGES_v2.csv needs refreshing independently
sudo ./rhel_pkginventory.sh
```

### Check what the latest run produced

```bash
# Section markers only -- quick run overview
grep '===' logs/rhel_inventory_v2_latest.log

# Filter summary -- counts per data stream per pssh pass
grep 'Filter summary' logs/rhel_inventory_v2_latest.log

# CMDB match stats
grep 'CMDB enrichment' logs/rhel_inventory_v2_latest.log

# SSH errors and warnings
grep '\[WARN\]\|\[ERROR\]' logs/rhel_inventory_v2_latest.log

# Host counts
grep 'lines collected\|records written\|host files written' logs/rhel_inventory_v2_latest.log
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

### Run a quick smoke test against a few known hosts

```bash
cat > /tmp/smoke.txt << 'EOF'
lmrg10ia
laac004w
laac002d
EOF
sudo ./rhel_inv_run.sh --test /tmp/smoke.txt
```

### Review test output

```bash
# What data was collected
ls -lh test/data/

# Log overview
grep '===' test/logs/test_rhel_inventory_latest.log

# Inventory records
head -5 test/data/TEST_RHEL_INVENTORY.dat

# Midrange Mod CSV
head -5 test/data/Midrange_Mod_Report_*.csv.tmp 2>/dev/null || \
  head -5 test/webdir/Midrange_Mod_Report.csv

# Compare JSON for a specific host
cat test/webdir/compare/data/laac004w.json 2>/dev/null

# Package count
wc -l test/data/TEST_RHEL_PACKAGES.csv 2>/dev/null
```

### Test mode file naming

All data files get `TEST_` prefix in test mode:

| Production | Test |
|---|---|
| `RHEL_INVENTORY_v2.dat` | `TEST_RHEL_INVENTORY.dat` |
| `RHEL_PACKAGES_v2.csv` | `TEST_RHEL_PACKAGES.csv` |
| `RHEL_IDINVENTORY_v2.dat` | `TEST_RHEL_IDINVENTORY.dat` |
| `RHEL_DBINVENTORY_v2.dat` | `TEST_RHEL_DBINVENTORY.dat` |

Midrange Mod and Compare JSON use the same date-stamped names but write under
`test/webdir/` and `test/data/` respectively. `RHEL_DEPLOYMENTS.dat` is read
but never written in test mode.

---

## Crontab Setup

### Main jumpbox (lmrg34ja) -- nightly inventory

```crontab
# v2 -- nightly RHEL inventory (alongside legacy during validation)
30 22 * * * cd /usr/local/pnc/bin/RHEL_Inventory_v2 ; sudo ./rhel_inv_run.sh >> logs/rhel_inventory_v2_run.$(date +\%Y\%m\%d_\%H\%M\%S).log 2>&1
```

Note: scheduled at 22:30 so it does not compete with legacy (21:30) for pssh
connections during the parallel validation period.

### AAP job template

The Fed Enclave collection runs as an AAP job template that calls
`rhel_inventory_v2.yml`. Schedule this to run at the same time as or
immediately before the main cron so fed data is available in `fed_stage/`
when `rhel_inv_run.sh` reaches Phase 4.5.

---

## What Changed vs Legacy

### Architecture

| Area | Legacy | v2 |
|---|---|---|
| pssh passes | 4 separate (INV, ID/DB, PKG, Midrange) | 2 (Phase 3a: INV+ID+DB+PKG, Phase 3b: MRG+JSON) |
| Remote scripts | 4-5 separate scripts | 2: rhel_remote_scan.sh + RHEL_data_gather.sh |
| Filter scripts | 4-5 separate | 1: rhel_filter_scan.sh (6 output streams) |
| Config | Variables scattered across scripts | Single rhel_inv.conf |
| Midrange Mod | Standalone Midrange_Mod_Report.sh | Integrated into Phase 3b/4.6 |
| Server Compare JSON | Standalone, SCPs from remote hosts | Integrated, stdout via pssh |
| Fed Enclave | Not handled | AAP playbook relay via lmrg34ba |
| Host list source | Static hosts.linux.ssh.txt | CMDB-derived, split by FedEnclave field |
| TIMEOUT carry-forward | 1 day only | Persists across consecutive unreachable days |
| Cloud detection on TIMEOUT | Lost (type becomes TIMEOUT_Virt) | Preserved (TIMEOUT_Cloud) |
| Logging | echo with date inline | log() function with levels |
| Test mode | None | --test [hostlist] with fully isolated paths |

### New scripts added

| Script | Purpose |
|---|---|
| `RHEL_data_gather.sh` | Remote -- Midrange Mod CSV + Compare JSON collection |
| `rhel_split_hosts.sh` | CMDB-based fed/non-fed host list generation |
| `rhel_fed_scan.sh` | Fed Enclave pssh scan on lmrg34ba |
| `rhel_inventory_v2.yml` | AAP playbook for Fed Enclave data relay |

### Scripts from legacy no longer called by main pipeline

| Script | Status |
|---|---|
| `rhel_pkginventory.sh` | Kept as standalone fallback; PKG now from Phase 3a |
| `Midrange_Mod_Report.sh` | Kept as standalone fallback; integrated into main pipeline |

### Files replaced

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
| `Midrange_Mod_Report.sh` | integrated into `rhel_inv_collect.sh` Phase 3b/4.6 |
| `RHEL_data_gather.sh` (legacy) | `RHEL_data_gather.sh` (rewritten, new tag format) |
| `Inventory_Consolidation.sh` | `rhel_inv_consolidate.sh` |

---

## Parallel Operation with Legacy

During the validation period both v2 and legacy run nightly simultaneously.
They are isolated by different directories and file names:

| Item | Legacy | v2 |
|---|---|---|
| Base directory | `RHEL_Inventory/` | `RHEL_Inventory_v2/` |
| PID file | `data/RHEL_INVENTORY.PID` | `data/RHEL_INV_V2.PID` |
| Inventory dat | `RHEL_INVENTORY.dat` | `RHEL_INVENTORY_v2.dat` |
| Package CSV | `RHEL_PACKAGES.csv` | `RHEL_PACKAGES_v2.csv` |
| Web directory | `/usr/local/midweb/RHEL/` | `/usr/local/midweb/RHEL_v2/` |
| Cron time | 21:30 | 22:30 |

The only shared resource is `RHEL_DEPLOYMENTS.dat` -- v2 reads it to avoid
re-scanning known hosts and appends new host records. This is safe because
both scripts only ever append to it in the same format.

---

## Cutover Checklist

Once v2 has run successfully for at least one week with validated output:

1. **Stop legacy cron** -- comment out `RHEL_update.sh` and any legacy
   `RHEL_pkginventory_refresh.sh` entries on both jumpboxes

2. **Confirm deployment history** is current:
   ```bash
   wc -l /usr/local/pnc/bin/RHEL_Inventory_v2/data/RHEL_DEPLOYMENTS.dat
   wc -l /usr/local/pnc/bin/RHEL_Inventory/data/RHEL_DEPLOYMENTS.dat
   ```

3. **Update `rhel_inv.conf`**:
   - Change `BASE_DIR` to `/usr/local/pnc/bin/RHEL_Inventory`
   - Change `WEBDIR` to `/usr/local/midweb/RHEL`
   - Remove `_v2` suffixes from all data file name variables

4. **Update crontab** on lmrg34ja -- change v2 entry to 21:30, remove legacy entry

5. **Update web server config** if needed to point at the new `WEBDIR`

6. **Verify first production run** under new paths completes cleanly

7. **Archive legacy scripts** -- do not delete immediately:
   ```bash
   tar czf /usr/local/pnc/bin/RHEL_Inventory_legacy_$(date +%Y%m%d).tar.gz \
       /usr/local/pnc/bin/RHEL_Inventory
   ```

### One-time setup before first v2 run

```bash
# Seed deployment history -- preserves all records back to 2004
cp /usr/local/pnc/bin/RHEL_Inventory/data/RHEL_DEPLOYMENTS.dat \
   /usr/local/pnc/bin/RHEL_Inventory_v2/data/RHEL_DEPLOYMENTS.dat

# Set permissions
chmod 755 /usr/local/pnc/bin/RHEL_Inventory_v2/*.sh
chmod 644 /usr/local/pnc/bin/RHEL_Inventory_v2/rhel_inv.conf

# Verify
wc -l /usr/local/pnc/bin/RHEL_Inventory_v2/data/RHEL_DEPLOYMENTS.dat
```

---

## Log Reference

### Log levels

| Level | Meaning |
|---|---|
| `[INFO]` | Normal progress |
| `[WARN]` | Unexpected but non-fatal -- review after run |
| `[ERROR]` | Fatal condition -- phase was skipped or script exited |
| `=== ... ===` | Phase boundary marker |
| `[SECTION]` | Sub-section within a phase |
| `[PASS]` / `[FAIL]` | End-of-run checklist results |

### Key log lines to monitor

```bash
# Phase 3a filter summary (INV/ID/DB/PKG counts)
grep 'Filter summary' logs/rhel_inventory_v2_latest.log | head -1

# Phase 3b filter summary (MRG_CSV/MRG_JSON counts)
grep 'Filter summary' logs/rhel_inventory_v2_latest.log | tail -1

# CMDB enrichment
grep 'CMDB enrichment' logs/rhel_inventory_v2_latest.log

# Midrange Mod promotion
grep 'MRG CSV promoted\|MRG CSV archived' logs/rhel_inventory_v2_latest.log

# Server Compare JSON split
grep 'Compare JSON split' logs/rhel_inventory_v2_latest.log

# SSH errors
grep 'hosts had errors' logs/rhel_inventory_v2_latest.log

# End-of-run checklist summary
grep 'CHECKLIST SUMMARY\|PASS\|FAIL\|RESULT' logs/rhel_inventory_v2_latest.log | tail -10

# All warnings
grep '\[WARN\]' logs/rhel_inventory_v2_latest.log
```

---

## Output Files Reference

### `RHEL_INVENTORY_v2.dat` -- space-delimited, one line per host

Fields (28 total):
```
Host Type Release Kernel Arch Memory CPU_Sockets CPU_Cores CPU_Threads
CPU_Type CPU_Speed HW_Vendor HW_Model HW_Serial Syslog-ng Uptime
VMToolsVer VMToolsRunning LastBackupDate IPAddr Location CIDevice
vCenter BuildType DBType AppCode Environment BuildDate
```

### `RHEL_INVENTORY_v2.csv` -- CSV with CMDB enrichment

Same 28 fields as the dat, converted to CSV, plus four CMDB columns:
`CMDB Support Group, CMDB Install Status, CMDB Desired Operational State, Fed Enclave`

### `RHEL_PACKAGES_v2.csv`

```
Host,Package,Version,Release,Install date
```

One row per installed RPM per host. Typically 20-25 million rows for a full fleet.

```bash
# All packages on a specific host
grep "^hostname," /usr/local/midweb/RHEL_v2/RHEL_PACKAGES.csv

# Which hosts have a specific package
grep ",openssl," /usr/local/midweb/RHEL_v2/RHEL_PACKAGES.csv | awk -F, '{print $1}' | sort -u

# Which hosts have a vulnerable version
grep ",log4j," /usr/local/midweb/RHEL_v2/RHEL_PACKAGES.csv | grep ",2\.14\."
```

### `Midrange_Mod_Report.csv` -- current run, 13 columns

```
Host,Location,Mnemonic,Environment,OS Version,Authentication Method,
OUD Query,AD Query,pnc_join_ad,Nsswitch,KRB5 Keytab,
xqvsmlinauthscan Sudo,xqmrglineng Sudo,xqmrglinaap Sudo
```

Archived dated copies kept for 31 days in `Midrange_Mod/archive/`.

### `hostname.json` -- Server Compare Tool data

One JSON file per host in `/usr/local/midweb/RHEL/compare/data/`. Always
overwritten with the most recent run's data. Structure:

```json
{
  "host": "lmrg10ia",
  "collected_at": "2026-06-24T23:21:22",
  "reachable": true,
  "data": {
    "location": "GF0",
    "environment": "UAT",
    "rhel_version": "9.7",
    "kernel": "5.14.0-611.54.1.el9_7.x86_64",
    "cpu": "2", "cores": "1", "sockets": "2",
    "memory": "4 GB",
    "volumes": [...],
    "auth_method": {"oud": "YES", "ad": "YES"},
    "services": {"sssd": "active", "sshd": "active"}
  }
}
```

Hosts unreachable in Phase 3b get `"reachable": false` with an error message.

### `RHEL_DEPLOYMENTS.dat` -- append-only, space-delimited

```
YYYY-MM-DD  hostname  Phys|Virt  RHEL_version
```

Permanent record going back to 2004. Never truncated or rewritten.

---

## Troubleshooting

### Scan produces very few INV records

Check pssh reachability and host list:
```bash
wc -l data/non_fed_hosts.txt
head -5 data/non_fed_hosts.txt
/usr/local/pssh/bin/pssh --version

# Test one host manually
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@laac004w uptime
```

Check the errdir from the last run:
```bash
ls -lt data/ | grep errdir | head -3
ls data/errdir.YYYYMMDD_HHMM/ | wc -l
cat data/errdir.YYYYMMDD_HHMM/somehostname
```

### Midrange Mod CSV shows all n/a

The MRGCSVTEMP file may be stale from a previous run and not cleared.
Phase 2 cleanup should handle this -- verify:
```bash
grep 'Cleared stale temp files' logs/rhel_inventory_v2_latest.log
```

If missing, check whether `MRGCSVTEMP` is being exported correctly:
```bash
grep 'MRG CSV temp' logs/rhel_inventory_v2_latest.log
```

Also check Phase 3b filter summary -- MRG_CSV count should match host count:
```bash
grep 'Filter summary' logs/rhel_inventory_v2_latest.log | tail -1
```

### Server Compare JSON files missing or not updating

Check Phase 4.6 log output:
```bash
grep 'Compare JSON' logs/rhel_inventory_v2_latest.log
```

If the split shows 0 files written, check whether MRGJSONTMP is valid JSON:
```bash
python3 -c "import json; f=open('data/compare_data_*.json.tmp'); json.load(f); print('valid')" 2>&1
```

Confirm the output directory exists and is writable:
```bash
ls -ld /usr/local/midweb/RHEL/compare/data/
```

### Phase 3b produces exit code 2 on remote hosts

This is a bash 4.4 (RHEL 7) parser error. It means the remote script has
non-ASCII characters or nested quote patterns that bash 4.4 cannot parse.
Test directly:
```bash
sudo ssh laac004w bash -n < RHEL_data_gather.sh 2>&1
echo "Exit: $?"
```

If it fails, check for non-ASCII characters:
```bash
grep -Pn '[^\x00-\x7F]' RHEL_data_gather.sh
```

### CMDB enrichment shows 0 matched

The daily CMDB file may not have arrived yet:
```bash
ls -lh /home/xaascpau/20*cmdb_ci_linux_server.csv | tail -3
```

Check that the file timestamp is from today and the hostname format matches:
```bash
head -3 /home/xaascpau/20*cmdb_ci_linux_server.csv | tail -1 | cut -d, -f1
head -3 data/RHEL_INVENTORY_v2.dat | awk '{print $1}'
```

### Hung-process watchdog fires unexpectedly

Check if the prior run is genuinely still running:
```bash
cat data/RHEL_INV_V2.PID
ps -p $(cat data/RHEL_INV_V2.PID) 2>/dev/null
```

If the process is gone, the PID file is stale -- remove and re-run:
```bash
rm data/RHEL_INV_V2.PID
sudo ./rhel_inv_run.sh
```

### Fed Enclave data not updating

If `AAP_FED_DIR not set` appears in the log, Phase 4.5 used the previous run's
fed files. This is normal for manual/cron runs -- AAP must call `rhel_inv_run.sh`
with `--fed-dir fed_stage/` to inject fresh fed data.

Check what fed data is currently staged:
```bash
ls -lh data/fed_stage/
ls -lh data/fed_enclave_*.dat data/fed_enclave_*.csv 2>/dev/null
```
