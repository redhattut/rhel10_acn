#!/bin/bash
# =============================================================================
# post_install.sh — everything that happens after the OS is up
#
# Replaces post_build.sh / post_functions_cisco.sh / dell_functions_post.
# Also replaces the CGI relay chain (post_config.cgi -> post_config.sh ->
# ssh to a second jumpbox -> post_build.sh): build_server.sh calls the
# functions here directly, on lmrg34ja, right after the OS comes up.
# =============================================================================

# -----------------------------------------------------------------------------
# Satellite registration / patching — NOT this pipeline's job.
#
# Package source decision (see README "Package source"): the OS installs
# from a static per-major-version mirror (RHEL8-x86_64 / RHEL9-x86_64),
# picked up via the `url --url=...` line in the kickstart. Satellite
# registration and patching to the exact requested minor (8.10, 9.8, ...)
# happens downstream, triggered by GOMP after gomp_submit() below — this
# pipeline never holds Satellite credentials and never calls
# subscription-manager itself. If that division of responsibility changes,
# this is the comment to update, not a function to un-stub.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# find_matching_pdisks_dell <idrac_ip> <disk_type> <size_gb> <count>
# Same +-15% tolerance matching used for the OS disk, generalized to any
# count/type. NVMe is intentionally never RAID-matched here — NVMe rows are
# handled separately in configure_extra_disk_dell().
# -----------------------------------------------------------------------------
find_matching_pdisks_dell(){
  local idrac_ip="$1" disk_type="$2" size_gb="$3" count="$4"
  local media_filter="${disk_type^^}"

  local pdisks; pdisks=$(run_racadm "$idrac_ip" storage get pdisks -o -p mediatype,size)
  local parsed; parsed=$(echo "$pdisks" | parse_pdisks)

  local found=() disk_id media disk_size size_up size_down
  while IFS=$'\t' read -r disk_id media disk_size; do
    [[ "${media^^}" == "$media_filter" ]] || continue
    [[ -z "$disk_size" ]] && continue
    size_up=$(( disk_size + disk_size*15/100 ))
    size_down=$(( disk_size - disk_size*15/100 ))
    if (( size_up >= size_gb && size_down <= size_gb )); then
      found+=("$disk_id")
      (( ${#found[@]} >= count )) && break
    fi
  done <<< "$parsed"
  # NOT a bare `printf '%s\n' "${found[@]}"` — confirmed directly: printf
  # reuses its format at least once even with zero arguments, so an
  # EMPTY found array still emits one blank line. The caller's `mapfile`
  # then sees 1 line (not 0), producing a bogus 1-element disks array
  # whose only element is an empty string — which bypasses the caller's
  # "< want_count" check and surfaces as a confusing "Could not determine
  # RAID controller ID from disk FQDD: " (blank) instead of the real,
  # useful "Could not find N matching disks" message. Guard against
  # printing anything at all when there's genuinely nothing to print.
  (( ${#found[@]} > 0 )) && printf '%s\n' "${found[@]}"
}

# -----------------------------------------------------------------------------
# configure_extra_disk_dell <idrac_ip> <hostname> <raid> <type> <numdisks> <size_gb>
# Creates the RAID volume via racadm. Returns nothing useful on stdout;
# the caller (configure_extra_disks) handles the subsequent LVM/partition
# work over SSH once the OS is up.
# -----------------------------------------------------------------------------
configure_extra_disk_dell(){
  local idrac_ip="$1" raid="$2" type="$3" numdisks="$4" size_gb="$5"

  if [[ "${type^^}" == "NVME" ]]; then
    log INFO "NVMe disk — no RAID to configure, LVM/parted happens directly on the OS"
    return 0
  fi

  local want_count=2
  [[ "$raid" == "0" ]] && want_count=1
  [[ "$raid" == "10" ]] && want_count="$numdisks"

  local disks; mapfile -t disks < <(find_matching_pdisks_dell "$idrac_ip" "$type" "$size_gb" "$want_count")
  if (( ${#disks[@]} < want_count )); then
    log ERROR "Could not find $want_count matching $type disks for size ${size_gb}GB"
    return 1
  fi

  local pdkey; pdkey=$(IFS=,; echo "${disks[*]}")
  # $NF (last colon field), not $3 — same fix as dell_hw.sh's create_os_vdisk:
  # controller ID isn't always the 3rd field (e.g. BOSS controllers use a
  # 2-field FQDD like Disk.Direct.1-1:BOSS.Slot.41-1, where $3 is empty).
  local raid_id; raid_id=$(echo "${disks[0]}" | awk -F: '{print $NF}')
  [[ -z "$raid_id" ]] && { log ERROR "Could not determine RAID controller ID from disk FQDD: ${disks[0]}"; return 1; }
  local vd_name="extra_${raid}_${size_gb}"
  log INFO "Creating RAID${raid} on physical disk(s): ${pdkey} (controller $raid_id)"
  local createvd_out; createvd_out=$(run_racadm "$idrac_ip" storage createvd:"$raid_id" -rl "r${raid}" -pdkey:"$pdkey" -name "$vd_name")
  if echo "$createvd_out" | grep -q "^ERROR"; then
    die "createvd rejected outright on $idrac_ip (controller $raid_id): $(echo "$createvd_out" | grep '^ERROR')"
  fi
  # commit_storage_config (dell_hw.sh), not the raw create_racadm_job +
  # wait_for_racadm_job pair — this controller can be exactly the kind
  # that doesn't support job-queue commits at all (confirmed: the SAME
  # RAID.Integrated.1-1 controller needed the reboot-fallback for both OS
  # vdisk creation and cryptographic erase in a real build). Using the
  # raw pattern here left extra-disk creation with no such fallback,
  # meaning it would fail outright on any hardware where the OS vdisk
  # step only succeeded BECAUSE of that fallback.
  commit_storage_config "$idrac_ip" "$raid_id" "Creating extra disk RAID${raid} (${type})" \
    || { log ERROR "Commit failed creating extra disk RAID${raid} on $idrac_ip (controller $raid_id)"; return 1; }

  # Logs the actual vdisk FQDD (e.g. Disk.Virtual.7:RAID.Integrated.1-1),
  # not just the physical disks and controller — requested specifically
  # for troubleshooting/general info. Looked up by the name we just gave
  # it, using the same non-indented-ID/indented-attribute block parsing
  # already proven correct elsewhere in this pipeline (see parse_pdisks,
  # common.sh) rather than a fragile line-content guess.
  local vd_fqdd
  vd_fqdd=$(run_racadm "$idrac_ip" storage get vdisks -o -p name | awk -v target="Name = ${vd_name}" '
    /^[^[:space:]]/ && NF>0 { id=$0; next }
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line); if (line == target) print id }
  ')
  log INFO "Extra disk RAID${raid} (${type}, ${size_gb}GB) created: vdisk ${vd_fqdd:-<not found — check manually>} on physical disk(s) ${pdkey}"
}

# -----------------------------------------------------------------------------
# configure_extra_disk_cisco <ucsm_ip> <hostname> <raid> <type> <numdisks> <size_gb>
# Uses storcli64 the same way the old ciscoraid.sh / post_build_cisco.sh did:
# storcli is run ON THE SERVER ITSELF (over SSH, post-OS-install) rather than
# through UCSM, since Cisco RAID controller config for data disks is done via
# MegaRAID storcli, not the UCS API.
# -----------------------------------------------------------------------------
configure_extra_disk_cisco(){
  local host_ip="$1" raid="$2" type="$3" numdisks="$4" size_gb="$5"
  log INFO "Querying storcli for available $type disks matching ${size_gb}GB on $host_ip"
  # storcli64 /call/vall show | matching against RAID + size, mirrors the
  # awk pipeline in the old ciscoraid.sh. Left as a direct ssh invocation
  # since the exact storcli enclosure/slot addressing is hardware-specific
  # and should be verified against a real C-series chassis before this is
  # trusted for a production Cisco build.
  # </dev/null — without it, ssh inherits the calling shell's stdin, which
  # silently breaks this if it's ever called from within a while-read loop
  # (confirmed the same root cause elsewhere in this pipeline — see
  # run_racadm()/run_ucsm() in common.sh for the full explanation).
  ssh $SSH_OPTS "$host_ip" "/opt/MegaRAID/storcli/storcli64 /c0 show" </dev/null || {
    log ERROR "storcli query failed on $host_ip"
    return 1
  }
  log WARN "Cisco RAID creation via storcli is stubbed pending real-hardware verification — see README"
}

# -----------------------------------------------------------------------------
# configure_lvm_over_ssh <host_ip> <mount_layout> <size_gb> <lvm_yes_no> <vg_name>
# mount_layout is the serialized "mount:size,mount:size" field from disks.tsv.
# If lvm=No, mount_layout is a single "mount:size" pair meaning "use the
# whole disk for this one mountpoint, no LVM" — matches the CSV/web-tool
# convention exactly.
# -----------------------------------------------------------------------------
configure_lvm_over_ssh(){
  local host_ip="$1" mount_layout="$2" size_gb="$3" lvm="$4" vg_name="$5" pv_device="$6"

  # </dev/null on every ssh call in this function — same fix as
  # run_racadm()/run_ucsm() in common.sh. This one matters most for the
  # LVM-creation loop further down, which calls ssh once per logical
  # volume inside a while-read loop; without this, only the FIRST volume
  # in the list would ever actually get created.
  ssh $SSH_OPTS "$host_ip" "wipefs -a /dev/${pv_device} && dd if=/dev/zero of=/dev/${pv_device} bs=1M count=100" </dev/null \
    || { log ERROR "Failed to wipe /dev/${pv_device} on $host_ip"; return 1; }

  if [[ "$lvm" != "Yes" ]]; then
    local mount; mount=$(echo "$mount_layout" | cut -d: -f1)
    ssh $SSH_OPTS "$host_ip" "
      parted --script /dev/${pv_device} mklabel gpt mkpart primary 0% 100%
      mkfs.xfs -f /dev/${pv_device}1
      uuid=\$(blkid -s UUID -o value /dev/${pv_device}1)
      mkdir -p ${mount}
      echo \"UUID=\$uuid ${mount} xfs defaults 0 0\" >> /etc/fstab
      mount ${mount}
    " </dev/null || { log ERROR "No-LVM filesystem setup failed for ${mount} on $host_ip"; return 1; }
    log INFO "Configured ${mount} (no LVM, whole disk) on $host_ip"
    return 0
  fi

  ssh $SSH_OPTS "$host_ip" "
    parted --script /dev/${pv_device} mklabel gpt mkpart primary 0% 100%
    pvcreate -y /dev/${pv_device}1
    vgcreate -y ${vg_name} /dev/${pv_device}1
  " </dev/null || { log ERROR "PV/VG creation failed on $host_ip"; return 1; }

  echo "$mount_layout" | tr ',' '\n' | while IFS=: read -r mount size; do
    [[ -z "$mount" ]] && continue
    local lv; lv=$(lv_name_for_mount "$mount")
    ssh $SSH_OPTS "$host_ip" "
      lvcreate -y -n ${lv} -L ${size}G ${vg_name}
      mkfs.xfs /dev/${vg_name}/${lv}
      mkdir -p ${mount}
      echo \"/dev/${vg_name}/${lv} ${mount} xfs defaults 0 0\" >> /etc/fstab
      mount ${mount}
    " </dev/null || log ERROR "LV ${lv} (${mount}) failed on $host_ip"
  done
  log INFO "Configured LVM volume group ${vg_name} on $host_ip"
}

# -----------------------------------------------------------------------------
# create_extra_folders_over_ssh <host_ip> <extra_folders_colon_separated>
# -----------------------------------------------------------------------------
create_extra_folders_over_ssh(){
  local host_ip="$1" folders="$2"
  [[ -z "$folders" ]] && return 0
  echo "$folders" | tr ':' '\n' | while read -r f; do
    [[ -z "$f" ]] && continue
    # </dev/null — same fix as above; this loop can iterate multiple
    # folders, and without it only the first would ever get created.
    ssh $SSH_OPTS "$host_ip" "mkdir -p '$f'" </dev/null
  done
}

# -----------------------------------------------------------------------------
# configure_extra_disks <hostname> <host_ip> <hardware> <mgmt_ip> <disks_tsv_path>
# Iterates every row in disks.tsv for this server (one row per RAID/volume
# group) and configures it end to end: RAID creation on the controller, then
# LVM/partition work over SSH into the freshly installed OS.
# -----------------------------------------------------------------------------
configure_extra_disks(){
  local hostname="$1" host_ip="$2" hardware="$3" mgmt_ip="$4" disks_tsv="$5"
  [[ -s "$disks_tsv" ]] || { log INFO "No additional disks configured for $hostname"; return 0; }

  local vg_index=0
  local raid type numdisks lvm mount_layout size_gb extra_folders
  # Confirmed root cause of a real failure (size_gb came through empty,
  # lvm held a mount:size-shaped value): bash's `read` treats TAB as an
  # "IFS whitespace" character NO MATTER WHAT IFS is actually set to —
  # consecutive tabs collapse into one delimiter and empty fields between
  # them are silently dropped, shifting every field after the empty one
  # left by one. num_disks_raid10 is empty on every RAID0/RAID1 row (i.e.
  # almost every real row — RAID10 is the rare case), so this fired on
  # nearly every disk this pipeline has ever tried to configure. A
  # non-whitespace delimiter (comma, pipe, colon) does NOT have this
  # problem and preserves empty fields correctly — confirmed directly.
  # disks.tsv itself doesn't need to change format; converting its tabs
  # to \x1f (Unit Separator, a control character that will never appear
  # in real field data) right here, only for this read, is the minimal
  # fix.
  local US; US=$(printf '\037')
  while IFS="$US" read -r raid type numdisks lvm mount_layout size_gb extra_folders; do
    [[ -z "$raid" && -z "$mount_layout" ]] && continue
    vg_index=$((vg_index+1))

    # Kept as a safety net even with the read fix above — if disks.tsv
    # itself is ever malformed for some other reason, this fails loudly
    # with the raw row shown instead of silently proceeding on empty/
    # garbage values three layers before the real error would surface.
    if [[ -z "$size_gb" || -z "$raid" || -z "$type" ]]; then
      log ERROR "disks.tsv row $vg_index looks malformed — raid='${raid}' type='${type}' numdisks='${numdisks}' lvm='${lvm}' mount_layout='${mount_layout}' size_gb='${size_gb}' extra_folders='${extra_folders}'"
      log ERROR "Raw row: $(awk -v n="$vg_index" 'NR==n' "$disks_tsv" | cat -A)"
      log ERROR "Skipping this row rather than proceeding with empty/garbage values"
      continue
    fi

    log STEP "Configuring extra disk row $vg_index: RAID${raid} ${type} ${size_gb}GB LVM=${lvm}"

    if [[ "$hardware" == "Cisco" ]]; then
      configure_extra_disk_cisco "$host_ip" "$raid" "$type" "$numdisks" "$size_gb"
    else
      configure_extra_disk_dell "$mgmt_ip" "$raid" "$type" "$numdisks" "$size_gb"
    fi

    # Device naming here assumes disks come up in controller order as
    # sdb, sdc, ... — reasonable for a freshly-built single-purpose server,
    # but WORTH VERIFYING against a real box with >1 extra volume before
    # trusting this blindly (see README open items).
    local pv_device
    pv_device=$(printf '\\x%02x' $((97 + vg_index)))  # 'b','c',...
    pv_device="sd$(printf "\\$(printf '%03o' $((98+vg_index-1)))")"

    configure_lvm_over_ssh "$host_ip" "$mount_layout" "$size_gb" "$lvm" "appvg${vg_index}" "$pv_device"
    create_extra_folders_over_ssh "$host_ip" "$extra_folders"
  done < <(tr '\t' "$US" < "$disks_tsv")
}

# -----------------------------------------------------------------------------
# gomp_submit <hostname> <datacenter_token> <os_version>
# Preserved as-is from gomp_submit.sh — this is a live CMDB/orchestration
# integration, not legacy cruft, so behavior is kept identical.
# -----------------------------------------------------------------------------
gomp_submit(){
  local hostname="$1" datacenter_token="$2" os_version="$3"
  local mnemonic; mnemonic=$(echo "$hostname" | head -c4 | tail -c3 | tr '[:lower:]' '[:upper:]')

  local json_data
  json_data=$(cat <<EOF
{
  "RequestInstanceID": 0,
  "Mnemonic": "${mnemonic}",
  "DataCenterToken": "${datacenter_token}",
  "OSVersionToken": "RHEL ${os_version}",
  "ServerInfo": [{"hostname": "${hostname}"}]
}
EOF
)
  log INFO "Submitting GOMP registration for $hostname"
  curl -sk -H "Accept: application/json" -H "Content-Type:application/json" -H "@${PROJECT_ROOT}/.headers" \
    -X POST --data "$json_data" \
    "https://gf-orchestration.pncint.net/PNC.GOMP.Services/api/v1/SOEProvisioning/SubmitUCSD" \
    | python3 -m json.tool >> "${JOB_LOG_DIR}/${hostname}.log" 2>&1
}

# -----------------------------------------------------------------------------
# cleanup_cisco_template <ucsm_ip> <profile> <org> <template_name>
# Rebinds the service profile to its source template (unbound at build start
# in cisco_hw.sh:unbind_profile). Only relevant for Cisco.
# -----------------------------------------------------------------------------
cleanup_cisco_template(){
  local ucsm_ip="$1" profile="$2" org="$3" template="$4"
  [[ -z "$template" ]] && { log WARN "No template name captured — skipping rebind for $profile"; return 0; }
  bind_template "$ucsm_ip" "$profile" "$org" "$template"
}
