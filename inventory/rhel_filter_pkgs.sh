#!/bin/bash
# =============================================================================
# rhel_filter_pkgs.sh — Package-only output filter for rhel_pkginventory.sh
# =============================================================================
# Replaces: filter_pkginventory_scan.sh
#
# Used exclusively by rhel_pkginventory.sh on the secondary jumpbox.
# Reads the combined pssh --inline-stdout stream from stdin.
# Passes only PKG| tagged lines through to stdout (strips all other tags,
# pssh status lines, and blank lines).
#
# Unlike rhel_filter_scan.sh (which splits into four files), this filter
# has a single output stream — stdout — appended directly to PACKAGETEMP
# by the calling script.
#
# Error accounting:
#   FAILURE lines are logged to package_inventory_errors.log in DATA_DIR.
#   All other non-PKG lines are silently discarded.
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found" >&2
    exit 1
fi
. "$CONF"

ERR_LOG="${DATA_DIR}/package_inventory_errors.$(date +%Y%m%d).log"

count_pkg=0
count_fail=0
count_skip=0

while IFS= read -r raw; do

    # Skip blank lines
    (( ${#raw} == 0 )) && continue

    # Strip pssh inline-stdout host prefix ("hostname: content")
    if [[ "$raw" == *": "* ]]; then
        line="${raw#*: }"
    else
        line="$raw"
    fi

    (( ${#line} == 0 )) && continue

    # Detect and log pssh FAILURE lines
    case "$line" in
        FAILURE*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') $raw" >> "$ERR_LOG"
            (( count_fail++ ))
            continue
            ;;
        SUCCESS*|\[*|\[stderr\]*)
            (( count_skip++ ))
            continue
            ;;
    esac

    # Skip pssh numbering lines
    if [[ "$line" =~ ^\[[0-9]+\] ]]; then
        (( count_skip++ ))
        continue
    fi

    # Only pass PKG| lines through
    case "$line" in
        PKG|*)
            # Strip the tag prefix
            data="${line#PKG|}"

            # Skip the "Inventory..." special case lines
            [[ "$data" == Inventory* ]] && continue

            echo "$data"
            (( count_pkg++ ))
            ;;
        INV|*|ID|*|DB|*)
            # Other tag types from rhel_remote_scan.sh — silently discard
            (( count_skip++ ))
            ;;
        *)
            # Anything else unrecognised — skip silently
            (( count_skip++ ))
            ;;
    esac

done

# Summary to stderr so it appears in the calling script's log
printf '%s  [INFO]    Package filter: %d records passed  %d failures  %d lines skipped\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$count_pkg" "$count_fail" "$count_skip" >&2

if [[ -f "$ERR_LOG" && -s "$ERR_LOG" ]]; then
    printf '%s  [WARN]    %d SSH failures logged to: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$count_fail" "$ERR_LOG" >&2
else
    rm -f "$ERR_LOG"
fi

exit 0
