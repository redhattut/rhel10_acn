DAT=/usr/local/pnc/bin/RHEL_Inventory_v2/data/RHEL_DEPLOYMENTS.dat

wc -l "$DAT"

# Dedup on short hostname, keep first occurrence of each host, write record as-is
awk '
{
    h = $2; sub(/\..*/, "", h)
    if (!(h in seen)) {
        seen[h] = 1
        print $0
    }
}
' "$DAT" | sort > "${DAT}.dedup"

wc -l "${DAT}.dedup"

# Review the counts, then swap if they look right
mv "$DAT" "${DAT}.bak.$(date +%Y%m%d)"
mv "${DAT}.dedup" "$DAT"
