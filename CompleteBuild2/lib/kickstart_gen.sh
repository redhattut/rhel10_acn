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
ROOTPW_HASH='$6$y5xGWWpN7mRTRQuG$V5.qvYvWJcv8QD6V5n.OgB5wFQmlFdFMKGRlSONg98alArX0Hm4beOnBLtglCuGyn3Ry4S1cKoxdnlPyzLScJ1'

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
  local boot_mode="$1" osdisk_gb="$2"  # osdisk_gb no longer used — see below
  local toolsvg_mb=81920   # 80GB, fixed regardless of actual disk size
  local rootvg_mb=153600   # 150GB minimum — --grow below consumes whatever
                            # space is actually left on the disk beyond this;
                            # this is a floor, not a computed exact-fit size
  if [[ "$boot_mode" == "UEFI" ]]; then
    cat <<EOF
bootloader --location=partition --boot-drive=sda --append="crashkernel=auto rhgb quiet" --driveorder=/dev/sda
zerombr
ignoredisk --only-use=/dev/sda
clearpart --all --drives=/dev/sda
part /boot --fstype xfs --size=2048
part /boot/efi --fstype efi --size=2048
part pv.13 --size=${rootvg_mb} --grow --ondisk=/dev/sda
part pv.14 --size=${toolsvg_mb} --ondisk=/dev/sda
volgroup rootvg --pesize=4096 pv.13
volgroup toolsvg --pesize=4096 pv.14
EOF
  else
    cat <<EOF
bootloader --location=mbr --append="crashkernel=auto rhgb quiet" --driveorder=/dev/sda
zerombr
ignoredisk --only-use=/dev/sda
clearpart --all --drives=/dev/sda
part /boot --fstype xfs --size=2048
part pv.13 --size=${rootvg_mb} --grow --ondisk=/dev/sda
part pv.14 --size=${toolsvg_mb} --ondisk=/dev/sda
volgroup rootvg --pesize=4096 pv.13
volgroup toolsvg --pesize=4096 pv.14
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
  local repo_url="http://lmrg34ga.prod.pncint.net/PNC/distros/RHEL${major}-x86_64/"
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

  # Single-pass substitution — one tool, one point of failure. This used to
  # be sed for simple tokens + a second, separate awk pass for the
  # multi-line blocks (partition layout, LVM volumes, PNC provisioning
  # config — genuinely need awk's gsub for multi-line replacement text,
  # sed struggles with that reliably). But splitting it into two stages
  # doubled the places this could silently break, and neither stage
  # captured its own error output — so when it broke on a real test run,
  # the only visible symptom was "empty file," with no way to tell which
  # stage failed or why. Consolidating to one awk pass with stderr actually
  # captured fixes both problems at once.
  local awk_err; awk_err=$(mktemp)
  awk \
    -v hostname="$HOSTNAME" \
    -v repo_url="$repo_url" \
    -v rootpw_hash="$rootpw_hash" \
    -v network_line="$network_line" \
    -v ip="$IP" \
    -v gateway="$GATEWAY" \
    -v domain="$domain" \
    -v mac="$MAC" \
    -v boot="$boot_partitions" \
    -v logvol="$logvol_block" \
    -v prov="$provision_block" '
    {
      line = $0
      gsub(/__HOSTNAME__/, hostname, line)
      gsub(/__REPO_URL__/, repo_url, line)
      gsub(/__ROOTPW_HASH__/, rootpw_hash, line)
      gsub(/__NETWORK_LINE__/, network_line, line)
      gsub(/__IP__/, ip, line)
      gsub(/__GATEWAY__/, gateway, line)
      gsub(/__DOMAIN__/, domain, line)
      gsub(/__MAC__/, mac, line)
      gsub(/__MTU__/, "9000", line)
      gsub(/__BOOT_PARTITIONS__/, boot, line)
      gsub(/__LOGVOL_BLOCK__/, logvol, line)
      gsub(/__PNC_PROVISION_CONFIG_BLOCK__/, prov, line)
      print line
    }' "$tmpl_path" > "$out_path" 2>"$awk_err"
  local awk_rc=$?

  if (( awk_rc != 0 )); then
    die "awk failed generating kickstart from $tmpl_path (exit $awk_rc): $(cat "$awk_err")"
  fi
  rm -f "$awk_err"

  [[ -s "$out_path" ]] || die "Generated kickstart is empty: $out_path — awk exited 0 with no error but produced no output. Template is $(wc -l < "$tmpl_path") lines at $tmpl_path — check it and the substitution values (HOSTNAME=$HOSTNAME, IP=$IP) manually."

  log INFO "Kickstart written to $out_path"
}
