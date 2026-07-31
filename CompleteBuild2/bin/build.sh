#!/bin/bash
# =============================================================================
# build.sh <csv_filename>
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
# Launches one backgrounded build_server.sh per server found in the CSV,
# same parallel-dispatch model as the old build_wrapper.sh.
# =============================================================================
set -u

CSV_FILENAME="$1"
[[ -z "$CSV_FILENAME" ]] && { echo "usage: build.sh <csv_filename_in_csv/incoming>"; exit 1; }

JOB_NAME="${CSV_FILENAME%.*}"   # strip extension -> becomes the job name

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV_PATH="${PROJECT_ROOT}/csv/incoming/${CSV_FILENAME}"
WORK_DIR="${PROJECT_ROOT}/work/${JOB_NAME}"
JOB_LOG_DIR="${PROJECT_ROOT}/logs/${JOB_NAME}"
JOB_SUMMARY_LOG="${JOB_LOG_DIR}/job-summary.log"
JOB_RESULTS_FILE="${JOB_LOG_DIR}/results.csv"
HOSTNAME_SHORT="dispatcher"

source "${PROJECT_ROOT}/lib/common.sh"
check_secrets

[[ -f "$CSV_PATH" ]] || die "CSV not found: $CSV_PATH (expected under csv/incoming/)"

mkdir -p "$JOB_LOG_DIR" "$WORK_DIR" "${PROJECT_ROOT}/csv/archive"
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
  log INFO "Dispatching $host"
  nohup "${PROJECT_ROOT}/bin/build_server.sh" "$host" "$JOB_NAME" \
    > "${JOB_LOG_DIR}/${host%%.*}.nohup.out" 2>&1 &
  echo "$! $host" >> "${JOB_LOG_DIR}/pids.txt"
done < "$hostlist"

log STEP "All builds dispatched. Track progress with:"
log INFO "  tail -f ${JOB_LOG_DIR}/*.log"
log INFO "Final per-server pass/fail summary will accumulate in:"
log INFO "  ${JOB_RESULTS_FILE}"