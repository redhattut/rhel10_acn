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

# common.sh sourced immediately, before argument parsing — needed so -h/
# --help and --skip validation can use the shared SKIP_REGISTRY (single
# source of truth for valid skip names, see common.sh) without duplicating
# it here and risking the two drifting apart. log()/die() both degrade
# gracefully with no JOB_LOG_DIR/HOSTNAME_SHORT set yet (falls back to
# stderr + a "job" placeholder name) — safe to source this early.
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"

usage(){
  cat << EOF
usage: build_server.sh [options] <hostname> <job_name>
       build_server.sh [options] <csv_filename>   (CSV must contain exactly one server)

Two ways to call this:
  <hostname> <job_name>   used internally by build.sh's per-host parallel
                           dispatch — one process per server.
  <csv_filename>           single-server convenience: point it straight at a
                           CSV in csv/incoming/ (same .csv the web tool
                           produces). Hostname and job name both come from
                           the CSV. The CSV must contain exactly one server;
                           for more than one, use build.sh.

Options:
  -t, --skip-idrac-wait   Legacy alias for --skip=racreset.
  --skip=<name>[,<name>...]
                          Skip an entire step or a specific fine-grained
                          task instead of redoing work that's already
                          correct on the actual hardware from a previous
                          run. Repeatable, or comma-separated in one flag.
                          Logs "SKIPPED: ..." for anything skipped this way.
  --mac=<address>         Supply the MAC address manually instead of
                          querying it from iDRAC/UCSM. REQUIRED if
                          --skip=get-mac is used.
  -h, --help              Show this help and the full list of --skip names.

EOF
  print_skip_help
}

SKIP_IDRAC_RESET=0
MAC_OVERRIDE=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--skip-idrac-wait) SKIP_IDRAC_RESET=1; shift ;;
    --skip=*) validate_skip_names "${1#*=}"; SKIP_LIST="${SKIP_LIST} ${1#*=}"; shift ;;
    --skip) validate_skip_names "$2"; SKIP_LIST="${SKIP_LIST} $2"; shift 2 ;;
    --mac=*) MAC_OVERRIDE="${1#*=}"; shift ;;
    --mac) MAC_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
SKIP_LIST="${SKIP_LIST// /,}"
SKIP_LIST="${SKIP_LIST//,,/,}"
SKIP_LIST="${SKIP_LIST# }"
(( SKIP_IDRAC_RESET == 1 )) && SKIP_LIST="${SKIP_LIST:+$SKIP_LIST,}racreset"
# Normalize to space-delimited with leading/trailing space for is_skipped()'s
# substring-safe membership test (" $SKIP_LIST " == *" $name "*).
SKIP_LIST=" ${SKIP_LIST//,/ } "

if is_skipped "get-mac" && [[ -z "$MAC_OVERRIDE" ]]; then
  die "--skip=get-mac requires --mac=<address> to supply the MAC manually — it's needed for kickstart/kernel append line generation and can't just be left blank."
fi

HOSTNAME_ARG=""
JOB_NAME=""

if (( ${#POSITIONAL[@]} == 1 )); then
  # CSV mode
  CSV_FILENAME="${POSITIONAL[0]}"
  JOB_NAME="${CSV_FILENAME%.*}"
  CSV_PATH="${PROJECT_ROOT}/csv/incoming/${CSV_FILENAME}"
  [[ -f "$CSV_PATH" ]] || { echo "CSV not found: $CSV_PATH (expected under csv/incoming/)"; exit 1; }

  # JOB_LOG_DIR/check_secrets — common.sh itself is already sourced (see
  # top of file); this whole CSV-mode block can already use log()/die()/
  # job_has_active_lock. HOSTNAME_SHORT stays unset ("job" fallback in
  # log()) until direct mode sets it to the real host.
  JOB_LOG_DIR="${PROJECT_ROOT}/logs/${JOB_NAME}"
  mkdir -p "$JOB_LOG_DIR"
  check_secrets

  csv_work_dir="${PROJECT_ROOT}/work/${JOB_NAME}"

  # Rerunning the same job name (same CSV filename) now resets that job's
  # work/ and logs/ directories automatically instead of requiring manual
  # cleanup first — but ONLY if nothing from a previous run of this job is
  # still actively building (job_has_active_lock, common.sh).
  still_active=$(job_has_active_lock "$JOB_LOG_DIR")
  if [[ -n "$still_active" ]]; then
    die "Job $JOB_NAME still has an active build in progress for: $still_active. Wait for it to finish, or cancel it first with: ./bin/stop_build.sh <hostname> $JOB_NAME — not resetting work/${JOB_NAME} or logs/${JOB_NAME} while that's running."
  fi
  rm -rf "$csv_work_dir" "$JOB_LOG_DIR"
  mkdir -p "$csv_work_dir" "$JOB_LOG_DIR"
  log INFO "Reset work/${JOB_NAME} and logs/${JOB_NAME} for a clean rerun"

  python3 "${PROJECT_ROOT}/lib/csv_split.py" "$CSV_PATH" "$csv_work_dir" \
    || die "csv_split.py failed to parse $CSV_PATH"

  hostlist="${csv_work_dir}/hostlist.txt"
  [[ -s "$hostlist" ]] || die "No servers found in $CSV_FILENAME"
  host_count=$(wc -l < "$hostlist")
  if (( host_count > 1 )); then
    die "This CSV has $host_count servers — build_server.sh only builds one at a time. Use build.sh for multi-server batches: ./bin/build.sh $CSV_FILENAME"
  fi
  HOSTNAME_ARG=$(head -1 "$hostlist")

  # CSV mode dispatches to itself in direct mode, backgrounded — same UX as
  # build.sh: print where to watch, then return control immediately. You
  # shouldn't have to babysit one server's live output when you're about to
  # kick off others.
  dispatch_extra_args=()
  # SKIP_LIST already has "racreset" folded in if -t/--skip-idrac-wait was
  # given (see the arg-parsing block above) — no need to also pass -t
  # separately, --skip= alone carries everything through.
  [[ -n "${SKIP_LIST// }" ]] && dispatch_extra_args+=(--skip="$(echo "$SKIP_LIST" | tr -s ' ' ',' | sed 's/^,//;s/,$//')")
  [[ -n "$MAC_OVERRIDE" ]] && dispatch_extra_args+=(--mac="$MAC_OVERRIDE")
  # setsid — makes the dispatched process its own session/process-group
  # leader, so stop_build.sh can kill the whole tree (build_server.sh plus
  # any in-flight ssh/sleep children) with one `kill -TERM -- -<pid>`
  # instead of leaving orphaned ssh sessions behind.
  setsid nohup "${PROJECT_ROOT}/bin/build_server.sh" "${dispatch_extra_args[@]}" "$HOSTNAME_ARG" "$JOB_NAME" </dev/null >/dev/null 2>&1 &
  echo "$! $HOSTNAME_ARG" >> "${JOB_LOG_DIR}/pids.txt"
  short_name="${HOSTNAME_ARG%%.*}"
  log INFO "Dispatched $HOSTNAME_ARG (job $JOB_NAME)."
  echo "Dispatched $HOSTNAME_ARG (job $JOB_NAME)."
  echo "Watch it with: tail -f ${JOB_LOG_DIR}/${short_name}.log"
  echo "Stop it with:  ./bin/stop_build.sh ${short_name} ${JOB_NAME}"
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

# Per-host lock — refuses a second concurrent build_server.sh run against
# the SAME host+job. Without this, running the same host twice (e.g.
# re-running after CSV-mode's dispatch-and-detach returned control
# immediately, not realizing the first run was still going in the
# background) launches two processes that both reconfigure the same
# physical server's BIOS/RAID/network concurrently and both append to the
# same per-host log file — the two timelines interleave, and one process's
# late-stage "waiting for SSH" can land chronologically in the middle of
# the other's still-in-progress RAID setup, which is exactly as confusing
# and as dangerous as it sounds for actual shared hardware.
LOCK_FILE="${JOB_LOG_DIR}/${HOSTNAME_SHORT}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  existing_pid=$(cat "$LOCK_FILE" 2>/dev/null)
  # die() (not a manual echo) — common.sh is already sourced at the top of
  # this file now, before argument parsing even starts, so log()/die() are
  # available here same as anywhere else in the script.
  die "A build_server.sh run for $HOSTNAME_ARG (job $JOB_NAME) is already in progress (lock held${existing_pid:+, pid in lock file: $existing_pid}). Not starting a second one. If that run is actually dead, remove $LOCK_FILE and retry."
fi
echo "$$" >&9

# Graceful cancellation — stop_build.sh sends SIGTERM to this whole process
# group (see setsid in the CSV-mode dispatch above / build.sh's dispatch).
# Without this trap, the process just dies wherever it happened to be
# (mid-racadm-call, mid-sleep) with no record of WHY in the log — this
# makes "someone cancelled it" a clear, deliberate log entry and a distinct
# results.csv outcome instead of looking like an unexplained crash.
trap 'log ERROR "Build cancelled (signal received) — stopping"; record_result "CANCELLED" "Build cancelled by user request"; exit 143' TERM INT

source "${PROJECT_ROOT}/lib/dell_hw.sh"
source "${PROJECT_ROOT}/lib/cisco_hw.sh"
source "${PROJECT_ROOT}/lib/kickstart_gen.sh"
source "${PROJECT_ROOT}/lib/iso_gen.sh"
source "${PROJECT_ROOT}/lib/post_install.sh"

check_secrets

[[ -f "${WORK_DIR}/server.env" ]] || die "No server.env found for $HOSTNAME_ARG — did csv_split.py run?"
source "${WORK_DIR}/server.env"

log_section "Starting build for $HOSTNAME (job $JOB_NAME, hardware $HARDWARE)"

# ---- Network facts ----
IP=$(resolve_ip "$HOSTNAME" "server hostname")
GATEWAY=$(echo "$IP" | sed 's/\.[0-9]*$/.1/')
log INFO "Resolved $HOSTNAME -> $IP (gateway $GATEWAY)"

MGMT_IP="$MGMT_ADDRESS"
if [[ ! "$MGMT_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  MGMT_IP=$(resolve_ip "$MGMT_ADDRESS" "iDRAC management address")
fi
log INFO "Management address: $MGMT_ADDRESS -> $MGMT_IP"

# Durable record of what was actually resolved and used — not just in the
# log, so it can be checked independent of scrolling back through it.
{
  echo "RESOLVED_IP=$IP"
  echo "RESOLVED_GATEWAY=$GATEWAY"
  echo "RESOLVED_MGMT_IP=$MGMT_IP"
} >> "${WORK_DIR}/server.env"

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

  log_section "Cisco bring-up: $PROFILE in org $ORG via UCSM $MGMT_IP"
  require_ucsm_reachable "$MGMT_IP"
  UCSM_TEMPLATE_NAME=$(get_template_name "$MGMT_IP" "$PROFILE" "$ORG")
  log_section "Network / kickstart"

  if is_skipped "get-mac"; then
    log_skip "Determine MAC address from UCSM" "get-mac"
    MAC="$MAC_OVERRIDE"
    log INFO "Using manually supplied MAC: $MAC"
  else
    MAC=$(get_mac_ucsm "$MGMT_IP" "$PROFILE" "$ORG")
    [[ -z "$MAC" ]] && die "Could not determine MAC address from UCSM"
  fi

  ucsm_boot_mode=$(get_boot_mode_ucsm "$MGMT_IP" "$PROFILE" "$ORG")
  [[ -n "$ucsm_boot_mode" ]] && BOOT_MODE="$ucsm_boot_mode"

  if is_skipped "kickstart"; then
    log_skip "Kickstart file generation" "kickstart"
    [[ -f "$KS_OUT" ]] || die "--skip=kickstart but no existing kickstart file at $KS_OUT — nothing for build_boot_iso to package. Either don't skip kickstart, or also --skip=iso-build."
  else
    generate_kickstart "$KS_OUT"
  fi

  if is_skipped "iso-build"; then
    log_skip "Building the boot ISO" "iso-build"
  else
    build_boot_iso "$KS_OUT"
  fi

  unbind_profile "$MGMT_IP" "$PROFILE" "$ORG"
  create_and_mount_vmedia "$MGMT_IP" "$PROFILE" "$ORG"
  SLOT=$(run_ucsm "$MGMT_IP" "scope org /${ORG};enter service-profile ${PROFILE} instance;show detail" | grep -i "Server:" | awk -F: '{print $2}' | tr -d ' ')
  reboot_server_ucsm "${SLOT:-$PROFILE}" "$MGMT_IP"

else
  NIC="ens0"
  log_section "Dell bring-up: $HOSTNAME via iDRAC $MGMT_IP"
  require_idrac_reachable "$MGMT_IP"
  racreset_idrac "$MGMT_IP"
  ensure_power_on "$MGMT_IP"
  gather_server_info "$MGMT_IP"

  if is_skipped "bios"; then
    log_skip "BIOS settings (ErrPrompt, CPU frequency policy, boot mode)" "bios"
  else
    stage_bios_settings "$MGMT_IP"
    set_boot_mode "$MGMT_IP" "$BOOT_MODE"
    commit_bios_settings "$MGMT_IP"
    verify_boot_mode "$MGMT_IP" "$BOOT_MODE"
  fi

  create_os_vdisk "$MGMT_IP" "$OS_DISK_GB"
  log_section "Network / kickstart"

  if is_skipped "get-mac"; then
    log_skip "Determine MAC address from iDRAC" "get-mac"
    MAC="$MAC_OVERRIDE"
    log INFO "Using manually supplied MAC: $MAC"
  else
    MAC=$(get_mac "$MGMT_IP")
    [[ -z "$MAC" ]] && die "Could not determine MAC address from iDRAC"
  fi

  if is_skipped "kickstart"; then
    log_skip "Kickstart file generation" "kickstart"
    [[ -f "$KS_OUT" ]] || die "--skip=kickstart but no existing kickstart file at $KS_OUT — nothing for build_boot_iso to package. Either don't skip kickstart, or also --skip=iso-build."
  else
    log INFO "OS disk values for kickstart's %pre device detection: OS_DISK_GB=${OS_DISK_GB} OS_DISK_BUS_PROTOCOL=${OS_DISK_BUS_PROTOCOL:-<empty/unknown>}"
    generate_kickstart "$KS_OUT"
  fi

  if is_skipped "iso-build"; then
    log_skip "Building the boot ISO" "iso-build"
  else
    build_boot_iso "$KS_OUT"
  fi

  if is_skipped "mount"; then
    log_skip "Mounting install media and power-cycling to start the OS install" "mount"
  else
    mount_install_media "$MGMT_IP" "$HOSTNAME_SHORT"
    restart_server_dell "$MGMT_IP"
  fi
fi

log INFO "Kickstart and hardware bring-up complete for $HOSTNAME."

# =============================================================================
# Wait for OS install to finish, then run post-install
# =============================================================================
log_section "Waiting for OS install on $HOSTNAME"
sleep 900   # rough estimate for a RHEL minimal install; ssh_wait below is the real gate
ssh_wait "$HOSTNAME" 40 30 || die "SSH never came up on $HOSTNAME after install"

log_section "OS is up on $HOSTNAME — starting post-install configuration"
# Satellite registration/patching is triggered downstream by GOMP after
# gomp_submit() below, not by this script — see lib/post_install.sh.
configure_extra_disks "$HOSTNAME_SHORT" "$HOSTNAME" "$HARDWARE" "$MGMT_IP" "${WORK_DIR}/disks.tsv"

if [[ "$HARDWARE" == "Cisco" ]]; then
  cleanup_cisco_template "$MGMT_IP" "$HOSTNAME_SHORT" "$ORG_NAME" "$UCSM_TEMPLATE_NAME"
fi

gomp_submit "$HOSTNAME_SHORT" "$DATACENTER" "$OS_VERSION"

log_section "Build complete for $HOSTNAME"
record_result "SUCCESS" "build and post-install complete"
