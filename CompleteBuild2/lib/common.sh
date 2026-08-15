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
  if [[ -n "$JOB_LOG_DIR" ]]; then
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
  if [[ -n "$JOB_LOG_DIR" ]]; then
    mkdir -p "$JOB_LOG_DIR"
    echo "$msg" >> "${JOB_LOG_DIR}/${HOSTNAME_SHORT:-job}.log"
  fi
}

# log_racadm_output <label> <output>
# Logs a racadm response (often multi-line, e.g. "STOR094: The storage
# configuration operation is successfully completed and the change is in
# pending state.") as PLAIN TEXT — no [timestamp][LEVEL][host] prefix per
# line — via log_raw(), so what lands in the log/console is exactly what
# racadm itself printed, not our own formatting wrapped around it. A single
# labeled header line (through log(), so it still gets a timestamp) marks
# where the raw block starts, since the raw lines themselves carry no
# indication of which command produced them.
log_racadm_output(){
  local label="$1"; shift
  local output="$*"
  [[ -z "$output" ]] && return
  log INFO "${label} output:"
  log_raw "$output"
}

die(){
  log ERROR "$*"
  record_result "FAILED" "$*"
  exit 1
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
  local errfile out rc
  errfile=$(mktemp)
  out=$(sshpass -f "$XSMRGAUTOMAT_PW_FILE" ssh $SSH_OPTS "${IDRAC_USER}@${IDRAC_AD_DOMAIN}@${idrac_ip}" "racadm $*" 2>"$errfile")
  rc=$?
  if (( rc != 0 )); then
    log ERROR "racadm '$*' on $idrac_ip failed (ssh exit $rc): $(cat "$errfile")"
  fi
  rm -f "$errfile"
  # Every racadm call's raw output goes to the log here, centrally — not
  # just the handful of call sites that used to call log_racadm_output()
  # explicitly. This goes through log()/log_raw() (stderr), so it's safe
  # even for callers doing `out=$(run_racadm ...)` to parse the result —
  # nothing here touches the stdout `echo "$out"` below.
  log INFO "racadm $*:"
  log_raw "$out"
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
      log INFO "$description — $job_id completed"
      return 0
    fi
    log INFO "$description — Waiting for racadm job $job_id to complete, ${pct:-0}%"
    sleep "$sleep_s"
    ((n++))
  done
  log ERROR "$description — $job_id did not complete after ${initial_delay}s + $((max_polls*sleep_s))s of polling"
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
