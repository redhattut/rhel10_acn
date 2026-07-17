DAT=/usr/local/pnc/bin/RHEL_Inventory_v2/data/RHEL_DEPLOYMENTS.dat

wc -l "$DAT"

# Remove unknown-date duplicates for hosts that also have a real dated record.
# Hosts with ONLY unknown records are kept as-is.
awk '
NR==FNR {
    h = $2; sub(/\..*/, "", h)
    if ($1 !~ /^unknown/) has_real_date[h] = 1
    next
}
{
    h = $2; sub(/\..*/, "", h)
    if ($1 ~ /^unknown/ && has_real_date[h]) next
    print $0
}
' "$DAT" "$DAT" > "${DAT}.dedup"

wc -l "${DAT}.dedup"

# Check lbmo319a and ldng148d look right before swapping
grep 'lbmo319a\|ldng148d' "${DAT}.dedup"

# Swap in only after verifying
mv "$DAT" "${DAT}.bak2.$(date +%Y%m%d)"
mv "${DAT}.dedup" "$DAT"
