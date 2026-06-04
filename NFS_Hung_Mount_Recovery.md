# NFS Hung Mount Recovery

## Background

During network switch upgrades, a brief outage of 30–60 seconds occurs when the
second switch is brought down before the first upgraded switch is ready to take
traffic. Servers that had NFS traffic in-flight at that moment end up with stale
kernel connections. Once the network comes back, those connections cannot
reconnect on their own — the mountpoint appears to exist but any operation
against it (`ls`, `stat`, `df`) hangs indefinitely. This is referred to as a
**hung mount**.

The servers most likely to be affected are those that were actively using their
NFS shares at the time of the outage. Servers with idle mounts typically
reconnect without issue.

---

## What causes the hang

NFS uses stateful TCP connections to the NAS. When the network drops mid-session
the kernel keeps the connection open waiting for it to resume. When the network
returns, the NAS has no record of the old connection (it was dropped) and the
server's kernel has a stale socket it cannot use. The mountpoint is still listed
in `/proc/mounts` and `df` but the kernel cannot satisfy any I/O requests against
it. The only way to clear it is to forcibly detach the mount and re-establish a
fresh connection.

---

## Script overview

**Script:** `nfs_remount.sh`

This is a standalone bash script. It uses `pssh` to fan out to all servers in
the provided host list in parallel, runs a detection and recovery routine on each
server, collects tagged output tokens, and produces a summary with per-server
per-mount results. No configuration files, no companion scripts, and no
subdirectories are required. Drop it anywhere, `chmod +x` it, and run it.

### How it works

The script runs in two layers.

**On the jumphost** — the main script reads a server list, builds a remote
script once, and fans it out to all servers via `pssh -I` (stdin pipe, same
pattern as TTI cleanup jobs). As output streams back, a parser reads tagged
token lines and updates counters and log files.

**On each remote server** — a small bash script runs locally via `bash -s`. It
uses `findmnt` to get the list of NFS mounts from the kernel (this never hangs
regardless of mount state), then runs a timed `stat` against each mountpoint. If
`stat` returns within the timeout, the mount is alive. If it times out, the mount
is hung. For hung mounts it determines the recovery method, performs the remount,
and verifies recovery with another timed `stat`. Every event is printed as a
tagged token line that the jumphost parser processes.

### Recovery method logic

For each hung mount the remote script checks two things in order:

1. Is the mountpoint in `/etc/fstab`? If yes — method is `fstab`. Recovery is
   `umount -lf` followed by `mount /mountpoint`.

2. Does systemd have a loaded `.mount` unit for this path? If yes — method is
   `systemd`. Recovery is `umount -lf` followed by `systemctl start unit.mount`.

3. Neither — method is `unknown`. The mount is skipped and flagged for manual
   review.

The fstab check runs first because systemd auto-generates `.mount` units for
fstab entries, so `LOAD_STATE=loaded` alone does not distinguish a real systemd
unit from a generated one.

### Why no `systemctl stop` before unmounting

The original playbook used `systemctl stop` before `umount -lf`. If a systemd
unit is hung, `systemctl stop` blocks waiting for the unit to deactivate — which
it cannot do while the mount is hung. This caused recovery jobs to stall for
several seconds per server when run serially across hundreds of hosts. This
script skips directly to `umount -lf`, which clears the stale kernel connection
without going through systemd. `systemctl start` then brings the unit back
cleanly.

### pssh pattern

The script uses the same pssh invocation pattern as TTI cleanup jobs:

```
pssh -I --inline-stdout -p <batch> -t <timeout> -l root -h <hostfile> bash
```

- `-I` — reads the script from stdin, no file copy needed on remote hosts
- `--inline-stdout` — merges all host output into a single stream
- Remote script prints `HOST:$(hostname)` first so the parser knows which host
  produced each subsequent line

### Output tokens

The remote script communicates with the jumphost parser via tagged lines. Every
line follows the pattern `TOKEN:data`.

| Token | Meaning |
|---|---|
| `HOST:<hostname>` | Self-identification — sets host context for lines that follow |
| `NFS_NONE` | No NFS mounts found on this server |
| `MOUNT_OK:<path>` | Mount responded to stat within timeout — healthy |
| `MOUNT_DRY:<path>:<method>` | Dry-run only — mount is hung, would recover via method |
| `MOUNT_HUNG:<path>:<method>` | Live run — hung mount detected, recovery starting |
| `RECOVERED:<path>:<method>` | Recovery successful — post-remount stat passed |
| `STILL_HUNG:<path>:<method>` | Recovery attempted but post-remount stat still timed out |
| `SKIPPED:<path>` | Hung but not in fstab and no loaded systemd unit — manual action needed |

### Log files

Both log files are written to the same directory as the script. The timestamp
suffix (`YYMMDDHHNN`) makes each run uniquely identifiable.

| File | Contents |
|---|---|
| `nfs_remount.YYMMDDHHNN` | Full timestamped log of all events for this run |
| `nfs_remount_dryrun.YYMMDDHHNN` | Same, but produced during a dry-run |
| `nfs_remount_hung.YYMMDDHHNN` | Only hung and failed mounts — handoff file for escalation |

The hung log is only created if there is something to put in it. If all mounts
recover cleanly it is removed at the end of the run.

### Options

| Option | Description | Default |
|---|---|---|
| `--hosts /path/file` | Server list, one hostname per line | Required |
| `--dry-run` | Detect only, make no changes | Off |
| `--timeout N` | Seconds before a mount is declared hung | 5 |
| `--batch N` | pssh parallel batch size | 75 |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All servers reached, no hung mounts remaining |
| `1` | One or more mounts still hung after recovery attempt |
| `2` | Fatal error — hosts file not found, pssh not found |

---

## Workflow

The standard workflow is three steps. Do not skip step 1 — it establishes what
is hung before anything is touched, which is important if you need to report
exactly what was affected.

### Prerequisites

- Script is on the jumphost and executable (`chmod +x nfs_remount.sh`)
- A host list file exists with one server per line (provided by the network team
  or pulled from the change ticket)
- pssh is available at `/usr/local/pssh/bin/pssh`
- Root SSH key access to target servers is in place (same as TTI jobs)

### Step 1 — detect (before or immediately after the change window)

Run a dry-run first. This touches nothing on any server. It tells you exactly
which servers have hung mounts, which mountpoints are affected, and what recovery
method would be used for each.

```bash
./nfs_remount.sh --hosts /tmp/weekend_servers.txt --dry-run
```

Review the output. Every `[DRY-RUN]` line is a hung mount that needs recovery.
The summary shows the total count. If the count is zero before the change window,
use this output as your baseline confirmation that everything was healthy going
in.

### Step 2 — recover (after the change window, once the network is back)

Run without `--dry-run`. The script fans out to all servers in parallel. For
each hung mount it immediately force-unmounts (`umount -lf`) and remounts, then
verifies with a second `stat` check. Results appear per-server per-mount as they
stream back.

```bash
./nfs_remount.sh --hosts /tmp/weekend_servers.txt
```

Watch for `[RECOVERED]` and `[FAILED]` lines as output streams. The summary at
the end shows the final counts.

### Step 3 — confirm (re-run dry-run after recovery)

Re-run the dry-run. If everything recovered, the hung count will be zero and all
mounts will show `[OK]`. This is your sign-off — the output of this run is what
you show the other team's manager to confirm the environment is clean.

```bash
./nfs_remount.sh --hosts /tmp/weekend_servers.txt --dry-run
```

If any `[DRY-RUN]` lines still appear after the live run, those mounts did not
recover automatically and require manual intervention (see below).

---

## Ideal scenario — full output for all three steps

This is the expected output for the typical case: hung mounts are detected,
recovered automatically, and confirmed clean.

### Step 1 — dry-run, hung mounts detected

```
------------------------------------------------------------
 NFS Hung Mount Recovery
------------------------------------------------------------
  MODE     : DRY RUN — detection only, no changes will be made
  Hosts    : 5  (/tmp/weekend_servers.txt)
  Timeout  : 5s per mount stat check
  Batch    : 75 hosts in parallel
  Log      : /opt/mrgtools/nfs_remount_dryrun.2606072314
------------------------------------------------------------

 Scanning servers...

  [OK]        prod-app-01  /mnt/nas/data
  [OK]        prod-app-01  /mnt/nas/logs
  [DRY-RUN]   prod-app-02  /mnt/nas/data  [fstab]  -> would unmount + remount
  [DRY-RUN]   prod-db-01   /mnt/nas/backups  [systemd]  -> would unmount + remount
  [DRY-RUN]   prod-db-02   /mnt/nas/backups  [fstab]  -> would unmount + remount
  [OK]        prod-batch-01  /mnt/nas/input
  [DRY-RUN]   prod-batch-01  /mnt/nas/output  [systemd]  -> would unmount + remount

------------------------------------------------------------
 Summary
------------------------------------------------------------
  DRY RUN — no changes were made

  Servers in scope:            5
  Reached via SSH:             5
  Unreachable:                 0
  No NFS mounts:               0
  Mounts responsive:           3

  Hung mounts detected: 4
  Re-run without --dry-run to recover them.
------------------------------------------------------------

  Full log : /opt/mrgtools/nfs_remount_dryrun.2606072314
  Hung log : /opt/mrgtools/nfs_remount_hung.2606072314
```

### Step 2 — live recovery run

```
------------------------------------------------------------
 NFS Hung Mount Recovery
------------------------------------------------------------
  MODE     : LIVE — hung mounts will be recovered
  Hosts    : 5  (/tmp/weekend_servers.txt)
  Timeout  : 5s per mount stat check
  Batch    : 75 hosts in parallel
  Log      : /opt/mrgtools/nfs_remount.2606072315
------------------------------------------------------------

 Scanning servers...

  [OK]        prod-app-01  /mnt/nas/data
  [OK]        prod-app-01  /mnt/nas/logs
  [HUNG]      prod-app-02  /mnt/nas/data  [fstab]
  [HUNG]      prod-db-01   /mnt/nas/backups  [systemd]
  [HUNG]      prod-db-02   /mnt/nas/backups  [fstab]
  [OK]        prod-batch-01  /mnt/nas/input
  [HUNG]      prod-batch-01  /mnt/nas/output  [systemd]
  [RECOVERED] prod-app-02  /mnt/nas/data  [fstab]
  [RECOVERED] prod-db-01   /mnt/nas/backups  [systemd]
  [RECOVERED] prod-db-02   /mnt/nas/backups  [fstab]
  [RECOVERED] prod-batch-01  /mnt/nas/output  [systemd]

------------------------------------------------------------
 Summary
------------------------------------------------------------
  Servers in scope:            5
  Reached via SSH:             5
  Unreachable:                 0
  No NFS mounts:               0
  Mounts responsive:           3
  Hung mounts found:           4
  Successfully recovered:      4
  Still hung after recovery:   0

  All hung mounts recovered successfully.
------------------------------------------------------------

  Full log : /opt/mrgtools/nfs_remount.2606072315
```

### Step 3 — dry-run confirmation, all clear

```
------------------------------------------------------------
 NFS Hung Mount Recovery
------------------------------------------------------------
  MODE     : DRY RUN — detection only, no changes will be made
  Hosts    : 5  (/tmp/weekend_servers.txt)
  Timeout  : 5s per mount stat check
  Batch    : 75 hosts in parallel
  Log      : /opt/mrgtools/nfs_remount_dryrun.2606072316
------------------------------------------------------------

 Scanning servers...

  [OK]        prod-app-01  /mnt/nas/data
  [OK]        prod-app-01  /mnt/nas/logs
  [OK]        prod-app-02  /mnt/nas/data
  [OK]        prod-db-01   /mnt/nas/backups
  [OK]        prod-db-02   /mnt/nas/backups
  [OK]        prod-batch-01  /mnt/nas/input
  [OK]        prod-batch-01  /mnt/nas/output

------------------------------------------------------------
 Summary
------------------------------------------------------------
  DRY RUN — no changes were made

  Servers in scope:            5
  Reached via SSH:             5
  Unreachable:                 0
  No NFS mounts:               0
  Mounts responsive:           7

  No hung mounts detected. All NFS mounts are responsive.
------------------------------------------------------------

  Full log : /opt/mrgtools/nfs_remount_dryrun.2606072316
```

Step 3 with zero hung mounts is your confirmation to close the incident and
present to the other team's manager.

---

## Output reference

### What each status line means

| Status | What happened | Action needed |
|---|---|---|
| `[OK]` | Mount responded to stat within timeout | None |
| `[DRY-RUN]` | Mount is hung, dry-run mode — no changes made | Run without `--dry-run` |
| `[HUNG]` | Hung mount detected, recovery starting | Watch for `[RECOVERED]` or `[FAILED]` |
| `[RECOVERED]` | Force unmount and remount succeeded | None |
| `[FAILED]` | Recovery attempted but mount still hung after remount | Manual action required — see below |
| `[SKIPPED]` | Hung but not in fstab and no loaded systemd unit | Manual action required — see below |
| `[WARN]` | Server unreachable via SSH | Verify server is up, re-run against that host |

---

## Manual action — when `[FAILED]` appears

If `[FAILED]` appears after a live run it means the script ran `umount -lf` and
the appropriate remount command, but a follow-up `stat` still timed out. At that
point automated recovery has done everything it can on the client side. One of
two things is preventing recovery:

**The NAS or NFS export is not responding.** The mount can be force-unmounted but
there is nothing to remount against. Check the NAS directly and confirm the
export is healthy and reachable from the affected server before attempting a
manual remount.

**A process is holding the mount open in an uninterruptible sleep state.** Even
`umount -lf` defers rather than completes if a process has an open file handle
on the mount and is stuck in kernel I/O wait (`D` state in `ps`). Find and kill
that process first, then the lazy unmount will complete and you can remount.

On the affected server:

```bash
# Find what is holding the mount open
fuser -m /mountpoint
lsof +D /mountpoint

# After killing the blocking process, force unmount and remount manually
umount -lf /mountpoint

# fstab mount
mount /mountpoint

# systemd mount (replace path separators with dashes)
systemctl start mnt-nas-backups.mount
```

The `nfs_remount_hung.*` log file next to the script contains only the failed
entries with server name, mountpoint, and method — use it as the checklist for
manual follow-up.

---

## Interpreting the log files

### Full run log — `nfs_remount.YYMMDDHHNN`

Every event is written with a timestamp and level tag.

```
[2026-06-07 23:14:01] [INFO      ] nfs_remount.sh start  dry_run=false  stat_timeout=5s
[2026-06-07 23:14:01] [INFO      ] Hosts file : /tmp/weekend_servers.txt  (5 servers)
[2026-06-07 23:14:06] [OK        ] prod-app-01: /mnt/nas/data — responsive
[2026-06-07 23:14:11] [HUNG      ] prod-app-02: /mnt/nas/data is HUNG (method=fstab) — attempting recovery
[2026-06-07 23:14:12] [RECOVERED ] prod-app-02: /mnt/nas/data RECOVERED (method=fstab)
[2026-06-07 23:14:17] [HUNG      ] prod-db-01: /mnt/nas/backups is HUNG (method=systemd) — attempting recovery
[2026-06-07 23:14:18] [RECOVERED ] prod-db-01: /mnt/nas/backups RECOVERED (method=systemd)
[2026-06-07 23:14:22] [SUMMARY   ] Recovered             : 4
[2026-06-07 23:14:22] [SUMMARY   ] Still hung            : 0
```

### Hung mount log — `nfs_remount_hung.YYMMDDHHNN`

Only contains entries for mounts that were still hung at the end of the run.
This file is the handoff artifact — give it to whoever is handling manual
follow-up. It is deleted automatically if empty.

```
prod-db-01: /mnt/nas/backups STILL HUNG after recovery attempt (method=systemd)
prod-batch-01: /mnt/nas/input STILL HUNG after recovery attempt (method=systemd)
```

---

## Quick reference

```
# Detect only — no changes
./nfs_remount.sh --hosts /tmp/weekend_servers.txt --dry-run

# Recover hung mounts
./nfs_remount.sh --hosts /tmp/weekend_servers.txt

# Confirm all clear
./nfs_remount.sh --hosts /tmp/weekend_servers.txt --dry-run

# Tighter timeout if network is known-fast
./nfs_remount.sh --hosts /tmp/weekend_servers.txt --timeout 3

# Check logs next to the script
ls -lt /opt/mrgtools/nfs_remount*
```
