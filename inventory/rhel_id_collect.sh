#!/bin/bash
# =============================================================================
# rhel_id_collect.sh — Collect UIDs, GIDs, netgroups and AD groups
# =============================================================================
# Replaces: RHEL_ID_Collect_uids.sh
#
# Reads RHEL_IDINVENTORY.dat and produces four consolidated files:
#   RHEL_UIDINVENTORY.dat  — unique UIDs sorted numerically (uid username)
#   RHEL_GIDINVENTORY.dat  — unique GIDs sorted numerically (gid username)
#   RHEL_NGINVENTORY.dat   — netgroup list (sorted, unique)
#   RHEL_ADINVENTORY.dat   — AD group list (sorted, unique)
#
# RHEL_IDINVENTORY.dat line formats (from rhel_remote_scan.sh):
#
#   USER lines:    hostname-USER-username:uid,gid,...
#     username = account name
#     uid      = user ID (field after colon, before first comma)
#     gid      = primary group ID (field after first comma, before second comma)
#
#   GROUP lines:   hostname-GROUP-groupname,...
#     groupname = group name only (no GID in this stream)
#
#   NETGROUP lines: hostname-NETGROUP-netgroupname,...
#   ADGROUP lines:  hostname-ADGROUP-adgroupname,...
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found" >&2
    exit 1
fi
. "$CONF"
. "$(dirname "$0")/rhel_utils.sh"

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# Set paths based on test mode
if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    _IDDATA="${BASE_DIR}/test/data/TEST_RHEL_IDINVENTORY.dat"
    _OUTDIR="${BASE_DIR}/test/data"
    _WEBDIR="${BASE_DIR}/test/webdir"
else
    _IDDATA="$IDINVENTORYDATA"
    _OUTDIR="$DATA_DIR"
    _WEBDIR="$WEBDIR"
fi

UIDDATA="${_OUTDIR}/RHEL_UIDINVENTORY.dat"
GIDDATA="${_OUTDIR}/RHEL_GIDINVENTORY.dat"
NGDATA="${_OUTDIR}/RHEL_NGINVENTORY.dat"
ADDATA="${_OUTDIR}/RHEL_ADINVENTORY.dat"

if [[ ! -f "$_IDDATA" || ! -s "$_IDDATA" ]]; then
    log WARN "IDINVENTORY data not found or empty: $_IDDATA — skipping UID/GID collection"
    exit 0
fi

LINECOUNT=$(wc -l < "$_IDDATA")
log INFO "Collecting UIDs/GIDs from: $_IDDATA"
log INFO "Processing $LINECOUNT ID inventory lines"

# =============================================================================
# UID collection — from USER lines
# Format per token: username:uid,gid,
# We want: uid (after colon, before first comma) and username (before colon)
# =============================================================================
grep "\-USER\-" "$_IDDATA" | while read -r IDLIST; do
    # Strip hostname prefix up to and including -USER-
    IDLIST="${IDLIST/*-USER-}"
    # Replace commas with spaces to iterate tokens
    IDLIST="${IDLIST//,/ }"
    for ID in $IDLIST; do
        # Skip empty tokens
        [[ -z "$ID" ]] && continue
        # username is everything before the colon
        IDNAME="${ID/:*}"
        # uid is everything after the colon — but may have been lost
        # if the token had no colon (group name only), skip it
        [[ "$ID" != *":"* ]] && continue
        IDUID="${ID#*:}"
        # Strip any trailing comma or extra fields
        IDUID="${IDUID%%,*}"
        # Validate it's a number before printf
        [[ "$IDUID" =~ ^[0-9]+$ ]] || continue
        printf "%11d %s\n" "$IDUID" "$IDNAME"
    done
done | sort -uf | sort -n > "$UIDDATA"

UID_COUNT=$(wc -l < "$UIDDATA")
log INFO "UID inventory: $UID_COUNT unique UIDs written to $UIDDATA"

# =============================================================================
# GID collection — also from USER lines (primary GID is 2nd field after colon)
# Format per token: username:uid,gid,
# We want: gid (second comma-delimited value) and username
# =============================================================================
grep "\-USER\-" "$_IDDATA" | while read -r IDLIST; do
    IDLIST="${IDLIST/*-USER-}"
    IDLIST="${IDLIST//,/ }"
    for ID in $IDLIST; do
        [[ -z "$ID" || "$ID" != *":"* ]] && continue
        IDNAME="${ID/:*}"
        # Full value after colon: uid,gid
        AFTER_COLON="${ID#*:}"
        # uid is before first comma, gid is after first comma
        IDUID="${AFTER_COLON%%,*}"
        IDGID="${AFTER_COLON#*,}"
        IDGID="${IDGID%%,*}"
        # Validate both are numbers
        [[ "$IDUID" =~ ^[0-9]+$ ]] || continue
        [[ "$IDGID" =~ ^[0-9]+$ ]] || continue
        printf "%11d %s\n" "$IDGID" "$IDNAME"
    done
done | sort -uf | sort -n > "$GIDDATA"

GID_COUNT=$(wc -l < "$GIDDATA")
log INFO "GID inventory: $GID_COUNT unique GIDs written to $GIDDATA"

# =============================================================================
# Netgroup collection — from NETGROUP lines
# Format: hostname-NETGROUP-netgroupname,...
# =============================================================================
grep "\-NETGROUP\-" "$_IDDATA" | while read -r IDLIST; do
    IDLIST="${IDLIST/*-NETGROUP-}"
    IDLIST="${IDLIST//,/ }"
    for ID in $IDLIST; do
        [[ -z "$ID" ]] && continue
        echo "$ID"
    done
done | sort -uf > "$NGDATA"

NG_COUNT=$(wc -l < "$NGDATA")
log INFO "Netgroup inventory: $NG_COUNT unique netgroups written to $NGDATA"

# =============================================================================
# AD group collection — from ADGROUP lines
# =============================================================================
grep "\-ADGROUP\-" "$_IDDATA" | while read -r IDLIST; do
    IDLIST="${IDLIST/*-ADGROUP-}"
    IDLIST="${IDLIST//,/ }"
    for ID in $IDLIST; do
        [[ -z "$ID" ]] && continue
        echo "$ID"
    done
done | sort -uf > "$ADDATA"

AD_COUNT=$(wc -l < "$ADDATA")
log INFO "AD group inventory: $AD_COUNT unique AD groups written to $ADDATA"

# =============================================================================
# Publish to web directory
# =============================================================================
cp -p "$UIDDATA" "$_WEBDIR/RHEL_UIDINVENTORY.dat"
cp -p "$GIDDATA" "$_WEBDIR/RHEL_GIDINVENTORY.dat"
cp -p "$_IDDATA" "$_WEBDIR/RHEL_IDINVENTORY.csv"
log INFO "UID/GID data published to $_WEBDIR"

exit 0
