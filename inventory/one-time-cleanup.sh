DAT=/usr/local/pnc/bin/RHEL_Inventory_v2/data/RHEL_DEPLOYMENTS.dat

# Count before
wc -l "$DAT"

# Dedup on short hostname, keep earliest date per host, normalize to short name
awk '
{
    h = $2; sub(/\..*/, "", h)
    if (!(h in seen)) {
        seen[h] = 1
        print $1, h, $3, $4
    }
}
' "$DAT" | sort > "${DAT}.dedup"

# Count after
wc -l "${DAT}.dedup"

# Swap in — verify counts look right first
mv "$DAT" "${DAT}.bak.$(date +%Y%m%d)"
mv "${DAT}.dedup" "$DAT"