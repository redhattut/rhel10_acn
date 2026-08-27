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
  echo "$line" >&2
  # ${JOB_LOG_DIR:-} not $JOB_LOG_DIR — common.sh now gets sourced very
  # early in build_server.sh (before JOB_LOG_DIR is ever set, so -h/--help
  # and --skip validation can use it), so log()/die() need to tolerate
  # JOB_LOG_DIR being genuinely unset, not just empty, under `set -u`.
  if [[ -n "${JOB_LOG_DIR:-}" ]]; then
    mkdir -p "$JOB_LOG_DIR"
    echo "$line" >> "${JOB_LOG_DIR}/${host}.log"
  fi
}

# log_raw — same destination as log(), no [timestamp][LEVEL][host] prefix.
# Used for content that needs to stay aligned as a table (the SERVER
# INFORMATION block) — the prefix was pushing lines past narrow-screen width.
log_raw(){
  local msg="$*"
  echo "$msg" >&2
  if [[ -n "${JOB_LOG_DIR:-}" ]]; then
    mkdir -p "$JOB_LOG_DIR"
    echo "$msg" >> "${JOB_LOG_DIR}/${HOSTNAME_SHORT:-job}.log"
  fi
}

# log_section <title>
# Visual divider for major phase transitions (hardware bring-up, storage,
# network/kickstart, waiting for OS install, post-install, ...). The title
# line still goes through log() — full [timestamp][STEP][host] — so it's
# still real signal for anything that parses the log the normal way; the
# divider bars themselves are log_raw() so they don't compete with that.
log_section(){
  local title="$1"
  log_raw ""
  log_raw "════════════════════════════════════════════════════════════════════"
  log STEP "$title"
  log_raw "════════════════════════════════════════════════════════════════════"
}

die(){
  log ERROR "$*"
  record_result "FAILED" "$*"
  exit 1
}

# =============================================================================
# Skip system — --skip=<name>[,<name>...] lets a rerun bypass entire steps
# or specific fine-grained tasks instead of redoing work that's already
# correct on the actual hardware from a previous run. Populated by
# build_server.sh's arg parsing; consulted from both build_server.sh itself
# (step-level: bios, kickstart, iso-build, mount, racreset) and dell_hw.sh
# (step-level: clear-vdisk, crypto-erase, create-vdisk; task-level:
# idrac-passthrough, get-mac) — this file is sourced by both, so one shared
# mechanism covers either granularity.
#
# SKIP_REGISTRY is the single source of truth for valid names — used for
# both validating --skip flags (reject a typo with a clear error instead of
# silently doing nothing) and generating --help text, so the two can never
# drift apart.
# =============================================================================
SKIP_LIST=""

declare -A SKIP_REGISTRY=(
  [racreset]="Dell — skip the iDRAC controller reboot entirely."
  [bios]="Dell — skip BIOS settings (ErrPrompt, CPU policy, boot mode)."
  [clear-vdisk]="Dell — skip removing any existing virtual disk."
  [crypto-erase]="Dell — skip cryptographic erase of physical disks."
  [create-vdisk]="Dell — skip creating the new OS virtual disk."
  [idrac-passthrough]="Dell — skip disabling iDRAC OS-BMC passthrough."
  [get-mac]="Skip MAC detection. Requires --mac=<address>."
  [kickstart]="Skip kickstart generation. Requires an existing .ks file."
  [iso-build]="Skip building the boot ISO."
  [mount]="Dell — skip mounting install media and power-cycling."
)

is_skipped(){
  local name="$1"
  [[ " $SKIP_LIST " == *" $name "* ]]
}

# log_skip <description> <skip_name>
# Consistent "this was intentionally left out" log line — steps and tasks
# both use this, so a rerun's log makes it immediately obvious what was
# deliberately skipped vs. what actually ran.
log_skip(){
  local description="$1" name="$2"
  log INFO "SKIPPED: ${description} (--skip=${name})"
}

# validate_skip_names <comma_separated_names>
# Dies with a clear message (listing valid names) on any unrecognized skip
# name, rather than silently doing nothing for a typo'd flag.
validate_skip_names(){
  local names="$1" name
  for name in ${names//,/ }; do
    [[ -n "${SKIP_REGISTRY[$name]:-}" ]] || die "Unknown --skip name: '$name'. Valid names: ${!SKIP_REGISTRY[*]}. Run with --help for descriptions."
  done
}

# print_skip_help — used by build_server.sh's -h/--help output.
print_skip_help(){
  echo "Available --skip names (comma-separated, repeatable):"
  local name
  for name in "${!SKIP_REGISTRY[@]}"; do
    printf "  %-20s %s\n" "$name" "${SKIP_REGISTRY[$name]}"
  done | sort
}

# job_has_active_lock <job_log_dir>
# Checks every *.lock file in a job's log directory and reports whether any
# is CURRENTLY held by a live build_server.sh process — i.e. flock -n
# fails against it, meaning some other process still owns it. Prints the
# hostname(s) still active on stdout (empty if none), for callers to check
# before wiping/resetting a job's work/log directories on a rerun — doing
# that while another host in the same job is still mid-build would delete
# its log/work files out from under it while it's actively writing to them.
# job_has_active_lock <job_log_dir> [short_hostname_to_check_only]
# With no 2nd arg: checks every *.lock in the dir (used for a full-job
# rerun). With a hostname given: checks only that host's own lock — used
# for a partial rerun targeting specific hosts, where other hosts in the
# same job being active/inactive is irrelevant.
job_has_active_lock(){
  local job_log_dir="$1" only_host="${2:-}"
  local active=""
  local lockfile
  if [[ -n "$only_host" ]]; then
    lockfile="${job_log_dir}/${only_host}.lock"
    [[ -e "$lockfile" ]] && ! flock -n "$lockfile" -c true 2>/dev/null && active="$only_host"
    echo "$active"
    return
  fi
  for lockfile in "${job_log_dir}"/*.lock; do
    [[ -e "$lockfile" ]] || continue
    if ! flock -n "$lockfile" -c true 2>/dev/null; then
      active+="${active:+, }$(basename "$lockfile" .lock)"
    fi
  done
  echo "$active"
}

# resolve_ip <hostname> <label>
# Explicit A-record lookup, filtered to only accept a well-formed IPv4
# result. Replaces a previous "dig +short | head -1" with no validation at
# all — dig can return CNAME chain lines, stale cache hits, or other
# non-address text, and that was being used blindly. Real-world failure
# this caused: a bad IP got baked into a boot ISO's kernel append line,
# which the install environment used to bring networking up BEFORE it
# ever reached the point of fetching the kickstart — editing the .ks
# file's own network line afterward had zero effect, since the install
# environment's networking was already up (or not) on the wrong address
# by then, from a value resolved at ISO-build time, not read from the .ks
# file at install time.
resolve_ip(){
  local hostname="$1" label="$2"
  local raw ip
  raw=$(dig "$hostname" +short)
  ip=$(echo "$raw" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | head -1)

  if [[ -z "$ip" ]]; then
    die "DNS lookup failed for $label ($hostname) — dig returned: '$(echo "$raw" | tr '\n' ' ')'"
  fi

  # Shape alone isn't enough — 999.999.999.999 matches this too.
  local IFS=. octet
  local -a octets=($ip)
  for octet in "${octets[@]}"; do
    if (( octet < 0 || octet > 255 )); then
      die "DNS lookup for $label ($hostname) returned a malformed address: $ip"
    fi
  done
  if [[ "$ip" == "0.0.0.0" || "$ip" == 127.* ]]; then
    die "DNS lookup for $label ($hostname) returned a non-routable address: $ip — check the DNS record manually before trusting anything downstream of this"
  fi

  echo "$ip"
}

# Records a final PASS/FAIL row for this server into the job's results CSV,
# so `build.sh` (or a human, or a spreadsheet) can see a one-row-per-server
# summary without having to grep through every individual log.
record_result(){
  local status="$1"; shift
  local detail="$*"
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "${JOB_RESULTS_FILE:-}" ]]; then
    if [[ ! -s "$JOB_RESULTS_FILE" ]]; then
      echo "timestamp,hostname,status,detail" > "$JOB_RESULTS_FILE"
    fi
    echo "$(csv_escape_field "$ts"),$(csv_escape_field "${HOSTNAME_SHORT:-unknown}"),$(csv_escape_field "$status"),$(csv_escape_field "$detail")" >> "$JOB_RESULTS_FILE"
  fi
}

# -----------------------------------------------------------------------------
# log_racadm_result <full_cmd> <output>
# Central place that decides HOW a racadm command's result gets logged —
# called by run_racadm() for every call. Three tiers:
#
#   1. SILENT — getsysinfo, hwinventory, bare attribute "get ..." reads
#      (BIOS boot mode / iDRAC name — used inside gather_server_info, which
#      already prints its own SERVER INFORMATION summary from these),
#      "nicstatistics ..." (used per-NIC while hunting for the live link in
#      get_mac() — 6 NICs' worth of full stats per server is pure noise),
#      "storage get pdisks"/"get vdisks" (any -p variant), and job-queue
#      polling/creation (both have their own purpose-built summary lines
#      from wait_for_racadm_job()/create_racadm_job() instead — see
#      common.sh). Nothing printed here for any of these.
#   2. CONDENSED — "set ..." and the storage delete/erase/create commands.
#      These always return the same few-line legal-notice boilerplate
#      (RAC1017/RAC1024/RAC1040/STOR094/"Object value modified
#      successfully") on success — condensed to one line. Genuine errors
#      (an "ERROR:" line anywhere in the output) are never condensed away —
#      those still show in full, since that's exactly the case you need
#      the detail for.
#   3. FALLBACK — anything not matched above (remoteimage, serveraction,
#      etc.) still gets the original header + full raw dump. These are
#      already short, one-shot, meaningful results as-is, and defaulting to
#      "show everything" is the safe choice for command shapes this
#      function doesn't specifically know about yet.
# -----------------------------------------------------------------------------
log_racadm_result(){
  local cmd="$1" out="$2"

  case "$cmd" in
    getsysinfo|hwinventory|"get "*|"nicstatistics "*|"storage get pdisks"*|"storage get vdisks"*|"jobqueue view -i "*|"jobqueue create "*)
      return 0
      ;;
  esac

  case "$cmd" in
    "set "*|"storage deletevd:"*|"storage cryptographicerase:"*|"storage createvd:"*)
      local result="" err_line=""
      err_line=$(echo "$out" | grep -m1 "^ERROR")
      if [[ -n "$err_line" ]]; then
        log ERROR "racadm ${cmd} -> ${err_line}"
        return 0
      elif [[ "$out" == *"Object value modified successfully"* ]]; then
        result="OK"
      elif [[ "$out" == *"RAC1017"* ]]; then
        result="pending (reboot required)"
      elif [[ "$out" == *"STOR094"* || "$out" == *"RAC1040"* ]]; then
        result="accepted, pending"
      fi
      if [[ -n "$result" ]]; then
        log INFO "racadm ${cmd} -> ${result}"
        return 0
      fi
      # Unrecognized shape for a command family we normally condense —
      # fall through to the full dump rather than silently show nothing.
      ;;
  esac

  log INFO "racadm ${cmd}:"
  log_raw "$out"
}

# -----------------------------------------------------------------------------
# racadm wrapper (Dell / iDRAC)
#   run_racadm <idrac_ip> <racadm-args...>
# Centralizes the sshpass/ssh invocation so credential handling and timeouts
# live in exactly one place instead of being copy-pasted ~30 times like the
# old dell_functions did.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# racadm wrapper (Dell / iDRAC)
#   run_racadm <idrac_ip> <racadm-args...>
# Centralizes the sshpass/ssh invocation so credential handling and timeouts
# live in exactly one place instead of being copy-pasted ~30 times like the
# old dell_functions did.
#
# Two layers of protection against the iDRAC10 SSH-session issue (confirmed:
# require_idrac_reachable() ran `racadm getsysinfo` successfully, then
# ensure_power_on() ran the SAME command ~1s later and got ssh exit 255 —
# succeeding again when re-run manually moments after. Many embedded BMC SSH
# daemons only tolerate one session at a time and refuse a new connection if
# the previous one hasn't fully torn down server-side yet):
#
#   1. RACADM_MIN_INTERVAL — a small mandatory gap BEFORE every racadm call,
#      regardless of whether the previous one succeeded or failed. This is
#      the proactive half: instead of only reacting after a failure, it just
#      never fires two calls closer together than this to begin with. This
#      is why some failures needed a 2nd or 3rd retry and others didn't —
#      the actual required gap varies a bit call to call (network jitter,
#      how busy the iDRAC's own controller is mid-job), so this is a
#      reasonable floor, not a guarantee.
#   2. Retry with RACADM_RETRY_DELAY — the reactive half, for whenever the
#      proactive gap above wasn't quite enough on its own. Silent by design
#      (no per-attempt log line) — a retry that succeeds is exactly the
#      "handled it, nothing to see" case; only total exhaustion after
#      RACADM_MAX_ATTEMPTS is worth surfacing.
#
# RACADM_CONSECUTIVE_FAILURE_LIMIT is the circuit breaker: if run_racadm
# fully exhausts its retries this many times in a row (reset by any
# success, including a retried one), something is wrong with the
# connection itself, not a one-off blip — die() rather than let the build
# stagger through step after step that's also likely to fail, the way this
# pipeline did on lmrg... er, ldsi340a, racking up errors for 15+ minutes
# before a human noticed.
# -----------------------------------------------------------------------------
RACADM_MIN_INTERVAL=3
RACADM_MAX_ATTEMPTS=15
RACADM_RETRY_DELAY=10
RACADM_CONSECUTIVE_FAILURE_LIMIT=3
_RACADM_LAST_CALL_EPOCH=0
_RACADM_CONSECUTIVE_FAILURES=0

run_racadm(){
  local idrac_ip="$1"; shift
  local errfile out rc err_content

  # Proactive cooldown — see RACADM_MIN_INTERVAL above.
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - _RACADM_LAST_CALL_EPOCH ))
  if (( elapsed < RACADM_MIN_INTERVAL )); then
    sleep $(( RACADM_MIN_INTERVAL - elapsed ))
  fi

  local attempt=1
  while (( attempt <= RACADM_MAX_ATTEMPTS )); do
    errfile=$(mktemp)
    out=$(sshpass -f "$XSMRGAUTOMAT_PW_FILE" ssh $SSH_OPTS "${IDRAC_USER}@${IDRAC_AD_DOMAIN}@${idrac_ip}" "racadm $*" 2>"$errfile")
    rc=$?
    err_content=$(cat "$errfile")
    rm -f "$errfile"
    _RACADM_LAST_CALL_EPOCH=$(date +%s)
    (( rc == 0 )) && break
    (( attempt < RACADM_MAX_ATTEMPTS )) && sleep "$RACADM_RETRY_DELAY"
    ((attempt++))
  done

  if (( rc != 0 )); then
    ((_RACADM_CONSECUTIVE_FAILURES++))
    log ERROR "racadm '$*' on $idrac_ip failed (ssh exit $rc) after ${RACADM_MAX_ATTEMPTS} attempts: ${err_content}"
    if (( _RACADM_CONSECUTIVE_FAILURES >= RACADM_CONSECUTIVE_FAILURE_LIMIT )); then
      die "${_RACADM_CONSECUTIVE_FAILURES} consecutive racadm calls to $idrac_ip have each failed after ${RACADM_MAX_ATTEMPTS} retries — this looks like a broken connection/session to the iDRAC, not a one-off blip. Stopping here rather than continuing through more steps likely to fail the same way. Check the iDRAC's SSH session directly before retrying this build."
    fi
  else
    _RACADM_CONSECUTIVE_FAILURES=0
  fi

  # log_racadm_result() decides what actually gets logged (silent/condensed/
  # full) — see it above for the rules. This goes through log()/log_raw()
  # (stderr), so it's safe even for callers doing `out=$(run_racadm ...)`
  # to parse the result — nothing here touches the stdout `echo` below.
  log_racadm_result "$*" "$out"
  echo "$out"
}

# -----------------------------------------------------------------------------
# UCSM wrapper (Cisco)
#   run_ucsm <ucsm_ip> <ucsm-cli-commands...>
# -----------------------------------------------------------------------------
run_ucsm(){
  local ucsm_ip="$1"; shift
  local errfile out rc
  errfile=$(mktemp)
  out=$(sshpass -f "$XSMRGAUTOMAT_PW_FILE" ssh $SSH_OPTS "${UCSM_AD_DOMAIN}\\\\${IDRAC_USER}@${ucsm_ip}" "$*" 2>"$errfile")
  rc=$?
  if (( rc != 0 )); then
    log ERROR "UCSM command on $ucsm_ip failed (ssh exit $rc): $(cat "$errfile")"
  fi
  rm -f "$errfile"
  echo "$out"
}

# -----------------------------------------------------------------------------
# require_idrac_reachable <idrac_ip>
# Real pre-flight check — call this BEFORE any hardware bring-up. This is
# what would have caught the lmrg181a failure immediately instead of 10+
# minutes into a racreset/power-cycle sequence that silently never happened:
# every racadm call was failing, but empty output was being read as "server
# is off" instead of "we never actually reached the iDRAC."
# -----------------------------------------------------------------------------
require_idrac_reachable(){
  local idrac_ip="$1"
  log INFO "Pre-flight: checking TCP/22 reachability to iDRAC $idrac_ip"
  if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/${idrac_ip}/22" 2>/dev/null; then
    die "iDRAC $idrac_ip is not reachable on TCP/22 from this host. Ping succeeding does NOT mean this will — check the network path/firewall before anything else. Manual test: timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${idrac_ip}/22' && echo OPEN"
  fi
  log INFO "Pre-flight: confirming racadm auth against $idrac_ip"
  local out; out=$(run_racadm "$idrac_ip" getsysinfo)
  if [[ -z "$out" ]]; then
    die "racadm getsysinfo returned nothing from $idrac_ip — SSH connected but auth or the racadm call itself failed. Re-run manually to see the real error: sshpass -f ${XSMRGAUTOMAT_PW_FILE} ssh -vvv ${SSH_OPTS} ${IDRAC_USER}@${IDRAC_AD_DOMAIN}@${idrac_ip} \"racadm getsysinfo\""
  fi
  log INFO "Pre-flight OK: racadm is working against $idrac_ip"
}

# -----------------------------------------------------------------------------
# require_ucsm_reachable <ucsm_ip>
# Same idea as require_idrac_reachable, for Cisco.
# -----------------------------------------------------------------------------
require_ucsm_reachable(){
  local ucsm_ip="$1"
  log INFO "Pre-flight: checking TCP/22 reachability to UCSM $ucsm_ip"
  if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/${ucsm_ip}/22" 2>/dev/null; then
    die "UCSM $ucsm_ip is not reachable on TCP/22 from this host. Manual test: timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${ucsm_ip}/22' && echo OPEN"
  fi
  log INFO "Pre-flight: confirming UCSM auth against $ucsm_ip"
  local out; out=$(run_ucsm "$ucsm_ip" "show clock")
  if [[ -z "$out" ]]; then
    die "UCSM command returned nothing from $ucsm_ip — SSH connected but auth failed. Re-run manually: sshpass -f ${XSMRGAUTOMAT_PW_FILE} ssh -vvv ${SSH_OPTS} \"${UCSM_AD_DOMAIN}\\\\${IDRAC_USER}@${ucsm_ip}\" \"show clock\""
  fi
  log INFO "Pre-flight OK: UCSM auth is working against $ucsm_ip"
}

# -----------------------------------------------------------------------------
# parse_pdisks
# Reads racadm's `storage get pdisks -o -p mediatype,size` output on stdin
# and emits clean tab-separated "diskid<TAB>mediatype<TAB>size_gb_int" lines.
#
# This output is NOT one flat "key: value" line per disk — it's a block per
# disk, e.g.:
#   Disk.Bay.0:Enclosure.Internal.0-1:RAID.Slot.3-1
#       MediaType = SSD
#       Size = 893.75 GB
# Treating it as single-line "key: value" pairs (an earlier version of this
# script did) silently matches nothing — the disk ID itself contains colons
# (it's a Dell FQDD), and MediaType/Size are on separate lines from the ID
# entirely. This is what caused "Could not find 2 SSDs matching OS disk size
# 894GB" against a real iDRAC showing two visible 893.75GB SSDs: it wasn't a
# rounding/tolerance problem, the parser just never found anything to match
# in the first place. Size is truncated to an integer GB (matching the
# original dell_functions' `awk -F. '{print $1}'` behavior) before the
# +-15% tolerance check that lives at each call site.
# -----------------------------------------------------------------------------
parse_pdisks(){
  awk '
    function emit() { if (diskid != "" && mediatype != "") print diskid "\t" mediatype "\t" sizeint }
    /^[^[:space:]]/ && NF>0 { emit(); diskid=$0; mediatype=""; sizeint=""; next }
    /MediaType[ \t]*=/ { split($0,a,"="); mediatype=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",mediatype); next }
    /Size[ \t]*=/ {
      split($0,a,"="); size=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",size); gsub(/ *GB.*/,"",size)
      split(size,b,"."); sizeint=b[1]; next
    }
    END { emit() }
  '
}

# parse_pdisks_full — same block format as parse_pdisks(), but also captures
# State (Online/Ready/Failed/...). A separate function rather than changing
# parse_pdisks() itself, so existing RAID-creation callers (which read
# exactly 3 tab fields) can't be silently broken by a 4th field showing up.
# Used only by gather_server_info() below.
parse_pdisks_full(){
  awk '
    function emit() { if (diskid != "" && mediatype != "") print diskid "\t" mediatype "\t" sizeint "\t" state }
    /^[^[:space:]]/ && NF>0 { emit(); diskid=$0; mediatype=""; state=""; sizeint=""; next }
    /MediaType[ \t]*=/ { split($0,a,"="); mediatype=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",mediatype); next }
    /State[ \t]*=/ { split($0,a,"="); state=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",state); next }
    /Size[ \t]*=/ {
      split($0,a,"="); size=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",size); gsub(/ *GB.*/,"",size)
      split(size,b,"."); sizeint=b[1]; next
    }
    END { emit() }
  '
}

# -----------------------------------------------------------------------------
# wait_for_racadm_job <idrac_ip> <job_id> [timeout_polls] [poll_sleep_seconds]
# Consolidates the "create job -> poll jobqueue view for Percent Complete=100"
# pattern that appeared six separate times, slightly differently, in the old
# dell_functions script. Every job creation in this rewrite uses `-r pwrcycle`
# consistently (the old code mixed --realtime and -r pwrcycle across
# different functions, which is the most likely reason some HDD/RAID jobs on
# iDRAC10 silently never completed).
#
# Logging: "jobqueue view -i ..." raw output is silenced in
# log_racadm_result() above — the full 8-line JOB block on every single poll
# was most of the log's length for no added information. This prints exactly
# one line per poll instead, and pulls Actual Start/Completion Time out of
# the final "Completed" poll for a one-line summary with elapsed time.
# -----------------------------------------------------------------------------
wait_for_racadm_job(){
  local idrac_ip="$1" job_id="$2" description="${3:-Job}"
  local max_polls="${4:-30}" sleep_s="${5:-60}" initial_delay="${6:-300}"
  log INFO "$description — $job_id created, waiting ${initial_delay}s before first status check"
  sleep "$initial_delay"
  local n=0
  while (( n < max_polls )); do
    local status_out; status_out=$(run_racadm "$idrac_ip" jobqueue view -i "$job_id")
    local pct; pct=$(echo "$status_out" | grep "Percent Complete" | grep -oE "[0-9]+")
    if [[ "$pct" == "100" ]]; then
      local start_str comp_str elapsed_str
      start_str=$(echo "$status_out" | sed -n 's/^Actual Start Time=\[\(.*\)\]$/\1/p')
      comp_str=$(echo "$status_out" | sed -n 's/^Actual Completion Time=\[\(.*\)\]$/\1/p')
      elapsed_str=""
      if [[ -n "$start_str" && -n "$comp_str" ]]; then
        local start_epoch comp_epoch
        start_epoch=$(date -d "$start_str" +%s 2>/dev/null)
        comp_epoch=$(date -d "$comp_str" +%s 2>/dev/null)
        if [[ -n "$start_epoch" && -n "$comp_epoch" ]]; then
          local diff=$(( comp_epoch - start_epoch ))
          elapsed_str=", ~$((diff/60))m$((diff%60))s"
        fi
      fi
      log INFO "$description — $job_id Completed 100% (${start_str:-?} -> ${comp_str:-?}${elapsed_str})"
      return 0
    fi
    log INFO "$description — $job_id Running ${pct:-0}%"
    sleep "$sleep_s"
    ((n++))
  done
  log ERROR "$description — $job_id did not complete after ${initial_delay}s + $((max_polls*sleep_s))s of polling"
  return 1
}

# Creates a racadm job (BIOS.Setup.1-1 or a storage RAID id) with -r pwrcycle
# and returns the parsed Job ID on stdout, or empty string on failure.
# Logging: "jobqueue create ..." raw output (RAC1024 boilerplate) is
# silenced in log_racadm_result() above — this prints the one line that
# actually matters (the resulting Commit JID, or FAILED) instead.
create_racadm_job(){
  local idrac_ip="$1" raid_or_bios_id="$2"
  local out jid
  out=$(run_racadm "$idrac_ip" jobqueue create "$raid_or_bios_id" -r pwrcycle)
  jid=$(echo "$out" | grep "Commit JID" | awk -F= '{print $2}' | tr -d ' ')
  if [[ -z "$jid" ]]; then
    # "jobqueue create ..." is silenced in log_racadm_result() — normally
    # just RAC1024 boilerplate we already condense into this one line. But
    # when jid-extraction fails, that's exactly the case where the actual
    # racadm response is the one thing worth seeing — surface it here
    # rather than leaving "FAILED, no Commit JID" as the only clue.
    log ERROR "racadm jobqueue create ${raid_or_bios_id} -r pwrcycle -> FAILED, no Commit JID in output. Raw response:"
    log_raw "$out"
  else
    log INFO "racadm jobqueue create ${raid_or_bios_id} -r pwrcycle -> ${jid}"
  fi
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
    # One line every 5 polls (2.5min at the default 30s interval) rather
    # than every single poll — a max_polls=40 wait would otherwise print 40
    # near-identical "not yet" lines; this still proves the wait is alive
    # without flooding the log during what's normally just "OS still
    # installing, nothing wrong yet."
    (( n > 0 && n % 5 == 0 )) && log INFO "Still waiting for SSH on $target ($n of $max_polls)"
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

# LMRG34GA_IP — lmrg34ga's IP address, used anywhere a URL needs to be
# resolvable from INSIDE the RHEL installer environment during boot
# (repo url, kickstart inst.ks= fetch). At that point in boot there is no
# /etc/resolv.conf yet — DNS for lmrg34ga.prod.pncint.net simply doesn't
# work — so these specific URLs have to be IP-based, confirmed against the
# legacy scripts (legacy_isolinux.cfg, legacy_create_ks_rhel8_dell.sh,
# legacy_templateDELL.ks all used this same IP). This is a DIFFERENT
# concern from ISO_HOST/ISO_HTTP_BASE in iso_gen.sh, which stay
# hostname-based on purpose — those are used for the iDRAC virtual-media
# mount, which iDRAC's own firmware/management-network DNS resolves fine,
# and for the SSH hop from lmrg34ja to lmrg34ga, which also isn't affected
# by the installed OS having no resolv.conf yet.
#
# One more thing confirmed from the legacy scripts: under THIS IP, the
# docroot layout is NOT the same as under the lmrg34ga.prod.pncint.net
# vhost — no "/PNC/installs" prefix for the kickstart tmpiso path (legacy:
# http://10.8.171.50/kickstart/SERVERS/tmpiso/...), while the distros repo
# path DOES keep "/PNC/distros/..." either way. Don't "fix" that asymmetry
# without checking with whoever owns the web server config on lmrg34ga —
# it's exactly the kind of assumption that broke the kickstart fetch once
# already.
LMRG34GA_IP="10.8.171.50"

# is_lacp_enabled <raw_lacp_value>
# Single source of truth for "does this server use LACP/bonding?" — used by
# BOTH kickstart_gen.sh (network --device=... line, applied at install time)
# and iso_gen.sh (kernel append line, applied at boot time). Those two MUST
# agree with each other, or the server gets a kickstart file that assumes
# bonding while the boot-time network never actually formed a bond (or vice
# versa) — a silent mismatch, not an error either script would ever catch.
#
# Historically this was a bare `[[ "$LACP" == "Yes" ]]` in each file
# separately, exact-match, case-sensitive. The web tool always sends the
# literal string "Yes"/"No", but any hand-built or legacy-sourced CSV
# (the old scripts checked lowercase "yes") silently falls through to the
# non-bonded branch on anything else — "yes", "YES", trailing whitespace,
# blank. No error, nothing in the log. If the switch port is actually
# configured for LACP, a single un-bundled NIC often can't pass traffic at
# all, which looks exactly like "the network never really comes up" at
# install time. Trim + lowercase here so that class of mismatch can't
# happen silently again; callers should log the raw value they received so
# it's visible in the per-server log either way.
is_lacp_enabled(){
  local raw="$1"
  # trim leading/trailing whitespace, lowercase
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ "${raw,,}" == "yes" ]]
}

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
