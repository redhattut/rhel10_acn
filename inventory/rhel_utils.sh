#!/bin/bash
# =============================================================================
# rhel_utils.sh — Shared utility functions for the RHEL Inventory system
# =============================================================================
# Sourced by rhel_inv_collect.sh, rhel_inv_report.sh, rhel_pkginventory.sh
# and any other script that needs file rotation or logging helpers.
#
# Replaces: rotate.sh, keep_history.sh
#
# Usage:
#   . "$(dirname "$0")/rhel_utils.sh"
#
# Functions provided:
#   rotate_compressed  <file> [max]   gzip current, shift .1.gz–.N.gz up
#   rotate_plain       <file> [max] [-e ext]  shift plain copies up (no gzip)
#   log                <LEVEL> <msg>  timestamped log line (INFO/WARN/ERROR/SECTION)
#   require_file       <path> <desc>  exit with ERROR if path missing
#   require_bin        <path> <desc>  exit with ERROR if binary missing/not executable
# =============================================================================

# Guard against double-sourcing
[[ -n "${_RHEL_UTILS_LOADED:-}" ]] && return 0
_RHEL_UTILS_LOADED=1

# =============================================================================
# log — timestamped, levelled log line
# =============================================================================
# All scripts define their own log() so they can work standalone.
# This definition is only used when a script sources rhel_utils.sh directly
# without defining its own log() first.
# If the calling script already defined log(), this is a no-op due to the guard.

if ! declare -f log > /dev/null 2>&1; then
    log() {
        local level="$1"; shift
        local ts
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        case "$level" in
            SECTION) printf '\n%s  === %s ===\n'   "$ts" "$*" ;;
            INFO)    printf '%s  [INFO]    %s\n'   "$ts" "$*" ;;
            WARN)    printf '%s  [WARN]    %s\n'   "$ts" "$*" ;;
            ERROR)   printf '%s  [ERROR]   %s\n'   "$ts" "$*" ;;
            *)       printf '%s  [INFO]    %s\n'   "$ts" "$*" ;;
        esac
    }
fi

# =============================================================================
# rotate_compressed <file> [max]
# =============================================================================
# Replaces: rotate.sh
#
# Gzips <file> then rotates compressed copies:
#   file.gz  →  file.1.gz
#   file.1.gz → file.2.gz
#   ...
#   file.(max-1).gz → file.max.gz   (oldest is overwritten)
#
# Arguments:
#   $1  file   : path to the file to rotate (must exist and be non-empty)
#   $2  max    : number of compressed copies to keep (default: 5)
#
# Exits with status 1 if gzip fails (mirrors legacy rotate.sh behavior).
# Silently skips if <file> does not exist (nothing to rotate on first run).
# =============================================================================
rotate_compressed() {
    local fn="$1"
    local max="${2:-5}"

    if [[ ! -f "$fn" ]]; then
        log INFO "rotate_compressed: $fn not found — nothing to rotate (first run?)"
        return 0
    fi

    log INFO "Rotating $fn — keeping max $max compressed copies"

    gzip -9 "$fn" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        log ERROR "rotate_compressed: gzip failed on $fn"
        return 1
    fi

    # Shift existing compressed copies up by one slot, dropping the oldest
    # Loop from max down to 2: slot N becomes slot N+1
    for (( n=max; n>1; n=n-1 )); do
        local a=$(( n - 1 ))
        [[ -f "${fn}.${a}.gz" ]] && mv -f "${fn}.${a}.gz" "${fn}.${n}.gz" 2>/dev/null
    done

    # The freshly gzipped file becomes slot 1
    mv "${fn}.gz" "${fn}.1.gz"

    log INFO "rotate_compressed: done — ${fn}.1.gz through ${fn}.${max}.gz"
    return 0
}

# =============================================================================
# rotate_plain <file> [max] [-e extension]
# =============================================================================
# Replaces: keep_history.sh
#
# Rotates plain (uncompressed) copies of a file with an optional extension:
#   file.csv     →  file.1.csv
#   file.1.csv   →  file.2.csv
#   ...
#   file.(max-1).csv → file.max.csv   (oldest is overwritten)
#
# Arguments:
#   $1  file      : base path (without extension)
#   $2  max       : number of copies to keep (default: 5)
#  [-e  ext]      : file extension including dot, e.g. ".csv" (default: "")
#                   If provided the base file checked is <file><ext>
#
# Unlike rotate_compressed, this does NOT gzip — files are kept as-is.
# Used for the WEBDIR historical CSV copies where you want readable files.
#
# Example:
#   rotate_plain "${WEBDIR}/historical_data/RHEL_INVENTORY" 14 -e ".csv"
#   → keeps RHEL_INVENTORY.1.csv through RHEL_INVENTORY.14.csv
# =============================================================================
rotate_plain() {
    local fn="$1"
    local max="${2:-5}"
    local ext=""

    # Parse optional -e flag (can appear after positional args)
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e) ext="$2"; shift 2 ;;
            *)  shift ;;
        esac
    done

    local base_file="${fn}${ext}"

    if [[ ! -f "$base_file" ]]; then
        log INFO "rotate_plain: $base_file not found — nothing to rotate"
        return 0
    fi

    log INFO "Rotating plain copies of $base_file — keeping max $max"

    # Shift existing copies up by one slot, dropping the oldest
    for (( n=max; n>1; n=n-1 )); do
        local a=$(( n - 1 ))
        [[ -f "${fn}.${a}${ext}" ]] && mv -f "${fn}.${a}${ext}" "${fn}.${n}${ext}" 2>/dev/null
    done

    # Current file becomes slot 1
    if [[ -f "$base_file" ]]; then
        mv "$base_file" "${fn}.1${ext}"
    fi

    log INFO "rotate_plain: done — ${fn}.1${ext} through ${fn}.${max}${ext}"
    return 0
}

# =============================================================================
# require_file <path> <description>
# =============================================================================
# Logs an ERROR and returns 1 if the file does not exist.
# Calling script should check the return code and exit if needed.
#
# Example:
#   require_file "$INVENTORYDATA" "RHEL inventory data" || exit 1
# =============================================================================
require_file() {
    local path="$1"
    local desc="${2:-$1}"
    if [[ ! -f "$path" ]]; then
        log ERROR "Required file not found: $path ($desc)"
        return 1
    fi
    return 0
}

# =============================================================================
# require_bin <path> <description>
# =============================================================================
# Logs an ERROR and returns 1 if the binary does not exist or is not executable.
#
# Example:
#   require_bin "$PSSH_BIN" "pssh" || exit 1
# =============================================================================
require_bin() {
    local path="$1"
    local desc="${2:-$1}"
    if [[ ! -x "$path" ]]; then
        log ERROR "Required binary not found or not executable: $path ($desc)"
        return 1
    fi
    return 0
}

# =============================================================================
# expand_location <code>
# =============================================================================
# Normalises location codes to short canonical form.
# Strips "Greenfield-" prefix from legacy values, maps known codes.
# Cloud datacenters (AZCE, AZE2, etc.) are returned as-is — short already.
# Prints the normalised code to stdout.
# Add new datacenters here as they come online.
#
# Examples:
#   expand_location "GF0"             → "GF0"
#   expand_location "Greenfield-GF0"  → "GF0"   (legacy value cleanup)
#   expand_location "AZCE"            → "AZCE"   (cloud, returned as-is)
# =============================================================================
expand_location() {
    local loc="$1"
    # Strip legacy "Greenfield-" prefix first
    loc="${loc#Greenfield-}"
    # Normalise remaining known codes
    case "$loc" in
        GF0|GF1|GF2)  echo "$loc" ;;   # on-prem datacenters
        AZCE|AZE2)    echo "$loc" ;;   # Azure cloud datacenters
        CH)           echo "CH"   ;;
        PIT)          echo "PIT"  ;;
        *)            echo "$loc" ;;   # unknown — return as-is (already stripped)
    esac
}

# is_cloud_location <code>
# =============================================================================
# Returns 0 (true) if the location is a cloud datacenter, 1 (false) otherwise.
# Used to classify hosts as Cloud vs Virt/Phys in summary counts.
# =============================================================================
is_cloud_location() {
    case "$1" in
        AZCE|AZE2) return 0 ;;
        *)         return 1 ;;
    esac
}
