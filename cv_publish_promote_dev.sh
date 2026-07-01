#!/bin/bash
#######################################################################
# Script:  cv_publish_promote_dev.sh
# Purpose: Publish & promote Satellite Content Views to DEV using the
#          local hammer CLI (run as root on the Satellite server -
#          no API/auth needed). Sat_Infrastructure continues on past
#          DEV through the rest of its lifecycle path.
#
#          Runs monthly via cron; logs full hammer output and sends a
#          plain-text email summary.
#
# Usage:   ./cv_publish_promote_dev.sh
# Cron:    0 3 1 * * /opt/scripts/cv_publish_promote_dev.sh >> /var/log/cv_publish_promote/cron.log 2>&1
#######################################################################

set -uo pipefail

### ---------------- CONFIG ----------------
ORG="Your_Org_Name"                      # hammer --organization value
HAMMER="/usr/bin/hammer"

LOGDIR="/var/log/cv_publish_promote"
MONTH_SHORT_LC="$(date +%b_%Y | tr '[:upper:]' '[:lower:]')"   # e.g. jul_2026
MONTH_SHORT="$(date +%b_%Y)"                                    # e.g. Jul_2026 (used in CV description tag)
LOGFILE="${LOGDIR}/cv_publish_promote_dev_${MONTH_SHORT_LC}.log"
LOCKFILE="/var/run/cv_publish_promote_dev.lock"

EMAIL_TO="mrg-team@pnc.com"
EMAIL_FROM="satellite-noreply@pnc.com"
SENDMAIL="/usr/sbin/sendmail"

RETENTION_DAYS=90

# Content views promoted only Library -> DEV
declare -A CV_STANDARD=(
  ["RHEL8.8"]="Library DEV"
  ["RHEL8_current"]="Library DEV"
  ["RHEL9_current"]="Library DEV"
  ["RHEL10_current"]="Library DEV"
)

# Content views promoted the full path to Prod
declare -A CV_FULL=(
  ["Sat_Infrastructure"]="Library DEV RND UAT QA Prod"
)
### ------------------------------------------

mkdir -p "$LOGDIR"
: > "$LOGFILE"

declare -A RESULTS
declare -A DETAILS
START_TIME=$(date +%s)
RUN_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOGFILE"
}

# ---- Prevent overlapping runs ----
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  log "ERROR: Another instance is already running (lock: $LOCKFILE). Exiting."
  exit 1
fi
trap 'flock -u 200' EXIT

# ---- Sanity checks ----
if [[ ! -x "$HAMMER" ]]; then
  log "FATAL: hammer binary not found/executable at $HAMMER"
  exit 1
fi

publish_cv() {
  local cv="$1"
  local desc="${cv}_${MONTH_SHORT}"

  log "INFO: Publishing content view '$cv' (description: $desc)"

  if $HAMMER content-view publish \
      --organization "$ORG" \
      --name "$cv" \
      --description "$desc" >> "$LOGFILE" 2>&1; then
    log "SUCCESS: Published '$cv'"
    DETAILS["$cv"]+="  Library: published OK\n"
    return 0
  else
    log "ERROR: Failed to publish '$cv'"
    DETAILS["$cv"]+="  Library: PUBLISH FAILED\n"
    return 1
  fi
}

get_latest_version_id() {
  local cv="$1"
  local csv
  csv=$($HAMMER --output csv content-view version list \
          --content-view "$cv" \
          --organization "$ORG" \
          --order "Version DESC" 2>>"$LOGFILE")

  echo "$csv" | awk -F',' '
    NR==1 { for (i=1;i<=NF;i++) if ($i=="Id") col=i }
    NR==2 { print $col }
  '
}

promote_cv() {
  local cv="$1"; shift
  local envs=("$@")
  local version_id fail=0

  version_id=$(get_latest_version_id "$cv")
  if [[ -z "$version_id" ]]; then
    log "ERROR: Could not determine latest version id for '$cv'"
    DETAILS["$cv"]+="  ERROR: could not retrieve version ID after publish\n"
    return 1
  fi
  log "INFO: Latest version id for '$cv' is $version_id"

  for env in "${envs[@]}"; do
    [[ "$env" == "Library" ]] && continue   # already covered by publish

    log "INFO: Promoting '$cv' version $version_id -> '$env'"
    if $HAMMER content-view version promote \
        --content-view "$cv" \
        --organization "$ORG" \
        --version "$version_id" \
        --to-lifecycle-environment "$env" >> "$LOGFILE" 2>&1; then
      log "SUCCESS: Promoted '$cv' to '$env'"
      DETAILS["$cv"]+="  ${env}: promoted OK\n"
    else
      log "ERROR: Failed promoting '$cv' to '$env'"
      DETAILS["$cv"]+="  ${env}: FAILED (chain halted)\n"
      fail=1
      break   # environments are ordered; stop on first failure
    fi
  done
  return $fail
}

process_cv() {
  local cv="$1"; shift
  local envs=("$@")

  if publish_cv "$cv"; then
    if promote_cv "$cv" "${envs[@]}"; then
      RESULTS["$cv"]="SUCCESS"
    else
      RESULTS["$cv"]="PARTIAL FAILURE"
    fi
  else
    RESULTS["$cv"]="PUBLISH FAILED"
  fi
}

log "===== Starting Content View Publish/Promote to DEV run ====="
log "Organization: $ORG | Tag: $MONTH_SHORT"

for cv in "${!CV_STANDARD[@]}"; do
  process_cv "$cv" ${CV_STANDARD[$cv]}
done

for cv in "${!CV_FULL[@]}"; do
  process_cv "$cv" ${CV_FULL[$cv]}
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "===== Run complete in ${DURATION}s ====="

# ---- Overall status ----
OVERALL_OK=1
for cv in "${!RESULTS[@]}"; do
  [[ "${RESULTS[$cv]}" != "SUCCESS" ]] && OVERALL_OK=0
done

### ---------------- BUILD & SEND EMAIL (plain text) ----------------
send_email() {
  local subject body

  if [[ "$OVERALL_OK" -eq 1 ]]; then
    subject="Satellite CV Publish/Promote to DEV - ${MONTH_SHORT//_/ }"
  else
    subject="Satellite CV Publish/Promote to DEV - ${MONTH_SHORT//_/ } - ERRORS DETECTED"
  fi

  body="Satellite Content View Publish/Promote to DEV
Run date: ${RUN_DATE}
Organization: ${ORG}
Duration: ${DURATION}s

"

  for cv in "${!RESULTS[@]}"; do
    body+="${cv} - ${RESULTS[$cv]}
"
    body+="$(printf '%b' "${DETAILS[$cv]}")
"
  done

  body+="Full log: ${LOGFILE}
"

  {
    echo "From: ${EMAIL_FROM}"
    echo "To: ${EMAIL_TO}"
    echo "Subject: ${subject}"
    echo
    echo "$body"
  } | $SENDMAIL -t

  log "INFO: Summary email sent to $EMAIL_TO (subject: $subject)"
}

send_email

# ---- Log retention cleanup ----
find "$LOGDIR" -name 'cv_publish_promote_dev_*.log' -mtime "+${RETENTION_DAYS}" -delete

log "===== Done ====="
exit 0
