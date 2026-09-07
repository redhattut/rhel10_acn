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

# derive_location_and_cidevice <datacenter> <environment>
# Sets DERIVED_LOCATION and DERIVED_CI_DEVICE globally (NOT via
# echo+command-substitution — die() below calls exit, and exit inside a
# $(...) subshell only kills the subshell, not the whole script; a bad
# DATACENTER value would silently continue with garbage instead of
# actually stopping the build).
#
# DATACENTER is either a bare location (GF0, GF2 — no CI device needed)
# or "LOCATION/DCEn" (GF1, East, Central — CI device is DCEn-PROD or
# DCEn-NP depending on ENVIRONMENT). Confirmed valid combinations:
#   GF1/DCE1, GF1/DCE2, GF1/DCE3
#   East/DCE1, East/DCE2, East/DCE3
#   Central/DCC1, Central/DCC2, Central/DCC3
# GF0 and GF2 take no CI device suffix at all.
derive_location_and_cidevice(){
  local datacenter="$1" environment="$2"
  DERIVED_LOCATION="$datacenter"
  DERIVED_CI_DEVICE=""

  local valid_locations=(GF0 GF1 GF2 East Central)

  if [[ "$datacenter" == */* ]]; then
    DERIVED_LOCATION="${datacenter%%/*}"
    local dce_prefix="${datacenter#*/}"
    case "$dce_prefix" in
      DCE1|DCE2|DCE3|DCC1|DCC2|DCC3) : ;;
      *) die "DATACENTER='$datacenter' has an unrecognized CI device prefix '$dce_prefix' — expected DCE1/DCE2/DCE3 (GF1/East) or DCC1/DCC2/DCC3 (Central)" ;;
    esac
    local env_suffix="NP"
    [[ "${environment,,}" == "prod" ]] && env_suffix="PROD"
    DERIVED_CI_DEVICE="${dce_prefix}-${env_suffix}"
  fi

  local ok=0 v
  for v in "${valid_locations[@]}"; do [[ "$DERIVED_LOCATION" == "$v" ]] && ok=1; done
  (( ok == 1 )) || die "DATACENTER='$datacenter' produced an unrecognized LOCATION '$DERIVED_LOCATION' — expected one of: ${valid_locations[*]}"
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

  # RHEL9_ROOTVG_EXTRA applies based on major version, not the exact
  # install-media minor — unlike the grub label/menuentry-title bug fixed
  # in iso_gen.sh (which was specifically about matching the fixed
  # install-media version), this is "are we building a RHEL9 server at
  # all," which is a $osver-major question, correctly answered regardless
  # of whether the CSV's exact target is 9.4, 9.5, etc.
  if [[ "$(rhel_major "$osver")" == "9" ]]; then
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

# network_device_part <LACP: Yes|No> <nic>
# The templates now show the full "network" line directly except for this
# one piece — --device=X differs structurally between a bonded and a plain
# NIC, not just by value, so it can't be a single-value substitution the
# way __IP__/__GATEWAY__ are.
#
# LACP yes/no is evaluated via is_lacp_enabled() (common.sh) — the SAME
# function iso_gen.sh uses for the boot-time kernel append line. Do not
# duplicate the comparison here; if the install-time network config and the
# boot-time kernel append line ever disagree about bonded vs. non-bonded,
# that's a silent, hard-to-diagnose failure.
network_device_part(){
  local lacp="$1" nic="$2"
  if is_lacp_enabled "$lacp"; then
    log INFO "LACP='${lacp}' -> bonded (--device=bond0, bondslaves=${nic})"
    echo "--device=bond0 --bondslaves=${nic} --bondopts=802.3ad,lacp_rate=fast,miimon=100,xmit_hash_policy=layer2+3"
  else
    log INFO "LACP='${lacp}' -> non-bonded (--device=${nic})"
    echo "--device=${nic}"
  fi
}

# generate_kickstart — main entry point
# Reads all fields from the already-sourced server.env (see build_server.sh),
# writes the finished .ks to $1
generate_kickstart(){
  local out_path="$1"

  local major; major=$(rhel_major "$OS_VERSION")
  if [[ "$major" != "8" && "$major" != "9" ]]; then
    die "Only RHEL 8 and RHEL 9 are supported (OS_VERSION=$OS_VERSION, major=$major)."
  fi

  local tmpl_path
  if [[ "$HARDWARE" == "Cisco" ]]; then
    tmpl_path="${TEMPLATE_DIR}/kickstart-cisco-rhel${major}.ks.tmpl"
  elif [[ "$BOOT_MODE" == "UEFI" ]]; then
    tmpl_path="${TEMPLATE_DIR}/kickstart-dell-rhel${major}-uefi.ks.tmpl"
  else
    tmpl_path="${TEMPLATE_DIR}/kickstart-dell-rhel${major}-legacy.ks.tmpl"
  fi
  [[ -s "$tmpl_path" ]] || die "Kickstart template missing or empty: $tmpl_path — confirm templates/ was deployed alongside the rest of this project on lmrg34ja"

  local domain; domain=$(echo "$HOSTNAME" | cut -d'.' -f2-)
  local net_device_part; net_device_part=$(network_device_part "$LACP" "$NIC")
  local logvol_block; logvol_block=$(build_logvol_block "$CORE_FILESYSTEMS" "$EXTRA_FILESYSTEMS" "$OS_VERSION")

  # LOCATION/CI_DEVICE were previously passed straight through from the
  # CSV's own (unpopulated) location/ci_device columns — confirmed always
  # empty in practice. They're actually DERIVED from DATACENTER +
  # ENVIRONMENT (see derive_location_and_cidevice above), not entered
  # directly.
  derive_location_and_cidevice "$DATACENTER" "$ENVIRONMENT"

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
  #
  # PNC_PROVISION_CONFIG_BLOCK no longer exists as a whole-block token — the
  # echo/PNC_PROVISION_CONFIG structure is now static text directly in each
  # template, with only the actual per-server values (__LOCATION__,
  # __CI_DEVICE__, plus the pre-existing __HOSTNAME__/__IP__/__GATEWAY__)
  # substituted individually.
  local awk_err; awk_err=$(mktemp)
  awk \
    -v hostname="$HOSTNAME" \
    -v net_device_part="$net_device_part" \
    -v ip="$IP" \
    -v gateway="$GATEWAY" \
    -v domain="$domain" \
    -v mac="$MAC" \
    -v location="$DERIVED_LOCATION" \
    -v ci_device="$DERIVED_CI_DEVICE" \
    -v environment="$ENVIRONMENT" \
    -v os_disk_gb="$OS_DISK_GB" \
    -v os_disk_bus_protocol="${OS_DISK_BUS_PROTOCOL:-}" \
    -v logvol="$logvol_block" '
    {
      line = $0
      gsub(/__HOSTNAME__/, hostname, line)
      gsub(/__NETWORK_DEVICE_PART__/, net_device_part, line)
      gsub(/__IP__/, ip, line)
      gsub(/__GATEWAY__/, gateway, line)
      gsub(/__DOMAIN__/, domain, line)
      gsub(/__MAC__/, mac, line)
      gsub(/__MTU__/, "9000", line)
      gsub(/__LOCATION__/, location, line)
      gsub(/__CI_DEVICE__/, ci_device, line)
      gsub(/__ENVIRONMENT__/, environment, line)
      gsub(/__OS_DISK_GB__/, os_disk_gb, line)
      gsub(/__OS_DISK_BUS_PROTOCOL__/, os_disk_bus_protocol, line)
      gsub(/__LOGVOL_BLOCK__/, logvol, line)
      print line
    }' "$tmpl_path" > "$out_path" 2>"$awk_err"
  # NOT two separate `local awk_rc=$?` lines — the second one was
  # clobbering the real awk exit code with 0 (its own `local` assignment's
  # own success status), silently defeating the die() check right below
  # this — awk could fail outright and this would never have caught it.
  local awk_rc=$?

  if (( awk_rc != 0 )); then
    die "awk failed generating kickstart from $tmpl_path (exit $awk_rc): $(cat "$awk_err")"
  fi
  rm -f "$awk_err"

  [[ -s "$out_path" ]] || die "Generated kickstart is empty: $out_path — awk exited 0 with no error but produced no output. Template is $(wc -l < "$tmpl_path") lines at $tmpl_path — check it and the substitution values (HOSTNAME=$HOSTNAME, IP=$IP) manually."

  log INFO "Kickstart written to $out_path"
}
