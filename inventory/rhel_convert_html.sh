#!/bin/bash
# =============================================================================
# rhel_convert_html.sh — Convert RHEL_INVENTORY.dat to styled HTML table
# =============================================================================
# Replaces: convert_text_to_html_table.sh (was ksh, outdated column headers)
#
# Reads RHEL_INVENTORY.dat from stdin, writes a fully styled HTML table
# to the output file passed as $1. Uses style.css from the same webdir
# (the same stylesheet as index.html and all other inventory reports).
#
# Features:
#   - Search box (hostname / IP)
#   - Filter dropdowns: Environment, Type, OS version, Location
#   - Filter text input: App Code
#   - Live row count badge
#   - Syslog-ng colored green/red
#   - Type, Environment, Fed Enclave as pills
#   - Secondary fields (kernel, model, vCenter) muted for readability
#   - Full-width layout matching index.html header/body alignment
#
# Usage (called from rhel_inv_collect.sh):
#   cat "$INVENTORYDATA" | ./rhel_convert_html.sh "$WEBDIR/$INVENTDATAHTML"
#
# .dat field order (28 fields, space-delimited):
#   1=Host  2=Type  3=OS  4=Kernel  5=Arch  6=Memory  7=CPUSockets
#   8=CPUCores  9=CPUThreads  10=CPUType  11=CPUSpeed  12=HWVendor
#   13=HWModel  14=Serial  15=Syslog  16=Uptime  17=VMToolsVer
#   18=VMToolsRun  19=LastBackup  20=IP  21=Location  22=CIDevice
#   23=vCenter  24=BuildType  25=DBType  26=AppCode  27=Environment
#   28=BuildDate
# =============================================================================

OUT="$1"
if [[ -z "$OUT" ]]; then
    echo "Usage: $0 <output_html_file>" >&2
    exit 1
fi

DATESTAMP=$(date)

# Write stdin to temp file first — allows multiple reads
TMPDAT=$(mktemp /tmp/rhel_inv_html.XXXXXX)
cat > "$TMPDAT"

cat > "$OUT" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Red Hat Linux Inventory — Host Table</title>
  <link rel="stylesheet" href="style.css">
  <style>
    .stats-bar{display:flex;gap:1.5rem;margin-bottom:1.25rem;flex-wrap:wrap}
    .stats-bar .stat{font-size:.875rem;color:var(--text-secondary)}
    .stats-bar .stat strong{color:var(--text-primary);font-weight:600}
    .stats-bar .stat.warn strong{color:var(--accent-red)}
    .controls{display:flex;gap:8px;margin-bottom:1rem;align-items:center;flex-wrap:wrap}
    .controls input,.controls select{padding:6px 10px;font-size:.875rem;border:1px solid var(--border-color);border-radius:.5rem;background:var(--card-bg);color:var(--text-primary);font-family:inherit;outline:none}
    .controls input:focus,.controls select:focus{border-color:#94a3b8}
    .count-badge{font-size:.8rem;color:var(--text-secondary);white-space:nowrap;margin-left:auto}
    .tbl-wrap{overflow-x:auto}
    table{width:100%;border-collapse:collapse;font-size:.8rem;min-width:2000px}
    thead tr{border-bottom:1px solid var(--border-color)}
    thead th{text-align:left;padding:6px 10px;font-size:.7rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em;white-space:nowrap;background:var(--primary-bg)}
    tbody tr{border-bottom:1px solid #f1f5f9}
    tbody tr:last-child{border-bottom:none}
    tbody tr:hover{background:#f8fafc}
    tbody td{padding:7px 10px;vertical-align:middle;white-space:nowrap;color:var(--text-primary)}
    .muted{font-size:.72rem;color:var(--text-secondary)}
    .pill{display:inline-block;padding:2px 8px;border-radius:20px;font-size:.7rem;font-weight:600}
    .pv{background:#eff6ff;color:#1d4ed8}
    .pp{background:#f1f5f9;color:#475569}
    .pe_prod{background:#f0fdf4;color:#166534}
    .pe_uat,.pe_qa{background:#fffbeb;color:#92400e}
    .pe_rnd{background:#f1f5f9;color:#475569}
    .pe_fed{background:var(--warning-bg);color:var(--warning-text);border:1px solid var(--warning-border)}
    .pe_nonfed{background:#f1f5f9;color:#475569}
    .sl_ok{color:#166534;font-weight:600;font-size:.78rem}
    .sl_fail{color:var(--warning-text);font-weight:600;font-size:.78rem}
    .sl_unk{color:var(--text-secondary);font-size:.78rem}
  </style>
</head>
<body>
HTMLEOF

# Write header with live datestamp
cat >> "$OUT" << HEADEREOF

  <div class="container" style="max-width:100%;padding:0">
    <header style="border-radius:0;margin-bottom:0">
      <h1>Red Hat Linux Inventory and Deployment Reports</h1>
      <p>Last updated: ${DATESTAMP}</p>
    </header>
    <div style="padding:1.5rem">
HEADEREOF

# Build stats bar — parse counts from dat via stdin
# We need to re-read the file; collect.sh passes it via stdin so we
# write to a temp file first, then process it.
# NOTE: this script is invoked as: cat $INVENTORYDATA | ./rhel_convert_html.sh $OUT
# so stdin IS the inventory data. Read it all at once into a temp file.

TOTAL_HOSTS=$(grep -v "^#" "$TMPDAT" | wc -l)
VIRT_COUNT=$(grep -v "^#" "$TMPDAT"  | awk '$2=="Virt"' | wc -l)
PHYS_COUNT=$(grep -v "^#" "$TMPDAT"  | awk '$2=="Phys"' | wc -l)
FAIL_COUNT=$(grep -c "SSHFAIL"        "$TMPDAT" 2>/dev/null || echo 0)

cat >> "$OUT" << STATSEOF
      <div class="stats-bar">
        <span class="stat"><strong>${TOTAL_HOSTS}</strong> total hosts</span>
        <span class="stat"><strong>${VIRT_COUNT}</strong> virtual</span>
        <span class="stat"><strong>${PHYS_COUNT}</strong> physical</span>
        <span class="stat warn"><strong>${FAIL_COUNT}</strong> SSH failures</span>
      </div>
STATSEOF

# Write card + controls
cat >> "$OUT" << 'CTRLEOF'
      <div class="card">
        <h2>Host inventory</h2>
        <div class="controls">
          <input type="text" id="search" placeholder="Search hostname, IP..."
                 oninput="ft()" style="min-width:140px;max-width:200px">
          <select id="envF" onchange="ft()">
            <option value="">All environments</option>
            <option>PROD</option><option>UAT</option>
            <option>QA</option><option>RND</option>
          </select>
          <select id="typF" onchange="ft()">
            <option value="">All types</option>
            <option>Virt</option><option>Phys</option>
          </select>
          <select id="osF" onchange="ft()">
            <option value="">All OS versions</option>
            <option>7.9</option><option>8.8</option><option>8.9</option>
            <option>8.10</option><option>9.5</option><option>9.6</option>
            <option>9.7</option><option>9.8</option>
          </select>
          <select id="locF" onchange="ft()">
            <option value="">All locations</option>
          </select>
          <input type="text" id="appF" placeholder="App code..."
                 oninput="ft()" style="min-width:100px;max-width:130px">
          <span class="count-badge" id="cb"></span>
        </div>
        <div class="tbl-wrap">
          <table id="t">
            <thead><tr>
              <th>Host</th><th>Type</th><th>Location</th><th>App Code</th>
              <th>Environment</th><th>Build Date</th><th>OS</th><th>Kernel</th>
              <th>Arch</th><th>Memory&nbsp;(MB)</th><th>Sockets</th><th>Cores</th>
              <th>Threads</th><th>CPU Type</th><th>CPU&nbsp;MHz</th><th>Vendor</th>
              <th>Model</th><th>Serial</th><th>Syslog-ng</th><th>Uptime&nbsp;(d)</th>
              <th>VMTools</th><th>VT&nbsp;Run</th><th>Last Backup</th>
              <th>IP Address</th><th>CI Device</th><th>vCenter</th>
              <th>Build Type</th><th>DB Type</th><th>CMDB Support Group</th>
              <th>Install Status</th><th>Op State</th><th>Fed Enclave</th>
            </tr></thead>
            <tbody id="tb">
CTRLEOF

# Generate table rows from dat file using awk
# Fields: 1=Host 2=Type 3=OS 4=Kernel 5=Arch 6=Mem 7=Skt 8=Cores 9=Thr
#         10=CPUType 11=CPUSpd 12=Vendor 13=Model 14=Serial 15=Syslog
#         16=Uptime 17=VMTools 18=VMRun 19=LastBkp 20=IP 21=Location
#         22=CIDev 23=vCenter 24=BuildType 25=DBType 26=AppCode
#         27=Env 28=BuildDate
# CSV-enriched fields appended: 29=CMDBSupGrp 30=InstallStatus
#                               31=OpState 32=FedEnclave

grep -v "^#" "$TMPDAT" | awk '
function pill_type(v) {
    if (v=="Virt") return "<span class=\"pill pv\">Virt</span>"
    if (v=="Phys") return "<span class=\"pill pp\">Phys</span>"
    return v
}
function pill_env(v) {
    lv = tolower(v)
    if (lv=="prod")    return "<span class=\"pill pe_prod\">"v"</span>"
    if (lv=="uat")     return "<span class=\"pill pe_uat\">"v"</span>"
    if (lv=="qa")      return "<span class=\"pill pe_qa\">"v"</span>"
    if (lv=="rnd")     return "<span class=\"pill pe_rnd\">"v"</span>"
    return v
}
function pill_fed(v) {
    if (v=="Fed")     return "<span class=\"pill pe_fed\">Fed</span>"
    if (v=="Non-Fed") return "<span class=\"pill pe_nonfed\">Non-Fed</span>"
    return v
}
function syslog_class(v) {
    if (v=="active") return "sl_ok"
    if (v=="failed") return "sl_fail"
    return "sl_unk"
}
{
    # Read all fields — CSV fields (29-32) may have commas inside quotes
    # The .dat file is space-delimited for fields 1-28
    # after CMDB enrichment the line has extra comma-sep fields
    # We handle by splitting on spaces for first 28 then remainder
    host=$1; typ=$2; os=$3; kernel=$4; arch=$5; mem=$6
    skt=$7; cores=$8; thr=$9; cputype=$10; cpuspd=$11
    vendor=$12; model=$13; serial=$14; syslog=$15; uptime=$16
    vmtools=$17; vmrun=$18; lastbkp=$19; ip=$20; loc=$21
    cidev=$22; vcenter=$23; buildtype=$24; dbtype=$25
    appcode=$26; env=$27; builddate=$28
    # CMDB fields if present (enriched CSV data joined back)
    cmdb_sg=$29; inst_stat=$30; op_state=$31; fed=$32

    # Defaults for missing CMDB fields
    if (cmdb_sg   == "") cmdb_sg   = "n/a"
    if (inst_stat == "") inst_stat = "n/a"
    if (op_state  == "") op_state  = "n/a"
    if (fed       == "") fed       = "n/a"

    sc = syslog_class(syslog)

    printf "<tr>"
    printf "<td>%s</td>", host
    printf "<td>%s</td>", pill_type(typ)
    printf "<td>%s</td>", loc
    printf "<td>%s</td>", appcode
    printf "<td>%s</td>", pill_env(env)
    printf "<td>%s</td>", builddate
    printf "<td>%s</td>", os
    printf "<td class=\"muted\">%s</td>", kernel
    printf "<td>%s</td>", arch
    printf "<td>%s</td>", mem
    printf "<td>%s</td>", skt
    printf "<td>%s</td>", cores
    printf "<td>%s</td>", thr
    printf "<td class=\"muted\">%s</td>", cputype
    printf "<td>%s</td>", cpuspd
    printf "<td>%s</td>", vendor
    printf "<td class=\"muted\">%s</td>", model
    printf "<td class=\"muted\">%s</td>", serial
    printf "<td class=\"%s\">%s</td>", sc, syslog
    printf "<td>%s</td>", uptime
    printf "<td>%s</td>", vmtools
    printf "<td>%s</td>", vmrun
    printf "<td>%s</td>", lastbkp
    printf "<td>%s</td>", ip
    printf "<td>%s</td>", cidev
    printf "<td class=\"muted\">%s</td>", vcenter
    printf "<td>%s</td>", buildtype
    printf "<td>%s</td>", dbtype
    printf "<td>%s</td>", cmdb_sg
    printf "<td>%s</td>", inst_stat
    printf "<td>%s</td>", op_state
    printf "<td>%s</td>", pill_fed(fed)
    printf "</tr>\n"
}' >> "$OUT"

rm -f "$TMPDAT"

# Close table and add JS filter logic
cat >> "$OUT" << 'FOOTEREOF'
            </tbody>
          </table>
        </div>
      </div>

      <footer>
        <p>&copy; 2026 PNC. OS Engineering.</p>
      </footer>
    </div><!-- /padding wrapper -->
  </div><!-- /container -->

  <script>
    const rows = Array.from(document.querySelectorAll('#tb tr'));

    // Populate location dropdown dynamically from data
    const locSet = new Set();
    rows.forEach(r => {
      const loc = r.querySelectorAll('td')[2];
      if (loc && loc.textContent.trim()) locSet.add(loc.textContent.trim());
    });
    const locSel = document.getElementById('locF');
    Array.from(locSet).sort().forEach(l => {
      const o = document.createElement('option');
      o.value = l; o.textContent = l;
      locSel.appendChild(o);
    });

    // Update total count on load
    document.getElementById('cb').textContent =
      'Showing ' + rows.length + ' of ' + rows.length + ' hosts';

    function ft() {
      const q   = document.getElementById('search').value.toLowerCase();
      const env = document.getElementById('envF').value.toLowerCase();
      const typ = document.getElementById('typF').value.toLowerCase();
      const os  = document.getElementById('osF').value.toLowerCase();
      const loc = document.getElementById('locF').value.toLowerCase();
      const app = document.getElementById('appF').value.toLowerCase();
      let visible = 0;
      rows.forEach(r => {
        const c   = r.querySelectorAll('td');
        const host    = c[0]  ? c[0].textContent.toLowerCase()  : '';
        const type    = c[1]  ? c[1].textContent.toLowerCase()  : '';
        const location= c[2]  ? c[2].textContent.toLowerCase()  : '';
        const appcode = c[3]  ? c[3].textContent.toLowerCase()  : '';
        const env_val = c[4]  ? c[4].textContent.toLowerCase()  : '';
        const os_val  = c[6]  ? c[6].textContent.toLowerCase()  : '';
        const ip_val  = c[23] ? c[23].textContent.toLowerCase() : '';
        const show = (!q   || host.includes(q) || ip_val.includes(q))
                  && (!env || env_val.includes(env))
                  && (!typ || type.includes(typ))
                  && (!os  || os_val.includes(os))
                  && (!loc || location.includes(loc))
                  && (!app || appcode.includes(app));
        r.style.display = show ? '' : 'none';
        if (show) visible++;
      });
      document.getElementById('cb').textContent =
        'Showing ' + visible + ' of ' + rows.length + ' hosts';
    }
  </script>
</body>
</html>
FOOTEREOF

echo "HTML table written to: $OUT"
