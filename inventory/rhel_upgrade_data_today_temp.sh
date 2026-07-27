# On lmrg34ja — manually process the existing .tmp file
UPGRADETEMP=/usr/local/pnc/bin/RHEL_Inventory/data/upgrade_eligibility_2026-07-27.csv.tmp
UPGRADE_WEB_DIR=/usr/local/midweb/RHEL/Upgrade
_UPG_DATE=2026-07-27
_UPG_ARCHIVE="${UPGRADE_WEB_DIR}/archive/upgrade_eligibility_${_UPG_DATE}.csv"
_UPG_CSV="${UPGRADE_WEB_DIR}/RHEL8-9_Upgrade_Eligibility_Report.csv"
_UPG_JS="${UPGRADE_WEB_DIR}/upgrade_data.js"

mkdir -p "${UPGRADE_WEB_DIR}/archive"

# Archive
cp "$UPGRADETEMP" "$_UPG_ARCHIVE"

# Write CSV header + sorted data
echo "Host,Datacenter,Mnemonic,Environment,OS,Eligibility,Comments" > "$_UPG_CSV"
sort -t, -k1,1 "$UPGRADETEMP" >> "$_UPG_CSV"

# Generate upgrade_data.js
{
  echo "// RHEL 8→9 Upgrade Eligibility — generated $(date '+%Y-%m-%d %H:%M:%S')"
  echo "// Fields: Host,Datacenter,Mnemonic,Environment,OS,Eligibility,Comments"
  printf 'const serverData = [\n'
  awk -F, 'NR>1 {
    for(i=1;i<=NF;i++){gsub(/\\/,"\\\\\\\\",\$i);gsub(/"/,"\\\\\"",\$i)}
    printf "  {\"Host\":\"%s\",\"Datacenter\":\"%s\",\"Mnemonic\":\"%s\",\"Environment\":\"%s\",\"OS\":\"%s\",\"Eligibility\":\"%s\",\"Comments\":\"%s\"},\n",
      \$1,\$2,\$3,\$4,\$5,\$6,\$7
  }' "$_UPG_CSV"
  echo "];"
} > "$_UPG_JS"

wc -l "$_UPG_JS"
echo "Done"


# On lmrg34ja — SCP directly from lmrg34ba if network allows
scp xqmrglinaap@lmrg34ba:/usr/local/pnc/bin/data/fed_enclave_upgrade.dat \
    /usr/local/pnc/bin/RHEL_Inventory/data/fed_stage/fed_enclave_upgrade.dat

# Then append it to the UPGRADETEMP before running the manual processing above
cat /usr/local/pnc/bin/RHEL_Inventory/data/fed_stage/fed_enclave_upgrade.dat \
    >> /usr/local/pnc/bin/RHEL_Inventory/data/upgrade_eligibility_2026-07-27.csv.tmp