#!/bin/bash
# One-time script to manually generate upgrade_data.js from existing .tmp file
# Run on lmrg34ja as root

UPGRADETEMP=/usr/local/pnc/bin/RHEL_Inventory/data/upgrade_eligibility_2026-07-27.csv.tmp
UPGRADE_WEB_DIR=/usr/local/midweb/RHEL/Upgrade
_UPG_DATE=2026-07-27
_UPG_ARCHIVE="${UPGRADE_WEB_DIR}/archive/upgrade_eligibility_${_UPG_DATE}.csv"
_UPG_CSV="${UPGRADE_WEB_DIR}/RHEL8-9_Upgrade_Eligibility_Report.csv"
_UPG_JS="${UPGRADE_WEB_DIR}/upgrade_data.js"

# First append fed data if available
FED_UPG=/usr/local/pnc/bin/RHEL_Inventory/data/fed_stage/fed_enclave_upgrade.dat
if [[ -s "$FED_UPG" ]]; then
    echo "Appending fed enclave data: $(wc -l < "$FED_UPG") records"
    cat "$FED_UPG" >> "$UPGRADETEMP"
else
    echo "No fed enclave data found at $FED_UPG — skipping"
fi

mkdir -p "${UPGRADE_WEB_DIR}/archive"

# Archive combined raw data
cp "$UPGRADETEMP" "$_UPG_ARCHIVE"
echo "Archived: $_UPG_ARCHIVE ($(wc -l < "$_UPG_ARCHIVE") lines)"

# Write final CSV with header + sorted data
echo "Host,Datacenter,Mnemonic,Environment,OS,Eligibility,Comments" > "$_UPG_CSV"
sort -t, -k1,1 "$UPGRADETEMP" >> "$_UPG_CSV"
echo "CSV written: $_UPG_CSV ($(( $(wc -l < "$_UPG_CSV") - 1 )) hosts)"

# Generate upgrade_data.js using a temp awk script file to avoid shell escaping issues
AWK_SCRIPT=$(mktemp /tmp/upg_awk.XXXXXX)
cat > "$AWK_SCRIPT" << 'AWKEOF'
BEGIN { FS="," }
NR==1 { next }
{
    h=$1; dc=$2; mn=$3; ev=$4; os=$5; el=$6
    # Collect comments — field 7 onward (may contain commas)
    cm=$7
    for(i=8;i<=NF;i++) cm=cm","$i
    # Simple JSON escaping — replace backslash then double-quote
    gsub(/\\/, "\\\\", cm); gsub(/"/, "\\\"", cm)
    gsub(/\\/, "\\\\", h);  gsub(/"/, "\\\"", h)
    printf "  {\"Host\":\"%s\",\"Datacenter\":\"%s\",\"Mnemonic\":\"%s\",\"Environment\":\"%s\",\"OS\":\"%s\",\"Eligibility\":\"%s\",\"Comments\":\"%s\"},\n",
        h,dc,mn,ev,os,el,cm
}
AWKEOF

{
    echo "// RHEL 8->9 Upgrade Eligibility -- generated $(date '+%Y-%m-%d %H:%M:%S')"
    echo "// Fields: Host,Datacenter,Mnemonic,Environment,OS,Eligibility,Comments"
    echo "const serverData = ["
    awk -f "$AWK_SCRIPT" "$_UPG_CSV"
    echo "];"
} > "$_UPG_JS"

rm -f "$AWK_SCRIPT"
echo "JS written: $_UPG_JS ($(wc -l < "$_UPG_JS") lines)"
echo "Done — reload the Upgrade page to see data"
