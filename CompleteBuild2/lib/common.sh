#!/bin/bash
# =============================================================================
# common.sh — shared logging, SSH/racadm wrappers, job polling
#
# Sourced by build.sh, build_server.sh, dell_hw.sh, cisco_hw.sh,
# kickstart_gen.sh, post_install.sh. Expects the following to already be set
# by the caller before sourcing:
#   PROJECT_ROOT   - e.g. /staging/BareMetalBuilds/CompleteBuild2
#   JOB_NAME       - the build/job name from the CSV
# Per-server scripts additionally expect HOSTNAME_SHORT to be set.
# =============================================================================

# =============================================================================
# Credentials
#
# One secret to manage: a plaintext password file for the xsmrgautomat AD
# account, named .xsmrgautomat, in the project root (same idea as the old
# scripts' "sshpass -fxsmrgautomat"). Used for iDRAC and UCSM logins, with
# different domain syntax for each — don't drop the domain suffix on either:
#   iDRAC: xsmrgautomat@pncbank.com@<idrac-ip>   (AD user@domain form)
#   UCSM:  ucs-PNCNT\xsmrgautomat@<ucsm-ip>       (Windows DOMAIN\user form)
#
# rootpw hash and GOMP's auth header are left where they already are — a
# hardcoded value in kickstart_gen.sh, and a .headers file the same as
# before — see those files directly rather than a secrets directory here.
# =============================================================================
XSMRGAUTOMAT_PW_FILE="${PROJECT_ROOT}/.xsmrgautomat"

IDRAC_USER="xsmrgautomat"
IDRAC_AD_DOMAIN="pncbank.com"     # do not drop this
UCSM_AD_DOMAIN="ucs-PNCNT"        # Windows-style DOMAIN\user, different syntax than iDRAC's
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

check_secrets(){
  [[ -f "$XSMRGAUTOMAT_PW_FILE" ]] || die "Missing $XSMRGAUTOMAT_PW_FILE — plaintext xsmrgautomat password, mode 400"
}

# -----------------------------------------------------------------------------
# Logging
#   log <LEVEL> <message...>
# Writes to:
#   - stdout (so `nohup ... &` output / journalctl still shows it)
#   - logs/<job>/<hostname>/<hostname>.log   (per-server detail log)
#   - logs/<job>/job-summary.log             (one line per event, all servers)
# LEVEL is one of INFO / WARN / ERROR / STEP
# -----------------------------------------------------------------------------
log(){
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local host="${HOSTNAME_SHORT:-job}"
  local line="[$ts] [$level] [$host] $msg"

  echo "$line"

  if [[ -n "$JOB_LOG_DIR" ]]; then
    mkdir -p "$JOB_LOG_DIR"
    echo "$line" >> "${JOB_LOG_DIR}/${host}.log"
  fi
  if [[ -n "$JOB_SUMMARY_LOG" ]]; then
    echo "$line" >> "$JOB_SUMMARY_LOG"
  fi
}

die(){
  log ERROR "$*"
  record_result "FAILED" "$*"
  exit 1
}

# Records a final PASS/FAIL row for this server into the job's results CSV,
# so `build.sh` (or a human, or a spreadsheet) can see a one-row-per-server
# summary without having to grep through every individual log.
record_result(){
  local status="$1"; shift
  local detail="$*"
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "$JOB_RESULTS_FILE" ]]; then
    if [[ ! -s "$JOB_RESULTS_FILE" ]]; then
      echo "timestamp,hostname,status,detail" > "$JOB_RESULTS_FILE"
    fi
    echo "$(csv_escape_field "$ts"),$(csv_escape_field "${HOSTNAME_SHORT:-unknown}"),$(csv_escape_field "$status"),$(csv_escape_field "$detail")" >> "$JOB_RESULTS_FILE"
  fi
}

# -----------------------------------------------------------------------------
# racadm wrapper (Dell / iDRAC)
#   run_racadm <idrac_ip> <racadm-args...>
# Centralizes the sshpass/ssh invocation so credential handling and timeouts
# live in exactly one place instead of being copy-pasted ~30 times like the
# old dell_functions did.
# -----------------------------------------------------------------------------
run_racadm(){
  local idrac_ip="$1"; shift
  sshpass -f "$XSMRGAUTOMAT_PW_FILE" ssh $SSH_OPTS "${IDRAC_USER}@${IDRAC_AD_DOMAIN}@${idrac_ip}" "racadm $*" 2>/dev/null
}

# -----------------------------------------------------------------------------
# UCSM wrapper (Cisco)
#   run_ucsm <ucsm_ip> <ucsm-cli-commands...>
# -----------------------------------------------------------------------------
run_ucsm(){
  local ucsm_ip="$1"; shift
  sshpass -f "$XSMRGAUTOMAT_PW_FILE" ssh $SSH_OPTS "${UCSM_AD_DOMAIN}\\\\${IDRAC_USER}@${ucsm_ip}" "$*" 2>/dev/null
}

# -----------------------------------------------------------------------------
# wait_for_racadm_job <idrac_ip> <job_id> [timeout_polls] [poll_sleep_seconds]
# Consolidates the "create job -> poll jobqueue view for Percent Complete=100"
# pattern that appeared six separate times, slightly differently, in the old
# dell_functions script. Every job creation in this rewrite uses `-r pwrcycle`
# consistently (the old code mixed --realtime and -r pwrcycle across
# different functions, which is the most likely reason some HDD/RAID jobs on
# iDRAC10 silently never completed).
# -----------------------------------------------------------------------------
wait_for_racadm_job(){
  local idrac_ip="$1" job_id="$2"
  local max_polls="${3:-40}" sleep_s="${4:-15}"
  local n=0
  log INFO "Waiting for racadm job $job_id to complete"
  while (( n < max_polls )); do
    if run_racadm "$idrac_ip" jobqueue view -i "$job_id" | grep -q "Percent Complete.*\[100\]"; then
      log INFO "Job $job_id completed"
      return 0
    fi
    sleep "$sleep_s"
    ((n++))
  done
  log ERROR "Job $job_id did not complete after $((max_polls*sleep_s))s"
  return 1
}

# Creates a racadm job (BIOS.Setup.1-1 or a storage RAID id) with -r pwrcycle
# and returns the parsed Job ID on stdout, or empty string on failure.
create_racadm_job(){
  local idrac_ip="$1" raid_or_bios_id="$2"
  local out jid
  out=$(run_racadm "$idrac_ip" jobqueue create "$raid_or_bios_id" -r pwrcycle)
  jid=$(echo "$out" | grep "Commit JID" | awk -F= '{print $2}' | tr -d ' ')
  echo "$jid"
}

# -----------------------------------------------------------------------------
# ping_wait <ip_or_host> [max_polls] [sleep_seconds]
# Consolidated version of the ready_idrac / get_ready / ready_server ping
# loops that were near-identical copies in the old scripts.
# -----------------------------------------------------------------------------
ping_wait(){
  local target="$1" max_polls="${2:-30}" sleep_s="${3:-30}"
  local n=0
  log INFO "Waiting for $target to respond to ping"
  while (( n < max_polls )); do
    if ping -c1 -W2 "$target" >/dev/null 2>&1; then
      log INFO "$target is reachable"
      return 0
    fi
    log INFO "Not yet reachable ($n of $max_polls)"
    sleep "$sleep_s"
    ((n++))
  done
  log ERROR "$target never became reachable"
  return 1
}

# -----------------------------------------------------------------------------
# ssh_wait <ip_or_host> [max_polls] [sleep_seconds]
# Used post-install: ping can be firewalled/unreliable on some builds, so the
# real gate for "OS is up and we can act on it" is SSH, not ICMP.
# -----------------------------------------------------------------------------
ssh_wait(){
  local target="$1" max_polls="${2:-40}" sleep_s="${3:-30}"
  local n=0
  log INFO "Waiting for SSH on $target"
  while (( n < max_polls )); do
    if ssh $SSH_OPTS -o BatchMode=yes "$target" true 2>/dev/null; then
      log INFO "SSH is up on $target"
      return 0
    fi
    sleep "$sleep_s"
    ((n++))
  done
  log ERROR "SSH never came up on $target"
  return 1
}

# Trim helper used in a few places when reading CSV-derived fields.
trim(){ echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# rhel_major <os_version>   ->  "8" or "9"
# Shared by kickstart_gen.sh (repo URL) and iso_gen.sh (installer boilerplate
# selection) so both agree on the same major-version grouping.
rhel_major(){ echo "${1%%.*}"; }

# -----------------------------------------------------------------------------
# CSV helpers (used by record_result() below and available generally)
# -----------------------------------------------------------------------------
csv_escape_field(){
  local v="$1"
  if [[ "$v" == *,* || "$v" == *'"'* || "$v" == *$'\n'* ]]; then
    v="${v//\"/\"\"}"
    echo "\"$v\""
  else
    echo "$v"
  fi
}
