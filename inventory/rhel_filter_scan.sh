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
#   $1  INVENTORYTEMP   — destination for INV| lines (system inventory)
#   $2  IDINVENTORYTEMP — destination for ID|  lines (users/groups)
#   $3  DBINVENTORYTEMP — destination for DB|  lines (Oracle SIDs)
#   $4  PACKAGETEMP     — destination for PKG| lines (RPM packages)
#   $5  MRGCSVTEMP      — destination for MID_MOD_CSV: lines (Midrange Mod CSV)
#   $6  MRGJSONTMP      — destination for COMPARE_JSON blocks (Server Compare JSON array)
#
# Tag formats from remote scripts:
#   INV|<data>                  — rhel_remote_scan.sh system inventory
#   ID|<data>                   — rhel_remote_scan.sh user/group data
#   DB|<data>                   — rhel_remote_scan.sh Oracle SID data
#   PKG|<data>                  — rhel_remote_scan.sh RPM package data
#   MID_MOD_CSV:<host>:<row>    — RHEL_data_gather.sh Midrange Mod CSV row
#   COMPARE_JSON_START:<host>   — RHEL_data_gather.sh JSON block start
#   <json lines...>             — RHEL_data_gather.sh JSON body lines
#   COMPARE_JSON_END:<host>     — RHEL_data_gather.sh JSON block end
# =============================================================================

# --- Argument validation -----------------------------------------------------
if [[ $# -ne 6 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_filter_scan.sh requires 6 arguments" >&2
    echo "  Usage: rhel_filter_scan.sh inv_tmp id_tmp db_tmp pkg_tmp mrg_csv_tmp mrg_json_tmp" >&2
    exit 1
fi

# Validate no empty paths — an empty arg causes silent data loss
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

# Counters for summary logging
count_inv=0
count_id=0
count_db=0
count_pkg=0
count_mrg_csv=0
count_mrg_json=0
count_err=0
count_skip=0

# JSON accumulation state — buffer per hostname
_json_host=""
_json_buf=""
_json_collecting=false

# Start the combined JSON array file
echo "[" > "$MRG_JSON_OUT"
_json_first_entry=true

# =============================================================================
# Main filter loop
# =============================================================================

while IFS= read -r raw; do

    # Skip completely blank lines
    (( ${#raw} == 0 )) && continue

    # --- Strip pssh inline-stdout host prefix --------------------------------
    # Format: "hostname: actual_content"
    if [[ "$raw" == *": "* ]]; then
        line="${raw#*: }"
    else
        line="$raw"
    fi

    # --- Skip blank content after prefix strip --------------------------------
    (( ${#line} == 0 )) && continue

    # --- JSON body accumulation — must check BEFORE pssh status detection -----
    # Lines between COMPARE_JSON_START and COMPARE_JSON_END are raw JSON.
    # They may look like pssh status lines (e.g. start with "[") so we must
    # handle them first while the collecting flag is set.
    if [[ "$_json_collecting" == true ]]; then
        # Check for end marker first
        if [[ "$line" == COMPARE_JSON_END:* ]]; then
            # Close and write the buffered JSON entry to the array file
            if [[ -n "$_json_host" && -n "$_json_buf" ]]; then
                if [[ "$_json_first_entry" == true ]]; then
                    printf '%s\n' "$_json_buf" >> "$MRG_JSON_OUT"
                    _json_first_entry=false
                else
                    printf ',\n%s\n' "$_json_buf" >> "$MRG_JSON_OUT"
                fi
                (( count_mrg_json++ ))
            fi
            _json_host=""
            _json_buf=""
            _json_collecting=false
        else
            # Accumulate JSON body line
            if [[ -z "$_json_buf" ]]; then
                _json_buf="$line"
            else
                _json_buf="${_json_buf}"$'\n'"${line}"
            fi
        fi
        continue
    fi

    # --- Detect and log pssh status lines ------------------------------------
    # Format A (bare):     "FAILURE hostname ..."
    # Format B (numbered): "[1] HH:MM:SS [FAILURE] hostname ..."

    _fail_host=""

    case "$line" in
        FAILURE*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') PSSH_FAILURE: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            _fail_host=$(echo "$line" | awk '{print $2}')
            ;;

        *\[FAILURE\]*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') PSSH_FAILURE: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            _fail_host=$(echo "$line" | sed 's/.*\[FAILURE\] //' | awk '{print $1}')
            ;;

        SUCCESS*|\[*|\[stderr\]*)
            (( count_skip++ ))
            continue
            ;;
    esac

    # If we extracted a failure hostname, write stubs for all streams
    if [[ -n "$_fail_host" ]]; then
        _fail_host="${_fail_host%%.*}"
        if [[ -n "$_fail_host" && "$_fail_host" != "[FAILURE]" ]]; then
            # INV stub — TIMEOUT record
            echo "$_fail_host TIMEOUT TIMEOUT n/a n/a 0 0 0 0 n/a 0 n/a n/a n/a TIMEOUT 0 n/a N UNKNOWN n/a n/a n/a n/a n/a n/a n/a n/a n/a" >> "$INV_OUT"
            (( count_inv++ ))

            # MID_MOD_CSV stub — all n/a
            echo "$_fail_host,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a" >> "$MRG_CSV_OUT"
            (( count_mrg_csv++ ))

            # COMPARE_JSON stub — reachable:false
            _ts="$(date '+%Y-%m-%dT%H:%M:%S')"
            _stub=$(printf '{\n  "host": "%s",\n  "collected_at": "%s",\n  "reachable": false,\n  "error": "Host unreachable or SSH failed during pssh collection"\n}' \
                "$_fail_host" "$_ts")
            if [[ "$_json_first_entry" == true ]]; then
                printf '%s\n' "$_stub" >> "$MRG_JSON_OUT"
                _json_first_entry=false
            else
                printf ',\n%s\n' "$_stub" >> "$MRG_JSON_OUT"
            fi
            (( count_mrg_json++ ))
        fi
        continue
    fi

    # Skip pssh numbered lines that are not FAILURE (belt-and-suspenders)
    if [[ "$line" =~ ^\[[0-9]+\] ]]; then
        (( count_skip++ ))
        continue
    fi

    # --- Route MRG tags (colon-delimited) before pipe-delimited tag routing ---
    # MID_MOD_CSV:<host>:<csv_row>
    if [[ "$line" == MID_MOD_CSV:*:* ]]; then
        _csv_row="${line#MID_MOD_CSV:}"   # strip tag
        _csv_row="${_csv_row#*:}"         # strip hostname prefix
        echo "$_csv_row" >> "$MRG_CSV_OUT"
        (( count_mrg_csv++ ))
        continue
    fi

    # COMPARE_JSON_START:<host> — begin buffering
    if [[ "$line" == COMPARE_JSON_START:* ]]; then
        _json_host="${line#COMPARE_JSON_START:}"
        _json_host="${_json_host%$'\r'}"   # strip CR if present
        _json_buf=""
        _json_collecting=true
        continue
    fi

    # --- Route by pipe-delimited tag -----------------------------------------
    tag="${line%%|*}"
    data="${line#*|}"

    case "$tag" in
        INV)
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
            [[ "$data" == Inventory* ]] && continue
            echo "$data" >> "$PKG_OUT"
            (( count_pkg++ ))
            ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') UNTAGGED: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            ;;
    esac

done

# Close the JSON array
echo "]" >> "$MRG_JSON_OUT"

# =============================================================================
# Summary to stdout (captured by rhel_inv_collect.sh log)
# =============================================================================

printf '%s  [INFO]    Filter summary — INV: %d  ID: %d  DB: %d  PKG: %d  MRG_CSV: %d  MRG_JSON: %d  skipped: %d  errors: %d\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$count_inv" "$count_id" "$count_db" "$count_pkg" \
    "$count_mrg_csv" "$count_mrg_json" \
    "$count_skip" "$count_err"

if [[ -f "$ERR_LOG" && -s "$ERR_LOG" ]]; then
    printf '%s  [WARN]    %d untagged/failure lines written to: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$count_err" "$ERR_LOG"
else
    rm -f "$ERR_LOG"
fi

exit 0
