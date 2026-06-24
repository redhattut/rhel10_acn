#!/bin/bash
# =============================================================================
# rhel_split_hosts.sh — Split CMDB into non-fed and fed enclave host lists
# =============================================================================
# Runs on lmrg34ja as Task 1 of the AAP inventory pipeline.
#
# Reads the latest CMDB extract and produces:
#   DATA_DIR/non_fed_hosts.txt  — non-Fed hosts, decommissions excluded
#   DATA_DIR/fed_hosts.txt      — Fed Enclave hosts, decommissions excluded
#
# Prints the fed host list to stdout (one hostname per line) so Ansible
# can register it as a list variable via stdout_lines.
#
# Exit codes:
#   0  — success, both files written, fed list printed to stdout
#   1  — CMDB file not found
#   2  — CMDB file empty or produced no usable hosts
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "ERROR: rhel_inv.conf not found at ${CONF}" >&2
    exit 1
fi
. "$CONF"

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

# --- Locate CMDB file --------------------------------------------------------
CMDB="${CMDBDATAFILE}"
if [[ -z "$CMDB" || ! -f "$CMDB" ]]; then
    # Re-evaluate in case conf cached an old path
    CMDB=$(ls /home/xaascpau/20*cmdb_ci_linux_server.csv 2>/dev/null | tail -1)
fi

if [[ -z "$CMDB" || ! -f "$CMDB" ]]; then
    log ERROR "CMDB file not found — expected /home/xaascpau/20*cmdb_ci_linux_server.csv"
    exit 1
fi

CMDB_LINES=$(wc -l < "$CMDB")
log INFO "CMDB file     : $CMDB ($CMDB_LINES records)"
log INFO "Output dir    : $DATA_DIR"

mkdir -p "$DATA_DIR"

NON_FED_FILE="${DATA_DIR}/non_fed_hosts.txt"
FED_FILE="${DATA_DIR}/fed_hosts.txt"

# --- Split logic -------------------------------------------------------------
# CMDB columns: hostname,SupportGroup,InstallStatus,DesiredOpState,FedEnclave
#
# No header row — file starts directly with data records.
# Strip \r from last field to handle Windows/ServiceNow CRLF line endings.
# Exclude: any line containing "Decommission" (case-insensitive)
# Fed:     FedEnclave field (col 5) is "True"  (case-insensitive)
# Non-Fed: FedEnclave field (col 5) is "False" (case-insensitive)
#
# Output: just the hostname (field 1), one per line, sorted.

# Non-fed hosts — FedEnclave = False, no Decommission anywhere in line
# grep ^l ensures only valid PNC Linux hostnames (start with lowercase l)
# This excludes IP addresses, blank lines, and non-Linux CI records
grep -iv "decommission" "$CMDB" \
    | awk -F, '{gsub(/\r/,"",$5); if (tolower($5)=="false" && $1!="") print $1}' \
    | grep "^l" \
    | sort > "$NON_FED_FILE"

# Fed enclave hosts — FedEnclave = True, no Decommission anywhere in line
grep -iv "decommission" "$CMDB" \
    | awk -F, '{gsub(/\r/,"",$5); if (tolower($5)=="true" && $1!="") print $1}' \
    | grep "^l" \
    | sort > "$FED_FILE"

NON_FED_COUNT=$(wc -l < "$NON_FED_FILE")
FED_COUNT=$(wc -l < "$FED_FILE")
TOTAL=$(( NON_FED_COUNT + FED_COUNT ))

log INFO "Non-Fed hosts : $NON_FED_COUNT → $NON_FED_FILE"
log INFO "Fed hosts     : $FED_COUNT → $FED_FILE"
log INFO "Total         : $TOTAL (excluded any containing Decommission in CMDB record)"

if [[ $TOTAL -eq 0 ]]; then
    log ERROR "No hosts produced — CMDB file may be malformed or empty"
    exit 2
fi

if [[ $FED_COUNT -eq 0 ]]; then
    log WARN "No Fed Enclave hosts found in CMDB — fed scan will be skipped"
fi

# Print fed host list to stdout for Ansible stdout_lines registration
# Ansible task: register: split_result
#               set_fact: fed_host_list: "{{ split_result.stdout_lines }}"
cat "$FED_FILE"

exit 0
