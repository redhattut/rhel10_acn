#!/bin/bash
# =============================================================================
# build_server.sh [-t] <hostname> <job_name>
# build_server.sh [-t] <csv_filename>
#
# Full lifecycle for one server: hardware bring-up -> kickstart generation ->
# OS install -> post-install disk/LVM config -> CMDB submission.
#
# Two ways to call this:
#   [-t] <hostname> <job_name>   used internally by build.sh's per-host
#                                 parallel dispatch — one process per server.
#   [-t] <csv_filename>          single-server convenience: point it straight
#                                 at a CSV in csv/incoming/ (same .csv file
#                                 the web tool produces, same filename
#                                 convention as build.sh). Hostname and job
#                                 name both come from the CSV — nothing to
#                                 type by hand. The CSV must contain exactly
#                                 one server; for more than one, use build.sh.
#
# -t / --skip-idrac-reset skips the iDRAC reboot (racadm racreset) entirely
# — no reboot, no 10-minute settle wait. Everything else (300s before
# polling any -r pwrcycle job, then 60s between polls) always happens
# regardless of -t — those aren't optional, iDRAC needs them to actually
# apply what it's committing.
#
# Everything after the OS comes up runs right here — no CGI relay, no
# second jumpbox hop.
# =============================================================================
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage(){
  echo "usage: build_server.sh [-t] <hostname> <job_name>"
  echo "       build_server.sh [-t] <csv_filename>   (CSV must contain exactly one server)"
  echo "  -t   skip the iDRAC reboot (racreset) entirely; everything else waits normally"
}

SKIP_IDRAC_RESET=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--skip-idrac-wait) SKIP_IDRAC_RESET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

HOSTNAME_ARG=""
JOB_NAME=""

if (( ${#POSITIONAL[@]} == 1 )); then
  # CSV mode
  CSV_FILENAME="${POSITIONAL[0]}"
  JOB_NAME="${CSV_FILENAME%.*}"
  CSV_PATH="${PROJECT_ROOT}/csv/incoming/${CSV_FILENAME}"
  [[ -f "$CSV_PATH" ]] || { echo "CSV not found: $CSV_PATH (expected under csv/incoming/)"; exit 1; }

  csv_work_dir="${PROJECT_ROOT}/work/${JOB_NAME}"
  mkdir -p "$csv_work_dir"
  python3 "${PROJECT_ROOT}/lib/csv_split.py" "$CSV_PATH" "$csv_work_dir" \
    || { echo "csv_split.py failed to parse $CSV_PATH"; exit 1; }

  hostlist="${csv_work_dir}/hostlist.txt"
  [[ -s "$hostlist" ]] || { echo "No servers found in $CSV_FILENAME"; exit 1; }
  host_count=$(wc -l < "$hostlist")
  if (( host_count > 1 )); then
    echo "This CSV has $host_count servers — build_server.sh only builds one at a time."
    echo "Use build.sh for multi-server batches: ./bin/build.sh $CSV_FILENAME"
    exit 1
  fi
  HOSTNAME_ARG=$(head -1 "$hostlist")

  # CSV mode dispatches to itself in direct mode, backgrounded — same UX as
  # build.sh: print where to watch, then return control immediately. You
  # shouldn't have to babysit one server's live output when you're about to
  # kick off others.
  dispatch_job_log_dir="${PROJECT_ROOT}/logs/${JOB_NAME}"
  mkdir -p "$dispatch_job_log_dir"
  dispatch_extra_args=()
  (( SKIP_IDRAC_RESET == 1 )) && dispatch_extra_args=(-t)
  nohup "${PROJECT_ROOT}/bin/build_server.sh" "${dispatch_extra_args[@]}" "$HOSTNAME_ARG" "$JOB_NAME" </dev/null >/dev/null 2>&1 &
  echo "$! $HOSTNAME_ARG" >> "${dispatch_job_log_dir}/pids.txt"
  short_name="${HOSTNAME_ARG%%.*}"
  echo "Dispatched $HOSTNAME_ARG (job $JOB_NAME)."
  echo "Watch it with: tail -f ${dispatch_job_log_dir}/${short_name}.log"
  exit 0

elif (( ${#POSITIONAL[@]} == 2 )); then
  # Direct mode — hostname + job name (build.sh's internal dispatch uses this)
  HOSTNAME_ARG="${POSITIONAL[0]}"
  JOB_NAME="${POSITIONAL[1]}"

else
  usage
  exit 1
fi

WORK_DIR="${PROJECT_ROOT}/work/${JOB_NAME}/${HOSTNAME_ARG}"
JOB_LOG_DIR="${PROJECT_ROOT}/logs/${JOB_NAME}"
JOB_RESULTS_FILE="${JOB_LOG_DIR}/results.csv"
HOSTNAME_SHORT="${HOSTNAME_ARG%%.*}"

# log() (in common.sh, sourced next) writes directly to
# logs/<job>/<hostname>.log — that's THE file to watch for one server.
mkdir -p "$JOB_LOG_DIR"

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
  gather_server_info "$MGMT_IP"
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
