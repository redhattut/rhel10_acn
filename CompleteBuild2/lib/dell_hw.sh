#!/bin/bash
# =============================================================================
# dell_hw.sh — Dell / iDRAC bring-up functions
#
# Ported from the old dell_functions script. Behavior is preserved; the
# duplicated "create job -> poll jobqueue" pattern now goes through
# wait_for_racadm_job()/create_racadm_job() in common.sh, and every job
# creation uses -r pwrcycle consistently (see common.sh comment on why).
#
# Requires common.sh already sourced (for log/run_racadm/wait_for_racadm_job/
# ping_wait) and HOSTNAME_SHORT set by the caller.
# =============================================================================

# racreset_idrac <idrac_ip>
# Resets the iDRAC controller itself and waits for it to come back before
# doing anything else against it.
racreset_idrac(){
  local idrac_ip="$1"
  if is_skipped "racreset"; then
    log_skip "iDRAC controller reboot (racreset)" "racreset"
    return 0
  fi
  log INFO "Rebooting iDRAC"
  run_racadm "$idrac_ip" racreset >/dev/null
  # Was a single blind `sleep 600` with zero log output for the full 10
  # minutes — confirmed this made a completely normal, expected wait look
  # exactly like a hang (a real report: checked at 7 minutes, well within
  # the designed 10, and concluded the build was stuck). Same fix already
  # applied to ssh_wait() for the same reason: a heartbeat every couple of
  # minutes, not a full silent sleep, so "still going" stays visible.
  local waited=0 chunk=120
  while (( waited < 600 )); do
    local this_sleep=$(( 600 - waited < chunk ? 600 - waited : chunk ))
    sleep "$this_sleep"
    waited=$(( waited + this_sleep ))
    (( waited < 600 )) && log INFO "Still waiting for iDRAC reset to settle (${waited}s of 600s)"
  done
  ping_wait "$idrac_ip" 30 30
  sleep 60
}

# -----------------------------------------------------------------------------
# gather_server_info <idrac_ip>
# Runs once per server, after racreset_idrac()/ensure_power_on() but before
# any BIOS/RAID changes — a snapshot of what's actually on the box, taken
# with the server in a known-good state (iDRAC responsive, power confirmed
# on) rather than whatever state it happened to be in when the script
# started. Saves ALL raw racadm output to a single file for
# reference/debugging, then logs a compact human-readable summary right
# after "Gathering server information" — nothing else prints in between.
#
# NOTE on ordering: this deliberately runs AFTER ensure_power_on(), so its
# own POWER field will always read ON — that's fine, not a bug. The actual
# pre-existing power state (in case the server was found off) is captured
# and logged by ensure_power_on() itself, before it does anything; nothing
# is lost by gather_server_info() no longer being the one to report it.
#
# Purely diagnostic: never fails the build. Fields it can't determine show
# as "unknown" rather than aborting anything.
#
# Confidence varies by field:
#   - POWER, HOST IP/DOMAIN/MNEMONIC/SUBNET, disk list/count: confirmed —
#     these reuse the same racadm calls (getsysinfo, storage get pdisks)
#     already proven working elsewhere in this pipeline, or are derived
#     directly from values this script already has (hostname, resolved IP).
#   - BIOS MODE: reasonably confident (mirrors set_boot_mode's proven
#     target path, just a `get` instead of a `set`).
#   - iDRAC NAME, RAID CONTROLLER: best-effort guesses at the right
#     racadm attribute path / hwinventory block, NOT confirmed against
#     real output. Expect "unknown" here until verified on a real box —
#     check the raw dump file this function saves if either comes back
#     empty and the real attribute path/label needs adjusting.
# -----------------------------------------------------------------------------
gather_server_info(){
  local idrac_ip="$1"
  log INFO "Gathering server information"
  local raw_file="${JOB_LOG_DIR}/${HOSTNAME_SHORT}.hwinventory.raw"

  {
    echo "=== getsysinfo ==="
    run_racadm "$idrac_ip" getsysinfo
    echo "=== hwinventory ==="
    run_racadm "$idrac_ip" hwinventory
    echo "=== storage get pdisks (mediatype,size,state) ==="
    run_racadm "$idrac_ip" storage get pdisks -o -p mediatype,size,state
    echo "=== BIOS boot mode ==="
    run_racadm "$idrac_ip" get BIOS.BiosBootSettings.BootMode
    echo "=== iDRAC name (best effort) ==="
    run_racadm "$idrac_ip" get iDRAC.NIC.DNSRacName
    echo "=== end ==="
  } > "$raw_file" 2>&1
  log INFO "Raw hardware inventory saved to $raw_file"

  # hwinventory specifically is not allowed to silently fail — everything
  # downstream that enumerates NICs/MACs (get_mac()) and disks depends on
  # it having real content, not an empty block from an exhausted-retries
  # racadm failure. A missing/garbage iDRAC NAME or BIOS MODE degrades
  # gracefully to "unknown" (they're informational), but a missing
  # hwinventory means the rest of the build has nothing real to work from
  # — die() here instead of limping forward with placeholder data.
  local hwinv_block; hwinv_block=$(sed -n '/=== hwinventory/,/=== storage get pdisks/p' "$raw_file")
  if [[ -z "$(echo "$hwinv_block" | grep -v '===' | tr -d '[:space:]')" ]]; then
    die "racadm hwinventory returned no usable content on $idrac_ip after retries — everything downstream (NIC/MAC enumeration, disk layout) depends on this. Not proceeding with an incomplete inventory. Check the raw file: $raw_file"
  fi

  local power; power=$(sed -n '/=== getsysinfo/,/=== hwinventory/p' "$raw_file" | grep "Power Status" | awk '{print $NF}' | head -1)
  local domain; domain=$(echo "$HOSTNAME" | cut -d'.' -f2-)
  local mnemonic; mnemonic=$(echo "$HOSTNAME" | head -c4 | tail -c3 | tr '[:lower:]' '[:upper:]')
  local subnet; subnet=$(echo "$IP" | sed 's/\.[0-9]*$/.0/')
  local idrac_name; idrac_name=$(grep "DNSRacName" "$raw_file" | awk '{print $3}' | head -1)

  # iDRAC firmware version + best-effort generation guess, logged up front
  # (not just tucked into the raw dump) precisely because behavior already
  # confirmed to differ between generations on this pipeline (BootMode
  # casing) — knowing which generation a build is running against is worth
  # seeing in the log without having to go dig through the raw file.
  # HEURISTIC, NOT AUTHORITATIVE: based only on this project's own two data
  # points so far (an iDRAC10 unit reporting firmware "1.30.30.50"; older
  # units in this fleet reporting the more familiar iDRAC9-era "4.x/5.x/6.x"
  # scheme) — a firmware major version of 1 is guessed as iDRAC10, anything
  # else is assumed iDRAC9-or-earlier. This is NOT from official Dell
  # documentation confirming the version-number-to-generation mapping in
  # general; treat the guess as a hint to sanity-check, not a fact to branch
  # meaningfully different logic on without verifying it yourself first.
  local idrac_fw; idrac_fw=$(sed -n '/=== getsysinfo/,/=== hwinventory/p' "$raw_file" | grep "Firmware Version" | awk '{print $NF}' | head -1)
  local idrac_gen_guess="unknown"
  if [[ "$idrac_fw" =~ ^1\. ]]; then
    idrac_gen_guess="iDRAC10 (heuristic — firmware major version 1)"
  elif [[ -n "$idrac_fw" ]]; then
    idrac_gen_guess="iDRAC9 or earlier (heuristic — firmware major version not 1)"
  fi
  log INFO "iDRAC firmware: ${idrac_fw:-unknown} — generation guess: ${idrac_gen_guess}"

  # NOT `grep -oE '(Uefi|Bios)'` — same landmine as verify_boot_mode()
  # below: the "[Key=BIOS.Setup.1-1#BiosBootSettings]" header line in this
  # block contains "Bios" as a substring of "BiosBootSettings", and an
  # unanchored match finds THAT before ever reaching the real
  # "BootMode=Uefi" value line — confirmed this was actually happening
  # (this field showed "Bios" on a real box whose manually-checked boot
  # mode was actually Uefi). Anchor to "BootMode=" specifically.
  # Case-insensitive for the same reason read_boot_mode() (below) is —
  # confirmed an iDRAC10 unit can report "UEFI" (all caps) in some states
  # and "Uefi" (title case) in others. This is purely informational display
  # here, but no reason to let it show "unknown" over a casing difference.
  local bios_mode; bios_mode=$(sed -n '/=== BIOS boot mode/,/=== iDRAC name/p' "$raw_file" | grep -oiE 'BootMode=(Uefi|Bios)' | cut -d= -f2)

  # NICs — same hwinventory block shape get_mac() already parses, just
  # collecting every NIC's MAC instead of stopping at the first Up link.
  local nics; nics=$(sed -n '/=== hwinventory/,/=== storage/p' "$raw_file" | awk '
    /^-+$/ { if (p && f) print p; p=""; f=0 }
    /Device Type = NIC/ { f=1 }
    { p = p $0 ORS }
    END { if (p && f) print p }
  ' | grep -oE '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' | sort -u)

  local disk_section; disk_section=$(sed -n '/=== storage get pdisks/,/=== BIOS/p' "$raw_file" | grep -v "===")
  local disk_lines; disk_lines=$(echo "$disk_section" | parse_pdisks_full)
  local disk_count; disk_count=$(echo "$disk_lines" | grep -c . || true)

  {
    echo ""
    echo "SERVER INFORMATION:"
    echo ""
    printf "%-16s= %s\n" "POWER" "${power:-unknown}"
    printf "%-16s= %s\n" "HOST NAME" "$HOSTNAME"
    printf "%-16s= %s\n" "DOMAIN" "$domain"
    printf "%-16s= %s\n" "MNEMONIC" "$mnemonic"
    printf "%-16s= %s\n" "HOST IP" "$IP"
    printf "%-16s= %s\n" "SUBNET" "$subnet"
    printf "%-16s= %s\n" "iDRAC NAME" "${idrac_name:-unknown}"
    printf "%-16s= %s\n" "iDRAC IP" "$idrac_ip"
    printf "%-16s= %s\n" "BIOS MODE" "${bios_mode:-unknown}"
    local i=1
    while read -r mac; do
      [[ -z "$mac" ]] && continue
      printf "%-16s= %s\n" "NIC-$i MAC" "$mac"
      ((i++))
    done <<< "$nics"
    printf "%-16s= %s\n" "DISK COUNT" "${disk_count:-0}"
    local d=1
    local sizestr
    while IFS=$'\t' read -r did media size state; do
      [[ -z "$did" ]] && continue
      sizestr="${size}G"
      printf "%-16s= %-58s|  TYPE: %-5s|  SIZE: %-7s|  STATUS: %s\n" "DISK-$d" "$did" "$media" "$sizestr" "${state:-unknown}"
      ((d++))
    done <<< "$disk_lines"
    echo ""
  } | while IFS= read -r line; do log_raw "$line"; done
}

# ensure_power_on <idrac_ip>
# Powers the server on if it's currently off. No BIOS staging/commit here —
# see stage_bios_settings()/commit_bios_settings() below. Kept separate on
# purpose: power state is a precondition to check, not a setting to stage.
ensure_power_on(){
  local idrac_ip="$1"
  local power_status
  power_status=$(run_racadm "$idrac_ip" getsysinfo | grep "Power Status" | awk '{print $NF}')
  if [[ -z "$power_status" ]]; then
    die "Could not get Power Status from racadm getsysinfo on $idrac_ip after retries. If run_racadm above logged an ssh-level failure, this is that same problem persisting past the retry — check the iDRAC's SSH session directly. If run_racadm succeeded (real racadm output came back) but this still came up empty, THEN it's an output-format mismatch — check manually (see README iDRAC10 open item)."
  fi
  log INFO "Current power status: $power_status"
  if [[ "${power_status^^}" != "ON" ]]; then
    log INFO "Server is off — power cycling and waiting"
    run_racadm "$idrac_ip" serveraction powercycle
    sleep 300
  fi
}

# stage_bios_settings <idrac_ip>
# Stages (does NOT commit) the one-off BIOS attribute changes this pipeline
# always wants: disabling the F1/F2 error prompt, and CPU frequency policy.
#
# FIX: the previous version of this pipeline had set_cpufreq() issue its
# `racadm set` and stop there — no job, no commit. It never actually took
# effect on its own; it only "worked" if some unrelated later BIOS.Setup
# job happened to also commit whatever was still pending. Staging it here
# alongside the error-prompt setting, with an explicit commit_bios_settings()
# call, makes it actually apply, deliberately, instead of by accident.
stage_bios_settings(){
  local idrac_ip="$1"
  log_section "BIOS settings"
  run_racadm "$idrac_ip" set bios.MiscSettings.ErrPrompt Disabled >/dev/null
  log INFO "Staging BIOS setting: CPU frequency policy PerfOptimized"
  run_racadm "$idrac_ip" set BIOS.SysProfileSettings.sysProfile PerfOptimized >/dev/null
}

# set_boot_mode <idrac_ip> <UEFI|Legacy>
# Stages the boot mode change — does NOT commit. Call commit_bios_settings()
# afterward to apply this along with whatever else was staged.
#
# Checks the CURRENT value first and skips the set entirely if it already
# matches — confirmed on an iDRAC10 unit that was already in Uefi mode:
# setting BootMode to the value it was ALREADY at got rejected outright
# with "RAC1025: The specified object is read-only and cannot be
# modified", not the "invalid value" error a real mismatch would give.
# Skipping a redundant set avoids that rejection happening at all, on any
# iDRAC generation, not just working around it after the fact.
#
# CRITICAL: BIOS.BiosBootSettings.BootMode is a case-sensitive racadm enum
# for the SET direction — the pipeline's own $BOOT_MODE convention (used
# everywhere else — template selection in iso_gen.sh/kickstart_gen.sh) is
# "UEFI" (all caps) / anything else for Legacy, which is NOT a valid value
# to SEND for this specific attribute (confirmed: sending "UEFI" gets
# RAC947 "Invalid object value specified"; the correct value to send is
# "Uefi"/"Bios", title case). dell_racadm_boot_mode() translates for
# exactly that reason. The GET direction is a separate concern — see
# read_boot_mode() below for why that side needs case-insensitive parsing
# instead (confirmed iDRAC10 can report back "UEFI", all caps, even though
# "Uefi" is what's valid to SEND).
dell_racadm_boot_mode(){
  local mode="$1"
  if [[ "${mode^^}" == "UEFI" ]]; then
    echo "Uefi"
  else
    echo "Bios"
  fi
}

# read_boot_mode <idrac_ip>
# Reads BIOS.BiosBootSettings.BootMode and normalizes the result to
# lowercase ("uefi"/"bios"/"") for case-insensitive comparison elsewhere.
# NOT case-sensitive on purpose — confirmed real hardware can return either
# "Uefi" (older iDRAC, and this same iDRAC10 unit's OWN pre-change read via
# gather_server_info) or "UEFI" (this iDRAC10 unit's read immediately after
# a rejected set attempt). Whatever's driving that inconsistency, the
# comparison itself shouldn't care about case.
#
# NOT `grep -oE '(Uefi|Bios)'` (unanchored) — the get output's OWN key
# header line is "[Key=BIOS.Setup.1-1#BiosBootSettings]", which contains
# "Bios" as a substring of "BiosBootSettings". An unanchored match finds
# that first and never reaches the real "BootMode=..." line below it.
# Anchoring to "BootMode=" is what actually distinguishes the value from
# the label text surrounding it. Confirmed this correctly handles a "#"
# prefix too (racadm's convention for "currently read-only") — a real
# read on this same iDRAC10 unit came back "#BootMode=Uefi", not just
# "BootMode=Uefi", and this still extracts "uefi" from it fine.
#
# Retries here are a DIFFERENT failure mode than run_racadm's own
# ssh-level retry: this handles ssh succeeding but the parsed value coming
# back empty anyway — confirmed on the same iDRAC10 unit, immediately
# after a BIOS.Setup.1-1 -r pwrcycle job hit "Completed 100%": no
# run_racadm ssh-failure was logged (ssh genuinely succeeded), yet the
# parsed BootMode came back empty. Most likely explanation: the iDRAC's
# own management stack hadn't fully settled from the reboot that job just
# triggered, even though the job queue already reported it done. A few
# retries with a real gap gives it that settling time without needing to
# hardcode a blind extra sleep after every BIOS job everywhere else.
read_boot_mode(){
  local idrac_ip="$1"
  local result=""
  # Reuses RACADM_MAX_ATTEMPTS/RACADM_RETRY_DELAY (common.sh) rather than
  # its own separate hardcoded values — this used to be its own 3-attempt
  # budget, independent of run_racadm's retry count, and silently stayed
  # at 3 when run_racadm's own retry budget was later bumped to 15. Two
  # different "how patient should we be" numbers living in two places is
  # exactly how that kind of drift happens; one shared knob avoids it.
  local attempt=1
  while (( attempt <= RACADM_MAX_ATTEMPTS )); do
    result=$(run_racadm "$idrac_ip" get BIOS.BiosBootSettings.BootMode \
      | grep -oiE 'BootMode=(Uefi|Bios)' | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
    [[ -n "$result" ]] && break
    (( attempt < RACADM_MAX_ATTEMPTS )) && sleep "$RACADM_RETRY_DELAY"
    ((attempt++))
  done
  echo "$result"
}

set_boot_mode(){
  local idrac_ip="$1" mode="$2"
  local racadm_mode; racadm_mode=$(dell_racadm_boot_mode "$mode")
  local current; current=$(read_boot_mode "$idrac_ip")
  if [[ "$current" == "${racadm_mode,,}" ]]; then
    log INFO "Boot mode already ${racadm_mode} — skipping set (avoids the read-only rejection some iDRACs give for a no-op set)"
    return 0
  fi
  log INFO "Staging BIOS setting: boot mode $mode (racadm value: $racadm_mode)"
  run_racadm "$idrac_ip" set BIOS.BiosBootSettings.BootMode "$racadm_mode" >/dev/null
}

# verify_boot_mode <idrac_ip> <UEFI|Legacy>
# Re-reads the boot mode AFTER commit_bios_settings() and compares against
# what was actually requested — a job reaching "Completed 100%" only means
# the JOB finished, not that every individual staged value was accepted;
# an invalid enum value (like the UEFI/Uefi casing bug this pipeline had)
# gets silently dropped from the batch while the rest of the job still
# commits and reports success. Building the wrong ISO format (EFI-only vs
# Legacy/isolinux) for whatever boot mode the firmware ACTUALLY ends up in
# is exactly the kind of mismatch that produces a boot menu that looks
# nothing like expected and an install that never really starts — this
# check exists so that failure mode is a loud die(), not a silent one.
verify_boot_mode(){
  local idrac_ip="$1" requested_mode="$2"
  local expected; expected=$(dell_racadm_boot_mode "$requested_mode")
  local actual; actual=$(read_boot_mode "$idrac_ip")
  if [[ "$actual" != "${expected,,}" ]]; then
    die "Boot mode verification failed on $idrac_ip: requested $requested_mode (racadm value $expected), but the server is actually in ${actual:-<empty/unparseable>}. Building an ISO for the wrong boot mode produces a boot menu/install that looks nothing like expected and typically fails outright — not proceeding. Check manually with: racadm get BIOS.BiosBootSettings.BootMode"
  fi
  log INFO "Boot mode verified: $actual"
}

# commit_bios_settings <idrac_ip>
# Commits every BIOS.Setup attribute staged above in ONE reboot, instead of
# a separate reboot per setting. All three (error prompt, CPU frequency,
# boot mode) are the same job type (BIOS.Setup.1-1) with no dependency on
# each other, so there's no reason they need three separate reboots —
# unlike the storage operations below, which genuinely do need to stay
# sequential (each one is a precondition for the next).
commit_bios_settings(){
  local idrac_ip="$1"
  local jid; jid=$(create_racadm_job "$idrac_ip" "BIOS.Setup.1-1")
  [[ -z "$jid" ]] && die "Job creation failed committing BIOS settings"
  wait_for_racadm_job "$idrac_ip" "$jid" "Applying BIOS settings" \
    || die "BIOS settings job never completed"
}

# commit_storage_config <idrac_ip> <controller_fqdd> <description>
# Applies a pending storage configuration change (deletevd/cryptographicerase/
# createvd all leave changes in "pending" state until committed) — returns
# non-zero on failure, same convention as wait_for_racadm_job.
#
# Tries the normal job-queue commit first (create_racadm_job, -r pwrcycle —
# already proven working on a real PERC/RAID.SL.3-1 controller). If THAT
# doesn't produce a Commit JID, falls back to a direct server reboot
# instead of treating it as a hard failure.
#
# Deliberately reactive, not capability-checked ahead of time — confirmed
# directly on a real BOSS controller on iDRAC10: the iDRAC web UI's own
# Storage -> Pending Operations screen showed "Apply Now" greyed out
# completely (only "At Next Reboot" / "Discard All Pending" available),
# and `racadm jobqueue create <FQDD>` — with EITHER `-r pwrcycle` OR
# `--realtime` — failed identically with "BOOT007: Unable to modify the
# boot source". An earlier version of this function pre-checked
# RealtimeConfigurationCapability to decide which path to take, but that
# ties the logic to one specific capability flag and one specific
# controller/iDRAC generation. Reacting to "no Commit JID came back",
# whatever the reason, generalizes to any future controller/iDRAC
# combination with the same limitation without needing to know about it
# in advance — a direct reboot is what "At Next Reboot" does in the GUI
# regardless of WHY the job-queue mechanism didn't accept this FQDD.
#
# The reboot fallback has no job to poll, so it's a fixed wait instead of
# wait_for_racadm_job's percent-complete polling, followed by a
# lightweight reachability check (not full state verification of the
# storage change itself — callers that need to confirm the actual result
# should re-query vdisks/pdisks afterward).
commit_storage_config(){
  local idrac_ip="$1" controller_fqdd="$2" description="$3"
  local max_polls="${4:-30}" sleep_s="${5:-60}" initial_delay="${6:-300}"
  local jid; jid=$(create_racadm_job "$idrac_ip" "$controller_fqdd")
  if [[ -n "$jid" ]]; then
    wait_for_racadm_job "$idrac_ip" "$jid" "$description" "$max_polls" "$sleep_s" "$initial_delay" \
      || { log ERROR "$description job $jid never completed"; return 1; }
    return 0
  fi

  log INFO "$description — job-queue commit didn't produce a job (no Commit JID) for controller $controller_fqdd; falling back to a direct server reboot instead (same as choosing 'At Next Reboot' in the iDRAC GUI's Pending Operations screen)"
  run_racadm "$idrac_ip" serveraction powercycle >/dev/null
  log INFO "$description — waiting ${initial_delay}s for reboot + pending config apply before checking the server is back"
  sleep "$initial_delay"
  local power_status; power_status=$(run_racadm "$idrac_ip" getsysinfo | grep "Power Status" | awk '{print $NF}')
  if [[ "$power_status" != "ON" ]]; then
    log ERROR "$description — server does not report power ON after the reboot+wait (got: '${power_status:-<empty>}'). The pending config may not have applied — check manually."
    return 1
  fi
  log INFO "$description — server is back up after reboot"
}

# remove_existing_vdisks <idrac_ip> <size_gb>
remove_existing_vdisks(){
  local idrac_ip="$1" size_gb="$2"
  log_section "Storage: clearing existing vdisk"
  if is_skipped "clear-vdisk"; then
    log_skip "Removing existing virtual disk" "clear-vdisk"
  else
    local vdisk_out; vdisk_out=$(run_racadm "$idrac_ip" storage get vdisks -o -p name)
    if echo "$vdisk_out" | grep -qi ERROR; then
      log INFO "No existing virtual disks to remove"
    else
      # Each vdisk is a block: an ID line (e.g. Disk.Virtual.0:RAID.SL.3-1),
      # then a "Name = ..." line. deletevd needs the FULL ID line — the
      # controller suffix alone (RAID.SL.3-1) is not a valid delete target and
      # silently fails. jobqueue create, separately, DOES want just the
      # controller suffix. These are two different values; don't conflate them.
      local vdisk_ids; vdisk_ids=$(echo "$vdisk_out" | grep -v "Name" | grep -v "^$")
      if [[ -z "$vdisk_ids" ]]; then
        log INFO "No existing virtual disks to remove"
      else
        local raid_id=""
        while read -r vdisk_id; do
          [[ -z "$vdisk_id" ]] && continue
          log INFO "Removing existing virtual disk $vdisk_id"
          local del_out; del_out=$(run_racadm "$idrac_ip" storage deletevd:"$vdisk_id")
          raid_id=$(echo "$vdisk_id" | awk -F: '{print $NF}')
        done <<< "$vdisk_ids"

        [[ -z "$raid_id" ]] && die "Found existing vdisk(s) but could not determine controller ID to commit the delete — check manually before proceeding"

        commit_storage_config "$idrac_ip" "$raid_id" "Removing existing virtual disk" \
          || die "Vdisk deletion commit failed on $idrac_ip (controller $raid_id) — the delete request was sent but never confirmed committed. Do not proceed to create a new OS vdisk until this is resolved; check manually with: racadm storage get vdisks -o -p name"
      fi
    fi
  fi

  cryptographic_erase_disks "$idrac_ip" "$size_gb"
}

# -----------------------------------------------------------------------------
# cryptographic_erase_disks <idrac_ip> <size_gb>
# Called after an existing vdisk has been removed, for a genuinely clean
# slate before physical-disk enumeration and RAID recreation — confirmed
# subcommand name via `racadm help storage | grep -i erase` on real
# hardware: `cryptographicerase`.
#
# Filters candidates by SIZE (matching create_os_vdisk()'s own candidate
# selection below), NOT by excluding disks whose MediaType literally says
# "NVME" — confirmed as a real bug on a real box with two large (1.7T)
# standalone NVMe data drives sitting alongside the OS's own RAID-managed
# SSDs: those drives report MediaType "Solid State Drive", not "NVME" (the
# same MediaType-unreliability already confirmed elsewhere in this
# pipeline — see BusProtocol/OS-disk-detection comments), so the old
# exclusion let them through. They're also not behind any RAID controller
# at all (status "Not Available", no controller suffix in their own FQDD —
# e.g. "Disk.Bay.1:Enclosure.Internal.0-1", 2 segments, nothing to commit a
# job against), so racadm rejected the resulting jobqueue create outright
# with "SWC0244: Invalid Fully Qualified Device Descriptor" — a real,
# confirmed failure, not just an unnecessary erase. Only disks actually
# sized for the OS vdisk should ever be candidates here; the two big data
# drives never should have been touched at all, by either function.
#
# NOT FULLY VERIFIED: whether cryptographicerase self-commits (returns its
# own job ID directly) or needs the same controller-level `jobqueue create`
# commit that deletevd/createvd need, was not confirmed against real job
# output. This tries the commit path defensively and warns (rather than
# failing the whole build) if it can't confirm completion — check the
# warning message against real output on the next test run and tighten this
# up once confirmed.
# -----------------------------------------------------------------------------
cryptographic_erase_disks(){
  local idrac_ip="$1" size_gb="$2"
  log_section "Storage: cryptographic erase"
  if is_skipped "crypto-erase"; then
    log_skip "Cryptographic erase of physical disks" "crypto-erase"
    return 0
  fi
  log INFO "Cryptographically erasing physical disks on $idrac_ip for a clean slate"
  local pdisks; pdisks=$(run_racadm "$idrac_ip" storage get pdisks -o -p mediatype,size)
  local parsed; parsed=$(echo "$pdisks" | parse_pdisks)

  local disk_id media disk_size size_up size_down raid_id="" erased_any="no"
  while IFS=$'\t' read -r disk_id media disk_size; do
    [[ -z "$disk_id" ]] && continue
    # SSD or HDD — the OS vdisk isn't always SSD (confirmed a real custom
    # rebuild using HDD for the OS disk specifically); size-matching below
    # is what actually determines whether a disk is the right candidate,
    # not the media type. NVMe is excluded implicitly here, not by name —
    # it's addressed by the size window not matching an NVMe drive's size,
    # same reasoning already applied elsewhere in this pipeline.
    [[ "$media" == "SSD" || "$media" == "HDD" ]] || continue
    [[ -z "$disk_size" ]] && continue
    # Same +-15% size window as create_os_vdisk()'s own candidate
    # selection — only disks that are actually candidates for the OS
    # vdisk should be erased here, not "every SSD on the box."
    size_up=$(( disk_size + disk_size*15/100 ))
    size_down=$(( disk_size - disk_size*15/100 ))
    (( size_up >= size_gb && size_down <= size_gb )) || continue
    log INFO "cryptographicerase: $disk_id"
    local erase_out; erase_out=$(run_racadm "$idrac_ip" storage cryptographicerase:"$disk_id")
    erased_any="yes"
    # Controller ID is the LAST colon-separated field of the FQDD, not
    # necessarily the 3rd — confirmed two real, different FQDD shapes:
    # "Disk.Bay.0:Enclosure.Internal.0-1:RAID.SL.3-1" (3 fields, PERC/RAID
    # controller) and "Disk.Direct.1-1:BOSS.Slot.41-1" (2 fields, BOSS
    # controller). `awk -F: '{print $3}'` only worked for the first shape
    # by coincidence of field count; $NF (last field) is correct for both.
    [[ -z "$raid_id" ]] && raid_id=$(echo "$disk_id" | awk -F: '{print $NF}')
  done <<< "$parsed"

  if [[ "$erased_any" == "no" ]]; then
    log INFO "No SSD/HDD physical disks found to erase"
    return 0
  fi

  if [[ -n "$raid_id" ]]; then
    commit_storage_config "$idrac_ip" "$raid_id" "Cryptographic erase commit" \
      || log WARN "cryptographicerase commit did not confirm completion — verify manually before trusting the disks are actually erased: racadm storage get pdisks -o -p mediatype,size,securitystate"
  fi
}

# create_os_vdisk <idrac_ip> <os_disk_size_gb>
# Picks two SSD or HDD disks whose size is within +-15% of the requested OS
# disk size and builds a RAID1 volume named OS_Disk. Same tolerance-matching
# logic as the original create_vdiskos; NVMe disks are still never real
# candidates in practice — not excluded by name, but by the size window not
# matching an NVMe drive's actual size (they can't be RAID'd through storage
# createvd anyway).
create_os_vdisk(){
  local idrac_ip="$1" size_gb="$2"
  remove_existing_vdisks "$idrac_ip" "$size_gb"

  # Declared unconditionally, before the skip-check below — NOT `local`,
  # build_server.sh reads this after calling create_os_vdisk() regardless
  # of whether create-vdisk was actually skipped, and `set -u` there would
  # crash on a genuinely-never-set variable rather than just an empty one.
  OS_DISK_BUS_PROTOCOL=""

  log_section "Storage: creating OS vdisk"
  if is_skipped "create-vdisk"; then
    log_skip "Creating the new OS virtual disk" "create-vdisk"
    # Still worth capturing BusProtocol even when creation itself is
    # skipped — if --skip=create-vdisk is used because the vdisk was
    # already built in a previous run, it still physically exists, and
    # giving up on identifying it just because we didn't (re)create it
    # THIS run would throw away information we don't actually need to.
    capture_os_disk_bus_protocol "$idrac_ip"
    return 0
  fi
  log INFO "Enumerating physical disks for OS vdisk (target ${size_gb}GB)"
  local pdisks; pdisks=$(run_racadm "$idrac_ip" storage get pdisks -o -p mediatype,size)
  local parsed; parsed=$(echo "$pdisks" | parse_pdisks)

  local candidates=()
  local disk_id media disk_size size_up size_down
  while IFS=$'\t' read -r disk_id media disk_size; do
    # SSD or HDD — confirmed a real custom rebuild where the OS vdisk was
    # deliberately built as HDD, not SSD. Hardcoding SSD-only here was
    # never a real requirement, just an assumption based on every prior
    # test server happening to use SSD. Size-matching below (the +-15%
    # window) is what actually identifies the right candidates, same as
    # it always was; media type is just a coarse first filter.
    [[ "$media" == "SSD" || "$media" == "HDD" ]] || continue
    [[ -z "$disk_size" ]] && continue
    size_up=$(( disk_size + disk_size*15/100 ))
    size_down=$(( disk_size - disk_size*15/100 ))
    if (( size_up >= size_gb && size_down <= size_gb )); then
      candidates+=("$disk_id")
    fi
  done <<< "$parsed"

  if (( ${#candidates[@]} < 2 )); then
    die "Could not find 2 SSD/HDD disks matching OS disk size ${size_gb}GB — check physical disk config"
  fi

  local disk1="${candidates[0]}" disk2="${candidates[1]}"
  # Controller ID is the LAST colon-separated field of the disk FQDD, not
  # necessarily the 3rd — confirmed two real, different FQDD shapes:
  # "Disk.Bay.0:Enclosure.Internal.0-1:RAID.SL.3-1" (3 fields, PERC/RAID
  # controller) -> RAID.SL.3-1, and "Disk.Direct.1-1:BOSS.Slot.41-1"
  # (2 fields, BOSS controller) -> BOSS.Slot.41-1. This MUST be derived
  # dynamically, not hardcoded — controller naming varies by hardware
  # generation/config, and a wrong hardcoded value here fails createvd
  # outright regardless of whether disk matching succeeded. $NF (last
  # field) is correct for both shapes; $3 only worked for the first one
  # by coincidence of field count — confirmed as the actual cause of a
  # real "Could not determine RAID controller ID" failure on a BOSS-based
  # server.
  local raid_id; raid_id=$(echo "$disk1" | awk -F: '{print $NF}')
  [[ -z "$raid_id" ]] && die "Could not determine RAID controller ID from disk FQDD: $disk1"
  log INFO "Creating RAID1 OS_Disk on $disk1 + $disk2 (controller $raid_id)"
  local out
  out=$(run_racadm "$idrac_ip" storage createvd:"$raid_id" -rl r1 -pdkey:"$disk1","$disk2" -name OS_Disk)
  commit_storage_config "$idrac_ip" "$raid_id" "Creating OS vdisk" 30 60 600 \
    || die "OS vdisk creation commit failed on $idrac_ip (controller $raid_id)"

  capture_os_disk_bus_protocol "$idrac_ip"
}

# capture_os_disk_bus_protocol <idrac_ip>
# Queries hwinventory for the OS_Disk virtual disk's BusProtocol (SAS vs
# PCIE) — used by the kickstart %pre script as an INFORMED FALLBACK only,
# not the primary detection method (that's size-matching against the CSV's
# OS disk size — see kickstart_gen.sh/the templates), for the rare case
# size-matching can't find a confident match. Queried fresh rather than
# assumed, since this varies by controller generation (SAS/SATA BOSS-S vs
# NVMe BOSS-N) and isn't something we can know ahead of time. Matched on
# "Name = OS_Disk" specifically, so this finds the disk whether it was
# just created THIS run or already existed from a previous one (see the
# is_skipped("create-vdisk") branch above, which still calls this).
capture_os_disk_bus_protocol(){
  local idrac_ip="$1"
  OS_DISK_BUS_PROTOCOL=$(run_racadm "$idrac_ip" hwinventory | awk '
    /^-+$/ { if (p && p ~ /Name = OS_Disk/) print p; p="" }
    { p = p $0 ORS }
    END { if (p && p ~ /Name = OS_Disk/) print p }
  ' | grep "BusProtocol" | awk -F= '{print $2}' | tr -d ' ')
  log INFO "OS_Disk BusProtocol: ${OS_DISK_BUS_PROTOCOL:-unknown}"
}

# get_mac <idrac_ip>
# Finds the first NIC reporting link "Up" and prints its MAC to stdout.
get_mac(){
  local idrac_ip="$1"
  if is_skipped "idrac-passthrough"; then
    log_skip "Disabling iDRAC OS-BMC passthrough (iDRAC.OS-BMC.AdminState)" "idrac-passthrough"
  else
    run_racadm "$idrac_ip" set iDRAC.OS-BMC.AdminState Disabled >/dev/null
  fi

  # Fetched once, reused for both NIC enumeration and the per-NIC MAC
  # lookup below — avoids a second racadm hwinventory call, and (more
  # importantly) fixes a real bug confirmed on an iDRAC10 unit: the old
  # per-NIC MAC lookup cross-referenced `racadm getsysinfo`'s own output
  # for a line containing the NIC's FQDD, assuming the MAC sat in a fixed
  # column (awk '{print $4}'). That came back empty on this hardware —
  # get_mac() found an Up NIC correctly, but the getsysinfo cross-
  # reference silently produced nothing, and get_mac() still returned
  # success (0) with an empty result. Nothing inside get_mac() itself
  # logged what specifically went wrong; the only visible symptom was
  # build_server.sh's generic "Could not determine MAC address" further
  # downstream. Extracting the MAC by regex shape directly from the SAME
  # NIC's own hwinventory block is exactly what gather_server_info already
  # does successfully for the SERVER INFORMATION NIC-N MAC listing —
  # reusing that same proven approach here instead of the fragile
  # cross-reference.
  local hwinv; hwinv=$(run_racadm "$idrac_ip" hwinventory)

  local nic_list
  nic_list=$(echo "$hwinv" | awk '
    /^-+$/ { if (p && f) print p; p=""; f=0 }
    /Device Type = NIC/ { f=1 }
    { p = p $0 ORS }
    END { if (p && f) print p }
  ' | grep -w '^FQDD' | awk '{print $3}' | sort -t: -k2)

  local nic link mac
  for nic in $nic_list; do
    link=$(run_racadm "$idrac_ip" nicstatistics "$nic" | grep -v Partition | grep "Link Status" | awk '{print $3}')
    if [[ "$link" == "Up" ]]; then
      # This NIC's own hwinventory block specifically (matched by exact
      # FQDD), not the whole dump — MAC extracted by regex shape, not
      # column position, matching gather_server_info's proven approach.
      mac=$(echo "$hwinv" | awk -v target="$nic" '
        /^-+$/ { if (p && p ~ target) print p; p="" }
        { p = p $0 ORS }
        END { if (p && p ~ target) print p }
      ' | grep -oE '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' | head -1)
      if [[ -n "$mac" ]]; then
        echo "$mac"
        return 0
      fi
      log ERROR "NIC $nic reports Link Status Up but no MAC address pattern was found in its own hwinventory block — check manually: racadm hwinventory"
      return 1
    fi
    log INFO "Link on $nic is down, trying next"
  done
  log ERROR "No NIC with an Up link status found"
  return 1
}

# mount_install_media <idrac_ip> <hostname_short>
mount_install_media(){
  local idrac_ip="$1" host="$2"
  log_section "Mounting install media & booting"
  local vmedia; vmedia=$(run_racadm "$idrac_ip" remoteimage -s | grep Enabled)
  if [[ -n "$vmedia" ]]; then
    # A plain unmount-then-immediate-remount doesn't always take reliably —
    # confirmed a real case where a failed build needed to unmount and
    # remount, and it silently didn't work without a reboot in between.
    # Power-cycling after the unmount gives the iDRAC's virtual media
    # subsystem a real reset before accepting the new mount, instead of
    # racing straight into remounting on top of whatever state the
    # previous mount left behind. Only done when media was ACTUALLY
    # mounted already — a fresh/already-clear mount skips straight to
    # mounting below, no reboot needed for that case.
    log INFO "Existing virtual media mount detected — unmounting and power-cycling before remounting"
    run_racadm "$idrac_ip" remoteimage -d >/dev/null
    run_racadm "$idrac_ip" serveraction powercycle >/dev/null
    log INFO "Waiting 120s for the power-cycle to settle before remounting"
    sleep 120
  fi
  log INFO "Mounting install ISO for $host"
  run_racadm "$idrac_ip" remoteimage -c -l "http://lmrg34ga.prod.pncint.net/PNC/installs/kickstart/SERVERS/tmpiso/${host}/build_${host}.iso" >/dev/null
  run_racadm "$idrac_ip" set iDRAC.VirtualMedia.BootOnce 1 >/dev/null
  run_racadm "$idrac_ip" set iDRAC.ServerBoot.FirstBootDevice VCD-DVD >/dev/null
}

# restart_server <idrac_ip>
restart_server_dell(){
  local idrac_ip="$1"
  log INFO "Power-cycling server to begin OS install"
  run_racadm "$idrac_ip" serveraction powercycle >/dev/null
}
