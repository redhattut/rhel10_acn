#!/bin/bash
# =============================================================================
# kickstart_gen.sh — builds a per-server kickstart file
#
# The old create_ks_rhel8_dell.sh/create_ks_rhel8_cisco.sh sed-replaced 8
# fixed tokens (rootsize, swapsize, varsize...) one at a time. Since the CSV
# now carries an arbitrary list of core + extra filesystems instead of a
# fixed 8-column layout, this generates the entire logvol block
# programmatically instead.
#
# Fixed toolsvg volumes and (RHEL9-only) rootvg extras are appended
# unconditionally — these mirror exactly what the web intake tool's lsblk
# preview shows, so what a builder previews before export is what actually
# gets built.
# =============================================================================

TEMPLATE_DIR="${PROJECT_ROOT}/templates"

# Root password hash for every kickstart this generates. Replace this value
# directly (e.g. `openssl passwd -6`) — it's a hash, not the plaintext
# password, so it lives here rather than in a separate secrets file.
ROOTPW_HASH='$6$REPLACE_ME_WITH_REAL_HASH$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

# Fixed toolsvg volumes — keep in sync with the web tool's TOOLSVG_LVS list.
TOOLSVG_MOUNTS=(
  "/opt/Tanium:lvopttanium:4096"
  "/opt/app:lvoptapp:20480"
  "/opt/cohesity:lvcohesity:3072"
  "/opt/syslog-ng:lvoptsyslogng:2048"
  "/opt/splunkforwarder:lvsplunkforwarder:10240"
  "/app/dynatraceOneAgent:lvappdynatraceOneAgent:10240"
)
# RHEL 9 only — keep in sync with the web tool's RHEL9_ROOTVG_EXTRA list.
RHEL9_ROOTVG_EXTRA=(
  "/var/tmp:lvvartmp:5120"
  "/var/log:lvvarlog:15360"
  "/var/log/audit:lvaudit:2048"
)

# lv_name_for_mount <mount>
# Mirrors the web tool's shortLvName(): concatenate path segments, strip
# non-alphanumerics, lowercase, prefix "lv". "/" and "swap" are special-cased.
lv_name_for_mount(){
  local mount="$1"
  if [[ "$mount" == "/" ]]; then echo "lvroot"; return; fi
  if [[ "${mount,,}" == "swap" ]]; then echo "lvswap"; return; fi
  local slug
  slug=$(echo "$mount" | tr -d '/' | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
  echo "lv${slug:-data}"
}

# emit_logvol_line <mount> <size_mb> <vgname> [is_last]
emit_logvol_line(){
  local mount="$1" size_mb="$2" vg="$3"
  local lv; lv=$(lv_name_for_mount "$mount")
  if [[ "${mount,,}" == "swap" ]]; then
    echo "logvol swap --fstype swap --name=${lv} --vgname=${vg} --size=${size_mb}"
  else
    echo "logvol ${mount} --fstype xfs --name=${lv} --vgname=${vg} --size=${size_mb}"
  fi
}

# parse_pairs "mount:size,mount:size,..." -> newline-separated "mount size"
parse_pairs(){
  local raw="$1"
  [[ -z "$raw" ]] && return
  echo "$raw" | tr ',' '\n' | while IFS=: read -r m s; do
    [[ -n "$m" ]] && echo "$m $s"
  done
}

# build_logvol_block <core_filesystems> <extra_filesystems> <osver>
# core/extra are the serialized "mount:size,mount:size" CSV fields.
build_logvol_block(){
  local core="$1" extra="$2" osver="$3"
  local block=""

  block+="# rootvg\n"
  while read -r mount size; do
    [[ -z "$mount" ]] && continue
    block+="$(emit_logvol_line "$mount" "$size" "rootvg")\n"
  done < <(parse_pairs "$core")

  while read -r mount size; do
    [[ -z "$mount" ]] && continue
    block+="$(emit_logvol_line "$mount" "$size" "rootvg")  # extra filesystem\n"
  done < <(parse_pairs "$extra")

  if [[ "$osver" == "9.8" ]]; then
    for entry in "${RHEL9_ROOTVG_EXTRA[@]}"; do
      IFS=: read -r mount lv size <<< "$entry"
      block+="logvol ${mount} --fstype xfs --name=${lv} --vgname=rootvg --size=${size}  # RHEL9 default\n"
    done
  fi

  block+="\n# toolsvg (fixed, not user-configurable)\n"
  for entry in "${TOOLSVG_MOUNTS[@]}"; do
    IFS=: read -r mount lv size <<< "$entry"
    block+="logvol ${mount} --fstype xfs --name=${lv} --vgname=toolsvg --size=${size}\n"
  done

  echo -e "$block"
}

# build_boot_partitions <boot_mode> <os_disk_gb>
# UEFI: /boot/efi + /boot + rootvg partition + toolsvg partition (80G fixed)
# Legacy: /boot + rootvg partition + toolsvg partition (80G fixed)
build_boot_partitions(){
  local boot_mode="$1" osdisk_gb="$2"
  local toolsvg_gb=80
  local rootvg_mb
  if [[ "$boot_mode" == "UEFI" ]]; then
    rootvg_mb=$(( (osdisk_gb - 2 - 2 - toolsvg_gb) * 1024 ))
    cat <<EOF
zerombr
clearpart --all --initlabel
part /boot/efi --fstype efi --size=2048
part /boot --fstype xfs --size=2048
part pv.13 --size=${rootvg_mb} --grow
part pv.14 --size=$((toolsvg_gb*1024))
volgroup rootvg --pesize=4096 pv.13
volgroup toolsvg --pesize=4096 pv.14
bootloader --location=partition --boot-drive=sda
EOF
  else
    rootvg_mb=$(( (osdisk_gb - 2 - toolsvg_gb) * 1024 ))
    cat <<EOF
zerombr
clearpart --all --initlabel
part /boot --fstype xfs --size=2048
part pv.13 --size=${rootvg_mb} --grow
part pv.14 --size=$((toolsvg_gb*1024))
volgroup rootvg --pesize=4096 pv.13
volgroup toolsvg --pesize=4096 pv.14
bootloader --location=mbr
EOF
  fi
}

# build_pnc_provision_config_block <name> <ip> <gateway> <location> <ci_device>
build_pnc_provision_config_block(){
  local name="$1" ip="$2" gw="$3" location="$4" ci_device="$5"
  cat <<EOF
echo "BUILDSERVER=\\"lmrg34ja\\"
BUILD_OS=\\"RHEL\\"
HOSTNAME=\\"${name}\\"
FINALIPADDR=\\"${ip}\\"
GATEWAY=\\"${gw}\\"
LOCATION=\\"${location}\\"
CIDEVICE=\\"${ci_device}\\"
###" >/boot/PNC_PROVISION_CONFIG
EOF
}

# generate_kickstart — main entry point
# Reads all fields from the already-sourced server.env (see build_server.sh),
# writes the finished .ks to $1
generate_kickstart(){
  local out_path="$1"
  local tmpl_path
  if [[ "$HARDWARE" == "Cisco" ]]; then
    tmpl_path="${TEMPLATE_DIR}/kickstart-cisco.ks.tmpl"
  else
    tmpl_path="${TEMPLATE_DIR}/kickstart-dell.ks.tmpl"
  fi
  [[ -s "$tmpl_path" ]] || die "Kickstart template missing or empty: $tmpl_path — confirm templates/ was deployed alongside the rest of this project on lmrg34ja"

  local domain; domain=$(echo "$HOSTNAME" | cut -d'.' -f2-)
  # Package source: a static mirror per RHEL MAJOR version, not per exact
  # minor. Every 8.x build (8.8 or 8.10 selected in the CSV) installs from
  # the same RHEL8-x86_64 base tree; Satellite patches it to the exact
  # requested minor afterward, triggered by GOMP after submission — see
  # README "Package source" for why this was chosen over registering to
  # Satellite during the install itself.
  local major; major=$(rhel_major "$OS_VERSION")
  local repo_url="http://100.64.1.101/PNC/distros/RHEL${major}-x86_64/"
  local rootpw_hash="$ROOTPW_HASH"

  local network_line
  if [[ "$LACP" == "Yes" ]]; then
    network_line="--bootproto static --ip=${IP} --netmask=255.255.255.0 --gateway=${GATEWAY} --nameserver=192.88.246.62 --hostname=${HOSTNAME} --device=bond0 --bondslaves=${NIC} --bondopts=802.3ad,lacp_rate=fast,miimon=100,xmit_hash_policy=layer2+3"
  else
    network_line="--bootproto static --ip=${IP} --netmask=255.255.255.0 --gateway=${GATEWAY} --nameserver=192.88.246.62 --hostname=${HOSTNAME} --device=${NIC}"
  fi

  local logvol_block; logvol_block=$(build_logvol_block "$CORE_FILESYSTEMS" "$EXTRA_FILESYSTEMS" "$OS_VERSION")
  local boot_partitions=""
  [[ "$HARDWARE" != "Cisco" ]] && boot_partitions=$(build_boot_partitions "$BOOT_MODE" "$OS_DISK_GB")
  local provision_block; provision_block=$(build_pnc_provision_config_block "$HOSTNAME" "$IP" "$GATEWAY" "$LOCATION" "$CI_DEVICE")

  sed \
    -e "s#__HOSTNAME__#${HOSTNAME}#g" \
    -e "s#__REPO_URL__#${repo_url}#g" \
    -e "s#__ROOTPW_HASH__#${rootpw_hash}#g" \
    -e "s#__NETWORK_LINE__#${network_line}#g" \
    -e "s#__IP__#${IP}#g" \
    -e "s#__GATEWAY__#${GATEWAY}#g" \
    -e "s#__DOMAIN__#${domain}#g" \
    -e "s#__MAC__#${MAC}#g" \
    -e "s#__MTU__#9000#g" \
    "$tmpl_path" > "$out_path"

  # Multi-line blocks are inserted with a python-free awk pass since sed
  # can't cleanly substitute newlines-in-replacement across all seds.
  awk -v boot="$boot_partitions" -v logvol="$logvol_block" -v prov="$provision_block" '
    { line=$0
      gsub(/__BOOT_PARTITIONS__/, boot, line)
      gsub(/__LOGVOL_BLOCK__/, logvol, line)
      gsub(/__PNC_PROVISION_CONFIG_BLOCK__/, prov, line)
      print line
    }' "$out_path" > "${out_path}.tmp" && mv "${out_path}.tmp" "$out_path"

  [[ -s "$out_path" ]] || die "Generated kickstart is empty: $out_path — sed/awk pipeline produced no output despite template existing, check $tmpl_path manually"

  log INFO "Kickstart written to $out_path"
}
