#!/bin/bash
# =============================================================================
# getdata.sh — Fetch and parse OIM termination/transfer files
# =============================================================================
# Replaces: getdata.ksh
#
# OIM produces four files per run under OIM_EAR_DIR on loim375a:
#
#   terms.YYYYMMDDHHMMSS     — raw tilde-delimited full data
#   terms.id.YYYYMMDDHHMMSS  — pre-extracted IDs, one uppercase ID per line
#   trans.YYYYMMDDHHMMSS     — raw tilde-delimited full data
#   trans.id.YYYYMMDDHHMMSS  — pre-extracted IDs, one uppercase ID per line
#
# This script SCPs both file types for each kind, then:
#   - Archives the raw file to data/terms/ or data/trans/
#   - Lowercases the .id. file and writes it as data/terms.ids or data/trans.ids
#   - Writes a timestamped snapshot to data/ids/
#   - Skips the run if the raw file is identical to the last archive (no new data)
#
# Exit codes:
#   0  terms.ids has content — caller should proceed with cleanup
#   1  terms.ids is empty after all attempts — caller should skip
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

# latest_archive DIR KIND
#   Returns the path of the most recently written archive file, or empty string.
latest_archive() {
    local dir="$1" kind="$2"
    ls -t "${dir}/${kind}."* 2>/dev/null | head -1 || true
}

# fetch_oim_raw KIND STAMP
#   SCPs the raw tilde-delimited file for KIND from OIM into a local staging file.
#   Remote filename: terms.YYYYMMDDHHMMSS  (OIM uses full seconds in the stamp)
#   We match with a glob since we don't know the exact seconds value.
fetch_oim_raw() {
    local kind="$1" stamp="$2"
    local remote_glob="${OIM_EAR_DIR}/${kind}.${stamp}*"
    local staging="${DATA_DIR}/${kind}.raw.new"

    log_info "Fetching raw ${kind}: ${OIM_HOST}:${remote_glob}"
    # shellcheck disable=SC2086
    if ! scp ${SSH_OPTS} "${OIM_HOST}:${remote_glob}" "${staging}" \
            >> "${LOG_GETDATA}" 2>&1; then
        log_error "SCP failed for raw ${kind} file"
        return 1
    fi
    [[ -s "${staging}" ]] || { log_error "Raw ${kind} staging file is empty after SCP"; return 1; }
    log_success "Fetched raw ${kind} — $(wc -l < "${staging}") rows"
    return 0
}

# fetch_oim_ids KIND STAMP
#   SCPs the pre-extracted .id. file for KIND from OIM.
#   Remote filename: terms.id.YYYYMMDDHHMMSS
fetch_oim_ids() {
    local kind="$1" stamp="$2"
    local remote_glob="${OIM_EAR_DIR}/${kind}.id.${stamp}*"
    local staging="${DATA_DIR}/${kind}.id.new"

    log_info "Fetching ID list ${kind}: ${OIM_HOST}:${remote_glob}"
    # shellcheck disable=SC2086
    if ! scp ${SSH_OPTS} "${OIM_HOST}:${remote_glob}" "${staging}" \
            >> "${LOG_GETDATA}" 2>&1; then
        log_error "SCP failed for ${kind}.id. file"
        return 1
    fi
    [[ -s "${staging}" ]] || { log_error "${kind}.id. staging file is empty after SCP"; return 1; }
    log_success "Fetched ${kind}.id. — $(wc -l < "${staging}") IDs"
    return 0
}

# normalize_ids RAW_ID_FILE IDS_FILE
#   Lowercases the OIM-provided ID list (which uses uppercase IDs).
#   Deduplicates and filters out any blank lines.
#   One lowercase ID per line in output.
normalize_ids() {
    local raw_id_file="$1" ids_file="$2"
    tr '[:upper:]' '[:lower:]' < "${raw_id_file}" \
        | grep -v '^\s*$' \
        | sort -u \
        > "${ids_file}"
    local count
    count=$(wc -l < "${ids_file}")
    log_success "Normalized ${count} user IDs -> ${ids_file##*/}"
}

# process_kind KIND
#   Full pipeline for one kind (terms or trans):
#     1. SCP raw file + .id. file from OIM
#     2. Compare raw file to last archive:
#        - Changed   -> archive raw file, normalize .id. -> KIND.ids, snapshot
#        - Unchanged -> skip archiving, re-normalize from .id. file -> KIND.ids, snapshot
#     Either way KIND.ids is written and cleanup proceeds.
#   Returns 0 on success, 1 only if SCP fails (trans non-fatal, terms fatal).
process_kind() {
    local kind="$1"
    local archive_dir="${DATA_DIR}/${kind}"
    local ids_file="${DATA_DIR}/${kind}.ids"
    local today snap_stamp raw_stamp
    today=$(date +%Y%m%d)             # date portion to match OIM filenames
    raw_stamp=$(date +%Y%m%d%H%M)    # YYYYMMDDHHMM for local archive name
    snap_stamp=$(date +%y%m%d%H%M)   # YYMMDDHHMM for ids snapshot name

    local new_archive="${archive_dir}/${kind}.${raw_stamp}"
    local ids_snap="${IDS_DIR}/${kind}.ids.${snap_stamp}"
    local raw_staging="${DATA_DIR}/${kind}.raw.new"
    local id_staging="${DATA_DIR}/${kind}.id.new"

    # Fetch both files; on failure handle terms as fatal, trans as non-fatal
    if ! fetch_oim_raw "${kind}" "${today}"; then
        if [[ "${kind}" == "terms" ]]; then
            log_fatal "Cannot fetch terms raw file — aborting run."
        else
            log_warn "Cannot fetch trans raw file — trans.ids will be empty."
            : > "${ids_file}"; : > "${ids_snap}"
            return 1
        fi
    fi

    if ! fetch_oim_ids "${kind}" "${today}"; then
        if [[ "${kind}" == "terms" ]]; then
            log_fatal "Cannot fetch terms.id. file — aborting run."
        else
            log_warn "Cannot fetch trans.id. file — trans.ids will be empty."
            rm -f "${raw_staging}"
            : > "${ids_file}"; : > "${ids_snap}"
            return 1
        fi
    fi

    # Compare raw file to last archive
    local last
    last=$(latest_archive "${archive_dir}" "${kind}")

    if [[ -n "${last}" ]] && diff -q "${last}" "${raw_staging}" > /dev/null 2>&1; then
        # Raw file unchanged since last run — skip archiving but still normalize
        # IDs so data/KIND.ids is current and cleanup proceeds normally.
        log_info "No change in ${kind} since ${last##*/} — re-using existing archive."
        rm -f "${raw_staging}"
        normalize_ids "${id_staging}" "${ids_file}"
        cp "${ids_file}" "${ids_snap}"
        log_success "ID snapshot -> ids/${kind}.ids.${snap_stamp}"
        rm -f "${id_staging}"
        return 0
    fi

    [[ -z "${last}" ]] \
        && log_info "No prior ${kind} archive found — treating as new." \
        || log_info "Change detected vs ${last##*/}."

    # Archive raw file
    cp "${raw_staging}" "${new_archive}"
    log_success "Archived raw ${kind} -> ${new_archive##*/}"

    # Normalize .id. file -> data/KIND.ids
    normalize_ids "${id_staging}" "${ids_file}"

    # Timestamped snapshot in data/ids/
    cp "${ids_file}" "${ids_snap}"
    log_success "ID snapshot -> ids/${kind}.ids.${snap_stamp}"

    rm -f "${raw_staging}" "${id_staging}"
    return 0
}

# =============================================================================
# Main
# =============================================================================

: > "${LOG_GETDATA}"
log_info "===== getdata.sh start on $(hostname) ====="

mkdir -p "${TERMS_ARCHIVE_DIR}" "${TRANS_ARCHIVE_DIR}" "${IDS_DIR}"

process_kind "terms" || true
process_kind "trans" || true

log_info "===== getdata.sh done ====="

# Exit 1 only if terms.ids ended up empty — that means no IDs to process
# and cleanup should be skipped. A re-run with unchanged OIM data still
# produces a populated terms.ids from the existing archive and exits 0.
[[ -s "${DATA_DIR}/terms.ids" ]] || exit 1
exit 0
