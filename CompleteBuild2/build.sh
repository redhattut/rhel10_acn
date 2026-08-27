#!/bin/bash
# =============================================================================
# build.sh [-t] <job_name_or_csv_filename>
#
# Entrypoint — lives in the CompleteBuild2 root itself (not bin/), so you
# can drop a CSV straight into this same directory and get real shell
# tab-completion: cd into CompleteBuild2, then
#
#   sudo ./build.sh amber-20260825-522<TAB>
#
# completes against the actual file sitting right here, before this script
# ever copies it anywhere.
#
# CSV resolution order:
#   1. If <name> doesn't already end in .csv, .csv is appended automatically
#      — `./build.sh amber-20260825-522` and `./build.sh amber-20260825-522.csv`
#      are equivalent.
#   2. If a file by that name exists in THIS directory (CompleteBuild2 root),
#      it's copied into csv/incoming/ (overwriting any stale copy there)
#      before proceeding — this is the normal, tab-completion-friendly path.
#   3. Otherwise, csv/incoming/<name> is used directly if it exists there
#      already (e.g. uploaded straight into csv/incoming/ the old way).
#   4. If neither location has it, this dies with a clear message showing
#      both paths it checked.
#
# The job name is taken automatically from the CSV filename (minus its
# extension) — e.g. BDP-cedar-20260729-482.csv gives you the job name
# BDP-cedar-20260729-482, matching what the web tool named the file when you
# downloaded it.
#
# -t / --skip-idrac-reset: same flag as build_server.sh, passed through to
# every dispatched server — skips the iDRAC reboot entirely, not just a wait.
#
# Launches one backgrounded build_server.sh per server found in the CSV, all
# fully independent parallel processes — same parallel-dispatch model as the
# old build_wrapper.sh. At this pipeline's scale (dozens, not thousands of
# servers per job) there's no need for any batching/throttling here.
# =============================================================================
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh sourced immediately, before argument parsing — needed so -h/
# --help can use the shared SKIP_REGISTRY (single source of truth for
# valid skip names, see common.sh) without duplicating it here. Same
# reasoning/pattern as build_server.sh.
# shellcheck source=lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"

usage(){
  cat << 'EOF'
NAME
    build.sh — dispatch a bare-metal build for every server in a CSV

SYNOPSIS
    build.sh [-t] [--skip=<name>[,<name>...]] <job_name_or_csv_filename>

DESCRIPTION
    Entrypoint for building a whole batch of servers at once. Launches one
    backgrounded build_server.sh per server found in the CSV, all in
    parallel — each server gets its own log file and proceeds
    independently. The job name is taken automatically from the CSV
    filename (minus its extension), matching what the web tool named the
    file when you downloaded it.

    Run this from lmrg34ja. Drop the exported CSV directly into this same
    directory (CompleteBuild2's root) first — that gives you real shell
    tab-completion when typing the job name, and this script copies it
    into csv/incoming/ automatically before proceeding. You don't need to
    manually place anything in csv/incoming/ yourself.

    Re-running with the same CSV filename automatically resets that job's
    work/ and logs/ directories first (unless a build from that job is
    still actively running, in which case it refuses and tells you to wait
    or cancel it — see bin/stop_build.sh).

    For a single server, build_server.sh can be pointed directly at the
    same CSV instead — see bin/build_server.sh --help.

OPTIONS
    -t, --skip-idrac-wait
            Legacy alias for --skip=racreset. Skips the iDRAC controller
            reboot entirely (not just the wait for it) for every server in
            this batch.

    --skip=<name>[,<name>...]
            Skip an entire step or a specific fine-grained task, for
            EVERY server in this batch, instead of redoing work that's
            already correct on the actual hardware from a previous run.
            Comma-separated, repeatable. Passed straight through to each
            dispatched build_server.sh, which validates the names and
            logs "SKIPPED: ..." for anything left out this way. See the
            full list of valid names below.

    -h, --help
            Show this help and the full list of --skip names.

    NOTE: there is no --mac= option here (unlike build_server.sh) — a
    manually supplied MAC address is inherently single-host, so
    --skip=get-mac only makes sense when building one server directly
    with build_server.sh, not across a whole batch.

EXAMPLES
    Build every server in a CSV, normally — CSV sitting right here in
    CompleteBuild2, .csv extension optional:
        ./build.sh amber-20260825-522
        ./build.sh amber-20260825-522.csv

    Same, but skip the iDRAC reboot for every server (they were already
    reset recently, e.g. earlier in the same troubleshooting session):
        ./build.sh -t amber-20260825-522

    Re-run a batch, but skip BIOS settings and the iDRAC reboot for every
    server — useful when a prior run already got BIOS/RAID right and you
    only need to redo kickstart/ISO/install for everyone:
        ./build.sh --skip=bios,racreset amber-20260825-522

    Re-run, skipping storage entirely (existing vdisks are already
    correct) but still redoing BIOS, kickstart, and the install:
        ./build.sh --skip=clear-vdisk,crypto-erase,create-vdisk amber-20260825-522

    Stopping one server's build partway through a batch (real example,
    not a placeholder — swap in your own hostname/job name the same way):
        ./bin/stop_build.sh ldsi341a amber-20260825-522

EOF
  print_skip_help
}

SKIP_IDRAC_RESET=0
SKIP_LIST_ARG=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--skip-idrac-wait) SKIP_IDRAC_RESET=1; shift ;;
    --skip=*) validate_skip_names "${1#*=}"; SKIP_LIST_ARG="${SKIP_LIST_ARG:+$SKIP_LIST_ARG,}${1#*=}"; shift ;;
    --skip) validate_skip_names "$2"; SKIP_LIST_ARG="${SKIP_LIST_ARG:+$SKIP_LIST_ARG,}$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
CSV_ARG="${POSITIONAL[0]:-}"
[[ -z "$CSV_ARG" ]] && { usage; exit 1; }

# .csv appended automatically if not already present — `./build.sh
# amber-20260825-522` and `./build.sh amber-20260825-522.csv` are
# equivalent, matching how the job name is used everywhere else anyway.
case "$CSV_ARG" in
  *.csv) CSV_FILENAME="$CSV_ARG" ;;
  *) CSV_FILENAME="${CSV_ARG}.csv" ;;
esac

JOB_NAME="${CSV_FILENAME%.*}"   # strip extension -> becomes the job name

CSV_PATH="${PROJECT_ROOT}/csv/incoming/${CSV_FILENAME}"
WORK_DIR="${PROJECT_ROOT}/work/${JOB_NAME}"
JOB_LOG_DIR="${PROJECT_ROOT}/logs/${JOB_NAME}"
JOB_RESULTS_FILE="${JOB_LOG_DIR}/results.csv"
HOSTNAME_SHORT="dispatch"

# This dispatcher's own handful of messages (archiving the CSV, parsing it,
# launching each server) go to their own small file, dispatch.log —
# deliberately NOT an aggregate of every server's detailed activity. Each
# server's full log is logs/<job>/<hostname>.log; see the message printed
# at the end of this script for which one to actually watch. log() (in
# common.sh) writes directly to that file — no subshell, so this script
# returns control to the terminal immediately after dispatching, which
# matters when you're launching several jobs back to back.
mkdir -p "$JOB_LOG_DIR"

check_secrets

# Main-directory CSV takes priority — this is the tab-completion-friendly
# path described at the top of this file. If it's not sitting here, fall
# back to whatever's already in csv/incoming/ (the older, manual-upload
# workflow still works too).
main_dir_csv="${PROJECT_ROOT}/${CSV_FILENAME}"
if [[ -f "$main_dir_csv" ]]; then
  mkdir -p "${PROJECT_ROOT}/csv/incoming"
  cp "$main_dir_csv" "$CSV_PATH"
  log INFO "Copied ${CSV_FILENAME} from CompleteBuild2 root into csv/incoming/"
elif [[ ! -f "$CSV_PATH" ]]; then
  die "CSV not found — checked ${main_dir_csv} and ${CSV_PATH}. Drop the CSV into either location (the CompleteBuild2 root is the normal place — gives you tab-completion) and try again."
fi

mkdir -p "$WORK_DIR" "${PROJECT_ROOT}/csv/archive"
rm -f "$JOB_RESULTS_FILE"

# Rerunning the same job name (same CSV filename) now resets that job's
# work/ and logs/ directories automatically instead of requiring manual
# cleanup first — but ONLY if nothing from a previous run of this job is
# still actively building (job_has_active_lock, common.sh). Wiping
# work/logs out from under a host that's still mid-build would delete its
# log/work files while it's actively writing to them. This is also what
# protects against running the SAME CSV/job twice concurrently — the
# second invocation refuses here rather than racing the first.
still_active=$(job_has_active_lock "$JOB_LOG_DIR")
if [[ -n "$still_active" ]]; then
  die "Job $JOB_NAME still has an active build in progress for: $still_active. Wait for it to finish, or cancel it first with: ./bin/stop_build.sh <hostname> $JOB_NAME — not resetting work/${JOB_NAME} or logs/${JOB_NAME} while that's running."
fi
rm -rf "$WORK_DIR" "$JOB_LOG_DIR"
mkdir -p "$WORK_DIR" "$JOB_LOG_DIR"
log INFO "Reset work/${JOB_NAME} and logs/${JOB_NAME} for a clean rerun"

log STEP "=== Starting job $JOB_NAME from $CSV_FILENAME ==="

# Archived immediately, right after being copied into csv/incoming/ — not
# deferred until "the build completes," and not just for THIS one host's
# sake. The raw CSV is only ever read once, by csv_split.py, right here,
# before any host is even dispatched — nothing downstream (any individual
# build_server.sh process) ever re-reads the original file again, they
# only read their own pre-parsed server.env. So there's nothing gained by
# waiting, and for a multi-host job "the build is complete" isn't even a
# single moment — each host finishes (or fails, or gets rerun) fully
# independently, at very different times.
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
  [[ "$SKIP_IDRAC_RESET" == "1" ]] && extra_args+=(-t)
  # --skip= is NOT independently validated here — each dispatched
  # build_server.sh validates it against the same SKIP_REGISTRY and dies
  # per-host with a clear message on a typo, so there's no need to
  # duplicate that check at this level. --mac= isn't offered here at all —
  # it's inherently single-host (one manual MAC can't apply across an
  # entire batch), so that override only makes sense via build_server.sh
  # directly for one server at a time.
  [[ -n "$SKIP_LIST_ARG" ]] && extra_args+=(--skip="$SKIP_LIST_ARG")
  # setsid — makes this its own process group/session leader, so
  # stop_build.sh can kill the whole tree (build_server.sh plus any
  # in-flight ssh/sleep children) with one `kill -TERM -- -<pid>` instead
  # of leaving orphaned ssh sessions behind when only the top process gets
  # killed.
  setsid nohup "${PROJECT_ROOT}/bin/build_server.sh" "${extra_args[@]}" "$host" "$JOB_NAME" </dev/null >/dev/null 2>&1 &
  echo "$! $host" >> "${JOB_LOG_DIR}/pids.txt"
done < "$hostlist"

log STEP "All builds dispatched."

# Every server gets its own explicit tail -f AND stop command listed —
# not a single "<hostname>" placeholder to mentally substitute, an actual
# copy-pasteable line per server, since that's what you're going to
# actually want to run for each one.
while read -r host; do
  [[ -z "$host" ]] && continue
  short="${host%%.*}"
  echo "  $host"
  echo "    watch:  tail -f ${JOB_LOG_DIR}/${short}.log"
  echo "    stop:   ./bin/stop_build.sh ${short} ${JOB_NAME}"
done < "$hostlist"

log INFO "Watch everything at once: tail -f ${JOB_LOG_DIR}/*.log"
log INFO "Final per-server pass/fail summary will accumulate in: ${JOB_RESULTS_FILE}"
