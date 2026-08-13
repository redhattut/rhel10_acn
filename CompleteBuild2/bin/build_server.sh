#!/bin/bash
# =============================================================================
# build_server.sh <hostname> <job_name>
#
# Full lifecycle for one server: hardware bring-up -> kickstart generation ->
# OS install -> post-install disk/LVM config -> CMDB submission.
#
# Called by build.sh, backgrounded (one process per server, same as the old
# build_wrapper.sh's parallel dispatch). Everything after the OS comes up
# runs right here — no CGI relay, no second jumpbox hop.
# =============================================================================
set -u

HOSTNAME_ARG="$1"
JOB_NAME="$2"
[[ -z "$HOSTNAME_ARG" || -z "$JOB_NAME" ]] && { echo "usage: build_server.sh <hostname> <job_name>"; exit 1; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${PROJECT_ROOT}/work/${JOB_NAME}/${HOSTNAME_ARG}"
JOB_LOG_DIR="${PROJECT_ROOT}/logs/${JOB_NAME}"
JOB_SUMMARY_LOG="${JOB_LOG_DIR}/job-summary.log"
JOB_RESULTS_FILE="${JOB_LOG_DIR}/results.csv"
HOSTNAME_SHORT="${HOSTNAME_ARG%%.*}"

# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/dell_hw.sh"
source "${PROJECT_ROOT}/lib/cisco_hw.sh"
source "${PROJECT_ROOT}/lib/kickstart_gen.sh"
source "${PROJECT_ROOT}/lib/iso_gen.sh"
source "${PROJECT_ROOT}/lib/post_install.sh"

check_secrets

[[ -f "${WORK_DIR}/server.env" ]] || die "No server.env found for $HOSTNAME_ARG — did csv_split.py run?"
source "${WORK_DIR}/server.env"

log STEP "=== Starting build for $HOSTNAME (job $JOB_NAME, hardware $HARDWARE) ==="

# ---- Network facts ----
IP=$(dig +short "$HOSTNAME" | head -1)
[[ -z "$IP" ]] && die "DNS lookup failed for $HOSTNAME"
GATEWAY=$(echo "$IP" | sed 's/\.[0-9]*$/.1/')
log INFO "Resolved $HOSTNAME -> $IP (gateway $GATEWAY)"

MGMT_IP="$MGMT_ADDRESS"
if [[ ! "$MGMT_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  MGMT_IP=$(dig +short "$MGMT_ADDRESS" | head -1)
  [[ -z "$MGMT_IP" ]] && die "DNS lookup failed for management address $MGMT_ADDRESS"
fi
log INFO "Management address: $MGMT_ADDRESS -> $MGMT_IP"

CORE_FILESYSTEMS="/:${ROOT_MB},swap:${SWAP_MB},/var:${VAR_MB},/opt:${OPT_MB},/app:${APP_MB},/home:${HOME_MB},/tmp:${TMP_MB}"
# NOTE: OPTAPP_MB ("/opt/app MB" in the CSV/web tool) is intentionally NOT
# included here. /opt/app is already a fixed toolsvg volume (see
# kickstart_gen.sh's TOOLSVG_MOUNTS) — including it here would mount the
# same path twice. The original OS-Sizes spreadsheet had this same column
# (optappsize) and never actually wired it into the real template either;
# this preserves that (harmless) dead-field behavior instead of turning it
# into an active mount collision. See README "Open items" for the
# corresponding follow-up on the web tool's OS Disk tab.

KS_OUT="${WORK_DIR}/${HOSTNAME_SHORT}.ks"
UCSM_TEMPLATE_NAME=""   # captured for Cisco rebind at the end

# =============================================================================
# Hardware bring-up
# =============================================================================
if [[ "$HARDWARE" == "Cisco" ]]; then
  NIC="nic1"
  PROFILE="$HOSTNAME_SHORT"
  ORG="$ORG_NAME"

  log STEP "Cisco bring-up: $PROFILE in org $ORG via UCSM $MGMT_IP"
  require_ucsm_reachable "$MGMT_IP"
  UCSM_TEMPLATE_NAME=$(get_template_name "$MGMT_IP" "$PROFILE" "$ORG")
  MAC=$(get_mac_ucsm "$MGMT_IP" "$PROFILE" "$ORG")
  [[ -z "$MAC" ]] && die "Could not determine MAC address from UCSM"
  ucsm_boot_mode=$(get_boot_mode_ucsm "$MGMT_IP" "$PROFILE" "$ORG")
  [[ -n "$ucsm_boot_mode" ]] && BOOT_MODE="$ucsm_boot_mode"

  generate_kickstart "$KS_OUT"
  build_boot_iso "$KS_OUT"

  unbind_profile "$MGMT_IP" "$PROFILE" "$ORG"
  create_and_mount_vmedia "$MGMT_IP" "$PROFILE" "$ORG"
  SLOT=$(run_ucsm "$MGMT_IP" "scope org /${ORG};enter service-profile ${PROFILE} instance;show detail" | grep -i "Server:" | awk -F: '{print $2}' | tr -d ' ')
  reboot_server_ucsm "${SLOT:-$PROFILE}" "$MGMT_IP"

else
  NIC="ens0"
  log STEP "Dell bring-up: $HOSTNAME via iDRAC $MGMT_IP"
  require_idrac_reachable "$MGMT_IP"
  racreset_idrac "$MGMT_IP"
  ensure_power_on "$MGMT_IP"
  set_cpufreq "$MGMT_IP"
  create_os_vdisk "$MGMT_IP" "$OS_DISK_GB"
  MAC=$(get_mac "$MGMT_IP")
  [[ -z "$MAC" ]] && die "Could not determine MAC address from iDRAC"
  set_boot_mode "$MGMT_IP" "$BOOT_MODE"

  generate_kickstart "$KS_OUT"
  build_boot_iso "$KS_OUT"

  mount_install_media "$MGMT_IP" "$HOSTNAME_SHORT"
  restart_server_dell "$MGMT_IP"
fi

log INFO "Kickstart and hardware bring-up complete for $HOSTNAME. Waiting for OS install."

# =============================================================================
# Wait for OS install to finish, then run post-install
# =============================================================================
sleep 900   # rough estimate for a RHEL minimal install; ssh_wait below is the real gate
ssh_wait "$HOSTNAME" 40 30 || die "SSH never came up on $HOSTNAME after install"

log STEP "OS is up on $HOSTNAME — starting post-install configuration"
# Satellite registration/patching is triggered downstream by GOMP after
# gomp_submit() below, not by this script — see lib/post_install.sh.
configure_extra_disks "$HOSTNAME_SHORT" "$HOSTNAME" "$HARDWARE" "$MGMT_IP" "${WORK_DIR}/disks.tsv"

if [[ "$HARDWARE" == "Cisco" ]]; then
  cleanup_cisco_template "$MGMT_IP" "$HOSTNAME_SHORT" "$ORG_NAME" "$UCSM_TEMPLATE_NAME"
fi

gomp_submit "$HOSTNAME_SHORT" "$DATACENTER" "$OS_VERSION"

log STEP "=== Build complete for $HOSTNAME ==="
record_result "SUCCESS" "build and post-install complete"
