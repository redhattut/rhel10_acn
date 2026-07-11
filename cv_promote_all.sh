#!/bin/bash
#######################################################################
# Script:  cv_promote_prod.sh
# Purpose: Promotes the latest version of each RHEL Content View
#          through RND -> UAT -> QA -> Prod using the local hammer
#          CLI (run as root on the Satellite server).
#
#          Assumes CVs have already been published and promoted to DEV
#          by cv_publish_promote_dev.sh. Sat_Infrastructure is excluded
#          as it is already promoted to all environments.
#
# Usage:   ./cv_promote_prod.sh
# Cron:    0 5 1 * * /opt/scripts/cv_promote_prod.sh >> /var/log/cv_promote_prod/cron.log 2>&1
#######################################################################

set -uo pipefail

### ---------------- CONFIG ----------------
ORG="Your_Org_Name"                      # hammer --organization value
HAMMER="/usr/bin/hammer"

LOGDIR="/var/log/cv_publish_promote"
MONTH_SHORT_LC="$(date +%b_%Y | tr '[:upper:]' '[:lower:]')"   # e.g. jul_2026
MONTH_SHORT="$(date +%b_%Y)"                                    # e.g. Jul_2026 - used in email subject
LOGFILE="${LOGDIR}/cv_promote_all_${MONTH_SHORT_LC}.log"
LOCKFILE="/var/run/cv_promote_all.lock"

EMAIL_TO="mrg-team@pnc.com"
MAILX="/usr/bin/mailx"

RETENTION_DAYS=90

# Environments to promote through in order (DEV already done)
ENVIRONMENTS=("RND" "UAT" "QA" "Prod")

# Content views to promote
CONTENT_VIEWS=(
  "RHEL8.8"
  "RHEL8_current"
  "RHEL9_current"
  "RHEL10_current"
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

get_latest_version_id() {
  local cv="$1"
  local csv
  csv=$($HAMMER --output csv content-view version list \
          --content-view "$cv" \
          --organization "$ORG" 2>>"$LOGFILE")

  echo "$csv" | awk -F',' '
    NR==1 {
      for (i=1;i<=NF;i++) {
        if ($i=="Id")      idcol=i
        if ($i=="Version") vercol=i
      }
      next
    }
    { if ($vercol+0 > maxver) { maxver=$vercol+0; maxid=$idcol } }
    END { print maxid }
  '
}

promote_cv() {
  local cv="$1"
  local fail=0
  local version_id

  version_id=$(get_latest_version_id "$cv")
  if [[ -z "$version_id" ]]; then
    log "ERROR: Could not determine latest version id for '$cv'"
    DETAILS["$cv"]+="  ERROR: could not retrieve version ID\n"
    RESULTS["$cv"]="FAILED"
    return 1
  fi
  log "INFO: Latest version id for '$cv' is $version_id"

  for env in "${ENVIRONMENTS[@]}"; do
    log "INFO: Promoting '$cv' version $version_id -> '$env'"
    if $HAMMER content-view version promote \
        --organization "$ORG" \
        --id "$version_id" \
        --to-lifecycle-environment "$env" >> "$LOGFILE" 2>&1; then
      log "SUCCESS: Promoted '$cv' to '$env'"
      DETAILS["$cv"]+="  ${env}: promoted OK\n"
    else
      log "ERROR: Failed promoting '$cv' to '$env'"
      DETAILS["$cv"]+="  ${env}: FAILED (chain halted)\n"
      fail=1
      break
    fi
  done

  if [[ "$fail" -eq 0 ]]; then
    RESULTS["$cv"]="SUCCESS"
  else
    RESULTS["$cv"]="PARTIAL FAILURE"
  fi
}

log "===== Starting Content View Promote to RND/UAT/QA/Prod run ====="
log "Organization: $ORG | Month: $MONTH_SHORT"

for cv in "${CONTENT_VIEWS[@]}"; do
  promote_cv "$cv"
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
  local subject

  if [[ "$OVERALL_OK" -eq 1 ]]; then
    subject="Satellite CV Promote to RND/UAT/QA/Prod - ${MONTH_SHORT//_/ }"
  else
    subject="Satellite CV Promote to RND/UAT/QA/Prod - ${MONTH_SHORT//_/ } - ERRORS DETECTED"
  fi

  local cv_summary=""
  for cv in "${CONTENT_VIEWS[@]}"; do
    cv_summary+="${cv} - ${RESULTS[$cv]:-NOT RUN}
$(printf '%b' "${DETAILS[$cv]:-}")
"
  done

  $MAILX -s "$subject" "$EMAIL_TO" <<EOF
Satellite Content View Promote to RND/UAT/QA/Prod
Run date: ${RUN_DATE}
Organization: ${ORG}
Duration: ${DURATION}s

${cv_summary}
Full log: ${LOGFILE}
EOF

  log "INFO: Summary email sent to $EMAIL_TO (subject: $subject)"
}

send_email

# ---- Log retention cleanup ----
find "$LOGDIR" -name 'cv_promote_all_*.log' -mtime "+${RETENTION_DAYS}" -delete

log "===== Done ====="
exit 0
