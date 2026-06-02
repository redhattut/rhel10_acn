# TTI EAR — Termination, Transfer, and Inactivity (EAR) Cleanup Process

Modern rewrite of the TTI EAR automation suite. Replaces the legacy KSH scripts from 2007 with clean, maintainable bash. Handles home directory removal, legacy `/etc/passwd` account cleanup, and `/etc/group` membership scrubbing for terminated and transferred users across the Linux server estate using parallel SSH (pssh).

---

## Table of Contents

1. [Background](#background)
2. [Folder Layout](#folder-layout)
3. [Script Overview](#script-overview)
4. [Configuration (tti.conf)](#configuration)
5. [OIM File Format](#oim-file-format)
6. [Log Files](#log-files)
7. [Email Notification](#email-notification)
8. [Run Examples](#run-examples)
9. [Dry-Run Mode](#dry-run-mode)
10. [Targeted Testing (custom IDs and hosts)](#targeted-testing)
11. [Cron Schedule](#cron-schedule)
12. [What Changed vs Legacy](#what-changed-vs-legacy)

---

## Background

The EAR process is driven by Oracle Identity Manager (OIM), which is the authoritative source for terminated and transferred user accounts. OIM produces daily data files on `loim375a` under `/app/OIM/AppSupport/EAR/`. This process collects those files, extracts affected user IDs, and fans out across the Linux estate via pssh to remove any traces of those accounts.

Account authentication and group membership in LDAP/OUD and Active Directory are managed elsewhere. This process handles:

- Home directory removal: `/home/<userid>` (AD-style) and `/home/<useridOUD>` (OUD-style)
- Legacy local account removal: `/etc/passwd` entries left over from pre-LDAP era
- Legacy group membership removal: user IDs embedded in `/etc/group` lines (e.g. sudoers groups)

---

## Folder Layout

```
/export/home/xamrgpti/
│
├── scripts/
│   ├── tti.conf          Central configuration — edit here only
│   ├── main.sh           Orchestrator — called by cron
│   ├── getdata.sh        Fetches OIM files, builds ID lists
│   └── cleanup.sh        Combined: home dirs + /etc/passwd + /etc/group (one SSH per server)
│
├── data/
│   ├── terms.ids         Current run termination IDs (one per line, lowercase)
│   ├── trans.ids         Current run transfer IDs (one per line, lowercase)
│   ├── terms/            Raw OIM termination files archived from loim375a
│   │   └── terms.YYYYMMDDHHMM
│   ├── trans/            Raw OIM transfer files archived from loim375a
│   │   └── trans.YYYYMMDDHHMM
│   └── ids/              Timestamped ID snapshots — one file per run
│       ├── terms.ids.YYMMDDHHMM
│       └── trans.ids.YYMMDDHHMM
│
└── logs/
    │
    │   Working logs — overwritten at the start of every run
    ├── tti_process.log           Full run log (main.sh + all subscripts)
    ├── tti_cleanup.log           cleanup.sh output only (body of completion email)
    ├── tti_getdata.log           getdata.sh output only
    ├── tti_unreachable.log       Hosts that did not respond this run
    │
    │   Timestamped archives — one per run, never overwritten
    ├── linuxterms.YYMMDDHHMM    Cleanup log for terminations
    ├── linuxtrans.YYMMDDHHMM    Cleanup log for transfers
    └── linux.YYMMDDHHMM         Unreachable hosts for that run
    │
    └── dryrun/                   All dry-run logs — never mixed with live
        │   Working logs — overwritten at start of every dry-run
        ├── dryrun_tti_process.log
        ├── dryrun_tti_cleanup.log
        ├── dryrun_tti_getdata.log
        ├── dryrun_tti_unreachable.log
        │
        │   Timestamped archives — one per dry-run, never overwritten
        ├── dryrun_linuxterms.YYMMDDHHMM
        ├── dryrun_linuxtrans.YYMMDDHHMM
        └── dryrun_linux.YYMMDDHHMM
```

---

## Script Overview

### `tti.conf`
Central configuration sourced by every script. All paths, OIM server details, pssh settings, notification target, and retention periods. **This is the only file you should need to edit** to adapt the process to a new environment.

### `main.sh`
The orchestrator. Called by cron daily. Acquires a lock, truncates working logs (fresh start), calls `getdata.sh`, then calls `cleanup.sh` for both terms and trans modes. Archives the unreachable hosts log. Sends a completion email. Releases the lock.

### `getdata.sh`
Fetches two file types per kind (terms/trans) from `loim375a:/app/OIM/AppSupport/EAR/`:
- Raw tilde-delimited file → archived to `data/terms/` or `data/trans/`
- `.id.` pre-extracted ID file → lowercased → written as `data/terms.ids` or `data/trans.ids`

Compares the raw file to the last archive. If identical, still writes `terms.ids` from the existing `.id.` file so cleanup always runs — it only skips archiving the raw file, not the cleanup job.

### `cleanup.sh`
The core cleanup engine. For each server in the host list (in parallel batches of 75 via pssh), runs a single SSH session that checks and acts on all user IDs for all three cleanup tasks at once:

1. **Home directories** — checks `/home/<userid>` and `/home/<useridOUD>`, removes any that exist
2. **`/etc/passwd`** — checks for a legacy local account (exact field-1 match), runs `userdel` if found
3. **`/etc/group`** — checks member lists for the user ID, backs up and patches the file with `sed` if found

One pssh invocation per batch = one SSH connection per server per batch, regardless of how many users are in the list.

---

## Configuration

All settings in `scripts/tti.conf`. Key values:

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_DIR` | `/export/home/xamrgpti` | Root of the entire process |
| `OIM_HOST` | `loim375a` | OIM server to SCP files from |
| `OIM_EAR_DIR` | `/app/OIM/AppSupport/EAR` | Directory on OIM server |
| `SERVER_LIST` | `/usr/local/bin/hosts.linux.nonfed.txt` | One hostname per line |
| `PSSH_BIN` | `/usr/local/pssh/bin/pssh` | Path to pssh binary |
| `PSSH_LOGIN` | `root` | Remote user for pssh connections |
| `PSSH_BATCH` | `75` | Hosts in parallel per pssh call |
| `PSSH_TIMEOUT` | `30` | Per-host timeout in seconds |
| `NOTIFY` | `ttinotify` | Mail alias for notifications |
| `DRYRUN_LOGS_DIR` | `logs/dryrun` | Isolated directory for all dry-run logs |

---

## OIM File Format

Four files produced per run under `/app/OIM/AppSupport/EAR/` on `loim375a`:

**`terms.id.YYYYMMDDHHMMSS`** — pre-extracted termination IDs, one uppercase ID per line:
```
SA48980
PL54191
PN15145
```

**`terms.YYYYMMDDHHMMSS`** — raw tilde-delimited termination data:
```
2026-05-20~SA48980~Doe, John A~00001~RETAIL BANKING~OH - NDR~Unknown~Smith, Jane~Unknown~
2026-05-20~PL54191~Reyes, Maria~00001~SHARED SERVICES~PA - PHL~Unknown~Brown, David~Unknown~
```

`trans.id.*` and `trans.*` follow the same format for transferred users.

`getdata.sh` uses the `.id.` files for the ID list (OIM pre-extracts them) and archives the raw files for audit. IDs are always lowercased before use since Linux home directories and passwd entries are lowercase.

---

## Log Files

### Working logs — overwritten every run

| File | Contents |
|------|----------|
| `logs/tti_process.log` | Full run — all scripts, all steps. Most useful for debugging and run history. |
| `logs/tti_cleanup.log` | cleanup.sh output only — all SUCCESS/FAILURE/DRY_RUN lines plus the SUMMARY block. This is the body of the completion email. |
| `logs/tti_getdata.log` | getdata.sh output only — OIM fetch, archive, and ID normalization. |
| `logs/tti_unreachable.log` | One line per host that did not respond during this run. |

### Timestamped archives — one per run, never overwritten

| File | Contents |
|------|----------|
| `logs/linuxterms.YYMMDDHHMM` | Copy of tti_cleanup.log from the terms run |
| `logs/linuxtrans.YYMMDDHHMM` | Copy of tti_cleanup.log from the trans run |
| `logs/linux.YYMMDDHHMM` | Copy of tti_unreachable.log for that run |

### Dry-run logs in `logs/dryrun/`

Same files with `dryrun_` prefix. Working logs are overwritten each dry-run. Timestamped archives use `dryrun_linuxterms.STAMP` and `dryrun_linuxtrans.STAMP`. Live logs are never touched.

### Log level reference

| Level | Meaning |
|-------|---------|
| `INFO` | Normal progress and structural milestones |
| `SUCCESS` | A write operation completed successfully |
| `DRY_RUN` | What would have been done in live mode |
| `WARN` | Unexpected but non-fatal (unreachable host, empty ID file) |
| `FAILURE` | A specific removal attempt failed on a specific server |
| `ERROR` | Something failed; run may continue |
| `FATAL` | Unrecoverable — script exits immediately |
| `SUMMARY` | End-of-run statistics block |

---

## Email Notification

Email is sent at **run completion** (after all cleanup steps finish) using `mailx`.

**Format:**
- **Subject:** `TTI EAR Cleanup Report — hostname — date [DRY-RUN if applicable]`
- **Body:** Short human-readable summary of counts extracted from the SUMMARY log lines
- **Attachment:** Full `tti_cleanup.log` (or dryrun equivalent) for detailed review

The body is intentionally kept short so it is readable in any mail client regardless of how many servers or users were processed. The full detail is in the attachment.

**Example body — normal run with terms and no trans:**
```
TTI EAR Cleanup Report
Host     : lmrg34la
Date     : 2026-06-02 11:33
=========================================

Terminations:
  User IDs          : 52
  Servers in scope  : 22468
  Hosts reached     : 22441
  Unreachable hosts : 27
  Home dirs removed : 8
  Home dirs failed  : 1
  /etc/passwd removed : 2
  /etc/group  removed : 3

Transfers:
  No transfers to process today.

=========================================
Full cleanup log attached.
```

**Example body — nothing to process (both OIM files empty):**
```
TTI EAR Cleanup Report
Host     : lmrg34la
Date     : 2026-06-02 11:33
=========================================

No terminations or transfers to process today.
OIM files were empty for this run.

No cleanup log to attach.
```
When both are empty, no attachment is sent.

**How it works:** `mailx` uses the system local MTA (sendmail/postfix). `ttinotify` is a local mail alias defined in `/etc/aliases` on the TTI server. Mail is sent as the Unix user running the script (root via sudo).

**To change recipients:** edit `/etc/aliases`, add or modify the `ttinotify` entry, then run `newaliases` to apply.

```
# /etc/aliases example
ttinotify: user1@company.com, user2@company.com, team-dl@company.com
```

**To disable email for a single run:** pass `--no-email` flag. Email is enabled by default.

---

## Run Examples

**Normal cron run:**
```bash
/export/home/xamrgpti/scripts/main.sh
```

**Dry-run — see what would be cleaned without touching anything:**
```bash
./main.sh --dry-run
```

**Dry-run, suppress email:**
```bash
./main.sh --dry-run --no-email
```

**Check today's results:**
```bash
cat /export/home/xamrgpti/logs/tti_process.log
```

**Find all failures:**
```bash
grep FAILURE /export/home/xamrgpti/logs/tti_cleanup.log
```

**Find everything touched for a specific user:**
```bash
grep 'sa48980' /export/home/xamrgpti/logs/tti_cleanup.log
```

**See which hosts were unreachable:**
```bash
cat /export/home/xamrgpti/logs/tti_unreachable.log
```

**Compare today's cleanup to yesterday's:**
```bash
diff logs/linuxterms.2605201120 logs/linuxterms.2605191120
```

---

## Dry-Run Mode

Pass `--dry-run` to `main.sh` or directly to `cleanup.sh`.

**What dry-run does:**
- Fetches OIM files and builds ID lists (read-only SCP from OIM server)
- Runs pssh to check every server — `test -e`, `grep` — all read-only
- Logs `DRY_RUN` lines describing what would have been removed/deleted
- Does **not** call `rm -rf`, `userdel`, or `sed` on any server

**What dry-run does NOT touch:**
- `logs/tti_process.log` — never written
- `logs/tti_cleanup.log` — never written
- `logs/tti_unreachable.log` — never written
- `logs/linuxterms.*` or `logs/linuxtrans.*` — never written
- Any file on any remote server

**All dry-run output goes to `logs/dryrun/`:**

```
logs/dryrun/dryrun_tti_process.log       — overwritten each dry-run
logs/dryrun/dryrun_tti_cleanup.log       — overwritten each dry-run
logs/dryrun/dryrun_tti_getdata.log       — overwritten each dry-run
logs/dryrun/dryrun_tti_unreachable.log   — overwritten each dry-run
logs/dryrun/dryrun_linuxterms.STAMP      — timestamped archive
logs/dryrun/dryrun_linuxtrans.STAMP      — timestamped archive
logs/dryrun/dryrun_linux.STAMP           — timestamped unreachable archive
```

---

## Targeted Testing

Use `--ids-file` and `--hosts-file` to test against a known set of users and servers before running against the full estate.

**Create test files:**
```bash
# Users you know have homes to clean up
cat > /tmp/test.ids << 'EOF'
sa48980
pl54191
EOF

# Servers you know those homes exist on
cat > /tmp/test.hosts << 'EOF'
lcdo322a
lcdo323a
lcdo317a
EOF
```

**Dry-run against just those:**
```bash
./cleanup.sh --mode terms --dry-run \
    --ids-file /tmp/test.ids \
    --hosts-file /tmp/test.hosts
```

**Verify SSH connectivity first:**
```bash
./cleanup.sh --mode terms --dry-run \
    --ids-file /tmp/test.ids \
    --hosts-file /tmp/test.hosts \
    --debug-pssh
```

**Live run once dry-run confirms:**
```bash
./cleanup.sh --mode terms \
    --ids-file /tmp/test.ids \
    --hosts-file /tmp/test.hosts
```

**Notes:**
- IDs in the file can be uppercase or lowercase — they are normalized to lowercase automatically
- `--ids-file` and `--hosts-file` can be used independently (override one or both)
- Dry-run still applies — `--ids-file` without `--dry-run` will make live changes
- The log shows `[CUSTOM]` next to overridden paths so targeted runs are clearly identifiable

---

## Cron Schedule

```cron
# Main run — daily at 11:20
20 11 * * * /export/home/xamrgpti/scripts/main.sh >> /dev/null 2>&1

# Retention — daily at 23:00
0 23 * * * find /export/home/xamrgpti/data/terms    -type f -mtime +365 -delete
0 23 * * * find /export/home/xamrgpti/data/trans    -type f -mtime +365 -delete
0 23 * * * find /export/home/xamrgpti/logs          -maxdepth 1 -type f -mtime +365 -delete
0 23 * * * find /export/home/xamrgpti/data/ids      -type f -mtime +730 -delete
0 23 * * * find /export/home/xamrgpti/logs/dryrun   -type f -mtime +90  -delete
```

---

## What Changed vs Legacy

### Script count

| | Legacy | Modern |
|-|--------|--------|
| Total scripts | 15 | 3 scripts + 1 config |
| SSH sessions per cleanup run | 22,000 × users × 2 patterns | 22,000 (one per server, all users + all tasks) |
| Config file | None (hardcoded per script) | `tti.conf` — single source of truth |

### What was removed and why

| Legacy | Reason removed |
|--------|---------------|
| `userdel -r` (deletes home with account) | Home cleanup handled separately in same SSH call |
| `/etc/group` full-line removal via `grep -v` | Replaced with surgical `sed` — other members preserved |
| `login-access.conf` cleanup | No longer written for human IDs; fully in LDAP/AD |
| `sendttimr.ksh` FTP event reporting | FTP already disabled in legacy; TTIMR schema retired |
| `Time.pl` Perl date helper | Not needed; bash `date` used throughout |
| Triple-nested loops per server | Replaced with pssh: one connection per server for all users |
| Wildcard `/home/$user*` removal | Exact patterns only: `/home/userid` and `/home/useridOUD` |
| Hardcoded paths in every script | All in `tti.conf` |
| Stale lock file on crash | `trap ERR EXIT` guarantees release |
| Append-only logs (history mixed with current run) | Working logs truncated each run; history in timestamped archives |
| No dry-run mode | Full `--dry-run` with isolated `logs/dryrun/` directory |

### What is deferred (not in this release)

| Deferred | Reason |
|----------|--------|
| Inactivity workflow (ldapinwarn, ldapinactive, etc.) | Requires confirming inactivity signal — separate track |
