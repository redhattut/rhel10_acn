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
  log INFO "Resetting iDRAC controller"
  run_racadm "$idrac_ip" racreset
  sleep 600
  ping_wait "$idrac_ip" 30 30
  sleep 60
}

# ensure_power_on <idrac_ip>
# Powers the server on if it's currently off; restarts it if it's already on
# (mirrors the old get_ready behavior of always recycling power before a
# fresh build, since Lifecycle Controller state can otherwise interfere).
ensure_power_on(){
  local idrac_ip="$1"
  local power_status
  power_status=$(run_racadm "$idrac_ip" getsysinfo | grep "Power Status" | awk '{print $NF}')
  if [[ -z "$power_status" ]]; then
    die "Could not parse Power Status from racadm getsysinfo output on $idrac_ip. require_idrac_reachable already confirmed racadm works, so this means the output format wasn't what was expected — check manually before assuming anything about power state (see README iDRAC10 open item)."
  fi
  log INFO "Current power status: $power_status"
  if [[ "$power_status" != "ON" ]]; then
    log INFO "Server is off — power cycling and waiting"
    run_racadm "$idrac_ip" serveraction powercycle
    sleep 300
  fi
  run_racadm "$idrac_ip" set bios.MiscSettings.ErrPrompt Disabled >/dev/null
  local jid; jid=$(create_racadm_job "$idrac_ip" "BIOS.Setup.1-1")
  [[ -z "$jid" ]] && die "Job creation failed enabling BIOS settings"
  wait_for_racadm_job "$idrac_ip" "$jid" || die "BIOS settings job never completed"
}

# set_cpufreq <idrac_ip>
set_cpufreq(){
  local idrac_ip="$1"
  log INFO "Setting CPU frequency policy to PerfOptimized"
  run_racadm "$idrac_ip" set BIOS.SysProfileSettings.sysProfile PerfOptimized >/dev/null
}

# set_boot_mode <idrac_ip> <UEFI|Legacy>
set_boot_mode(){
  local idrac_ip="$1" mode="$2"
  log INFO "Setting boot mode to $mode"
  run_racadm "$idrac_ip" set BIOS.BiosBootSettings.BootMode "$mode" >/dev/null
  local jid; jid=$(create_racadm_job "$idrac_ip" "BIOS.Setup.1-1")
  [[ -z "$jid" ]] && die "Job creation failed setting boot mode"
  wait_for_racadm_job "$idrac_ip" "$jid" || die "Boot mode job never completed"
}

# remove_existing_vdisks <idrac_ip>
remove_existing_vdisks(){
  local idrac_ip="$1"
  local vdisk_out; vdisk_out=$(run_racadm "$idrac_ip" storage get vdisks -o -p name)
  if echo "$vdisk_out" | grep -qi ERROR; then
    log INFO "No existing virtual disks to remove"
    return 0
  fi

  # Each vdisk is a block: an ID line (e.g. Disk.Virtual.0:RAID.SL.3-1),
  # then a "Name = ..." line. deletevd needs the FULL ID line — the
  # controller suffix alone (RAID.SL.3-1) is not a valid delete target and
  # silently fails. jobqueue create, separately, DOES want just the
  # controller suffix. These are two different values; don't conflate them.
  local vdisk_ids; vdisk_ids=$(echo "$vdisk_out" | grep -v "Name" | grep -v "^$")
  [[ -z "$vdisk_ids" ]] && { log INFO "No existing virtual disks to remove"; return 0; }

  local raid_id=""
  while read -r vdisk_id; do
    [[ -z "$vdisk_id" ]] && continue
    log INFO "Removing existing virtual disk $vdisk_id"
    run_racadm "$idrac_ip" storage deletevd:"$vdisk_id" >/dev/null
    raid_id=$(echo "$vdisk_id" | awk -F: '{print $2}')
  done <<< "$vdisk_ids"

  [[ -z "$raid_id" ]] && die "Found existing vdisk(s) but could not determine controller ID to commit the delete — check manually before proceeding"

  local jid; jid=$(create_racadm_job "$idrac_ip" "$raid_id")
  if [[ -z "$jid" ]]; then
    die "Job creation failed committing vdisk deletion on $idrac_ip (controller $raid_id) — the delete request was sent but never committed. Do not proceed to create a new OS vdisk until this is resolved; check manually with: racadm storage get vdisks -o -p name"
  fi
  wait_for_racadm_job "$idrac_ip" "$jid" || die "Vdisk deletion job $jid never completed on $idrac_ip"
}

# create_os_vdisk <idrac_ip> <os_disk_size_gb>
# Picks two SSDs whose size is within +-15% of the requested OS disk size and
# builds a RAID1 volume named OS_Disk. Same tolerance-matching logic as the
# original create_vdiskos; NVMe disks are still never candidates for the OS
# vdisk (they can't be RAID'd through storage createvd).
create_os_vdisk(){
  local idrac_ip="$1" size_gb="$2"
  remove_existing_vdisks "$idrac_ip"

  log INFO "Enumerating physical disks for OS vdisk (target ${size_gb}GB)"
  local pdisks; pdisks=$(run_racadm "$idrac_ip" storage get pdisks -o -p mediatype,size)
  local parsed; parsed=$(echo "$pdisks" | parse_pdisks)

  local candidates=()
  local disk_id media disk_size size_up size_down
  while IFS=$'\t' read -r disk_id media disk_size; do
    [[ "$media" == "SSD" ]] || continue
    [[ -z "$disk_size" ]] && continue
    size_up=$(( disk_size + disk_size*15/100 ))
    size_down=$(( disk_size - disk_size*15/100 ))
    if (( size_up >= size_gb && size_down <= size_gb )); then
      candidates+=("$disk_id")
    fi
  done <<< "$parsed"

  if (( ${#candidates[@]} < 2 )); then
    die "Could not find 2 SSDs matching OS disk size ${size_gb}GB — check physical disk config"
  fi

  local disk1="${candidates[0]}" disk2="${candidates[1]}"
  # Controller ID lives embedded in the disk FQDD itself (3rd colon field,
  # e.g. Disk.Bay.0:Enclosure.Internal.0-1:RAID.SL.3-1 -> RAID.SL.3-1).
  # This MUST be derived dynamically, not hardcoded — controller naming
  # varies by hardware generation/config (RAID.Slot.3-1 vs RAID.SL.3-1 seen
  # in practice), and a wrong hardcoded value here fails createvd outright
  # regardless of whether disk matching succeeded.
  local raid_id; raid_id=$(echo "$disk1" | awk -F: '{print $3}')
  [[ -z "$raid_id" ]] && die "Could not determine RAID controller ID from disk FQDD: $disk1"
  log INFO "Creating RAID1 OS_Disk on $disk1 + $disk2 (controller $raid_id)"
  local out
  out=$(run_racadm "$idrac_ip" storage createvd:"$raid_id" -rl r1 -pdkey:"$disk1","$disk2" -name OS_Disk)
  local jid; jid=$(create_racadm_job "$idrac_ip" "$raid_id")
  [[ -z "$jid" ]] && die "Job creation failed creating OS vdisk"
  wait_for_racadm_job "$idrac_ip" "$jid" 60 30 || die "OS vdisk creation job never completed"
}

# get_mac <idrac_ip>
# Finds the first NIC reporting link "Up" and prints its MAC to stdout.
get_mac(){
  local idrac_ip="$1"
  run_racadm "$idrac_ip" set iDRAC.OS-BMC.AdminState Disabled >/dev/null

  local nic_list
  nic_list=$(run_racadm "$idrac_ip" hwinventory | awk '
    /^-+$/ { if (p && f) print p; p=""; f=0 }
    /Device Type = NIC/ { f=1 }
    { p = p $0 ORS }
    END { if (p && f) print p }
  ' | grep -w '^FQDD' | awk '{print $3}' | sort -t: -k2)

  local nic link
  for nic in $nic_list; do
    link=$(run_racadm "$idrac_ip" nicstatistics "$nic" | grep -v Partition | grep "Link Status" | awk '{print $3}')
    if [[ "$link" == "Up" ]]; then
      run_racadm "$idrac_ip" getsysinfo | grep "$nic" | awk '{print $4}'
      return 0
    fi
    log INFO "Link on $nic is down, trying next"
  done
  log ERROR "No NIC with an Up link status found"
  return 1
}

# mount_install_media <idrac_ip> <hostname_short>
mount_install_media(){
  local idrac_ip="$1" host="$2"
  local vmedia; vmedia=$(run_racadm "$idrac_ip" remoteimage -s | grep Enabled)
  if [[ -n "$vmedia" ]]; then
    log INFO "Unmounting existing virtual media first"
    run_racadm "$idrac_ip" remoteimage -d >/dev/null
  fi
  log INFO "Mounting install ISO for $host"
  run_racadm "$idrac_ip" remoteimage -c -l "http://10.8.171.50/kickstart/SERVERS/tmpiso/${host}/build_${host}.iso" >/dev/null
  run_racadm "$idrac_ip" set iDRAC.VirtualMedia.BootOnce 1 >/dev/null
  run_racadm "$idrac_ip" set iDRAC.ServerBoot.FirstBootDevice VCD-DVD >/dev/null
}

# restart_server <idrac_ip>
restart_server_dell(){
  local idrac_ip="$1"
  log INFO "Power-cycling server to begin OS install"
  run_racadm "$idrac_ip" serveraction powercycle >/dev/null
}
