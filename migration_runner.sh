#!/bin/bash
# =============================================================================
# migration_runner.sh
# MRG Midrange Engineering — Datacenter Migration Utility
#
# Usage:
#   ./migration_runner.sh <csv_filename> <dry_run: true|false>
#
# csv_filename is the basename only (e.g. migration_request_20260611_103701.csv)
# Script resolves all paths relative to BASE_DIR.
#
# Directory layout under BASE_DIR:
#   pending/    - drop CSV here before running
#   processed/  - CSV moved here on full success
#   failed/     - CSV moved here on any skip or failure
#   logs/       - run log and rsync log written here
# =============================================================================

set -uo pipefail

# =============================================================================
# Configuration
# =============================================================================
BASE_DIR="/data/MRGeng/Migration_Utility"
PENDING_DIR="${BASE_DIR}/pending"
PROCESSED_DIR="${BASE_DIR}/processed"
FAILED_DIR="${BASE_DIR}/failed"
LOG_DIR="${BASE_DIR}/logs"

EXPECTED_HEADER="#Type,Source server,Destination server,Source path,Destination path,Source user,Target user,Source group,Target group"
EXPECTED_COLUMNS=9

SSH_TIMEOUT=5
RSYNC_OPTS="-avz"

# =============================================================================
# Arguments
# =============================================================================
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <csv_filename> <dry_run: true|false>" >&2
    exit 1
fi

CSV_FILENAME="$1"
DRY_RUN="$2"

if [[ "${DRY_RUN}" != "true" && "${DRY_RUN}" != "false" ]]; then
    echo "Error: dry_run must be 'true' or 'false'" >&2
    exit 1
fi

CSV_BASENAME="${CSV_FILENAME%.csv}"
CSV_FILE="${PENDING_DIR}/${CSV_FILENAME}"
RUN_LOG="${LOG_DIR}/${CSV_BASENAME}.run.log"
RSYNC_LOG="${LOG_DIR}/${CSV_BASENAME}.rsync.log"

# =============================================================================
# Ensure directories exist
# =============================================================================
mkdir -p "${PENDING_DIR}" "${PROCESSED_DIR}" "${FAILED_DIR}" "${LOG_DIR}"

> "${RUN_LOG}"
> "${RSYNC_LOG}"

# =============================================================================
# Logging helpers
# =============================================================================
log() {
    echo "$*" | tee -a "${RUN_LOG}"
}

rsync_log() {
    echo "$*" >> "${RSYNC_LOG}"
}

# =============================================================================
# Timing helpers
# =============================================================================
get_epoch() { date +%s; }

elapsed() {
    local start=$1
    echo $(( $(get_epoch) - start ))
}

# =============================================================================
# Finalise and exit
# =============================================================================
finish() {
    local status="$1"

    log "================================================================================"
    log " Finished    : $(date '+%Y-%m-%d %H:%M:%S')"
    log " Duration    : $(elapsed "${START_TIME}")s"

    case "${status}" in
        processed)
            log " CSV status  : moved to processed/${CSV_FILENAME}"
            mv "${CSV_FILE}" "${PROCESSED_DIR}/${CSV_FILENAME}"
            ;;
        failed)
            log " CSV status  : moved to failed/${CSV_FILENAME}"
            mv "${CSV_FILE}" "${FAILED_DIR}/${CSV_FILENAME}"
            ;;
        pending)
            log " CSV status  : left in pending/"
            ;;
    esac

    log "================================================================================"
}

# =============================================================================
# SSH connectivity check
# =============================================================================
check_ssh() {
    ssh -o ConnectTimeout="${SSH_TIMEOUT}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        "$1" true 2>/dev/null
}

# =============================================================================
# Remote helpers
# =============================================================================
remote_du() {
    ssh -o ConnectTimeout="${SSH_TIMEOUT}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        "$1" "du -sb '$2' 2>/dev/null | cut -f1" 2>/dev/null
}

remote_df_avail() {
    ssh -o ConnectTimeout="${SSH_TIMEOUT}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        "$1" "df -B1 --output=avail '$2' 2>/dev/null | tail -1" 2>/dev/null
}

remote_user_exists() {
    ssh -o ConnectTimeout="${SSH_TIMEOUT}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        "$1" "id '$2' > /dev/null 2>&1" 2>/dev/null
}

remote_group_exists() {
    ssh -o ConnectTimeout="${SSH_TIMEOUT}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        "$1" "getent group '$2' > /dev/null 2>&1" 2>/dev/null
}

# =============================================================================
# START
# =============================================================================
START_TIME=$(get_epoch)
START_TS=$(date '+%Y-%m-%d %H:%M:%S')

if [[ "${DRY_RUN}" == "true" ]]; then
    MODE_LABEL="DRY RUN — no changes will be made"
else
    MODE_LABEL="LIVE"
fi

log "================================================================================"
[[ "${DRY_RUN}" == "true" ]] && log " MRG Migration Runner — DRY RUN" \
                              || log " MRG Migration Runner — LIVE"
log "================================================================================"
log " File       : ${CSV_FILENAME}"
log " Started    : ${START_TS}"
log " Mode       : ${MODE_LABEL}"
log "================================================================================"

# =============================================================================
# Validate file exists
# =============================================================================
if [[ ! -f "${CSV_FILE}" ]]; then
    log "[ERROR] File not found: ${CSV_FILE}"
    log "[ABORT] No rows executed. Confirm the filename and re-upload to pending/."
    finish "pending"
    exit 1
fi

# =============================================================================
# CRLF strip
# =============================================================================
set -x
if command -v dos2unix &>/dev/null; then
    dos2unix "${CSV_FILE}" 2>/dev/null
else
    sed -i $'s/\r//' "${CSV_FILE}"
fi
log "[PARSE] Stripping CRLF line endings... done"

# =============================================================================
# Header validation
# =============================================================================
ACTUAL_HEADER=$(head -1 "${CSV_FILE}")

if [[ "${ACTUAL_HEADER}" != "${EXPECTED_HEADER}" ]]; then
    ACTUAL_COLS=$(awk -F',' '{print NF; exit}' "${CSV_FILE}")
    log "[PARSE] Validating CSV header... FAIL"
    log "[ABORT] Unexpected header format. Expected ${EXPECTED_COLUMNS} columns, got ${ACTUAL_COLS}."
    log "        No rows executed. Re-upload the correct CSV file."
    finish "pending"
    exit 1
fi

log "[PARSE] Validating CSV header... OK"

# =============================================================================
# Count rows
# =============================================================================
mapfile -t DATA_ROWS < <(tail -n +2 "${CSV_FILE}" | grep -v '^[[:space:]]*$')
TOTAL_ROWS=${#DATA_ROWS[@]}
DT_COUNT=0
OT_COUNT=0

for row in "${DATA_ROWS[@]}"; do
    type_field=$(echo "${row}" | cut -d',' -f1)
    [[ "${type_field}" == "DATA_TRANSFER" ]]     && (( DT_COUNT++ ))  || true
    [[ "${type_field}" == "OWNERSHIP_TRANSFER" ]] && (( OT_COUNT++ )) || true
done

log "[PARSE] ${TOTAL_ROWS} data rows found (${DT_COUNT} DATA_TRANSFER, ${OT_COUNT} OWNERSHIP_TRANSFER)"

# =============================================================================
# PRECHECK 1 — SSH connectivity
# =============================================================================
declare -A SSH_STATUS
ALL_HOSTS=()

while IFS=',' read -r type src_srv dst_srv src_path dst_path src_usr dst_usr src_grp dst_grp; do
    [[ "${type}" == \#* || -z "${type}" ]] && continue
    src_srv=$(echo "${src_srv}" | xargs)
    dst_srv=$(echo "${dst_srv}" | xargs)
    [[ -n "${src_srv}" ]] && ALL_HOSTS+=("${src_srv}")
    [[ -n "${dst_srv}" ]] && ALL_HOSTS+=("${dst_srv}")
done < "${CSV_FILE}"

# Deduplicate — handle empty array safely
if [[ ${#ALL_HOSTS[@]} -gt 0 ]]; then
    mapfile -t UNIQUE_HOSTS < <(printf '%s\n' "${ALL_HOSTS[@]}" | sort -u | grep -v '^$')
else
    UNIQUE_HOSTS=()
fi
set +x

log "[PRECHECK] Testing SSH connectivity for all hosts in CSV..."
UNREACHABLE_HOSTS=()

for host in "${UNIQUE_HOSTS[@]}"; do
    if check_ssh "${host}"; then
        printf "  %-45s OK\n" "${host}" | tee -a "${RUN_LOG}"
        SSH_STATUS["${host}"]="OK"
    else
        printf "  %-45s UNREACHABLE\n" "${host}" | tee -a "${RUN_LOG}"
        SSH_STATUS["${host}"]="UNREACHABLE"
        UNREACHABLE_HOSTS+=("${host}")
    fi
done

# Hard abort if any DT source is unreachable
while IFS=',' read -r type src_srv dst_srv src_path dst_path src_usr dst_usr src_grp dst_grp; do
    [[ "${type}" == \#* || -z "${type}" ]] && continue
    src_srv=$(echo "${src_srv}" | xargs)
    if [[ "${type}" == "DATA_TRANSFER" && "${SSH_STATUS[${src_srv}]:-UNREACHABLE}" == "UNREACHABLE" ]]; then
        log "[PRECHECK] Source host ${src_srv} is unreachable."
        log "[ABORT] Cannot proceed — source host must be reachable for DATA_TRANSFER rows."
        log "        No rows executed. Re-upload once connectivity is resolved."
        finish "pending"
        exit 1
    fi
done < "${CSV_FILE}"

# =============================================================================
# PRECHECK 2 — Space and ownership checks
# =============================================================================
declare -A PRECHECK_FAILURES
declare -A HOST_SPACE_NEEDED
declare -A HOST_DST_PATH
declare -A HOST_CHECK_USER
declare -A HOST_CHECK_GROUP

while IFS=',' read -r type src_srv dst_srv src_path dst_path src_usr dst_usr src_grp dst_grp; do
    [[ "${type}" == \#* || -z "${type}" ]] && continue

    type=$(echo "${type}"         | xargs)
    src_srv=$(echo "${src_srv}"   | xargs)
    dst_srv=$(echo "${dst_srv}"   | xargs)
    src_path=$(echo "${src_path}" | xargs)
    dst_path=$(echo "${dst_path}" | xargs)
    dst_usr=$(echo "${dst_usr}"   | xargs)
    dst_grp=$(echo "${dst_grp}"   | xargs)

    if [[ "${type}" == "DATA_TRANSFER" ]]; then
        [[ "${SSH_STATUS[${dst_srv}]:-UNREACHABLE}" == "UNREACHABLE" ]] && continue
        src_size=$(remote_du "${src_srv}" "${src_path}")
        if [[ -n "${src_size}" && "${src_size}" =~ ^[0-9]+$ ]]; then
            current=${HOST_SPACE_NEEDED["${dst_srv}"]:-0}
            HOST_SPACE_NEEDED["${dst_srv}"]=$(( current + src_size ))
            HOST_DST_PATH["${dst_srv}"]="${dst_path}"
        fi
        [[ -n "${dst_usr}" ]] && HOST_CHECK_USER["${dst_srv}:${dst_usr}"]="1"
        [[ -n "${dst_grp}" ]] && HOST_CHECK_GROUP["${dst_srv}:${dst_grp}"]="1"

    elif [[ "${type}" == "OWNERSHIP_TRANSFER" ]]; then
        [[ "${SSH_STATUS[${src_srv}]:-UNREACHABLE}" == "UNREACHABLE" ]] && continue
        [[ -n "${dst_usr}" ]] && HOST_CHECK_USER["${src_srv}:${dst_usr}"]="1"
        [[ -n "${dst_grp}" ]] && HOST_CHECK_GROUP["${src_srv}:${dst_grp}"]="1"
    fi

done < "${CSV_FILE}"

# Space checks
for host in "${!HOST_SPACE_NEEDED[@]}"; do
    needed=${HOST_SPACE_NEEDED["${host}"]}
    dst_path=${HOST_DST_PATH["${host}"]}
    avail=$(remote_df_avail "${host}" "${dst_path}")
    if [[ -z "${avail}" || ! "${avail}" =~ ^[0-9]+$ ]]; then
        existing="${PRECHECK_FAILURES[${host}]:-}"
        PRECHECK_FAILURES["${host}"]="${existing:+${existing}|}Could not determine available space on ${dst_path}"
    elif (( needed > avail )); then
        needed_h=$(( needed / 1024 / 1024 ))
        avail_h=$(( avail  / 1024 / 1024 ))
        existing="${PRECHECK_FAILURES[${host}]:-}"
        PRECHECK_FAILURES["${host}"]="${existing:+${existing}|}Insufficient space: need ${needed_h}M, available ${avail_h}M on ${dst_path}"
    fi
done

# User existence checks
for key in "${!HOST_CHECK_USER[@]}"; do
    host="${key%%:*}"
    user="${key#*:}"
    if ! remote_user_exists "${host}" "${user}"; then
        existing="${PRECHECK_FAILURES[${host}]:-}"
        PRECHECK_FAILURES["${host}"]="${existing:+${existing}|}User '${user}' not found"
    fi
done

# Group existence checks
for key in "${!HOST_CHECK_GROUP[@]}"; do
    host="${key%%:*}"
    group="${key#*:}"
    if ! remote_group_exists "${host}" "${group}"; then
        existing="${PRECHECK_FAILURES[${host}]:-}"
        PRECHECK_FAILURES["${host}"]="${existing:+${existing}|}Group '${group}' not found"
    fi
done

# Report space/ownership results
log "[PRECHECK] Space and ownership checks..."
PRECHECK_FAILED_HOSTS=()

for host in "${UNIQUE_HOSTS[@]}"; do
    [[ "${SSH_STATUS[${host}]:-UNREACHABLE}" == "UNREACHABLE" ]] && continue
    if [[ -n "${PRECHECK_FAILURES[${host}]:-}" ]]; then
        printf "  %-45s FAIL\n" "${host}" | tee -a "${RUN_LOG}"
        IFS='|' read -ra reasons <<< "${PRECHECK_FAILURES[${host}]}"
        for reason in "${reasons[@]}"; do
            log "    - ${reason}"
        done
        PRECHECK_FAILED_HOSTS+=("${host}")
    else
        printf "  %-45s OK\n" "${host}" | tee -a "${RUN_LOG}"
    fi
done

if [[ ${#UNREACHABLE_HOSTS[@]} -gt 0 || ${#PRECHECK_FAILED_HOSTS[@]} -gt 0 ]]; then
    if [[ ${#UNREACHABLE_HOSTS[@]} -gt 0 ]]; then
        UNREACHABLE_LIST=$(printf '%s, ' "${UNREACHABLE_HOSTS[@]}")
        log "[PRECHECK] ${#UNREACHABLE_HOSTS[@]} host(s) unreachable: ${UNREACHABLE_LIST%, }"
    fi
    if [[ ${#PRECHECK_FAILED_HOSTS[@]} -gt 0 ]]; then
        FAILED_LIST=$(printf '%s, ' "${PRECHECK_FAILED_HOSTS[@]}")
        log "[PRECHECK] ${#PRECHECK_FAILED_HOSTS[@]} host(s) failed space/ownership checks: ${FAILED_LIST%, }"
    fi
    log "[PRECHECK] Affected rows will be skipped. Remaining rows will proceed."
else
    log "[PRECHECK] All checks passed. Continuing."
fi

log "================================================================================"

# =============================================================================
# Process rows
# =============================================================================
SUCCEEDED=0
SKIPPED=0
FAILED=0
SKIPPED_DETAIL=()
FAILED_DETAIL=()
HOSTS_TOUCHED=()

ROW_NUM=0

while IFS=',' read -r type src_srv dst_srv src_path dst_path src_usr dst_usr src_grp dst_grp; do
    [[ "${type}" == \#* || -z "${type}" ]] && continue

    (( ROW_NUM++ )) || true

    type=$(echo "${type}"         | xargs)
    src_srv=$(echo "${src_srv}"   | xargs)
    dst_srv=$(echo "${dst_srv}"   | xargs)
    src_path=$(echo "${src_path}" | xargs)
    dst_path=$(echo "${dst_path}" | xargs)
    src_usr=$(echo "${src_usr}"   | xargs)
    dst_usr=$(echo "${dst_usr}"   | xargs)
    src_grp=$(echo "${src_grp}"   | xargs)
    dst_grp=$(echo "${dst_grp}"   | xargs)

    CHOWN_ARG=""
    if [[ -n "${dst_usr}" || -n "${dst_grp}" ]]; then
        CHOWN_ARG="--chown=${dst_usr}:${dst_grp}"
    fi

    log "ROW ${ROW_NUM} — ${type}"

    # ------------------------------------------------------------------
    if [[ "${type}" == "DATA_TRANSFER" ]]; then

        log "  Source      : ${src_srv}:${src_path}"
        log "  Destination : ${dst_srv}:${dst_path}"
        [[ -n "${src_usr}" ]] && log "  User remap  : ${src_usr} -> ${dst_usr}" || log "  User remap  : (none)"
        [[ -n "${src_grp}" ]] && log "  Group remap : ${src_grp} -> ${dst_grp}" || log "  Group remap : (none)"

        if [[ "${SSH_STATUS[${dst_srv}]:-UNREACHABLE}" == "UNREACHABLE" ]]; then
            log "[SKIP] ${dst_srv} unreachable — skipping row ${ROW_NUM}"
            (( SKIPPED++ )) || true
            SKIPPED_DETAIL+=("ROW ${ROW_NUM}: ${dst_srv} — unreachable at precheck")
            continue
        fi

        if [[ -n "${PRECHECK_FAILURES[${dst_srv}]:-}" ]]; then
            REASON=$(echo "${PRECHECK_FAILURES[${dst_srv}]}" | cut -d'|' -f1)
            log "[SKIP] ${dst_srv} failed precheck (${REASON}) — skipping row ${ROW_NUM}"
            (( SKIPPED++ )) || true
            SKIPPED_DETAIL+=("ROW ${ROW_NUM}: ${dst_srv} — failed precheck")
            continue
        fi

        RSYNC_CMD="rsync ${RSYNC_OPTS}"
        [[ -n "${CHOWN_ARG}" ]] && RSYNC_CMD="${RSYNC_CMD} ${CHOWN_ARG}"
        RSYNC_CMD="${RSYNC_CMD} ${src_srv}:${src_path} ${dst_srv}:${dst_path}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            log "[DRY-RUN] ${RSYNC_CMD}"
        else
            log "[EXEC] ${RSYNC_CMD}"
            ROW_START=$(get_epoch)
            rsync_log "--- ROW ${ROW_NUM}: ${src_srv}:${src_path} -> ${dst_srv}:${dst_path} ---"
            if eval "${RSYNC_CMD}" >> "${RSYNC_LOG}" 2>&1; then
                log "[OK]   exit 0 ($(elapsed "${ROW_START}")s)"
                (( SUCCEEDED++ )) || true
                HOSTS_TOUCHED+=("${dst_srv}")
            else
                EXIT_CODE=$?
                log "[FAIL] exit ${EXIT_CODE} ($(elapsed "${ROW_START}")s)"
                (( FAILED++ )) || true
                FAILED_DETAIL+=("ROW ${ROW_NUM}: ${dst_srv} — exit ${EXIT_CODE}")
            fi
        fi

    # ------------------------------------------------------------------
    elif [[ "${type}" == "OWNERSHIP_TRANSFER" ]]; then

        log "  Server      : ${src_srv}"
        log "  Path        : ${src_path}"
        [[ -n "${src_usr}" ]] && log "  User remap  : ${src_usr} -> ${dst_usr}" || log "  User remap  : (none)"
        [[ -n "${src_grp}" ]] && log "  Group remap : ${src_grp} -> ${dst_grp}" || log "  Group remap : (none)"

        if [[ "${SSH_STATUS[${src_srv}]:-UNREACHABLE}" == "UNREACHABLE" ]]; then
            log "[SKIP] ${src_srv} unreachable — skipping row ${ROW_NUM}"
            (( SKIPPED++ )) || true
            SKIPPED_DETAIL+=("ROW ${ROW_NUM}: ${src_srv} — unreachable at precheck")
            continue
        fi

        if [[ -n "${PRECHECK_FAILURES[${src_srv}]:-}" ]]; then
            REASON=$(echo "${PRECHECK_FAILURES[${src_srv}]}" | cut -d'|' -f1)
            log "[SKIP] ${src_srv} failed precheck (${REASON}) — skipping row ${ROW_NUM}"
            (( SKIPPED++ )) || true
            SKIPPED_DETAIL+=("ROW ${ROW_NUM}: ${src_srv} — failed precheck")
            continue
        fi

        RSYNC_CMD="rsync ${RSYNC_OPTS}"
        [[ -n "${CHOWN_ARG}" ]] && RSYNC_CMD="${RSYNC_CMD} ${CHOWN_ARG}"
        RSYNC_CMD="${RSYNC_CMD} ${src_srv}:${src_path} ${src_srv}:${src_path}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            log "[DRY-RUN] ${RSYNC_CMD}"
        else
            log "[EXEC] ${RSYNC_CMD}"
            ROW_START=$(get_epoch)
            rsync_log "--- ROW ${ROW_NUM}: ${src_srv}:${src_path} (ownership remap in-place) ---"
            if eval "${RSYNC_CMD}" >> "${RSYNC_LOG}" 2>&1; then
                log "[OK]   exit 0 ($(elapsed "${ROW_START}")s)"
                (( SUCCEEDED++ )) || true
                HOSTS_TOUCHED+=("${src_srv}")
            else
                EXIT_CODE=$?
                log "[FAIL] exit ${EXIT_CODE} ($(elapsed "${ROW_START}")s)"
                (( FAILED++ )) || true
                FAILED_DETAIL+=("ROW ${ROW_NUM}: ${src_srv} — exit ${EXIT_CODE}")
            fi
        fi

    # ------------------------------------------------------------------
    else
        log "[SKIP] Unknown type '${type}' — skipping row ${ROW_NUM}"
        (( SKIPPED++ )) || true
        SKIPPED_DETAIL+=("ROW ${ROW_NUM}: unknown type '${type}'")
    fi

done < "${CSV_FILE}"

# =============================================================================
# Summary
# =============================================================================
log "================================================================================"
log "SUMMARY"

if [[ "${DRY_RUN}" == "true" ]]; then
    log "  Total rows    : ${TOTAL_ROWS}"
    log "  Would execute : ${TOTAL_ROWS}"
    log "  Skipped       : ${SKIPPED}"
    if [[ ${#UNIQUE_HOSTS[@]} -gt 0 ]]; then
        SCOPE_LIST=$(printf '%s, ' "${UNIQUE_HOSTS[@]}")
        log "  Hosts in scope: ${SCOPE_LIST%, }"
    fi
    log " DRY RUN complete — no changes were made."
    log " Re-run with DRY_RUN=false to execute."
    finish "pending"
else
    log "  Total rows    : ${TOTAL_ROWS}"
    log "  Succeeded     : ${SUCCEEDED}"
    log "  Skipped       : ${SKIPPED}"
    log "  Failed        : ${FAILED}"

    if [[ ${#SKIPPED_DETAIL[@]} -gt 0 ]]; then
        for s in "${SKIPPED_DETAIL[@]}"; do log "    - ${s}"; done
    fi
    if [[ ${#FAILED_DETAIL[@]} -gt 0 ]]; then
        for f in "${FAILED_DETAIL[@]}"; do log "    - ${f}"; done
    fi
    if [[ ${#HOSTS_TOUCHED[@]} -gt 0 ]]; then
        mapfile -t UNIQUE_TOUCHED < <(printf '%s\n' "${HOSTS_TOUCHED[@]}" | sort -u)
        TOUCHED_LIST=$(printf '%s, ' "${UNIQUE_TOUCHED[@]}")
        log "  Hosts touched : ${TOUCHED_LIST%, }"
    fi

    if [[ ${FAILED} -gt 0 || ${SKIPPED} -gt 0 ]]; then
        [[ ${SKIPPED} -gt 0 ]] && log " WARNING: ${SKIPPED} row(s) skipped."
        [[ ${FAILED}  -gt 0 ]] && log " WARNING: ${FAILED} row(s) failed."
        log " CSV moved to failed/ — re-upload after resolving issues."
        finish "failed"
    else
        finish "processed"
    fi
fi
