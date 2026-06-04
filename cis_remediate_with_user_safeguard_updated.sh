#!/bin/bash

########################################
# CIS Remediation Script
# Rules: 6.1.11, 6.1.12, 6.2.11
# Two-step process: run scan script first to produce CSV, then run this.
########################################

set -uo pipefail

########################################
# Defaults
########################################

DEFAULT_OWNER="root"
DEFAULT_GROUP="root"
LOG_FILE=""
DRY_RUN=false
CURRENT_HOSTNAME=$(hostname)

# Paths excluded from remediation.
# Exact paths: exact match only.
# Patterns with "*": glob match.
# Patterns ending "/*": also match the base directory itself.
EXCLUDE_PATHS=(
    "/boot/*"
    "/root/*"
)

########################################
# Logging
# Thread-safe: flock on FD 9, which is opened to LOG_FILE in main.
########################################

log_message() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%m-%d-%Y %H:%M:%S')
    {
        flock -x 9
        printf '[%s] %-11s %s\n' "$timestamp" "[$level]" "$message" >&9
    } 2>/dev/null
}

########################################
# Path helpers
########################################

normalize_path() {
    local p="$1"
    p=$(echo "$p" | xargs)
    while [[ "$p" != "/" && "$p" == */ ]]; do
        p="${p%/}"
    done
    echo "$p"
}

is_excluded_path() {
    local target
    target=$(normalize_path "$1")

    local ex base
    for ex in "${EXCLUDE_PATHS[@]}"; do
        ex=$(normalize_path "$ex")

        if [[ "$ex" == *"*"* ]]; then
            [[ "$target" == $ex ]] && return 0
            if [[ "$ex" == *"/*" ]]; then
                base=$(normalize_path "${ex%/*}")
                if [[ "$base" == *"*"* ]]; then
                    [[ "$target" == $base ]] && return 0
                else
                    [[ "$target" == "$base" ]] && return 0
                fi
            fi
            continue
        fi

        [[ "$target" == "$ex" ]] && return 0
    done
    return 1
}

is_home_directory_path() {
    local target
    target=$(normalize_path "$1")
    [[ -d "$target" && "$target" =~ ^/home/[^/]+$ ]]
}

########################################
# Permission helpers
########################################

# Return the last 3 octal digits of a file's current mode.
get_mode_3() {
    local m
    m=$(stat -c '%a' "$1" 2>/dev/null || echo "")
    m="${m//[^0-9]/}"
    echo "${m: -3}"
}

# Validate and return the last 3 digits of a CSV permission string.
# Returns 1 if not a valid 3- or 4-digit octal value.
csv_mode_3() {
    local m="$1"
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
    echo "${m: -3}"
}

# Normalize a mode string for comparison: strip leading zeros.
normalize_mode() {
    local m
    m=$(echo "$1" | sed 's/^0*//')
    [[ -z "$m" ]] && m="0"
    echo "$m"
}

# True if mode has no world-write bit (other & 2 == 0).
is_non_world_writable_mode() {
    local m
    m=$(csv_mode_3 "$1") || return 1
    (( ( ${m:2:1} & 2 ) == 0 ))
}

# True if mode satisfies CIS 6.2.11 dot-file rules:
#   user-execute=0, group-write=0, group-execute=0, other-write=0, other-execute=0
is_dotfile_compliant_mode() {
    local m
    m=$(csv_mode_3 "$1") || return 1
    (( ( ${m:0:1} & 1 ) == 0 && ( ${m:1:1} & 3 ) == 0 && ( ${m:2:1} & 3 ) == 0 ))
}

# Compute mode that removes world-write from a file's current permissions.
compute_remove_world_write() {
    local m
    m=$(get_mode_3 "$1")
    [[ -z "$m" ]] && return 1
    echo "${m:0:2}$(( ${m:2:1} & 5 ))"
}

# Compute mode that adds sticky bit to a file's current permissions.
compute_add_sticky_bit() {
    local raw special base
    raw=$(stat -c '%a' "$1" 2>/dev/null || echo "")
    [[ "$raw" =~ ^[0-7]{3,4}$ ]] || return 1
    if (( ${#raw} == 4 )); then
        special=${raw:0:1}
        base=${raw:1:3}
    else
        special=0
        base="$raw"
    fi
    echo "$(( special | 1 ))${base}"
}

# Compute mode that removes dot-file-violating bits from a file's current permissions.
# Clears: user-execute, group-write, group-execute, other-write, other-execute.
compute_remove_dotfile_access() {
    local m
    m=$(get_mode_3 "$1")
    [[ -z "$m" ]] && return 1
    echo "$(( ${m:0:1} & 6 ))$(( ${m:1:1} & 4 ))$(( ${m:2:1} & 4 ))"
}

# Return a safe home-directory mode: accepts 700 or 750 from CSV, defaults to 700.
get_home_directory_mode() {
    local csv_perms="$1"
    local m
    if m=$(csv_mode_3 "$csv_perms" 2>/dev/null); then
        [[ "$m" == "700" || "$m" == "750" ]] && echo "$m" && return
    fi
    echo "700"
}

########################################
# Identity helpers
########################################

is_valid_owner() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && return 0
    getent passwd "$v" >/dev/null 2>&1
}

is_valid_group() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && return 0
    getent group "$v" >/dev/null 2>&1
}

########################################
# Remediation functions
# Each returns a human-readable change summary on stdout.
# Returns 1 on chmod/chown failure.
########################################

# CIS 6.1.11 — World-writable files/directories
# For directories with no CSV perms: add sticky bit.
# For files with no CSV perms: remove other-write.
# CSV perms: applied only if non-world-writable.
remediate_6_1_11() {
    local path="$1" target_perms="$4"
    local old_perms
    old_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "N/A")

    if [[ "$DRY_RUN" == true ]]; then
        local display_perms="${target_perms:-$(if [[ -d "$path" ]]; then echo "(sticky bit)"; else echo "(o-w)"; fi)}"
        echo "Permissions: $old_perms -> $display_perms [DRY RUN]"
        return 0
    fi

    if [[ -n "$target_perms" ]]; then
        chmod "$target_perms" "$path" 2>/dev/null || return 1
    else
        if [[ -d "$path" ]]; then
            chmod +t "$path" 2>/dev/null || return 1
        else
            chmod o-w "$path" 2>/dev/null || return 1
        fi
    fi

    echo "Permissions: $old_perms -> $(stat -c '%a' "$path" 2>/dev/null || echo "N/A")"
}

# CIS 6.1.12 — Unowned/ungrouped files (ownership only; no permission changes except /home override)
remediate_6_1_12() {
    local path="$1" target_owner="$2" target_group="$3" target_perms="$4"
    local old_owner old_perms changes=""
    old_owner=$(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")
    old_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "N/A")

    local current_owner current_group
    current_owner=$(stat -c '%U' "$path" 2>/dev/null || echo "")
    current_group=$(stat -c '%G' "$path" 2>/dev/null || echo "")

    if [[ "$DRY_RUN" == true ]]; then
        local display_owner="${target_owner:-$current_owner}:${target_group:-$current_group}"
        changes="Owner: $old_owner -> $display_owner [DRY RUN]"
        if [[ -n "$target_perms" ]]; then
            changes="$changes, Permissions: $old_perms -> $target_perms [DRY RUN]"
        fi
        echo "$changes"
        return 0
    fi

    if [[ -n "$target_owner" && -n "$target_group" ]]; then
        if [[ "$target_owner" != "$current_owner" || "$target_group" != "$current_group" ]]; then
            chown "$target_owner:$target_group" "$path" 2>/dev/null || return 1
        fi
    elif [[ -n "$target_owner" ]]; then
        if [[ "$target_owner" != "$current_owner" ]]; then
            chown "$target_owner" "$path" 2>/dev/null || return 1
        fi
    elif [[ -n "$target_group" ]]; then
        if [[ "$target_group" != "$current_group" ]]; then
            chgrp "$target_group" "$path" 2>/dev/null || return 1
        fi
    fi
    changes="Owner: $old_owner -> $(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")"

    # Only applied when the /home/userID override fires.
    if [[ -n "$target_perms" ]]; then
        chmod "$target_perms" "$path" 2>/dev/null || return 1
        changes="$changes, Permissions: $old_perms -> $(stat -c '%a' "$path" 2>/dev/null || echo "N/A")"
    fi

    echo "$changes"
}

# CIS 6.2.11 — Dot-file access
remediate_6_2_11() {
    local path="$1" target_owner="$2" target_group="$3" target_perms="$4"
    local old_owner old_perms changes=""
    old_owner=$(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")
    old_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "N/A")

    if [[ "$DRY_RUN" == true ]]; then
        local current_owner current_group
        current_owner=$(stat -c '%U' "$path" 2>/dev/null || echo "")
        current_group=$(stat -c '%G' "$path" 2>/dev/null || echo "")
        changes="Permissions: $old_perms -> ${target_perms:-"(u-x,go-wx)"} [DRY RUN]"
        if [[ -n "$target_owner" || -n "$target_group" ]]; then
            local display_owner="${target_owner:-$current_owner}:${target_group:-$current_group}"
            changes="$changes, Owner: $old_owner -> $display_owner [DRY RUN]"
        fi
        echo "$changes"
        return 0
    fi

    if [[ -n "$target_perms" ]]; then
        chmod "$target_perms" "$path" 2>/dev/null || return 1
    else
        chmod u-x,go-wx "$path" 2>/dev/null || return 1
    fi
    changes="Permissions: $old_perms -> $(stat -c '%a' "$path" 2>/dev/null || echo "N/A")"

    if [[ -n "$target_owner" && -n "$target_group" ]]; then
        chown "$target_owner:$target_group" "$path" 2>/dev/null || return 1
        changes="$changes, Owner: $old_owner -> $(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")"
    elif [[ -n "$target_owner" ]]; then
        chown "$target_owner" "$path" 2>/dev/null || return 1
        changes="$changes, Owner: $old_owner -> $(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")"
    elif [[ -n "$target_group" ]]; then
        chgrp "$target_group" "$path" 2>/dev/null || return 1
        changes="$changes, Owner: $old_owner -> $(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")"
    fi

    echo "$changes"
}

########################################
# CSV line processor
# Prints one status line to stdout: SUCCESS|... / SKIPPED|... / FAILED|...
# All log output goes to FD 9 via log_message.
########################################

process_csv_line() {
    local raw_line="$1"
    local line_num="$2"

    # Parse fields
    local hostname os_version cis_rule description path owner group perms recommendation
    IFS=',' read -r hostname os_version cis_rule description path owner group perms recommendation <<< "$raw_line"

    # Trim whitespace from fields we use
    hostname=$(echo "$hostname" | xargs)
    cis_rule=$(echo "$cis_rule" | xargs)
    path=$(echo "$path" | xargs)
    owner=$(echo "$owner" | xargs)
    group=$(echo "$group" | xargs)
    perms=$(echo "$perms" | xargs)

    # Host guard (pre-filter should have already handled this, but belt-and-suspenders)
    if [[ "$hostname" != "$CURRENT_HOSTNAME" ]]; then
        echo "IGNORED|hostname mismatch"
        return 0
    fi

    # Path must exist
    if [[ ! -e "$path" ]]; then
        log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Path does not exist: $path"
        echo "SKIPPED|path does not exist"
        return 0
    fi

    # Excluded path check
    if is_excluded_path "$path"; then
        local state
        state="Owner: $(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A"), Perms: $(stat -c '%a' "$path" 2>/dev/null || echo "N/A")"
        log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Excluded path: $path | $state"
        echo "SKIPPED|excluded path"
        return 0
    fi

    # Read current state once
    local current_owner current_group current_perms
    current_owner=$(stat -c '%U' "$path" 2>/dev/null || echo "UNKNOWN")
    current_group=$(stat -c '%G' "$path" 2>/dev/null || echo "UNKNOWN")
    current_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "0")

    # Compute target values per CIS rule
    local target_owner="" target_group="" target_perms=""

    case "$cis_rule" in

        "6.1.11")
            # No ownership changes for this rule.
            target_owner=""
            target_group=""

            if [[ -n "$perms" ]] && is_non_world_writable_mode "$perms"; then
                target_perms="$perms"
            else
                if [[ -d "$path" ]]; then
                    target_perms=$(compute_add_sticky_bit "$path") || {
                        log_message "FAILED" "Line $line_num: CIS 6.1.11 - Could not compute sticky-bit mode for $path"
                        echo "FAILED|mode computation error"
                        return 0
                    }
                else
                    target_perms=$(compute_remove_world_write "$path") || {
                        log_message "FAILED" "Line $line_num: CIS 6.1.11 - Could not compute world-write removal mode for $path"
                        echo "FAILED|mode computation error"
                        return 0
                    }
                fi
            fi
            ;;

        "6.1.12")
            # Permissions are not touched by this rule except via the /home override below.
            target_perms=""

            # Owner: CSV value wins if valid; UNKNOWN or invalid falls back to root; blank defers to current (or root if current is invalid).
            if [[ -n "$owner" ]]; then
                if [[ "${owner^^}" == "UNKNOWN" ]] || ! is_valid_owner "$owner"; then
                    target_owner="$DEFAULT_OWNER"
                else
                    target_owner="$owner"
                fi
            else
                if [[ "$current_owner" == "UNKNOWN" ]] || ! is_valid_owner "$current_owner"; then
                    target_owner="$DEFAULT_OWNER"
                else
                    target_owner=""   # no change needed
                fi
            fi

            # Group: same logic.
            if [[ -n "$group" ]]; then
                if [[ "${group^^}" == "UNKNOWN" ]] || ! is_valid_group "$group"; then
                    target_group="$DEFAULT_GROUP"
                else
                    target_group="$group"
                fi
            else
                if [[ "$current_group" == "UNKNOWN" ]] || ! is_valid_group "$current_group"; then
                    target_group="$DEFAULT_GROUP"
                else
                    target_group=""   # no change needed
                fi
            fi
            ;;

        "6.2.11")
            # Owner: invalid CSV value → skip the whole row (per spec).
            if [[ -n "$owner" ]]; then
                if [[ "${owner^^}" == "UNKNOWN" ]] || ! is_valid_owner "$owner"; then
                    log_message "FAILED" "Line $line_num: CIS 6.2.11 - Invalid owner in CSV: '$owner' for $path"
                    echo "FAILED|invalid owner"
                    return 0
                fi
                target_owner="$owner"
            fi

            # Group: same.
            if [[ -n "$group" ]]; then
                if [[ "${group^^}" == "UNKNOWN" ]] || ! is_valid_group "$group"; then
                    log_message "FAILED" "Line $line_num: CIS 6.2.11 - Invalid group in CSV: '$group' for $path"
                    echo "FAILED|invalid group"
                    return 0
                fi
                target_group="$group"
            fi

            # Permissions: CSV value used only if it satisfies both dotfile and non-world-writable rules.
            # This ensures we fix the dotfile VUF without creating a world-writable VUF.
            if [[ -n "$perms" ]] && is_dotfile_compliant_mode "$perms" && is_non_world_writable_mode "$perms"; then
                target_perms="$perms"
            else
                target_perms=$(compute_remove_dotfile_access "$path") || {
                    log_message "FAILED" "Line $line_num: CIS 6.2.11 - Could not compute dot-file access mode for $path"
                    echo "FAILED|mode computation error"
                    return 0
                }
            fi
            ;;

        *)
            log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Unknown rule, skipping: $path"
            echo "SKIPPED|unknown CIS rule"
            return 0
            ;;
    esac

    # /home/userID override: must be 700 or 750, regardless of rule or CSV value.
    if is_home_directory_path "$path"; then
        target_perms=$(get_home_directory_mode "$perms")
    fi

    # Determine if already in desired state.
    local owner_match=true group_match=true perms_match=true

    if [[ -n "$target_owner" && "$current_owner" != "$target_owner" ]]; then
        owner_match=false
    fi
    if [[ -n "$target_group" && "$current_group" != "$target_group" ]]; then
        group_match=false
    fi
    if [[ -n "$target_perms" ]]; then
        local norm_current norm_target
        norm_current=$(normalize_mode "$current_perms")
        norm_target=$(normalize_mode "$target_perms")
        [[ "$norm_current" != "$norm_target" ]] && perms_match=false
    fi

    if [[ "$owner_match" == true && "$group_match" == true && "$perms_match" == true ]]; then
        local skip_state="Owner: ${current_owner}:${current_group}, Perms: ${current_perms}"
        log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Already remediated: $path | $skip_state"
        echo "SKIPPED|already remediated"
        return 0
    fi

    # Run remediation
    local changes
    local log_level="CHANGED"
    [[ "$DRY_RUN" == true ]] && log_level="DRYRUN"
    case "$cis_rule" in
        "6.1.11")
            if changes=$(remediate_6_1_11 "$path" "" "" "$target_perms"); then
                log_message "$log_level" "Line $line_num: CIS 6.1.11 - $path | $changes"
                echo "SUCCESS|$changes"
            else
                log_message "FAILED" "Line $line_num: CIS 6.1.11 - Remediation error: $path"
                echo "FAILED|remediation error"
            fi
            ;;
        "6.1.12")
            if changes=$(remediate_6_1_12 "$path" "$target_owner" "$target_group" "$target_perms"); then
                log_message "$log_level" "Line $line_num: CIS 6.1.12 - $path | $changes"
                echo "SUCCESS|$changes"
            else
                log_message "FAILED" "Line $line_num: CIS 6.1.12 - Remediation error: $path"
                echo "FAILED|remediation error"
            fi
            ;;
        "6.2.11")
            if changes=$(remediate_6_2_11 "$path" "$target_owner" "$target_group" "$target_perms"); then
                log_message "$log_level" "Line $line_num: CIS 6.2.11 - $path | $changes"
                echo "SUCCESS|$changes"
            else
                log_message "FAILED" "Line $line_num: CIS 6.2.11 - Remediation error: $path"
                echo "FAILED|remediation error"
            fi
            ;;
    esac
}

########################################
# Main
########################################

usage() {
    cat <<EOF
Usage: $0 -i <input_csv> [-o <output_log>] [-j <jobs>] [-n]

Options:
  -i    Input CSV file (required)
        Format: Hostname,OS Version,CIS Rule,Description,Path,Owner,Group,Permissions,Recommendation
  -o    Output log file (default: /var/tmp/chg/lrp/custom_cis_remediation_<timestamp>.log)
  -j    Number of parallel jobs (default: nproc; use 1 for single-threaded)
  -n    Dry run: show what would change without making any changes
  -h    Show this help message

Examples:
  $0 -i remediation_input.csv
  $0 -i remediation_input.csv -o custom_log.log
  $0 -i remediation_input.csv -j 8
  $0 -i remediation_input.csv -n

Default Values:
  CIS 6.1.12 Owner: $DEFAULT_OWNER
  CIS 6.1.12 Group: $DEFAULT_GROUP

Note: Requires MIS and Vuln Team approvals before running step 2 remediation.
EOF
    exit 1
}

INPUT_CSV=""
JOBS=""

while getopts "i:o:j:nh" opt; do
    case $opt in
        i) INPUT_CSV="$OPTARG" ;;
        o) LOG_FILE="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "$INPUT_CSV" ]] && { echo "Error: Input CSV file is required"; usage; }
[[ ! -f "$INPUT_CSV" ]] && { echo "Error: Input CSV file not found: $INPUT_CSV"; exit 1; }

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/var/tmp/chg/lrp/custom_cis_remediation_$(date +%m%d%Y_%H%M%S).log"
fi

if [[ -z "$JOBS" ]]; then
    JOBS=$(nproc 2>/dev/null || echo 4)
fi

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || (( JOBS < 1 )); then
    echo "Error: Invalid -j value: $JOBS. Must be a positive integer."
    exit 1
fi

# Create log directory and open FD 9 for flock-based thread-safe logging.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec 9>>"$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null || true

if [[ $EUID -ne 0 ]]; then
    log_message "WARN" "Running as non-root; ownership changes may fail."
fi

log_message "INFO" "======================================"
log_message "INFO" "CIS Remediation Script Started"
log_message "INFO" "Input CSV: $INPUT_CSV"
log_message "INFO" "Log File: $LOG_FILE"
log_message "INFO" "Hostname: $CURRENT_HOSTNAME"
log_message "INFO" "Job Threads: $JOBS"
if [[ "$DRY_RUN" == true ]]; then
    log_message "INFO" "Mode: DRY RUN - no changes will be made"
fi
log_message "INFO" "======================================"

# Export DRY_RUN so parallel subshells inherit it.
export DRY_RUN

# Pre-filter CSV to rows for this host only.
# Each output line is prefixed with its original CSV line number: "NR|raw_line"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FILTERED="$TMPDIR/filtered.txt"
# NR==1 keeps the header (line 1); $1==h keeps matching hostname rows.
awk -F, -v h="$CURRENT_HOSTNAME" 'NR==1 || $1==h {print NR "|" $0}' "$INPUT_CSV" > "$FILTERED"

# Body without header (line 1 of filtered file = CSV header)
FILTERED_BODY="$TMPDIR/filtered_body.txt"
tail -n +2 "$FILTERED" > "$FILTERED_BODY" || true

total_lines=0
success_count=0
skip_count=0
fail_count=0

if (( JOBS <= 1 )); then
    # Single-threaded
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        line_num="${rec%%|*}"
        line="${rec#*|}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]] && continue

        (( ++total_lines ))
        result=$(process_csv_line "$line" "$line_num")
        status=$(echo "$result" | head -n1 | cut -d'|' -f1)

        case "$status" in
            SUCCESS) (( ++success_count )) ;;
            SKIPPED) (( ++skip_count )) ;;
            FAILED)  (( ++fail_count )) ;;
        esac
    done < "$FILTERED_BODY"

else
    # Parallel: split body into JOBS chunks, process each in a background subshell.
    if [[ -s "$FILTERED_BODY" ]]; then
        split -n l/"$JOBS" -d -- "$FILTERED_BODY" "$TMPDIR/chunk_"

        pids=()
        for f in "$TMPDIR"/chunk_*; do
            [[ ! -s "$f" ]] && continue
            {
                while IFS= read -r rec; do
                    [[ -z "$rec" ]] && continue
                    line_num="${rec%%|*}"
                    line="${rec#*|}"
                    [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]] && continue
                    process_csv_line "$line" "$line_num"
                done < "$f"
            } > "${f}.results" 2>/dev/null &
            pids+=($!)
        done

        for pid in "${pids[@]}"; do wait "$pid"; done

        RESULTS_ALL="$TMPDIR/results_all.txt"
        cat "$TMPDIR"/chunk_*.results > "$RESULTS_ALL" 2>/dev/null || true

        total_lines=$(wc -l < "$FILTERED_BODY" 2>/dev/null || echo 0)
        success_count=$(grep -c '^SUCCESS|' "$RESULTS_ALL" 2>/dev/null || true)
        skip_count=$(grep -c '^SKIPPED|' "$RESULTS_ALL" 2>/dev/null || true)
        fail_count=$(grep -c '^FAILED|' "$RESULTS_ALL" 2>/dev/null || true)
    else
        total_lines=0
        success_count=0
        skip_count=0
        fail_count=0
    fi
fi

log_message "INFO" "======================================"
log_message "INFO" "Remediation Summary"
log_message "INFO" "Total lines processed: $total_lines"
log_message "INFO" "Successful remediations: $success_count"
log_message "INFO" "Skipped: $skip_count"
log_message "INFO" "Failed: $fail_count"
log_message "INFO" "======================================"

echo ""
echo "Log file: $LOG_FILE"
echo ""

(( fail_count > 0 )) && exit 1 || exit 0
