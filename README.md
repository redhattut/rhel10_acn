# TTI EAR — Termination, Transfer, and Inactivity (EAR) Cleanup Process

Modern rewrite of the TTI EAR automation suite. Replaces the legacy KSH scripts from 2007 with clean, maintainable bash. Handles home directory removal, legacy `/etc/passwd` account cleanup, and `/etc/group` membership scrubbing for terminated and transferred users across the Linux server estate.

---

## Table of Contents

1. [Background](#background)
2. [What Changed vs Legacy](#what-changed-vs-legacy)
3. [Folder Layout](#folder-layout)
4. [Script Overview](#script-overview)
5. [Run Examples](#run-examples)
6. [Dry-Run Mode](#dry-run-mode)
7. [Log Files](#log-files)
8. [Script Comparison: Legacy vs Modern](#script-comparison-legacy-vs-modern)

---

## Background

The EAR process is driven by Oracle Identity Manager (OIM), which is the authoritative source for terminated and transferred user accounts. OIM produces daily data files on `loim375a` under `/app/OIM/AppSupport/EAR/`. This process collects those files, extracts affected user IDs, and fans out across the Linux estate to remove any traces of those accounts.

Accounts themselves (authentication, group membership in LDAP/OUD and Active Directory) are managed elsewhere. This process handles:

- Home directory removal: `/home/<userid>` (AD-style) and `/home/<useridOUD>` (OUD-style)
- Legacy local account removal: `/etc/passwd` entries left over from pre-LDAP era
- Legacy group membership removal: user IDs embedded in `/etc/group` lines (e.g. sudoers groups)

---

## What Changed vs Legacy

### What was kept and why

| Kept | Reason |
|------|--------|
| OIM as the authoritative data source | Still the first system to report terminations/transfers |
| SCP from OIM server to collect files | Same server, same directory, same file format |
| `terms`/`trans` distinction | Terminations and transfers have different downstream implications |
| Per-run timestamped archives | Audit trail requirement unchanged |
| `/etc/group` backup before edit | Safety requirement — `group.preremove.<userid>` preserved |
| Email notification on completion | Operational requirement unchanged |
| Lock file to prevent concurrent runs | Unchanged — prevents race conditions |

### What was removed and why

| Legacy script/behaviour | Reason removed |
|------------------------|----------------|
| `userdel -r` (delete home with account) | Home cleanup now handled separately by `cleanup_homes.sh`; `-r` flag dropped to prevent double-delete race |
| `/etc/group` full line removal | Only the user ID is removed; other members preserved |
| `login-access.conf` cleanup (`groupandaccess.sh`) | No longer written for human IDs; fully managed in LDAP/AD |
| FTP-based TTIMR event reporting (`sendttimr.ksh`) | FTP delivery was already disabled in legacy scripts; TTIMR schema is retired |
| `Time.pl` (Perl date helper) | Used only by inactivity scripts; Python `datetime` will replace it when inactivity is rebuilt |
| Triple-nested loops (server × termuser × localuser) | Replaced by flat user array + pssh parallelism |
| Wildcard home removal `/home/$user*` | Replaced by exact pattern check for `/home/userid` and `/home/useridOUD` |
| Hardcoded paths scattered across 15 scripts | All paths and settings centralised in `tti.conf` |
| Stale lock file on crash | `trap` on ERR and EXIT guarantees lock release |
| Log truncated each run (no history) | Master log is append-only; working logs archived with timestamp |
| Sequential SSH to each server | Replaced by `pssh` with 75-host parallelism |

### What is deferred (not in this POC)

| Deferred | Reason |
|----------|--------|
| Inactivity workflow (`ldapinwarn`, `ldapinactive`, `ldapindelete`, `linuxinwarn`, `linuxinactive`, `linuxindelete`) | Requires confirming the correct inactivity signal (LDAP `modifytimestamp` vs AD `lastLogonTimestamp`). Will be a separate track. |

---

## Folder Layout

```
/export/home/xamrgpti/
│
├── scripts/
│   ├── tti.conf                  Central configuration — edit here only
│   ├── main.sh                   Orchestrator — called by cron
│   ├── getdata.sh                Fetches OIM files, builds ID lists
│   ├── cleanup_homes.sh          Removes home directories
│   └── cleanup_passwd_group.sh   Cleans /etc/passwd and /etc/group
│
├── data/
│   ├── terms.ids                 Current run termination IDs (one per line, lowercase)
│   ├── trans.ids                 Current run transfer IDs (one per line, lowercase)
│   │
│   ├── terms/                    Raw OIM termination files archived
│   │   └── terms.YYYYMMDDHHMM    e.g. terms.202605201130
│   │
│   ├── trans/                    Raw OIM transfer files archived
│   │   └── trans.YYYYMMDDHHMM
│   │
│   └── ids/                      Timestamped ID snapshots — one file per run
│       ├── terms.ids.YYMMDDHHMM  e.g. terms.ids.2605201130
│       └── trans.ids.YYMMDDHHMM
│
└── logs/
    ├── tti_process.log            Master append-only log — full run history
    │
    ├── linuxterms.YYMMDDHHMM     Home cleanup log for terminations (per run)
    ├── linuxtrans.YYMMDDHHMM     Home cleanup log for transfers (per run)
    ├── linuxfiles.YYMMDDHHMM     passwd/group cleanup log (per run)
    ├── linux.YYMMDDHHMM          Unreachable hosts log (per run)
    │
    └── dryrun/                   Dry-run logs — never mixed with live logs
        └── dryrun-N-YYMMDDHHMM   N increments per dry-run on the same timestamp
```

---

## Script Overview

### `tti.conf`
Central configuration sourced by every script. Contains all paths, OIM server details, pssh settings, notification target, and retention periods. **This is the only file you should need to edit** to adapt the process to a new environment.

### `main.sh`
The orchestrator. Called by cron. Acquires a lock, calls `getdata.sh`, then calls `cleanup_homes.sh` and `cleanup_passwd_group.sh` for both terms and trans modes. Archives the unreachable hosts log. Releases the lock. The `--dry-run` flag is passed through to all cleanup scripts.

### `getdata.sh`
Fetches two file types per kind (terms/trans) from `loim375a:/app/OIM/AppSupport/EAR/`:
- Raw tilde-delimited file → archived to `data/terms/` or `data/trans/`
- `.id.` pre-extracted ID file → lowercased → written as `data/terms.ids` or `data/trans.ids`

Compares the raw file to the last archive. If identical, exits with code 1 (no new data) and `main.sh` skips the run entirely.

### `cleanup_homes.sh`
For each user ID, fans out across all servers in batches of 75 via `pssh`. Checks for `/home/<userid>` and `/home/<useridOUD>`. Removes any that exist. Only logs when a home directory is actually found — zero log output for users with no homes anywhere across 22k+ hosts. Supports `--dry-run`.

### `cleanup_passwd_group.sh`
For each user ID, fans out via `pssh` to:
1. Check `/etc/passwd` for a legacy local account (exact field-1 match). If found, runs `userdel` (without `-r`).
2. Check `/etc/group` for the user ID in any group's member list. If found, backs up `/etc/group` then removes just the user ID using `sed`, leaving all other members untouched.

Supports `--dry-run`. All check commands are read-only; write commands (`userdel`, `sed`, `cp`) are skipped in dry-run mode.

---

## Run Examples

**Normal live run (called by cron):**
```bash
/export/home/xamrgpti/scripts/main.sh
```

**Manual live run:**
```bash
cd /export/home/xamrgpti/scripts
./main.sh
```

**Dry-run — see what would be cleaned without touching anything:**
```bash
./main.sh --dry-run
```

**Run a single cleanup script manually (terms, live):**
```bash
./cleanup_homes.sh --mode terms
./cleanup_passwd_group.sh --mode terms
```

**Run a single cleanup script in dry-run:**
```bash
./cleanup_homes.sh --mode terms --dry-run
./cleanup_passwd_group.sh --mode trans --dry-run
```

**Check the master log:**
```bash
tail -100 /export/home/xamrgpti/logs/tti_process.log
```

**Find all FAILURE lines in today's logs:**
```bash
grep FAILURE /export/home/xamrgpti/logs/tti_process.log
```

**Find all FOUND lines for a specific user:**
```bash
grep 'pn15145' /export/home/xamrgpti/logs/tti_process.log
```

**See what a dry-run found:**
```bash
ls /export/home/xamrgpti/logs/dryrun/
cat /export/home/xamrgpti/logs/dryrun/dryrun-1-2605201130
```

---

## Dry-Run Mode

Pass `--dry-run` to `main.sh` or directly to either cleanup script.

**What dry-run does:**
- Calls `getdata.sh` normally — OIM files are fetched and ID lists are built. This is read-only on the OIM server (SCP pull only).
- Calls `pssh` in **check-only** mode to discover which servers have home directories or legacy `/etc/passwd`/`/etc/group` entries — these remote commands are all read-only (`test -e`, `grep`).
- Logs every `FOUND` entry exactly as a live run would.
- Logs `DRY_RUN` lines describing what would have been removed.
- Does **not** call `pssh` for any write operation (`rm -rf`, `userdel`, `sed`, `cp`).

**What dry-run does NOT do:**
- Does not remove any home directories.
- Does not run `userdel` on any server.
- Does not modify or back up `/etc/group` on any server.
- Does not write to `linuxterms.*`, `linuxtrans.*`, or `linuxfiles.*` log files.

**Where dry-run logs go:**

Dry-run logs are isolated in `logs/dryrun/` so they can never be confused with live run archives. The naming convention is:

```
logs/dryrun/dryrun-N-YYMMDDHHMM
```

`N` auto-increments for each dry-run on the same minute stamp, so running multiple dry-runs back to back is safe:

```
dryrun-1-2605201130   first dry-run of the 11:30 run
dryrun-2-2605201130   second dry-run same minute
dryrun-3-2605201130   third
```

The master `tti_process.log` **is** written during dry-runs (clearly tagged `[DRY-RUN]`). This gives you a complete history of both live and dry-run activity in one place.

Dry-run logs are retained for 90 days (configurable via `DRYRUN_RETAIN_DAYS` in `tti.conf`).

---

## Log Files

### `logs/tti_process.log` — Master log
Append-only. Every run (live or dry-run) adds to this file. Never truncated. Use this for audit trails, investigating past incidents, or grepping for a specific user across all runs.

### `logs/linuxterms.YYMMDDHHMM` — Termination home cleanup
Written per live run. Contains only FOUND/SUCCESS/FAILURE entries for home directories. Silent for users with no homes found — at 22k hosts a user on only one server produces two log lines (FOUND + SUCCESS) for that path.

### `logs/linuxtrans.YYMMDDHHMM` — Transfer home cleanup
Same format as linuxterms, but for transferred users.

### `logs/linuxfiles.YYMMDDHHMM` — passwd/group cleanup
Written per live run. Contains FOUND/SUCCESS/FAILURE for `/etc/passwd` account removal and `/etc/group` membership removal. Includes the group names affected and the backup file path.

### `logs/linux.YYMMDDHHMM` — Unreachable hosts
Written per live run. One line per host that did not respond during any pssh check. Useful for identifying servers that need attention independently of the cleanup process.

### `logs/dryrun/dryrun-N-YYMMDDHHMM` — Dry-run archive
Written per dry-run. Contains FOUND and DRY_RUN entries. Never contains SUCCESS or FAILURE (since no changes are made).

### Log level reference

| Level | Meaning |
|-------|---------|
| `INFO` | Normal progress and structural milestones |
| `SUCCESS` | A write operation completed successfully |
| `FOUND` | A home dir, passwd entry, or group membership was detected |
| `CLEANUP` | _(reserved — not currently used in output)_ |
| `DRY_RUN` | What would have been done in live mode |
| `WARN` | Unexpected but non-fatal (e.g. unreachable host, empty ID file) |
| `ERROR` | Something failed; run continues |
| `FAILURE` | A specific removal attempt failed on a specific server |
| `FATAL` | Unrecoverable error; script exits immediately |
| `SUMMARY` | End-of-run statistics block |

---

## Script Comparison: Legacy vs Modern

### File count

| | Legacy | Modern |
|-|--------|--------|
| Total scripts | 15 | 4 scripts + 1 config |
| Config file | None (hardcoded per script) | `tti.conf` — single source of truth |

### Side-by-side comparison

| Behaviour | Legacy | Modern |
|-----------|--------|--------|
| **OIM data source** | SCP raw tilde file only; re-parses field 2 | SCP both raw file and `.id.` file; uses OIM's pre-extracted ID list |
| **OIM path config** | Two variables: `OIM_TERMS_PATH`, `OIM_TRANS_PATH` | One variable: `OIM_EAR_DIR` (same directory for both) |
| **Server fan-out** | Sequential SSH, one host at a time | `pssh` with 75 hosts in parallel |
| **Home dir removal** | `userdel -r` (account + home in one call) | `cleanup_homes.sh` (home only) then `cleanup_passwd_group.sh` (account only via `userdel` without `-r`) |
| **Home dir pattern** | Wildcard `/home/$user*` — could match unintended dirs | Exact patterns: `/home/userid` and `/home/useridOUD` only |
| **`/etc/passwd` cleanup** | `userdel` called as part of home loop | Separate pssh sweep; `userdel` without `-r` |
| **`/etc/group` cleanup** | Full line replaced via `grep -v` (risky if group name contains username) | Surgical `sed` removes only the ID from member list; group line preserved |
| **`/etc/group` backup** | `group.preremove.<user>` created inline | Same backup naming, created atomically via `cp` before `sed` |
| **`login-access.conf`** | Cleaned by `groupandaccess.sh` | Removed — no longer written for human IDs |
| **Inactivity workflow** | 6 scripts (ldapinwarn, ldapinactive, ldapindelete, linuxinwarn, linuxinactive, linuxindelete) | Not in this POC — separate track pending signal confirmation |
| **TTIMR FTP reporting** | `sendttimr.ksh` (already disabled) | Removed entirely |
| **Perl date helper** | `Time.pl` | Removed — bash `date` and future Python `datetime` |
| **Lock file on crash** | Left behind — manual cleanup required | `trap ERR EXIT` guarantees release on all exit paths |
| **Log format** | Free-form text, inconsistent across scripts | Structured `[timestamp] [LEVEL] [script] message` — grep-friendly |
| **Log history** | Truncated each run; no history | `tti_process.log` is append-only; per-run logs archived with timestamp |
| **Dry-run mode** | None | `--dry-run` flag — check-only pssh, no writes, isolated log directory |
| **Dry-run logs** | N/A | `logs/dryrun/dryrun-N-YYMMDDHHMM` — separate from live logs |
| **Unreachable hosts** | Logged inline with cleanup output | Isolated in `linux.YYMMDDHHMM` — separate concern |
| **No-change detection** | Runs full cleanup every day regardless | `getdata.sh` diffs against last archive; skips run if OIM data unchanged |
| **Config management** | Paths hardcoded in each script | All settings in `tti.conf`; scripts source it on startup |
