#!/bin/bash
# =============================================================================
# migrate_v2_names.sh — ONE-TIME rename of _v2-suffixed files
# =============================================================================
# Run ONCE on the main jumpbox (lmrg34ja) after deploying the updated scripts
# and BEFORE the next nightly run. Renames every existing data file, archive
# generation, log, and published web file from the parallel-validation _v2
# names to the plain production names, so archive continuity (and therefore
# carry-forward) is preserved across the rename.
#
# Safe to re-run: every rename is skipped if the source no longer exists.
# Does NOT touch BASE_DIR or WEBDIR directory paths — renaming those requires
# coordinating crontab, httpd, and the AAP job template (see rhel_inv.conf).
#
# Usage:  ./migrate_v2_names.sh          # perform renames
#         ./migrate_v2_names.sh --dry-run  # show what would be renamed
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "ERROR: rhel_inv.conf not found" >&2
    exit 1
fi
. "$CONF"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

_mv() {
    local src="$1" dst="$2"
    [[ -e "$src" ]] || return 0
    if [[ -e "$dst" ]]; then
        echo "SKIP (target exists): $src -> $dst"
        return 0
    fi
    if [[ $DRY -eq 1 ]]; then
        echo "DRY : $src -> $dst"
    else
        mv "$src" "$dst" && echo "MOVED: $src -> $dst"
    fi
}

# Rename a base file plus all rotated generations (.N, .N.gz, .gz)
_mv_gens() {
    local src_base="$1" dst_base="$2"
    _mv "$src_base" "$dst_base"
    local f suffix
    for f in "${src_base}".*; do
        [[ -e "$f" ]] || continue
        suffix="${f#${src_base}}"
        _mv "$f" "${dst_base}${suffix}"
    done
}

echo "=== Data files (${DATA_DIR}) ==="
_mv_gens "${DATA_DIR}/RHEL_INVENTORY_v2.dat"    "${DATA_DIR}/RHEL_INVENTORY.dat"
_mv_gens "${DATA_DIR}/RHEL_INVENTORY_v2.csv"    "${DATA_DIR}/RHEL_INVENTORY.csv"
_mv      "${DATA_DIR}/RHEL_INVENTORY_v2.tmp"    "${DATA_DIR}/RHEL_INVENTORY.tmp"
_mv_gens "${DATA_DIR}/RHEL_IDINVENTORY_v2.dat"  "${DATA_DIR}/RHEL_IDINVENTORY.dat"
_mv      "${DATA_DIR}/RHEL_IDINVENTORY_v2.tmp"  "${DATA_DIR}/RHEL_IDINVENTORY.tmp"
_mv_gens "${DATA_DIR}/RHEL_DBINVENTORY_v2.dat"  "${DATA_DIR}/RHEL_DBINVENTORY.dat"
_mv      "${DATA_DIR}/RHEL_DBINVENTORY_v2.tmp"  "${DATA_DIR}/RHEL_DBINVENTORY.tmp"
_mv_gens "${DATA_DIR}/RHEL_PACKAGES_v2.csv"     "${DATA_DIR}/RHEL_PACKAGES.csv"
_mv      "${DATA_DIR}/RHEL_PACKAGES_v2.tmp"     "${DATA_DIR}/RHEL_PACKAGES.tmp"
_mv      "${DATA_DIR}/RHEL_Inventory_History_v2.dat" "${DATA_DIR}/RHEL_Inventory_History.dat"
_mv      "${DATA_DIR}/check_RHEL_versions_MNEMONIC_PLATFORM_v2.dat" "${DATA_DIR}/check_RHEL_versions_MNEMONIC_PLATFORM.dat"
_mv      "${DATA_DIR}/check_RHEL_versions_MNEMONIC_RELEASES_v2.dat" "${DATA_DIR}/check_RHEL_versions_MNEMONIC_RELEASES.dat"
_mv      "${DATA_DIR}/check_RHEL_versions_LOCATION_PLATFORM_v2.dat" "${DATA_DIR}/check_RHEL_versions_LOCATION_PLATFORM.dat"
_mv      "${DATA_DIR}/check_RHEL_versions_LOCATION_RELEASES_v2.dat" "${DATA_DIR}/check_RHEL_versions_LOCATION_RELEASES.dat"
_mv      "${DATA_DIR}/RHEL_INV_V2.PID"          "${DATA_DIR}/RHEL_INV.PID"

echo "=== Published web files (${WEBDIR}) ==="
_mv "${WEBDIR}/RHEL_INVENTORY_v2.csv"    "${WEBDIR}/RHEL_INVENTORY.csv"
_mv "${WEBDIR}/RHEL_INVENTORY_v2.txt"    "${WEBDIR}/RHEL_INVENTORY.txt"
_mv "${WEBDIR}/RHEL_INVENTORY_v2.html"   "${WEBDIR}/RHEL_INVENTORY.html"
_mv "${WEBDIR}/RHEL_PACKAGES_v2.csv"     "${WEBDIR}/RHEL_PACKAGES.csv"
_mv "${WEBDIR}/RHEL_DEPLOYMENTS_v2.csv"  "${WEBDIR}/RHEL_DEPLOYMENTS.csv"
_mv "${WEBDIR}/RHEL_nonresponsive_v2.txt" "${WEBDIR}/RHEL_nonresponsive.txt"
_mv "${WEBDIR}/RHEL_Inventory_History_v2.txt" "${WEBDIR}/RHEL_Inventory_History.txt"

echo "=== Historical CSV archive (${WEBDIR}/historical_data) ==="
if [[ -d "${WEBDIR}/historical_data" ]]; then
    for f in "${WEBDIR}/historical_data"/RHEL_INVENTORY_v2*.csv; do
        [[ -e "$f" ]] || continue
        _mv "$f" "${f/RHEL_INVENTORY_v2/RHEL_INVENTORY}"
    done
fi

echo "=== Logs (${LOGS_DIR}) ==="
for f in "${LOGS_DIR}"/rhel_inventory_v2*.log; do
    [[ -e "$f" ]] || continue
    _mv "$f" "${f/rhel_inventory_v2/rhel_inventory}"
done
# Recreate the latest-log symlink under the new name
if [[ $DRY -eq 0 && -L "${LOGS_DIR}/rhel_inventory_v2_latest.log" ]]; then
    _target=$(readlink "${LOGS_DIR}/rhel_inventory_v2_latest.log")
    rm -f "${LOGS_DIR}/rhel_inventory_v2_latest.log"
    ln -sf "${_target/rhel_inventory_v2/rhel_inventory}" "${LOGS_DIR}/rhel_inventory_latest.log"
    echo "SYMLINK: rhel_inventory_latest.log -> ${_target/rhel_inventory_v2/rhel_inventory}"
fi

echo ""
echo "Migration complete. Reminders:"
echo "  - AAP job template must now reference rhel_inventory.yml (renamed from rhel_inventory_v2.yml)"
echo "  - Crontab log-name entries: update rhel_inventory_v2_run/latest to rhel_inventory_run/latest"
echo "  - BASE_DIR (${BASE_DIR}) and WEBDIR (${WEBDIR}) paths unchanged — separate move if desired"
exit 0