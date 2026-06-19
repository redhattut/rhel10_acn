#!/bin/bash
# =============================================================================
# rhel_deploy_scan.sh — New host detection and deployment record creation
# =============================================================================
# Replaces: RHEL_deployment_scan.sh
#
# Scans all hosts in MASTERHOSTLIST. For any host not already present in
# RHEL_DEPLOYMENTS.dat, determines its build date and appends a new record.
#
# RHEL_DEPLOYMENTS.dat format (space-delimited, append-only, permanent):
#   YYYY-MM-DD  hostname  Phys|Virt  RHEL_version
#
# Build date detection priority (newest SOE first, legacy fallbacks last):
#   1. PROVISIONDATE field in /boot/PNC_PROVISION_CONFIG
#   2. "added via VCO" line in /boot/PNC_PROVISION_CONFIG
#   3. pnc_changedomain RPM install timestamp
#   4. /root/PNC_FirstBoot file mtime
#   5. /root/PNC_FirstBoot.log file mtime
#   6. /root/anaconda-ks.cfg file mtime
#   7. /etc/sysconfig directory mtime
#   8. "unknown" if all methods fail
#
# New hosts found are printed to stdout (captured by orchestrator log).
# SSH failures (exit 255) are skipped silently — host will be retried
# on the next nightly run.
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found" >&2
    exit 1
fi
. "$CONF"

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# SSH options for single-host connections (not pssh — deployment scan is
# serial because it only touches hosts not yet in the dat file)
SSH="ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

# Ensure data file exists
touch "$DEPLOYMENTDATA"

# Build a quick lookup of already-known hosts to avoid grep-per-host
KNOWN_HOSTS=$(awk '{print $2}' "$DEPLOYMENTDATA" 2>/dev/null)

HOSTLIST=$(grep -v "^#" "$MASTERHOSTLIST")
TOTAL=$(echo "$HOSTLIST" | wc -l)
NEW_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

log INFO "Deployment scan starting — $TOTAL hosts to check"
log INFO "Deployment data: $DEPLOYMENTDATA"

# =============================================================================
# convert_date — parse a date string like "Mon Mar  3 14:22:01 EST 2025"
#                into YYYY-MM-DD format
# =============================================================================
convert_date() {
    local datestring="$1"
    local month day year

    month=$(echo "$datestring" | awk '{print $2}')
    day=$(echo "$datestring"   | awk '{print $3}')
    year=$(echo "$datestring"  | awk '{print $4}')

    # Pad day with leading zero if needed
    (( ${#day} < 2 )) && day=$(printf "%02d" "$day")

    case $month in
        Jan) month="01" ;; Feb) month="02" ;; Mar) month="03" ;;
        Apr) month="04" ;; May) month="05" ;; Jun) month="06" ;;
        Jul) month="07" ;; Aug) month="08" ;; Sep) month="09" ;;
        Oct) month="10" ;; Nov) month="11" ;; Dec) month="12" ;;
        *)   month="00" ;;
    esac

    BUILDDATE="${year}-${month}-${day}"
}

# =============================================================================
# Main scan loop
# =============================================================================

while IFS= read -r h; do

    [[ -z "$h" || "$h" == \#* ]] && continue

    # Skip hosts already in the deployment file
    if echo "$KNOWN_HOSTS" | grep -qw "$h"; then
        (( SKIP_COUNT++ ))
        continue
    fi

    # --- Virt/Phys detection -------------------------------------------------
    PV=$(eval $SSH "$h" ls -d /etc/vmware-tools 2>/dev/null)
    if (( $? == 255 )); then
        log WARN "SSH timeout/failure for $h — skipping"
        (( FAIL_COUNT++ ))
        continue
    fi
    [[ -z "$PV" ]] && PV="Phys" || PV="Virt"

    # --- OS version ----------------------------------------------------------
    RREC=$(eval $SSH "$h" head -1 /etc/redhat-release 2>/dev/null)
    release=$(echo "${RREC/*release /}" | awk '{print $1}')
    version=$(echo "${RREC/*Update /}")
    if [[ "$version" = "$RREC" ]]; then
        version=""
    else
        version=$(echo ".$version" | awk -F'\)' '{print $1}')
    fi
    OSVER="${release}${version}"

    # --- Build date detection ------------------------------------------------
    BUILDDATE=""

    # Priority 1: PROVISIONDATE in /boot/PNC_PROVISION_CONFIG
    eval "$(eval $SSH "$h" \
        sudo grep PROVISIONDATE /boot/PNC_PROVISION_CONFIG 2>/dev/null \
        | tail -1)"

    if [[ -n "$PROVISIONDATE" ]]; then
        BUILDDATE="$PROVISIONDATE"
        log INFO "$h: build date from PROVISIONDATE: $BUILDDATE"
    fi

    # Priority 2: "added via VCO" line in /boot/PNC_PROVISION_CONFIG
    if [[ -z "$BUILDDATE" ]]; then
        datestring=$(eval $SSH "$h" \
            egrep '"added by\|via VCO"' /boot/PNC_PROVISION_CONFIG \
            2>/dev/null \
            | tail -1 \
            | awk '{print $(NF-5)" "$(NF-4)" "$(NF-3)" "$(NF)}')
        if [[ -n "$datestring" ]]; then
            convert_date "$datestring"
            log INFO "$h: build date from VCO line: $BUILDDATE"
        fi
    fi

    # Priority 3: pnc_changedomain RPM install timestamp
    if [[ -z "$BUILDDATE" ]]; then
        datestring=$(eval $SSH "$h" \
            rpm -q --queryformat "'%{installtime:day}'" pnc_changedomain \
            2>/dev/null)
        if (( $? == 0 )) && [[ -n "$datestring" ]]; then
            convert_date "$datestring"
            log INFO "$h: build date from pnc_changedomain RPM: $BUILDDATE"
        fi
    fi

    # Priority 4–7: legacy file mtime fallbacks
    if [[ -z "$BUILDDATE" ]]; then
        for probe in \
            "/root/PNC_FirstBoot" \
            "/root/PNC_FirstBoot.log" \
            "/root/anaconda-ks.cfg" \
            "/etc/sysconfig"
        do
            BUILDDATE=$(eval $SSH "$h" \
                ls --full-time "$probe" 2>/dev/null \
                | awk '{print $6}')
            if [[ -n "$BUILDDATE" ]]; then
                log INFO "$h: build date from $probe mtime: $BUILDDATE"
                break
            fi
        done
    fi

    # Final fallback
    if [[ -z "$BUILDDATE" ]]; then
        BUILDDATE="unknown"
        log WARN "$h: could not determine build date — recording as unknown"
    fi

    # --- Append to deployment file -------------------------------------------
    echo "$BUILDDATE $h $PV $OSVER" >> "$DEPLOYMENTDATA"
    log INFO "NEW HOST: $BUILDDATE $h $PV $OSVER"
    (( NEW_COUNT++ ))

done <<< "$HOSTLIST"

# =============================================================================
log INFO "Deployment scan complete — new: $NEW_COUNT  already known: $SKIP_COUNT  SSH failures: $FAIL_COUNT"
# =============================================================================

exit 0
