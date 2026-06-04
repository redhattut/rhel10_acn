#!/bin/bash

########################################
# Process CSV files with CIS compliance rules and applies remediation
# Rules supported: 6.1.11, 6.1.12, 6.2.11
########################################

set -uo pipefail

# Default values for remediation
DEFAULT_OWNER_6_1_12="root"        # CIS 6.1.12 - unowned files
DEFAULT_GROUP_6_1_12="root"        # CIS 6.1.12 - ungrouped files
# Log file
LOG_FILE=""
CURRENT_HOSTNAME=$(hostname)


# Exclude list from applying the remediation
# Rules:
# - Exact absolute path (file or dir): "/home" (matches only /home)
# - Glob pattern with "*" anywhere: "*/kubelet/pods/*", "/var/*/private/*"
# - Patterns ending in "/*" also match the base directory itself
#   (example: "/root/*" matches "/root" and all descendants)
EXCLUDE_PATHS=(
    "/boot/*"
    "/root/*"
)

########################################
# Functions
########################################

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%m-%d-%Y %H:%M:%S')
    local level_tag="[$level]"
    printf '[%s] %-11s %s\n' "$timestamp" "$level_tag" "$message" | tee -a "$LOG_FILE" >&2
}

# Normalize a path (remove trailing slashes except for /)
normalize_path() {
    local p="$1"
    # trim whitespace
    p="$(echo "$p" | xargs)"
    # remove trailing slashes
    while [[ "$p" != "/" && "$p" == */ ]]; do
        p="${p%/}"
    done
    echo "$p"
}

# Return true if $1 is excluded by EXCLUDE_PATHS
# Matching behavior:
# - Plain path: exact match only
# - Pattern containing "*": glob match
# - Pattern ending with "/*": also matches the base directory itself
is_excluded_path() {
    local target
    target="$(normalize_path "$1")"

    local ex base
    for ex in "${EXCLUDE_PATHS[@]}"; do
        ex="$(normalize_path "$ex")"

        # Any wildcard pattern
        if [[ "$ex" == *"*"* ]]; then
            if [[ "$target" == $ex ]]; then
                return 0
            fi

            # Preserve legacy recursive behavior for patterns like /root/*
            if [[ "$ex" == *"/*" ]]; then
                base="$(normalize_path "${ex%/*}")"
                if [[ "$base" == *"*"* ]]; then
                    if [[ "$target" == $base ]]; then
                        return 0
                    fi
                elif [[ "$target" == "$base" ]]; then
                    return 0
                fi
            fi
            continue
        fi

        # Exact path
        if [[ "$target" == "$ex" ]]; then
            return 0
        fi
    done

    return 1
}

# State string for logging
get_state() {
    local p="$1"
    local perms ownergrp
    perms=$(stat -c '%a' "$p" 2>/dev/null || echo "N/A")
    ownergrp=$(stat -c '%U:%G' "$p" 2>/dev/null || echo "N/A")
    echo "Owner: ${ownergrp}, Perms: ${perms}"
}

# Return last 3 permission digits
get_mode_3() {
    local p
    p=$(stat -c '%a' "$1" 2>/dev/null || echo "")
    p="${p//[^0-9]/}"
    # take the last 3 digits
    echo "${p: -3}"
}

remove_world_write_mode() {
    local m o
    m="$(get_mode_3 "$1")"
    [[ -z "$m" ]] && return 1
    o=$(( ${m:2:1} & 5 ))
    echo "${m:0:2}${o}"
}

add_sticky_bit_mode() {
    local p="$1"
    local m special base
    m=$(stat -c '%a' "$p" 2>/dev/null || echo "")
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1

    if [[ ${#m} -eq 4 ]]; then
        special=${m:0:1}
        base=${m:1:3}
    else
        special=0
        base="$m"
    fi

    echo "$(( special | 1 ))${base}"
}

remove_dotfile_access_mode() {
    local m u g o
    m="$(get_mode_3 "$1")"
    [[ -z "$m" ]] && return 1
    u=$(( ${m:0:1} & 6 ))
    g=$(( ${m:1:1} & 4 ))
    o=$(( ${m:2:1} & 4 ))
    echo "${u}${g}${o}"
}

csv_mode_3() {
    local m="$1"
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
    echo "${m: -3}"
}

is_non_world_writable_mode() {
    local m
    m="$(csv_mode_3 "$1")" || return 1
    (( ( ${m:2:1} & 2 ) == 0 ))
}

is_dotfile_compliant_mode() {
    local m
    m="$(csv_mode_3 "$1")" || return 1
    (( ( ${m:0:1} & 1 ) == 0 && ( ${m:1:1} & 3 ) == 0 && ( ${m:2:1} & 3 ) == 0 ))
}

is_home_directory_path() {
    local target
    target="$(normalize_path "$1")"
    [[ -d "$target" && "$target" =~ ^/home/[^/]+$ ]]
}

get_home_directory_mode() {
    local csv_perms="$1"
    local m

    if m="$(csv_mode_3 "$csv_perms")"; then
        if [[ "$m" == "700" || "$m" == "750" ]]; then
            echo "$m"
            return 0
        fi
    fi

    echo "700"
}

is_valid_owner() {
    local owner="$1"
    [[ "$owner" =~ ^[0-9]+$ ]] && return 0
    getent passwd "$owner" >/dev/null 2>&1
}

is_valid_group() {
    local group="$1"
    [[ "$group" =~ ^[0-9]+$ ]] && return 0
    getent group "$group" >/dev/null 2>&1
}

is_valid_csv_owner_name() {
    local owner="$1"
    getent passwd "$owner" >/dev/null 2>&1
}

is_valid_csv_group_name() {
    local group="$1"
    getent group "$group" >/dev/null 2>&1
}

# Function to remediate CIS 6.1.11 - World writable files
remediate_6_1_11() {
    local path="$1"
    local perms="$4"

    local changes=""
    local old_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "N/A")

    if [[ -n "$perms" ]]; then
        chmod "$perms" "$path" 2>/dev/null || return 1
    else
        if [[ -d "$path" ]]; then
            chmod +t "$path" 2>/dev/null || return 1
        else
            chmod o-w "$path" 2>/dev/null || return 1
        fi
    fi

    changes="Permissions: $old_perms -> $(stat -c '%a' "$path" 2>/dev/null || echo "N/A")"

    echo "$changes"
    return 0
}

# Function to remediate CIS 6.1.12 - Unowned/Ungrouped files
remediate_6_1_12() {
    local path="$1"
    local owner="$2"
    local group="$3"
    local perms="$4"

    local old_owner old_perms
    old_owner=$(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")
    old_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "N/A")

    local current_owner current_group
    current_owner=$(stat -c '%U' "$path" 2>/dev/null)
    current_group=$(stat -c '%G' "$path" 2>/dev/null)

    if [[ -n "$owner" ]] && [[ -n "$group" ]]; then
        if [[ "$owner" != "$current_owner" || "$group" != "$current_group" ]]; then
            chown "$owner:$group" "$path" 2>/dev/null || return 1
        fi
    elif [[ -n "$owner" ]]; then
        if [[ "$owner" != "$current_owner" ]]; then
            chown "$owner" "$path" 2>/dev/null || return 1
        fi
    elif [[ -n "$group" ]]; then
        if [[ "$group" != "$current_group" ]]; then
            chgrp "$group" "$path" 2>/dev/null || return 1
        fi
    fi

    local changes="Owner: $old_owner -> $(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")"

    # 6.1.12 normally ignores permissions; this is only for the /home/userID override.
    if [[ -n "$perms" ]]; then
        chmod "$perms" "$path" 2>/dev/null || return 1
        changes="$changes, Permissions: $old_perms -> $(stat -c '%a' "$path" 2>/dev/null || echo "N/A")"
    fi

    echo "$changes"
    return 0
}

# Function to remediate CIS 6.2.11 - Dot files access
remediate_6_2_11() {
    local path="$1"
    local owner="$2"
    local group="$3"
    local perms="$4"

    local old_owner=$(stat -c '%U:%G' "$path" 2>/dev/null || echo "N/A")
    local old_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "N/A")
    local changes=""

    if [[ -n "$perms" ]]; then
        chmod "$perms" "$path" 2>/dev/null || return 1
    else
        chmod u-x,go-wx "$path" 2>/dev/null || return 1
    fi
    changes="Permissions: $old_perms -> $(stat -c '%a' "$path")"

    # Apply owner/group if specified
    if [[ -n "$owner" ]] && [[ -n "$group" ]]; then
        chown "$owner:$group" "$path" 2>/dev/null || return 1
        changes="$changes, Owner: $old_owner -> $(stat -c '%U:%G' "$path")"
    elif [[ -n "$owner" ]]; then
        chown "$owner" "$path" 2>/dev/null || return 1
        changes="$changes, Owner: $old_owner -> $(stat -c '%U:%G' "$path")"
    elif [[ -n "$group" ]]; then
        chgrp "$group" "$path" 2>/dev/null || return 1
        changes="$changes, Owner: $old_owner -> $(stat -c '%U:%G' "$path")"
    fi

    echo "$changes"
    return 0
}

# Process a single CSV line
process_csv_line() {
    local line="$1"
    local line_num="$2"
    local recommendation

    # Parse CSV (assumes no commas in fields)
    IFS=',' read -r hostname os_version cis_rule description path owner group perms recommendation <<< "$line"

    # Trim whitespace
    hostname=$(echo "$hostname" | xargs)
    cis_rule=$(echo "$cis_rule" | xargs)
    path=$(echo "$path" | xargs)
    owner=$(echo "$owner" | xargs)
    group=$(echo "$group" | xargs)
    perms=$(echo "$perms" | xargs)

    # Get current state for logging
    local current_owner
    local current_group
    local current_perms
    local current_state
    current_owner=$(stat -c '%U' "$path" 2>/dev/null || echo "UNKNOWN")
    current_group=$(stat -c '%G' "$path" 2>/dev/null || echo "UNKNOWN")
    current_perms=$(stat -c '%a' "$path" 2>/dev/null || echo "unknown")
    current_state="Owner: ${current_owner}:${current_group}, Perms: ${current_perms}"

    # Normalize current perms ONCE so it can be used anywhere below
    local normalized_current_perms
    normalized_current_perms=$(echo "$current_perms" | sed 's/^0*//')
    [[ -z "$normalized_current_perms" ]] && normalized_current_perms="0"

    # Safety guard: if host does not match, silently ignore.
    if [[ "$hostname" != "$CURRENT_HOSTNAME" ]]; then
        echo "IGNORED|hostname mismatch"
        return 0
    fi

    # Check if path is excluded
    if is_excluded_path "$path"; then
        local state
        state=$(get_state "$path")
        log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Skipping - Excluded path: $path | $state"
        echo "SKIPPED|excluded path|$state"
        return 0
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Skipping - Path does not exist: $path"
        echo "SKIPPED|path does not exist"
        return 0
    fi

    # Check if already remediated (check owner, group, AND permissions)
    local already_remediated=false

    # Determine what the TARGET values should be (including defaults for each CIS rule)
    local target_owner="$owner"
    local target_group="$group"
    local target_perms="$perms"

    # Apply CIS rule defaults if values are empty
    case "$cis_rule" in
        "6.1.12")
            local owner_csv_upper group_csv_upper
            local owner_invalid=false
            local group_invalid=false
            owner_csv_upper="${owner^^}"
            group_csv_upper="${group^^}"

            if [[ -n "$owner" ]] && [[ "$owner_csv_upper" != "UNKNOWN" ]] && ! is_valid_csv_owner_name "$owner"; then
                owner_invalid=true
            fi
            if [[ -n "$group" ]] && [[ "$group_csv_upper" != "UNKNOWN" ]] && ! is_valid_csv_group_name "$group"; then
                group_invalid=true
            fi

            if [[ -n "$owner" ]]; then
                if [[ "$owner_csv_upper" == "UNKNOWN" ]] || [[ "$owner_invalid" == "true" ]]; then
                    target_owner="$DEFAULT_OWNER_6_1_12"
                else
                    target_owner="$owner"
                fi
            elif [[ "$current_owner" == "UNKNOWN" ]] || ! is_valid_owner "$current_owner"; then
                target_owner="$DEFAULT_OWNER_6_1_12"
            else
                target_owner=""
            fi

            if [[ -n "$group" ]]; then
                if [[ "$group_csv_upper" == "UNKNOWN" ]] || [[ "$group_invalid" == "true" ]]; then
                    target_group="$DEFAULT_GROUP_6_1_12"
                else
                    target_group="$group"
                fi
            else
                if [[ "$current_group" == "UNKNOWN" ]] || ! is_valid_group "$current_group"; then
                    target_group="$DEFAULT_GROUP_6_1_12"
                else
                    target_group=""
                fi
            fi
            target_perms=""
            ;;
        "6.1.11")
            # Owner/group do not apply to this rule.
            target_owner=""
            target_group=""

            if [[ -n "$perms" ]] && is_non_world_writable_mode "$perms"; then
                target_perms="$perms"
            else
                if [[ -d "$path" ]]; then
                    target_perms=$(add_sticky_bit_mode "$path")
                else
                    target_perms=$(remove_world_write_mode "$path")
                fi
            fi
            ;;
        "6.2.11")
            if [[ -n "$owner" ]] && [[ "${owner^^}" != "UNKNOWN" ]] && ! is_valid_csv_owner_name "$owner"; then
                log_message "FAILED" "Line $line_num: CIS 6.2.11 - Invalid owner in CSV: $owner for $path"
                echo "FAILED|invalid owner"
                return 0
            fi
            if [[ -n "$group" ]] && [[ "${group^^}" != "UNKNOWN" ]] && ! is_valid_csv_group_name "$group"; then
                log_message "FAILED" "Line $line_num: CIS 6.2.11 - Invalid group in CSV: $group for $path"
                echo "FAILED|invalid group"
                return 0
            fi
            if [[ -n "$perms" ]] && is_dotfile_compliant_mode "$perms" && is_non_world_writable_mode "$perms"; then
                target_perms="$perms"
            else
                target_perms=$(remove_dotfile_access_mode "$path")
            fi
            ;;
    esac

    # Home directories from scan CSVs must be 700 or 750, regardless of rule.
    if is_home_directory_path "$path"; then
        target_perms="$(get_home_directory_mode "$perms")"
    fi

    # Normalize owner/group targets.
    # For 6.1.12, UNKNOWN or invalid values map to root.
    if [[ "$cis_rule" == "6.1.12" ]]; then
        if [[ -n "$target_owner" ]]; then
            if [[ "${target_owner^^}" == "UNKNOWN" ]] || ! is_valid_owner "$target_owner"; then
                target_owner="$DEFAULT_OWNER_6_1_12"
            fi
        fi
        if [[ -n "$target_group" ]]; then
            if [[ "${target_group^^}" == "UNKNOWN" ]] || ! is_valid_group "$target_group"; then
                target_group="$DEFAULT_GROUP_6_1_12"
            fi
        fi
    else
        if [[ -n "$target_owner" ]]; then
            if [[ "${target_owner^^}" == "UNKNOWN" ]] || ! is_valid_owner "$target_owner"; then
                target_owner="$DEFAULT_OWNER_6_1_12"
            fi
        fi
        if [[ -n "$target_group" ]]; then
            if [[ "${target_group^^}" == "UNKNOWN" ]] || ! is_valid_group "$target_group"; then
                target_group="$DEFAULT_GROUP_6_1_12"
            fi
        fi
    fi

    # Normalize permissions for comparison (remove ALL leading zeros)
    local normalized_current_perms
    normalized_current_perms=$(echo "${current_perms:-}" | sed 's/^0*//')
    [[ -z "$normalized_current_perms" ]] && normalized_current_perms="0"

    local normalized_target_perms
    normalized_target_perms=$(echo "${target_perms:-}" | sed 's/^0*//')
    [[ -z "$normalized_target_perms" ]] && normalized_target_perms="0"

    # Check if current state matches target state
    local owner_match=true
    local group_match=true
    local perms_match=true

    if [[ -n "$target_owner" ]] && [[ "$current_owner" != "$target_owner" ]]; then
        owner_match=false
    fi

    if [[ -n "$target_group" ]] && [[ "$current_group" != "$target_group" ]]; then
        group_match=false
    fi

    if [[ -n "$target_perms" ]]; then
        if [[ "$normalized_current_perms" != "$normalized_target_perms" ]]; then
            perms_match=false
        fi
    fi

    # Only skip if everything that should be checked matches
    if [[ "$owner_match" == "true" ]] && [[ "$group_match" == "true" ]] && [[ "$perms_match" == "true" ]]; then
        already_remediated=true
    fi

    if [[ "$already_remediated" == "true" ]]; then
        if [[ "$cis_rule" == "6.1.12" ]]; then
            log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Already remediated: $path | Owner: ${current_owner}:${current_group}"
        else
            log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Already remediated: $path | $current_state"
        fi
        echo "SKIPPED|already remediated"
        return 0
    fi

    # Determine which remediation function to call
    local changes=""
    case "$cis_rule" in
        "6.1.11")
            changes=$(remediate_6_1_11 "$path" "" "" "$target_perms")
            if [[ $? -eq 0 ]]; then
                log_message "CHANGED" "Line $line_num: CIS 6.1.11 - $path | $changes"
                echo "SUCCESS|$changes"
            else
                log_message "FAILED" "Line $line_num: Failed to remediate CIS 6.1.11 - $path"
                echo "FAILED|remediation error"
            fi
            ;;
        "6.1.12")
            changes=$(remediate_6_1_12 "$path" "$target_owner" "$target_group" "$target_perms")
            if [[ $? -eq 0 ]]; then
                log_message "CHANGED" "Line $line_num: CIS 6.1.12 - $path | $changes"
                echo "SUCCESS|$changes"
            else
                log_message "FAILED" "Line $line_num: Failed to remediate CIS 6.1.12 - $path"
                echo "FAILED|remediation error"
            fi
            ;;
        "6.2.11")
            changes=$(remediate_6_2_11 "$path" "$target_owner" "$target_group" "$target_perms")
            if [[ $? -eq 0 ]]; then
                log_message "CHANGED" "Line $line_num: CIS 6.2.11 - $path | $changes"
                echo "SUCCESS|$changes"
            else
                log_message "FAILED" "Line $line_num: Failed to remediate CIS 6.2.11 - $path"
                echo "FAILED|remediation error"
            fi
            ;;
        *)
            log_message "SKIPPED" "Line $line_num: CIS $cis_rule - Unknown CIS rule: $cis_rule"
            echo "SKIPPED|unknown CIS rule"
            ;;
    esac
}

########################################
# Main
########################################

usage() {
    cat << EOF
Usage: $0 -i <input_csv> [-o <output_log>]

Options:
  -i    Input CSV file (required)
        Format: Hostname,OS Version,CIS Rule,Description,Path,Owner,Group,Permissions,Recommendation
  -o    Output log file (default: /var/tmp/chg/lrp/custom_cis_remediation_<timestamp>.log)
  -h    Show this help message

Examples:
  $0 -i remediation_input.csv
  $0 -i remediation_input.csv -o custom_log.log

Default Values:
  CIS 6.1.12 Owner: $DEFAULT_OWNER_6_1_12
  CIS 6.1.12 Group: $DEFAULT_GROUP_6_1_12

Note: Requires MIS and Vuln Team approvals before running step 2 remediation.
EOF
    exit 1
}

# Parse arguments
INPUT_CSV=""

while getopts "i:o:h" opt; do
    case $opt in
        i) INPUT_CSV="$OPTARG" ;;
        o) LOG_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate input
if [[ -z "$INPUT_CSV" ]]; then
    echo "Error: Input CSV file is required"
    usage
fi

if [[ ! -f "$INPUT_CSV" ]]; then
    echo "Error: Input CSV file not found: $INPUT_CSV"
    exit 1
fi

# Set default log file if not specified
if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/var/tmp/chg/lrp/custom_cis_remediation_$(date +%m%d%Y_%H%M%S).log"
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Warning: This script should be run as root for proper file ownership changes"
    echo "Press Enter to continue anyway, or Ctrl+C to cancel..."
    read
fi

# Start logging
log_message "INFO" "======================================"
log_message "INFO" "CIS Remediation Script Started"
log_message "INFO" "Input CSV: $INPUT_CSV"
log_message "INFO" "Log File: $LOG_FILE"
log_message "INFO" "Hostname: $CURRENT_HOSTNAME"
log_message "INFO" "======================================"

# Process CSV file
line_num=0
total_lines=0
success_count=0
skip_count=0
fail_count=0

while IFS= read -r line; do
    ((++line_num))

    # Skip header line
    if [[ $line_num -eq 1 ]]; then
        if [[ "$line" =~ ^Hostname.*CIS.*Rule ]]; then
            continue
        fi
    fi

    # Skip empty lines
    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
        continue
    fi

    # Process only rows for this host to avoid cross-host mismatch noise.
    IFS=',' read -r row_hostname _ <<< "$line"
    row_hostname=$(echo "$row_hostname" | xargs)
    if [[ "$row_hostname" != "$CURRENT_HOSTNAME" ]]; then
        continue
    fi

    ((++total_lines))

    # Process the line
    result=$(process_csv_line "$line" "$line_num")
    status=$(echo "$result" | tail -n1 | cut -d'|' -f1)

    case "$status" in
        SUCCESS) ((success_count++)) ;;
        SKIPPED) ((skip_count++)) ;;
        FAILED)  ((fail_count++)) ;;
    esac

done < "$INPUT_CSV"

# Summary
log_message "INFO" "======================================"
log_message "INFO" "Remediation Summary"
log_message "INFO" "Total lines processed: $total_lines"
log_message "INFO" "Successful remediations: $success_count"
log_message "INFO" "Skipped: $skip_count"
log_message "INFO" "Failed: $fail_count"
log_message "INFO" "======================================"

echo ""
echo "Log file saved to: $LOG_FILE"
echo ""

# Exit with appropriate code
if [[ $fail_count -gt 0 ]]; then
    exit 1
else
    exit 0
fi
