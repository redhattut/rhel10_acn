# CompleteBuild2 — CSV-driven bare metal build pipeline

Rewrite of the old Excel/split.sh-based `CompleteBuild` pipeline, driven by
the single combined CSV exported from the **Bare Metal Server Build
Template** web tool instead of a 3-worksheet Excel file.

## Where this lives

```
/staging/BareMetalBuilds/CompleteBuild2/     <- on lmrg34ja
├── bin/build.sh              entrypoint
├── bin/build_server.sh        per-server orchestrator (backgrounded)
├── lib/                       shared functions
│   └── iso_gen.sh              assembles the bootable ISO — see below
├── templates/                 kickstart templates
├── csv/incoming/              <- upload your exported CSV here
├── csv/archive/                timestamped copy kept automatically
├── work/<job_name>/            parsed per-server state for one job
└── logs/<job_name>/            per-server logs + job summary + results.csv
```

## Two hosts are involved, not one

`lmrg34ja` runs the orchestration (`build.sh`/`build_server.sh`) — same as
before. But the actual RHEL installer boot binaries (`vmlinuz`, `initrd.img`,
`isolinux.bin`, etc.) and the `tmpiso` staging area where per-server bootable
ISOs get assembled live under `/mnt/installs/kickstart/SERVERS/` on
**`lmrg34ga`**, a separate host — that's exactly where the old
`create_ks_rhel8_dell.sh`/`create_ks_rhel8_cisco.sh` scripts lived too, and
`lib/iso_gen.sh` preserves that same SSH hop rather than assuming everything
is local to `lmrg34ja`.

## Running a build

```
scp BDP-cedar-20260729-482.csv lmrg34ja:/staging/BareMetalBuilds/CompleteBuild2/csv/incoming/
ssh lmrg34ja
cd /staging/BareMetalBuilds/CompleteBuild2
./bin/build.sh BDP-cedar-20260729-482.csv
```

The job name is taken automatically from the CSV filename (minus its
extension) — no second argument needed. This matches the filename the web
tool already produces when you click Download, so in practice it's just:
upload the file the tool gave you, run `build.sh` with that same filename.

`build.sh` archives the CSV, parses it with `csv_split.py`, and launches one
backgrounded `build_server.sh` per server — same parallel-dispatch model the
old `build_wrapper.sh` used.

## Watching progress / results

```
tail -f logs/<job_name>/*.log                 # live per-server detail
cat logs/<job_name>/results.csv                # one line per server: pass/fail
cat logs/<job_name>/job-summary.log            # every event, all servers, one file
```

`results.csv` is the thing to check at the end of a batch run — it's a
comma-separated `timestamp,hostname,status,detail` line per server,
written once each server finishes (or dies), so you don't have to grep
through every individual log to know what actually landed.

**See `logs/EXAMPLE-BDP-cedar-20260729-482/` for what real output looks
like** — a worked example of a 2-server job (one Dell, one Cisco) showing
the full lifecycle: dispatch, hardware bring-up, kickstart generation, ISO
assembly, install wait, post-install disk configuration, and completion.

## What changed from the old pipeline, and why

- **One CSV instead of three Excel worksheets.** `csv_split.py` replaces
  `split.sh`. Python's `csv` module handles quoted fields with embedded
  commas natively — no more colon-collapsing tricks for multi-value cells.
- **Collapsed the CGI relay chain.** Old flow: kickstart `%post` → `curl` →
  `post_config.cgi` → `post_config.sh` → SSH to a second jumpbox →
  `post_build.sh`. New flow: `build_server.sh` just waits for SSH and calls
  the post-install functions directly, on `lmrg34ja`, in the same process —
  one continuous log per server instead of state split across three scripts
  on two hosts.
- **Standardized RAID job creation.** The old `dell_functions` mixed
  `--realtime` and `-r pwrcycle` across different functions (`remove_vdisk`
  and `make_raid` used `--realtime`, `create_vdiskos` used `-r pwrcycle`).
  Every job creation here goes through `create_racadm_job`/
  `wait_for_racadm_job` in `common.sh`, consistently using `-r pwrcycle`.
  **This was a guess based on the audit of the old code, not something
  verified against a real iDRAC10 unit — see Open Items.**
- **Kickstart logvol block is generated from the CSV**, not from 8 fixed
  `sed` tokens. Supports the same variable-length core/extra filesystem
  model the web tool produces. Fixed `toolsvg` volumes and (RHEL9-only)
  `rootvg` extras are appended unconditionally, in the same order/sizes the
  web tool's lsblk preview shows — what a builder previews before export is
  what actually gets built.
- **`/boot/PNC_PROVISION_CONFIG` now gets populated** with real `LOCATION`/
  `CIDEVICE` values derived from the CSV's Datacenter field.
- **Fixed the plaintext root password issue.** Old templates had
  `rootpw "Pnc1234$"` in plaintext, served over anonymous HTTP. This build
  uses a pre-hashed password (`ROOTPW_HASH` in `lib/kickstart_gen.sh` — edit
  that value directly with `openssl passwd -6` output) instead — a hash,
  never plaintext, in the `.ks` file.
- **Satellite registration is deliberately NOT part of this pipeline.**
  See "Package source" below for the full reasoning — net effect is this
  pipeline never holds Satellite credentials and never calls
  `subscription-manager`; that happens downstream, triggered by GOMP.
- **GOMP submission preserved as-is** (`gomp_submit` in `post_install.sh`) —
  real, live CMDB integration, not legacy cruft.
- **ISO assembly is now its own module** (`lib/iso_gen.sh`), separate from
  kickstart *content* generation. It stages the RHEL installer boilerplate,
  writes `isolinux.cfg` (Legacy) or `EFI/BOOT/grub.cfg` (UEFI) with the
  correct kernel append line — bonded (`bond=bond0:[MAC]:mode=802.3ad,...`)
  or single-NIC (`ifname=NIC:MAC`) depending on the server's LACP setting —
  and runs `mkisofs`. The old scripts had this logic too, just entangled
  with the kickstart-token substitution; separating it made the LACP
  branching and the RHEL-version/boot-mode template selection each testable
  on their own.
- **Pre-flight connectivity/auth checks, always.** Found via a real failed
  test build (`lmrg181a`): `run_racadm`/`run_ucsm` originally had `2>/dev/null`
  on them, so any SSH/auth failure returned silently empty output — which
  downstream code then misread as real data ("power status: unknown" →
  "must be off" → tries to power-cycle, which *also* silently fails). Net
  effect: 15+ minutes burned before the build died, with no actual racadm
  connection ever having happened, and nothing in the iDRAC's own logs to
  show why. `require_idrac_reachable()`/`require_ucsm_reachable()` in
  `common.sh` now run as the very first step of hardware bring-up — a real
  TCP/22 check (ping succeeding doesn't confirm this) followed by an actual
  racadm/UCSM auth probe — and die immediately with a specific diagnostic
  if either fails, instead of proceeding on a wrong assumption.

## Package source

Two options were considered for where OS packages come from during install:

1. **Register to Satellite temporarily during install**, pull packages from
   there, unregister, then let GOMP register properly afterward.
2. **Install from a static per-major-version mirror**; leave Satellite
   registration and patching to the exact target minor entirely to
   GOMP-triggered downstream automation.

**Option 2 was chosen.** Option 1 doesn't actually save a registration step —
by its own description it still ends with GOMP doing a real, durable
registration afterward, so you'd be registering, unregistering, and
registering again within roughly the same hour for every server. That adds a
hard runtime dependency on Satellite being reachable at the single most
fragile point in provisioning (bare install), and `subscription-manager`
register/unregister cycles aren't really built to be used as a disposable
package-download shim at fleet scale. Option 2 also matches how the system
already works today (the old `templateDELL.ks`'s static `url --url=...`
line), which is the lower-risk migration path.

One simplification this enables: since Satellite patches to the *exact*
target minor afterward, **the static mirror only needs one copy per RHEL
major version**, not one per minor — every RHEL 8.x build (whether 8.8 or
8.10 was selected) installs from the same `RHEL8-x86_64` tree.
`kickstart_gen.sh` computes the repo URL from the major version only.

**Required mirror directories** (web-accessible, referenced by the
kickstart's `url --url=...` line, generated from `OS_VERSION`'s major
version):
- `http://10.8.171.50/PNC/distros/RHEL8-x86_64/` — full RHEL 8 DVD/repo tree
- `http://10.8.171.50/PNC/distros/RHEL9-x86_64/` — full RHEL 9 DVD/repo tree

This is a separate, larger thing from the `TEMPLATE8`/`TEMPLATE9` boot
media discussed above — those are ~90MB of boot-only binaries
(`vmlinuz`/`initrd.img`/`isolinux`), just enough to get the installer
running and pointed at this repo tree for the actual packages. If
`RHEL9-x86_64` doesn't exist yet alongside `TEMPLATE9`/`TEMPLATE9EFI`, that's
the other piece to stage before RHEL 9 builds will work end to end.



## Credentials

**One secret file to manage**: a plaintext password for the `xsmrgautomat`
AD account, named `.xsmrgautomat`, in the project root — same idea as the
old scripts' `sshpass -fxsmrgautomat`. Mode 400. Used for both iDRAC and
UCSM logins, with different domain syntax for each — don't drop either:
- iDRAC: `xsmrgautomat@pncbank.com@<idrac-ip>` (AD `user@domain` form —
  dropping `@pncbank.com` breaks auth entirely, it's not a jump host).
- UCSM: `ucs-PNCNT\xsmrgautomat@<ucsm-ip>` (Windows `DOMAIN\user` form).

`build.sh` and `build_server.sh` both call `check_secrets()` at startup and
fail immediately (before touching any hardware) if `.xsmrgautomat` is
missing.

**Everything else stays where it already was, edited in place, not read
from a separate secrets file:**
- **GOMP auth** — a `.headers` file in the project root, read via
  `curl -H @.headers`, exactly like the old `gomp_submit.sh` did.
- **Root password hash** — hardcoded directly into each kickstart template
  (`templates/kickstart-dell-uefi.ks.tmpl`, `kickstart-dell-legacy.ks.tmpl`,
  `kickstart-cisco.ks.tmpl`) as a plain `rootpw --iscrypted <hash>` line —
  edit it directly with real `openssl passwd -6` output. It's the same
  fixed value everywhere, so it isn't generated/substituted by
  `kickstart_gen.sh` at all anymore.
- **SSH authorized_keys** — added directly into all three templates above,
  the same way the original `templateDELL.ks`/`templateCISCO.ks` had real
  keys baked in inline. **Whatever key goes here needs to be able to SSH
  into every newly built
  server**, since `lib/post_install.sh` uses it for post-install disk/LVM
  configuration.

Separately, **SSH key auth from lmrg34ja → lmrg34ga** (used by
`lib/iso_gen.sh` to assemble the boot ISO) is a different thing entirely —
whatever account runs `build.sh`/`build_server.sh` needs its own public key
already authorized on `lmrg34ga`. Not part of the `.xsmrgautomat`/`.headers`
credential set above.

- `storcli64` present at `/opt/MegaRAID/storcli/storcli64` on Cisco targets
  (matches the old `post_build_cisco.sh` behavior of copying/installing it).
- **On `lmrg34ga`**, under `/mnt/installs/kickstart/SERVERS/`, one staged
  installer-boilerplate directory per RHEL major version + boot mode:
  - `TEMPLATE8` / `TEMPLATE8EFI` — already exist (confirmed from your `ls`).
  - `TEMPLATE9` / `TEMPLATE9EFI` — **do not exist yet.** `iso_gen.sh` checks
    for these and fails clearly (rather than failing confusingly at
    `mkisofs`) if they're missing. To create them: extract `vmlinuz` and
    `initrd.img` from `/images/pxeboot/` on the RHEL 9.8 install ISO, plus
    `isolinux.bin`/`boot.cat`/`ldlinux.c32`/`libcom32.c32`/`libutil.c32`/
    `vesamenu.c32`/`splash.png` (Legacy) or the `EFI/BOOT/` tree and
    `efiboot.img` (UEFI) the same way `TEMPLATE8`/`TEMPLATE8EFI` are laid
    out today. This is the one piece of this rewrite that's a real
    operational task, not something scriptable from here.

## Open items — verify before trusting this on real hardware

These are places where the rewrite made a reasonable, documented choice but
**could not be validated against real Dell/Cisco gear** during this exercise:

1. **`-r pwrcycle` vs `--realtime` standardization** (above) — confirm
   against a real iDRAC10 unit that RAID/BIOS jobs actually complete this
   way; the original inconsistency may have been intentional for a reason
   that wasn't documented anywhere I could find.
2. **Extra-disk device naming** (`configure_extra_disks` in
   `post_install.sh`) assumes disks come up in controller order as
   `sdb`, `sdc`, ... for however many extra volumes exist. Fine for a single
   extra volume; worth confirming ordering on a server with 2+ extra RAID
   groups (e.g. the RAID1 + RAID0 + RAID10 example from the CSV/web tool).
3. **Cisco storcli RAID creation is stubbed** (`configure_extra_disk_cisco`)
   — the exact controller/enclosure addressing needs to be confirmed on a
   real C-series chassis before this does anything beyond querying current
   state. This mirrors where the old `post_build_cisco.sh` also had the most
   hardware-specific, least-portable logic.
4. **UCSM blade slot discovery** (`show detail | grep Server:` in
   `build_server.sh`) — ported directly from the old script's approach but
   not verified against a live UCSM domain in this exercise.
5. **NIC device names are hardcoded** (`ens0` for Dell, `nic1` for Cisco),
   matching the old scripts exactly — flag if your fleet has any hardware
   generation where that's not true.
6. **`get_mac()`'s hwinventory parsing** (`dell_hw.sh`) is a straight port of
   the original awk pipeline; iDRAC10's `racadm hwinventory` output format
   was one of the things flagged as possibly changed from iDRAC9 during the
   original audit and was never confirmed either way.
7. **The web tool's "/opt/app MB" column on the OS Disk tab is vestigial.**
   Discovered during dry-run testing of the logvol generator here: `/opt/app`
   is already a fixed `toolsvg` volume (20480MB), so also emitting it from
   the user-configurable core filesystems caused an actual duplicate-mount
   collision. `build_server.sh` now drops that field before generating the
   kickstart, matching a pre-existing dead-field quirk in the real
   `templateDELL.ks`/`OS-Sizes` (the column was parsed but never wired into
   the actual template). **Worth deciding**: remove the "/opt/app MB" column
   from the web tool's OS Disk tab entirely, since as of this rewrite it's
   collected but silently discarded.
