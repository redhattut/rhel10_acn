#!/bin/bash
# =============================================================================
# rhel_filter_scan.sh — Jumpbox-side pssh output filter and stream splitter
# =============================================================================
# Reads the combined pssh --inline-stdout stream from stdin.
# Strips pssh status/header noise, then routes each tagged data line to
# the correct output file based on its prefix tag.
#
# Usage (called from rhel_inv_collect.sh):
#   cat rhel_remote_scan.sh RHEL_data_gather.sh \
#     | pssh $PSSH_OPTS -h $MASTERHOSTLIST bash \
#     | rhel_filter_scan.sh \
#         <inv_tmpfile> \
#         <id_tmpfile> \
#         <db_tmpfile> \
#         <pkg_tmpfile> \
#         <mrg_csv_tmpfile> \
#         <mrg_json_tmpfile>
#
# Arguments:
#   $1  INVENTORYTEMP   — destination for INV| lines
#   $2  IDINVENTORYTEMP — destination for ID|  lines
#   $3  DBINVENTORYTEMP — destination for DB|  lines
#   $4  PACKAGETEMP     — destination for PKG| lines
#   $5  MRGCSVTEMP      — destination for MID_MOD_CSV: lines
#   $6  MRGJSONTMP      — destination for COMPARE_JSON: lines (one JSON per line)
#
# CRITICAL DESIGN NOTE:
# pssh --inline-stdout runs hosts in parallel and INTERLEAVES output lines.
# Therefore ALL routing must be stateless — one line in, one line out.
# Multi-line buffering (JSON state machine) is NOT safe here.
# RHEL_data_gather.sh emits JSON as a single minified line per host.
#
# Tag formats:
#   INV|<data>                    — rhel_remote_scan.sh system inventory
#   ID|<data>                     — rhel_remote_scan.sh user/group data
#   DB|<data>                     — rhel_remote_scan.sh Oracle SID data
#   PKG|<data>                    — rhel_remote_scan.sh RPM package data
#   MID_MOD_CSV:<host>:<row>      — RHEL_data_gather.sh Midrange Mod CSV
#   COMPARE_JSON:<host>:<json>    — RHEL_data_gather.sh single-line JSON
# =============================================================================

# --- Argument validation -----------------------------------------------------
if [[ $# -ne 6 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_filter_scan.sh requires 6 arguments" >&2
    echo "  Usage: rhel_filter_scan.sh inv_tmp id_tmp db_tmp pkg_tmp mrg_csv_tmp mrg_json_tmp" >&2
    exit 1
fi

# Validate no empty paths
for _arg in "$1" "$2" "$3" "$4" "$5" "$6"; do
    if [[ -z "$_arg" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_filter_scan.sh: one or more output path arguments is empty" >&2
        echo "  Check that MRGCSVTEMP and MRGJSONTMP are set before calling rhel_inv_collect.sh" >&2
        exit 1
    fi
done

INV_OUT="$1"
ID_OUT="$2"
DB_OUT="$3"
PKG_OUT="$4"
MRG_CSV_OUT="$5"
MRG_JSON_OUT="$6"

# Error log sits alongside the inventory temp files
ERR_LOG="$(dirname "$INV_OUT")/scan_filter_errors.$(date +%Y%m%d_%H%M%S).log"

# RPM DB error tracking — hosts where rpm -qa failed due to corrupt rpmdb.
# These hosts ARE in the inventory (INV line collected) but have no package data.
# Check this file at the start of the next run to retry rpm -qa on just these hosts.
RPM_DB_ERR_LOG="$(dirname "$INV_OUT")/rpm_db_errors.dat"

# Counters
count_inv=0
count_id=0
count_db=0
count_pkg=0
count_mrg_csv=0
count_mrg_json=0
count_err=0
count_skip=0
count_rpmdb=0

# Start the combined JSON array file — each line is one minified JSON object
echo "[" > "$MRG_JSON_OUT"
_json_first=true

# --- Diagnostic: log first 50 raw lines to understand stream format ----------
# Remove this block after confirming routing works correctly
DIAG_LOG="$(dirname "$INV_OUT")/filter_diag.$(date +%Y%m%d_%H%M%S).log"
DIAG_COUNT=0
DIAG_MAX=50
_seen_inv=false; _seen_pkg=false; _seen_mrg=false; _seen_json=false

# =============================================================================
# Main filter loop — fully stateless, one line at a time
# =============================================================================

while IFS= read -r raw; do

    (( ${#raw} == 0 )) && continue

    # --- Diagnostic logging --------------------------------------------------
    if (( DIAG_COUNT < DIAG_MAX )); then
        echo "RAW[$DIAG_COUNT]: $raw" >> "$DIAG_LOG"
        (( DIAG_COUNT++ ))
    fi

    # Strip pssh inline-stdout host prefix "hostname: "
    if [[ "$raw" == *": "* ]]; then
        line="${raw#*: }"
    else
        line="$raw"
    fi

    (( ${#line} == 0 )) && continue

    # --- pssh FAILURE detection ----------------------------------------------
    # Classifies each failure as either SSHFAIL or TIMEOUT_Virt:
    #
    #   SSHFAIL  — SSH connected but host is administratively unreachable:
    #              • error code 1  = SSH connected, remote side rejected session
    #                                (forced password change, PAM policy, etc.)
    #              • error code 255 = SSH transport error (key mismatch, etc.)
    #              • "No space left" in stderr = filesystem full, sshd dropped session
    #
    #   TIMEOUT_Virt — Host did not respond within PSSH_TIMEOUT.
    #                  Type suffix is Virt as the safe default; Phase 7 carry-forward
    #                  will restore the real type (Virt/Phys/Cloud) from the prior run.
    #
    # Both types write identical stubs so downstream processing is unchanged.
    # The $2 field (SSHFAIL vs TIMEOUT_Virt) is what the report script counts.

    _fail_host=""
    _fail_type="TIMEOUT_Virt"    # default — overridden to SSHFAIL below when detected
    _fail_reason="Host unreachable or timed out during pssh collection"

    case "$line" in
        FAILURE*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') PSSH_FAILURE: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            _fail_host=$(echo "$line" | awk '{print $2}')
            # "error code 1"  → forced password change / PAM rejection
            # "error code 255" → SSH transport failure / host key issue
            if echo "$line" | grep -qE 'error code (1|255)'; then
                _fail_type="SSHFAIL"
                _fail_reason="SSH connection rejected (password expiry or key issue)"
            fi
            ;;
        *\[FAILURE\]*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') PSSH_FAILURE: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            _fail_host=$(echo "$line" | sed 's/.*\[FAILURE\] //' | awk '{print $1}')
            if echo "$line" | grep -qE 'error code (1|255)'; then
                _fail_type="SSHFAIL"
                _fail_reason="SSH connection rejected (password expiry or key issue)"
            fi
            ;;
        # Low-disk: sshd writes a tmp file at session start; full filesystem
        # causes it to drop the connection immediately before any command runs.
        # pssh sees this as a stderr line (not a FAILURE status line).
        *[Nn]o\ space\ left*|*[Dd]isk\ quota\ exceeded*|*[Cc]annot\ write*\ *[Nn]o\ space*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') PSSH_LOWDISK: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            # Extract hostname from the pssh "hostname: message" prefix
            _fail_host="${raw%%: *}"
            _fail_host="${_fail_host##*\[}"   # strip any "[N] " pssh prefix
            _fail_host="${_fail_host%%.*}"
            _fail_type="SSHFAIL"
            _fail_reason="SSH session dropped — filesystem full on remote host"
            ;;
        SUCCESS*|\[*|\[stderr\]*)
            (( count_skip++ ))
            continue
            ;;
    esac

    if [[ -n "$_fail_host" ]]; then
        _fail_host="${_fail_host%%.*}"
        if [[ -n "$_fail_host" && "$_fail_host" != "[FAILURE]" ]]; then
            # INV stub — $2 is SSHFAIL or TIMEOUT_Virt depending on failure type
            # $3 is n/a (not TIMEOUT) so Phase 7 $3=="?" skip doesn't fire
            echo "$_fail_host ${_fail_type} n/a n/a n/a 0 0 0 0 n/a 0 n/a n/a n/a ${_fail_type} 0 n/a N UNKNOWN n/a n/a n/a n/a n/a n/a n/a n/a n/a" >> "$INV_OUT"
            (( count_inv++ ))
            # MID_MOD_CSV stub
            echo "$_fail_host,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a" >> "$MRG_CSV_OUT"
            (( count_mrg_csv++ ))
            # COMPARE_JSON stub — single line
            _ts="$(date '+%Y-%m-%dT%H:%M:%S')"
            _stub="{\"host\":\"${_fail_host}\",\"collected_at\":\"${_ts}\",\"reachable\":false,\"error\":\"${_fail_reason}\"}"
            if [[ "$_json_first" == true ]]; then
                printf '%s\n' "$_stub" >> "$MRG_JSON_OUT"
                _json_first=false
            else
                printf ',\n%s\n' "$_stub" >> "$MRG_JSON_OUT"
            fi
            (( count_mrg_json++ ))
        fi
        continue
    fi

    # Skip remaining pssh numbered lines
    if [[ "$line" =~ ^\[[0-9]+\] ]]; then
        (( count_skip++ ))
        continue
    fi

    # --- Route MID_MOD_CSV (colon-delimited) ---------------------------------
    # Format: MID_MOD_CSV:<host>:<csv_row>
    if [[ "$line" == MID_MOD_CSV:*:* ]]; then
        if [[ "$_seen_mrg" == false ]]; then
            echo "FIRST_MRG_LINE: $line" >> "$DIAG_LOG"
            echo "FIRST_MRG_RAW:  $raw"  >> "$DIAG_LOG"
            _seen_mrg=true
        fi
        _csv_row="${line#MID_MOD_CSV:}"
        _csv_row="${_csv_row#*:}"
        echo "$_csv_row" >> "$MRG_CSV_OUT"
        (( count_mrg_csv++ ))
        continue
    fi

    # --- Route COMPARE_JSON (single-line minified JSON) ----------------------
    # Format: COMPARE_JSON:<host>:<json_object>
    if [[ "$line" == COMPARE_JSON:*:* ]]; then
        if [[ "$_seen_json" == false ]]; then
            echo "FIRST_JSON_LINE: ${line:0:120}" >> "$DIAG_LOG"
            echo "FIRST_JSON_RAW:  ${raw:0:120}"  >> "$DIAG_LOG"
            _seen_json=true
        fi
        # Extract just the JSON part (everything after second colon)
        _json_part="${line#COMPARE_JSON:}"
        _json_part="${_json_part#*:}"
        if [[ "$_json_first" == true ]]; then
            printf '%s\n' "$_json_part" >> "$MRG_JSON_OUT"
            _json_first=false
        else
            printf ',\n%s\n' "$_json_part" >> "$MRG_JSON_OUT"
        fi
        (( count_mrg_json++ ))
        continue
    fi

    # --- Route pipe-delimited tags -------------------------------------------
    tag="${line%%|*}"
    data="${line#*|}"

    case "$tag" in
        INV)
            if [[ "$_seen_inv" == false ]]; then
                echo "FIRST_INV_LINE: $line" >> "$DIAG_LOG"
                echo "FIRST_INV_RAW:  $raw"  >> "$DIAG_LOG"
                _seen_inv=true
            fi
            echo "$data" >> "$INV_OUT"
            (( count_inv++ ))
            ;;
        ID)
            echo "$data" >> "$ID_OUT"
            (( count_id++ ))
            ;;
        DB)
            echo "$data" >> "$DB_OUT"
            (( count_db++ ))
            ;;
        PKG)
            if [[ "$_seen_pkg" == false ]]; then
                echo "FIRST_PKG_LINE: $line" >> "$DIAG_LOG"
                echo "FIRST_PKG_RAW:  $raw"  >> "$DIAG_LOG"
                _seen_pkg=true
            fi
            [[ "$data" == Inventory* ]] && continue
            # RPM DB corrupt sentinel — log the host, skip writing to PACKAGETEMP.
            # The host's INV line was still collected so it appears in inventory.
            # rpm_db_errors.dat is checked at the start of the next run to retry.
            if [[ "$data" == RPM_DB_ERROR:* ]]; then
                _rpmdb_host="${data#RPM_DB_ERROR:}"
                echo "$_rpmdb_host" >> "$RPM_DB_ERR_LOG"
                (( count_rpmdb++ ))
                continue
            fi
            echo "$data" >> "$PKG_OUT"
            (( count_pkg++ ))
            ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') UNTAGGED: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            ;;
    esac

done

# Close JSON array
echo "]" >> "$MRG_JSON_OUT"

# =============================================================================
printf '%s  [INFO]    Filter summary — INV: %d  ID: %d  DB: %d  PKG: %d  MRG_CSV: %d  MRG_JSON: %d  skipped: %d  errors: %d  rpmdb_corrupt: %d\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$count_inv" "$count_id" "$count_db" "$count_pkg" \
    "$count_mrg_csv" "$count_mrg_json" \
    "$count_skip" "$count_err" "$count_rpmdb"

if [[ -s "$RPM_DB_ERR_LOG" ]]; then
    printf '%s  [WARN]    %d host(s) with corrupt RPM DB logged to: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$count_rpmdb" "$RPM_DB_ERR_LOG"
fi

if [[ -f "$ERR_LOG" && -s "$ERR_LOG" ]]; then
    printf '%s  [WARN]    %d untagged/failure lines written to: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$count_err" "$ERR_LOG"
else
    rm -f "$ERR_LOG"
fi

printf '%s  [DIAG]    Diagnostic log (first %d raw lines + first tag occurrences): %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$DIAG_MAX" "$DIAG_LOG"

exit 0
