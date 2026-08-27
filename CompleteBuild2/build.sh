#!/bin/bash
# =============================================================================
# build.sh [-t] [--skip=<name>[,<name>...]] <job_name> [host...] [--failed]
#
# Entrypoint — lives in the CompleteBuild2 root itself (not bin/), so a CSV
# dropped in this same directory tab-completes when typing the job name.
# See --help for the full breakdown.
# =============================================================================
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"

usage(){
  cat << 'EOF'
NAME
    build.sh — dispatch a bare-metal build for every server in a CSV

SYNOPSIS
    build.sh [-t] [--skip=<name>[,<name>...]] <job_name> [host...]
    build.sh [-t] [--skip=<name>[,<name>...]] <job_name> --failed

DESCRIPTION
    Builds every server in a CSV, in parallel — one independent
    build_server.sh process per host. Job name = CSV filename (.csv
    optional). Drop the CSV in this directory for tab-completion; it's
    copied into csv/incoming/ automatically.

    Rerunning a job normally resets and rebuilds everyone. To rebuild only
    specific hosts instead (without touching already-successful ones),
    list them after the job name, or use --failed to auto-target every
    host whose last recorded result wasn't SUCCESS.

OPTIONS
    -t, --skip-idrac-wait   Alias for --skip=racreset.
    --skip=<name>[,...]     Skip a step/task for every host being built
                            this run. See list below.
    --failed, -f            Target only hosts that didn't succeed last
                            time, instead of the whole job.
    -h, --help              This help.

    (No --mac= here — single-host only, use build_server.sh directly.)

EXAMPLES
    ./build.sh amber-20260825-522                    build everyone
    ./build.sh amber-20260825-522 ldsi341a           rebuild just this host
    ./build.sh amber-20260825-522 --failed            rebuild only failures
    ./build.sh amber-20260825-522 --skip=bios,racreset   skip for everyone
    ./bin/stop_build.sh ldsi341a amber-20260825-522   stop one host's build

EOF
  print_skip_help
}

SKIP_IDRAC_RESET=0
SKIP_LIST_ARG=""
FAILED_ONLY=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--skip-idrac-wait) SKIP_IDRAC_RESET=1; shift ;;
    --skip=*) validate_skip_names "${1#*=}"; SKIP_LIST_ARG="${SKIP_LIST_ARG:+$SKIP_LIST_ARG,}${1#*=}"; shift ;;
    --skip) validate_skip_names "$2"; SKIP_LIST_ARG="${SKIP_LIST_ARG:+$SKIP_LIST_ARG,}$2"; shift 2 ;;
    --failed|-f) FAILED_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
CSV_ARG="${POSITIONAL[0]:-}"
[[ -z "$CSV_ARG" ]] && { usage; exit 1; }
# Anything after the job name is a specific host to target — mutually
# exclusive with --failed (ambiguous otherwise: which set wins?).
EXPLICIT_HOSTS=("${POSITIONAL[@]:1}")
if (( FAILED_ONLY == 1 )) && (( ${#EXPLICIT_HOSTS[@]} > 0 )); then
  echo "Use either --failed or explicit hostnames, not both." >&2
  exit 1
fi

# .csv appended automatically if not already present.
case "$CSV_ARG" in
  *.csv) CSV_FILENAME="$CSV_ARG" ;;
  *) CSV_FILENAME="${CSV_ARG}.csv" ;;
esac

JOB_NAME="${CSV_FILENAME%.*}"

CSV_PATH="${PROJECT_ROOT}/csv/incoming/${CSV_FILENAME}"
WORK_DIR="${PROJECT_ROOT}/work/${JOB_NAME}"
JOB_LOG_DIR="${PROJECT_ROOT}/logs/${JOB_NAME}"
JOB_RESULTS_FILE="${JOB_LOG_DIR}/results.csv"
HOSTNAME_SHORT="dispatch"

mkdir -p "$JOB_LOG_DIR"
check_secrets

# Main-directory CSV takes priority (the tab-completion-friendly path);
# falls back to whatever's already in csv/incoming/.
main_dir_csv="${PROJECT_ROOT}/${CSV_FILENAME}"
if [[ -f "$main_dir_csv" ]]; then
  mkdir -p "${PROJECT_ROOT}/csv/incoming"
  cp "$main_dir_csv" "$CSV_PATH"
  log INFO "Copied ${CSV_FILENAME} from CompleteBuild2 root into csv/incoming/"
elif [[ ! -f "$CSV_PATH" ]]; then
  die "CSV not found — checked ${main_dir_csv} and ${CSV_PATH}."
fi

mkdir -p "$WORK_DIR" "${PROJECT_ROOT}/csv/archive"

PARTIAL_MODE=0
(( FAILED_ONLY == 1 || ${#EXPLICIT_HOSTS[@]} > 0 )) && PARTIAL_MODE=1

if (( PARTIAL_MODE == 0 )); then
  # Full-job rerun — same as before: refuse if ANY host in this job is
  # still actively building, otherwise wipe and rebuild everyone.
  still_active=$(job_has_active_lock "$JOB_LOG_DIR")
  if [[ -n "$still_active" ]]; then
    die "Job $JOB_NAME still has an active build in progress for: $still_active. Wait, or cancel with: ./bin/stop_build.sh <hostname> $JOB_NAME"
  fi
  rm -rf "$WORK_DIR" "$JOB_LOG_DIR"
  mkdir -p "$WORK_DIR" "$JOB_LOG_DIR"
  rm -f "$JOB_RESULTS_FILE"
  log INFO "Reset work/${JOB_NAME} and logs/${JOB_NAME} for a clean rerun"
fi

log STEP "=== Starting job $JOB_NAME from $CSV_FILENAME ==="

archive_name="$(date '+%Y%m%d-%H%M%S')_${CSV_FILENAME}"
cp "$CSV_PATH" "${PROJECT_ROOT}/csv/archive/${archive_name}"
log INFO "Archived CSV as csv/archive/${archive_name}"

# Always re-parsed, even in partial mode — this just regenerates
# hostlist.txt and every host's server.env from the CSV, which is fully
# derived/reproducible data. It doesn't touch logs/ or any host's actual
# build state, so doing this for hosts we're not rebuilding is harmless.
python3 "${PROJECT_ROOT}/lib/csv_split.py" "$CSV_PATH" "$WORK_DIR" \
  || die "csv_split.py failed to parse $CSV_PATH"

hostlist="${WORK_DIR}/hostlist.txt"
[[ -s "$hostlist" ]] || die "No servers found in $CSV_FILENAME"

# Resolve which hosts actually get dispatched this run.
targets=()
if (( PARTIAL_MODE == 0 )); then
  mapfile -t targets < "$hostlist"
elif (( FAILED_ONLY == 1 )); then
  # Last recorded status per hostname — a host with no row at all (never
  # completed, e.g. killed mid-build) counts as "not SUCCESS" too. Reading
  # fields 2/3 positionally is safe even though "detail" (the last field)
  # can contain embedded commas — timestamp/hostname/status never do.
  declare -A last_status
  if [[ -s "$JOB_RESULTS_FILE" ]]; then
    while IFS=, read -r ts host status _rest; do
      [[ "$ts" == "timestamp" ]] && continue
      host="${host%\"}"; host="${host#\"}"
      status="${status%\"}"; status="${status#\"}"
      last_status["$host"]="$status"
    done < "$JOB_RESULTS_FILE"
  fi
  while read -r host; do
    [[ -z "$host" ]] && continue
    short="${host%%.*}"
    st="${last_status[$host]:-${last_status[$short]:-}}"
    [[ "$st" != "SUCCESS" ]] && targets+=("$host")
  done < "$hostlist"
  (( ${#targets[@]} == 0 )) && die "--failed found nothing to rebuild — every host in $JOB_NAME already succeeded."
else
  # Explicit hostnames — match against hostlist.txt by full name or short
  # name, die immediately on anything that doesn't match (typo protection).
  for given in "${EXPLICIT_HOSTS[@]}"; do
    match=""
    while read -r host; do
      [[ -z "$host" ]] && continue
      if [[ "$host" == "$given" || "${host%%.*}" == "$given" ]]; then
        match="$host"; break
      fi
    done < "$hostlist"
    [[ -z "$match" ]] && die "'$given' is not in $JOB_NAME's CSV — check the hostname and try again."
    targets+=("$match")
  done
fi

if (( PARTIAL_MODE == 1 )); then
  log INFO "Partial rerun — targeting ${#targets[@]} of $(wc -l < "$hostlist") host(s): ${targets[*]}"
  for host in "${targets[@]}"; do
    short="${host%%.*}"
    active=$(job_has_active_lock "$JOB_LOG_DIR" "$short")
    [[ -n "$active" ]] && die "$host is still actively building — wait, or cancel with: ./bin/stop_build.sh $short $JOB_NAME"
  done
  for host in "${targets[@]}"; do
    short="${host%%.*}"
    # NOT deleting work/${JOB_NAME}/${host} here — csv_split.py (above)
    # already regenerated its server.env fresh, before this loop runs;
    # deleting it now would just destroy that and leave nothing for
    # build_server.sh to read. Only the LOG artifacts from a previous run
    # of this specific host need clearing for a clean rerun.
    rm -f "${JOB_LOG_DIR}/${short}.log" "${JOB_LOG_DIR}/${short}.lock" "${JOB_LOG_DIR}/${short}.hwinventory.raw"
    log INFO "Reset logs for $host only (work/server.env already freshly regenerated above)"
  done
  # csv_split.py (above) already regenerated this host's server.env fresh.
fi

count="${#targets[@]}"
log INFO "Launching $count server build(s) in parallel"

for host in "${targets[@]}"; do
  log INFO "Dispatching $host — its full log will be logs/${JOB_NAME}/${host%%.*}.log"
  extra_args=()
  [[ "$SKIP_IDRAC_RESET" == "1" ]] && extra_args+=(-t)
  [[ -n "$SKIP_LIST_ARG" ]] && extra_args+=(--skip="$SKIP_LIST_ARG")
  setsid nohup "${PROJECT_ROOT}/bin/build_server.sh" "${extra_args[@]}" "$host" "$JOB_NAME" </dev/null >/dev/null 2>&1 &
  echo "$! $host" >> "${JOB_LOG_DIR}/pids.txt"
done

log STEP "All builds dispatched."
for host in "${targets[@]}"; do
  short="${host%%.*}"
  echo "  $host"
  echo "    watch:  tail -f ${JOB_LOG_DIR}/${short}.log"
  echo "    stop:   ./bin/stop_build.sh ${short} ${JOB_NAME}"
done
log INFO "Watch everything at once: tail -f ${JOB_LOG_DIR}/*.log"
log INFO "Final per-server pass/fail summary will accumulate in: ${JOB_RESULTS_FILE}"
