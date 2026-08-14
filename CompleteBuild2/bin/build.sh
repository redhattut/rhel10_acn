#!/bin/bash
# =============================================================================
# build.sh [-t] <csv_filename>
#
# Entrypoint. Run this from lmrg34ja after uploading the exported combined
# CSV to csv/incoming/. The job name is taken automatically from the CSV
# filename (minus its extension) — e.g. BDP-cedar-20260729-482.csv gives you
# the job name BDP-cedar-20260729-482, matching what the web tool named the
# file when you downloaded it.
#
#   scp BDP-cedar-20260729-482.csv lmrg34ja:/staging/BareMetalBuilds/CompleteBuild2/csv/incoming/
#   ssh lmrg34ja
#   cd /staging/BareMetalBuilds/CompleteBuild2
#   ./bin/build.sh BDP-cedar-20260729-482.csv
#
# -t / --skip-idrac-wait: same flag as build_server.sh, passed through to
# every dispatched server — skips only the 10-minute post-racreset wait.
#
# Launches one backgrounded build_server.sh per server found in the CSV,
# same parallel-dispatch model as the old build_wrapper.sh.
# =============================================================================
set -u

usage(){ echo "usage: build.sh [-t] <csv_filename_in_csv/incoming>"; }

SKIP_IDRAC_RESET_WAIT=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--skip-idrac-wait) SKIP_IDRAC_RESET_WAIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
CSV_FILENAME="${POSITIONAL[0]:-}"
[[ -z "$CSV_FILENAME" ]] && { usage; exit 1; }

JOB_NAME="${CSV_FILENAME%.*}"   # strip extension -> becomes the job name

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV_PATH="${PROJECT_ROOT}/csv/incoming/${CSV_FILENAME}"
WORK_DIR="${PROJECT_ROOT}/work/${JOB_NAME}"
JOB_LOG_DIR="${PROJECT_ROOT}/logs/${JOB_NAME}"
JOB_RESULTS_FILE="${JOB_LOG_DIR}/results.csv"
HOSTNAME_SHORT="dispatcher"

# This dispatcher's own handful of messages (archiving the CSV, parsing it,
# launching each server) go to their own small file — deliberately NOT an
# aggregate of every server's detailed activity (each server's full log is
# logs/<job>/<hostname>.log; see the message printed at the end of this
# script for which one to actually watch).
mkdir -p "$JOB_LOG_DIR"
DISPATCH_LOG="${JOB_LOG_DIR}/dispatch.log"
exec > >(tee -a "$DISPATCH_LOG") 2>&1

source "${PROJECT_ROOT}/lib/common.sh"
check_secrets

[[ -f "$CSV_PATH" ]] || die "CSV not found: $CSV_PATH (expected under csv/incoming/)"

mkdir -p "$WORK_DIR" "${PROJECT_ROOT}/csv/archive"
rm -f "$JOB_RESULTS_FILE"

log STEP "=== Starting job $JOB_NAME from $CSV_FILENAME ==="

# Archive a timestamped copy of the CSV so re-running csv_split.py later
# (or auditing what was actually built) doesn't depend on the uploader not
# overwriting/deleting their file afterward.
archive_name="$(date '+%Y%m%d-%H%M%S')_${CSV_FILENAME}"
cp "$CSV_PATH" "${PROJECT_ROOT}/csv/archive/${archive_name}"
log INFO "Archived CSV as csv/archive/${archive_name}"

python3 "${PROJECT_ROOT}/lib/csv_split.py" "$CSV_PATH" "$WORK_DIR" \
  || die "csv_split.py failed to parse $CSV_PATH"

hostlist="${WORK_DIR}/hostlist.txt"
[[ -s "$hostlist" ]] || die "No servers found in $CSV_FILENAME"

count=$(wc -l < "$hostlist")
log INFO "Launching $count server build(s) in parallel"

while read -r host; do
  [[ -z "$host" ]] && continue
  log INFO "Dispatching $host — its full log will be logs/${JOB_NAME}/${host%%.*}.log"
  # build_server.sh sets up its own log file internally (see its exec+tee
  # near the top) — nothing further to capture at this level.
  extra_args=()
  [[ "$SKIP_IDRAC_RESET_WAIT" == "1" ]] && extra_args=(-t)
  nohup "${PROJECT_ROOT}/bin/build_server.sh" "${extra_args[@]}" "$host" "$JOB_NAME" </dev/null >/dev/null 2>&1 &
  echo "$! $host" >> "${JOB_LOG_DIR}/pids.txt"
done < "$hostlist"

log STEP "All builds dispatched."
if (( count == 1 )); then
  only_host=$(head -1 "$hostlist")
  log INFO "One server — watch it with: tail -f ${JOB_LOG_DIR}/${only_host%%.*}.log"
else
  log INFO "Watch one server:  tail -f ${JOB_LOG_DIR}/<hostname>.log"
  log INFO "Watch everything:  tail -f ${JOB_LOG_DIR}/*.log"
fi
log INFO "Final per-server pass/fail summary will accumulate in: ${JOB_RESULTS_FILE}"
