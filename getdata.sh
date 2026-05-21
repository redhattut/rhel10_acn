#!/bin/bash
# =============================================================================
# getdata.sh — Fetch and parse OIM termination/transfer files
# =============================================================================
# Replaces: getdata.ksh
#
# Flow:
#   1. Guard against running twice in the same minute
#   2. SCP today's terms and trans raw files from OIM server
#      Raw files are archived to data/terms/ and data/trans/ with timestamp
#      Format: terms.YYYYMMDDHHMM  (full year in archive name for readability)
#   3. Compare each against most recent archive — skip if unchanged
#   4. If changed: extract field 2 (user ID), lowercase, write to:
#        data/terms.ids   — current run IDs (overwritten each run)
#        data/trans.ids   — current run IDs (overwritten each run)
#        data/ids/terms.ids.YYMMDDHHMM  — timestamped snapshot
#        data/ids/trans.ids.YYMMDDHHMM  — timestamped snapshot
#
# Exit codes:
#   0  new terms data found and written
#   1  terms unchanged — main.sh should skip this run
#   2  fatal error
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG="${SCRIPT_DIR}/tti.conf"
[[ -f "${CONFIG}" ]] || { echo "[FATAL] Config not found: ${CONFIG}" >&2; exit 2; }
source "${CONFIG}"

# --- Logging -----------------------------------------------------------------

_log() {
    local level="$1" msg="$2" ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] [%-9s] [%s] %s\n" "${ts}" "${level}" "${SCRIPT_NAME}" "${msg}" \
        | tee -a "${LOG_GETDATA}" >> "${MAIN_LOG}"
}
log_info()    { _log "INFO"    "$1"; }
log_success() { _log "SUCCESS" "$1"; }
log_warn()    { _log "WARN"    "$1"; }
log_error()   { _log "ERROR"   "$1"; }
log_fatal()   {
    _log "FATAL" "$1"
    /usr/bin/mail -s "FATAL: ${SCRIPT_NAME} on $(hostname)" "${NOTIFY}" \
        < "${LOG_GETDATA}" || true
    exit 2
}

# --- Helpers -----------------------------------------------------------------

too_soon_check() {
    local stamp
    stamp=$(date +%y%m%d%H%M)
    for kind in terms trans; do
        if ls "${DATA_DIR}/${kind}/${kind}."*"${stamp}" >/dev/null 2>&1; then
            log_warn "Too soon since last run — ${kind} archive exists for stamp ${stamp}."
            /usr/bin/mail -s "TTI getdata: too soon since last run on $(hostname)" \
                "${NOTIFY}" < "${LOG_GETDATA}" || true
            exit 1
        fi
    done
}

# extract_ids RAW_FILE IDS_FILE
#   Reads tilde-delimited OIM file. Field 2 is the user ID.
#   Lowercased, deduplicated, length > 6 only. One ID per line.
extract_ids() {
    local raw_file="$1"
    local ids_file="$2"
    awk -F'~' '
        NF >= 2 {
            id = tolower($2)
            if (length(id) > 6) print id
        }
    ' "${raw_file}" | sort -u > "${ids_file}"
    local count
    count=$(wc -l < "${ids_file}")
    log_success "Extracted ${count} user IDs -> ${ids_file##*/}"
}

latest_archive() {
    local dir="$1" kind="$2"
    ls -t "${dir}/${kind}."* 2>/dev/null | head -1 || true
}

# fetch_oim KIND
#   SCPs today's OIM file into data/$KIND.new staging area.
fetch_oim() {
    local kind="$1"
    local today remote_path staging
    today=$(date +%Y%m%d)
    remote_path="$( [[ "${kind}" == "terms" ]] && echo "${OIM_TERMS_PATH}" || echo "${OIM_TRANS_PATH}" ).${today}"
    staging="${DATA_DIR}/${kind}.new"

    log_info "Fetching ${OIM_HOST}:${remote_path}*"
    # shellcheck disable=SC2086
    if ! scp ${SSH_OPTS} "${OIM_HOST}:${remote_path}"* "${staging}" >> "${LOG_GETDATA}" 2>&1; then
        log_error "SCP failed for ${kind}"
        return 1
    fi
    [[ -s "${staging}" ]] || { log_error "Staging file empty after SCP: ${kind}.new"; return 1; }
    log_success "Fetched ${kind} — $(wc -l < "${staging}") rows"
    return 0
}

# process_kind KIND
#   Full pipeline: fetch -> compare -> archive -> extract IDs -> snapshot IDs
#   Returns 0 if new data was written, 1 if unchanged/unavailable.
process_kind() {
    local kind="$1"
    local archive_dir="${DATA_DIR}/${kind}"
    local ids_file="${DATA_DIR}/${kind}.ids"
    local run_stamp snap_stamp
    run_stamp=$(date +%Y%m%d%H%M)   # YYYYMMDDHHMM for archive filename
    snap_stamp=$(date +%y%m%d%H%M)  # YYMMDDHHMM for ids snapshot filename
    local new_archive="${archive_dir}/${kind}.${run_stamp}"
    local staging="${DATA_DIR}/${kind}.new"
    local ids_snap="${IDS_DIR}/${kind}.ids.${snap_stamp}"

    if ! fetch_oim "${kind}"; then
        if [[ "${kind}" == "terms" ]]; then
            log_fatal "Cannot fetch terms file — aborting run."
        else
            log_warn "Cannot fetch trans file — trans.ids will be empty."
            : > "${ids_file}"
            : > "${ids_snap}"
            return 1
        fi
    fi

    local last
    last=$(latest_archive "${archive_dir}" "${kind}")

    if [[ -n "${last}" ]] && diff -q "${last}" "${staging}" > /dev/null 2>&1; then
        log_info "No change in ${kind} since ${last##*/} — skipping."
        rm -f "${staging}"
        return 1
    fi

    [[ -z "${last}" ]] && log_info "No prior ${kind} archive — treating as new." \
                       || log_info "Change detected vs ${last##*/}."

    cp "${staging}" "${new_archive}"
    log_success "Archived raw ${kind} -> ${new_archive##*/}"

    extract_ids "${new_archive}" "${ids_file}"

    # Write timestamped snapshot to ids/
    cp "${ids_file}" "${ids_snap}"
    log_success "ID snapshot -> ids/${kind}.ids.${snap_stamp}"

    rm -f "${staging}"
    return 0
}

# =============================================================================
# Main
# =============================================================================

: > "${LOG_GETDATA}"
log_info "===== getdata.sh start on $(hostname) ====="

too_soon_check
mkdir -p "${TERMS_ARCHIVE_DIR}" "${TRANS_ARCHIVE_DIR}" "${IDS_DIR}"

terms_changed=0
process_kind "terms" && terms_changed=1 || true

trans_changed=0
process_kind "trans" && trans_changed=1 || true

log_info "===== getdata.sh done (terms_changed=${terms_changed} trans_changed=${trans_changed}) ====="

[[ "${terms_changed}" -eq 0 ]] && exit 1
exit 0
