#!/bin/bash
# =============================================================================
# stop_build.sh <hostname> [job_name]
#
# Cancels an in-progress build_server.sh run. Reads the PID recorded when
# the build was dispatched (build.sh / build_server.sh CSV mode both write
# "<pid> <hostname>" lines into work/<job>/pids.txt), confirms that PID is
# actually still a build_server.sh process for this host (not some
# unrelated process that happens to have reused the PID after the real one
# already exited — PIDs get recycled), then sends SIGTERM to the whole
# process group (build_server.sh was dispatched via setsid specifically so
# this reaches any in-flight ssh/sleep children too, not just the top
# process).
#
# build_server.sh traps SIGTERM itself and logs a clear "cancelled by user"
# entry before exiting — this doesn't just silently kill something.
#
# If job_name is omitted, searches every job under work/ for a pids.txt
# entry matching this hostname and uses the most recent one. Note this is
# still job-scoped (pids.txt is per-job bookkeeping), even though the
# actual per-host log/lock files it points at now live under logs/<host>/
# rather than logs/<job>/ — see common.sh/build.sh for that split.
# =============================================================================
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage(){
  echo "usage: stop_build.sh <hostname> [job_name]"
  echo "  hostname   short or full hostname, as it appears in logs/<hostname>/<hostname>.log"
  echo "  job_name   optional — if omitted, searches all jobs for this hostname"
}

[[ $# -lt 1 || $# -gt 2 ]] && { usage; exit 1; }
HOSTNAME_ARG="$1"
HOSTNAME_SHORT="${HOSTNAME_ARG%%.*}"
JOB_NAME="${2:-}"

find_pid_entry(){
  local job_dir="$1"
  local pids_file="${job_dir}/pids.txt"
  [[ -f "$pids_file" ]] || return 1
  # Match on either the short or full hostname as recorded — pids.txt
  # stores whatever hostname string was actually dispatched with, which
  # may be short or FQDN depending on how the job was invoked.
  grep -E " (${HOSTNAME_ARG}|${HOSTNAME_SHORT}(\.|$))" "$pids_file" | tail -1
}

if [[ -n "$JOB_NAME" ]]; then
  job_dirs=("${PROJECT_ROOT}/work/${JOB_NAME}")
else
  # Search every job dir under work/, newest first, for a pids.txt entry
  # matching this host — most recent match wins if the same hostname was
  # ever built under more than one job name.
  mapfile -t job_dirs < <(find "${PROJECT_ROOT}/work" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
fi

match=""
matched_job_dir=""
for job_dir in "${job_dirs[@]}"; do
  [[ -d "$job_dir" ]] || continue
  entry=$(find_pid_entry "$job_dir")
  if [[ -n "$entry" ]]; then
    match="$entry"
    matched_job_dir="$job_dir"
    break
  fi
done

if [[ -z "$match" ]]; then
  echo "No dispatched-build record found for '$HOSTNAME_ARG'${JOB_NAME:+ in job $JOB_NAME} (checked pids.txt)." >&2
  exit 1
fi

pid=$(awk '{print $1}' <<< "$match")
found_job_name=$(basename "$matched_job_dir")

if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "Recorded PID ($pid) for '$HOSTNAME_ARG' (job $found_job_name) is not running — the build has already finished, failed, or was already stopped." >&2
  exit 1
fi

# Safety check before killing anything: confirm this PID is actually a
# build_server.sh process, not some unrelated process that reused the PID
# after the real one exited (PIDs get recycled by the OS over time).
cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
if [[ "$cmdline" != *build_server.sh* ]]; then
  echo "PID $pid is running but is NOT a build_server.sh process (cmdline: '${cmdline:-<none>}')." >&2
  echo "Refusing to kill it — the recorded PID has likely been reused by an unrelated process since the build finished." >&2
  exit 1
fi

echo "Stopping build for $HOSTNAME_ARG (job $found_job_name, pid $pid)..."
# Negative PID = signal the whole process group, not just this one PID —
# reaches any in-flight ssh/racadm/sleep child too. Relies on build.sh /
# build_server.sh CSV mode having dispatched this via setsid.
if kill -TERM -- "-${pid}" 2>/dev/null; then
  echo "Sent SIGTERM. It may take a few seconds for the current step to notice and exit cleanly."
  echo "Watch it stop: tail -f ${PROJECT_ROOT}/logs/${HOSTNAME_SHORT}/${HOSTNAME_SHORT}.log"
else
  echo "kill -TERM failed against process group -${pid} — trying the single PID instead." >&2
  kill -TERM "$pid" 2>/dev/null || { echo "Could not signal PID $pid at all — it may need root/sudo, or may already be gone." >&2; exit 1; }
fi
