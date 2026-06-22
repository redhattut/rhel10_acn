#!/bin/bash
# =============================================================================
# rhel_filter_scan.sh — Jumpbox-side pssh output filter and stream splitter
# =============================================================================
# Replaces: filter_inventory_scan.sh
#           filter_IDinventory_scan.sh
#           filter_DBinventory_scan.sh
#           filter_pkginventory_scan.sh
#
# Reads the combined pssh --inline-stdout stream from stdin.
# Strips pssh status/header noise, then routes each tagged data line to
# the correct output file based on its prefix tag.
#
# Usage (called from rhel_inv_collect.sh):
#   cat rhel_remote_scan.sh \
#     | pssh $PSSH_OPTS -h $MASTERHOSTLIST bash \
#     | rhel_filter_scan.sh \
#         <inv_tmpfile> \
#         <id_tmpfile> \
#         <db_tmpfile> \
#         <pkg_tmpfile>
#
# Arguments:
#   $1  INVENTORYTEMP   — destination for INV| lines (system inventory)
#   $2  IDINVENTORYTEMP — destination for ID|  lines (users/groups)
#   $3  DBINVENTORYTEMP — destination for DB|  lines (Oracle SIDs)
#   $4  PACKAGETEMP     — destination for PKG| lines (RPM packages)
#
# pssh --inline-stdout prepends each output line with:
#   "hostname: <actual output>"
# Our remote script already prefixes lines with INV|, ID|, DB|, PKG| so
# the full line seen here looks like:
#   "hostname: INV|hostname field1 field2 ..."
# We strip everything up to and including the first ": " then route by tag.
#
# Lines that are pssh status/metadata (SUCCESS, FAILURE, [stderr] etc.)
# are logged to an error file and skipped.
# =============================================================================

# --- Argument validation -----------------------------------------------------
if [[ $# -ne 4 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_filter_scan.sh requires 4 arguments" >&2
    echo "  Usage: rhel_filter_scan.sh inv_tmp id_tmp db_tmp pkg_tmp" >&2
    exit 1
fi

INV_OUT="$1"
ID_OUT="$2"
DB_OUT="$3"
PKG_OUT="$4"

# Error log sits alongside the inventory temp files
ERR_LOG="$(dirname "$INV_OUT")/scan_filter_errors.$(date +%Y%m%d_%H%M%S).log"

# Counters for summary logging
count_inv=0
count_id=0
count_db=0
count_pkg=0
count_err=0
count_skip=0

# =============================================================================
# Main filter loop
# =============================================================================

while IFS= read -r raw; do

    # Skip completely blank lines
    (( ${#raw} == 0 )) && continue

    # --- Strip pssh inline-stdout host prefix --------------------------------
    # Format: "hostname: actual_content"
    # We strip up to and including the first ": "
    # If there is no ": " the line is pssh metadata — handle below.
    if [[ "$raw" == *": "* ]]; then
        line="${raw#*: }"
    else
        line="$raw"
    fi

    # --- Skip blank content after prefix strip --------------------------------
    (( ${#line} == 0 )) && continue

    # --- Detect and log pssh status lines ------------------------------------
    # pssh emits "hostname: [1] ...", "SUCCESS", "FAILURE", "[stderr]" etc.
    # The remote script never emits lines starting with these tokens.
    case "$line" in
        SUCCESS*|FAILURE*|\[*|\[stderr\]*)
            if [[ "$line" == FAILURE* ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') PSSH_FAILURE: $raw" >> "$ERR_LOG"
                (( count_err++ ))

                # Extract hostname from pssh FAILURE line.
                # Format: "FAILURE <hostname> ..."  or from raw "hostname: FAILURE ..."
                # Try raw first (most reliable — pssh prefixes the hostname)
                _fail_host=""
                if [[ "$raw" == *": "* ]]; then
                    _fail_host="${raw%%: *}"
                    _fail_host="${_fail_host##* }"   # strip any leading number
                fi
                # Fallback: parse from "FAILURE <hostname>" in the stripped line
                if [[ -z "$_fail_host" ]]; then
                    _fail_host=$(echo "$line" | awk '{print $2}')
                fi
                # Strip FQDN suffix if present — keep short hostname
                _fail_host="${_fail_host%%.*}"

                # Write a stub INV record so the host appears in the .dat
                # and can be counted as an SSH failure in reports.
                # Format matches rhel_remote_scan.sh INV output (28 space-delimited fields):
                # Host Type OS Kernel Arch Mem Skt Cores Thds CPUType CPUSpd Vendor Model
                # Serial Syslog Uptime VMVer VMRun LastBkp IP Loc CIDev vCenter BldType
                # DBType AppCode Env BuildDate
                if [[ -n "$_fail_host" ]]; then
                    echo "$_fail_host SSHFAIL SSHFAIL n/a n/a 0 0 0 0 n/a 0 n/a n/a n/a SSHFAIL 0 n/a N UNKNOWN n/a n/a n/a n/a n/a n/a n/a n/a n/a" >> "$INV_OUT"
                    (( count_inv++ ))
                fi
            else
                (( count_skip++ ))
            fi
            continue
            ;;
    esac

    # Also skip lines that look like pssh's "[1] ..." numbering
    if [[ "$line" =~ ^\[[0-9]+\] ]]; then
        (( count_skip++ ))
        continue
    fi

    # --- Route by tag --------------------------------------------------------
    # NOTE: We cannot use "TAG|*" in a bash case statement because | is the
    # case OR operator. Instead we extract the tag prefix explicitly and
    # route with a case on the tag alone.
    tag="${line%%|*}"       # everything before the first |
    data="${line#*|}"       # everything after the first |

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
            # Skip lines that start with "Inventory" — special case from
            # original filter (a few systems emit this as their first line)
            [[ "$data" == Inventory* ]] && continue
            echo "$data" >> "$PKG_OUT"
            (( count_pkg++ ))
            ;;
        *)
            # Unrecognised tag or untagged line — log for diagnostics
            echo "$(date '+%Y-%m-%d %H:%M:%S') UNTAGGED: $raw" >> "$ERR_LOG"
            (( count_err++ ))
            ;;
    esac

done

# =============================================================================
# Summary to stdout (captured by rhel_inv_collect.sh log)
# =============================================================================

printf '%s  [INFO]    Filter summary — INV: %d  ID: %d  DB: %d  PKG: %d  skipped: %d  errors: %d\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$count_inv" "$count_id" "$count_db" "$count_pkg" \
    "$count_skip" "$count_err"

if [[ -f "$ERR_LOG" && -s "$ERR_LOG" ]]; then
    printf '%s  [WARN]    %d untagged/failure lines written to: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$count_err" "$ERR_LOG"
else
    # Remove empty error log
    rm -f "$ERR_LOG"
fi

exit 0
