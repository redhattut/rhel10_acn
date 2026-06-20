#!/bin/bash
# =============================================================================
# rhel_convert_html.sh — Convert RHEL_INVENTORY.dat to styled HTML table
# =============================================================================
# Usage: cat "$INVENTORYDATA" | ./rhel_convert_html.sh "$WEBDIR/$INVENTDATAHTML"
#
# Column headers match the CSV first-line header exactly (from rhel_inv_collect.sh):
#   Host, Type, Location, App Code, Environment, Build Date, OS, Kernel,
#   Architecture, Memory(MB), CPU Sockets, CPU Cores, CPU Threads, CPU Type,
#   CPU Speed, Server Vendor, Server Model, Serial Num, Syslog-ng,
#   Uptime(days), VMToolsVer, VMToolsRun, LastBackupDate, IP Address,
#   CI Device, vCenter server, BuildType, DBType,
#   CMDB Support Group, CMDB Install Status, CMDB Desired Operational State,
#   Fed Enclave
# =============================================================================

OUT="$1"
if [[ -z "$OUT" ]]; then
    echo "Usage: $0 <output_html_file>" >&2
    exit 1
fi

DATESTAMP=$(date)

# Write stdin to temp file — allows multiple reads
TMPDAT=$(mktemp /tmp/rhel_inv_html.XXXXXX)
cat > "$TMPDAT"

TOTAL_HOSTS=$(grep -v "^#" "$TMPDAT" | wc -l)
VIRT_COUNT=$(awk '!/^#/ && $2=="Virt"' "$TMPDAT" | wc -l)
PHYS_COUNT=$(awk '!/^#/ && $2=="Phys"' "$TMPDAT" | wc -l)
# SSHFAIL: hosts where type field is SSHFAIL or OS field contains SSHFAIL
FAIL_COUNT=$(awk '!/^#/ && ($2=="SSHFAIL" || $3=="SSHFAIL")' "$TMPDAT" | wc -l)
FAIL_COUNT=$(( FAIL_COUNT + 0 ))

cat > "$OUT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Red Hat Linux Inventory — Host Table</title>
  <link rel="stylesheet" href="style.css">
  <style>
    .page-wrap{width:100%}
    .stats-bar{display:flex;gap:1.5rem;margin-bottom:1.25rem;flex-wrap:wrap}
    .stats-bar .stat{font-size:.875rem;color:var(--text-secondary)}
    .stats-bar .stat strong{color:var(--text-primary);font-weight:600}
    .stats-bar .stat.warn strong{color:var(--accent-red)}
    .controls{display:flex;gap:8px;margin-bottom:1rem;align-items:center;flex-wrap:wrap}
    .controls input,.controls select{padding:6px 10px;font-size:.875rem;border:1px solid var(--border-color);border-radius:.5rem;background:var(--card-bg);color:var(--text-primary);font-family:inherit;outline:none}
    .controls input:focus,.controls select:focus{border-color:#94a3b8}
    .count-badge{font-size:.8rem;color:var(--text-secondary);white-space:nowrap;margin-left:auto}
    .tbl-wrap{overflow-x:auto}
    table{width:100%;border-collapse:collapse;font-size:.8rem;min-width:2200px}
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
<div class="page-wrap">
  <header>
    <h1>Red Hat Linux Inventory and Deployment Reports</h1>
    <p>Last updated: ${DATESTAMP} &nbsp;&middot;&nbsp; <a href="index.html" style="color:#93c5fd;text-decoration:none">&#8592; Dashboard</a></p>
  </header>
  <div class="container" style="max-width:100%;padding:1.5rem">

    <div class="stats-bar">
      <span class="stat"><strong>${TOTAL_HOSTS}</strong> total hosts</span>
      <span class="stat"><strong>${VIRT_COUNT}</strong> virtual</span>
      <span class="stat"><strong>${PHYS_COUNT}</strong> physical</span>
      <span class="stat warn"><strong>${FAIL_COUNT}</strong> SSH failures</span>
    </div>

    <div class="card">
      <h2>Host inventory</h2>
      <div class="controls">
        <input type="text" id="search"
               placeholder="Search hostname, environment, location, IP..."
               oninput="ft()" style="min-width:280px;max-width:380px">
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
          <option>8.10</option><option>9.4</option><option>9.5</option>
          <option>9.6</option><option>9.7</option><option>9.8</option>
        </select>
        <select id="locF" onchange="ft()">
          <option value="">All locations</option>
        </select>
        <span class="count-badge" id="cb"></span>
      </div>
      <div class="tbl-wrap">
        <table id="t">
          <thead><tr>
            <th>Host</th>
            <th>Type</th>
            <th>Location</th>
            <th>App Code</th>
            <th>Environment</th>
            <th>Build Date</th>
            <th>OS</th>
            <th>Kernel</th>
            <th>Architecture</th>
            <th>Memory&nbsp;(MB)</th>
            <th>CPU&nbsp;Sockets</th>
            <th>CPU&nbsp;Cores</th>
            <th>CPU&nbsp;Threads</th>
            <th>CPU Type</th>
            <th>CPU&nbsp;Speed</th>
            <th>Server Vendor</th>
            <th>Server Model</th>
            <th>Serial Num</th>
            <th>Syslog-ng</th>
            <th>Uptime&nbsp;(days)</th>
            <th>VMTools Ver</th>
            <th>VMTools Run</th>
            <th>Last Backup Date</th>
            <th>IP Address</th>
            <th>CI Device</th>
            <th>vCenter server</th>
            <th>Build Type</th>
            <th>DB Type</th>
            <th>CMDB Support Group</th>
            <th>CMDB Install Status</th>
            <th>CMDB Desired Operational State</th>
            <th>Fed Enclave</th>
          </tr></thead>
          <tbody id="tb">
HTMLEOF

# Generate table rows from dat file
grep -v "^#" "$TMPDAT" | awk '
function pill_type(v) {
    if (v=="Virt") return "<span class=\"pill pv\">Virt</span>"
    if (v=="Phys") return "<span class=\"pill pp\">Phys</span>"
    return v
}
function pill_env(v) {
    lv=tolower(v)
    if (lv=="prod") return "<span class=\"pill pe_prod\">"v"</span>"
    if (lv=="uat")  return "<span class=\"pill pe_uat\">"v"</span>"
    if (lv=="qa")   return "<span class=\"pill pe_qa\">"v"</span>"
    if (lv=="rnd")  return "<span class=\"pill pe_rnd\">"v"</span>"
    return v
}
function pill_fed(v) {
    if (v=="Fed")     return "<span class=\"pill pe_fed\">Fed</span>"
    if (v=="Non-Fed") return "<span class=\"pill pe_nonfed\">Non-Fed</span>"
    return v
}
function sl(v) {
    if (v=="active") return "sl_ok"
    if (v=="failed") return "sl_fail"
    return "sl_unk"
}
{
    # .dat fields 1-28 space-delimited
    # CSV enrichment adds fields 29-32 comma-separated on the same line
    # Read $1-$28 normally; fields 29+ extracted via split on comma from remainder
    host=$1;typ=$2;os=$3;kernel=$4;arch=$5;mem=$6
    skt=$7;cores=$8;thr=$9;cputype=$10;cpuspd=$11
    vendor=$12;model=$13;serial=$14;syslog=$15;uptime=$16
    vmtools=$17;vmrun=$18;lastbkp=$19;ip=$20;loc=$21
    cidev=$22;vcenter=$23;buildtype=$24;dbtype=$25
    appcode=$26;env=$27;builddate=$28
    # CMDB fields if present
    cmdb_sg=$29; inst=$30; opstate=$31; fed=$32
    if (cmdb_sg=="") cmdb_sg="n/a"
    if (inst=="")    inst="n/a"
    if (opstate=="") opstate="n/a"
    if (fed=="")     fed="n/a"

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
    printf "<td class=\"%s\">%s</td>", sl(syslog), syslog
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
    printf "<td>%s</td>", inst
    printf "<td>%s</td>", opstate
    printf "<td>%s</td>", pill_fed(fed)
    printf "</tr>\n"
}' >> "$OUT"

cat >> "$OUT" << 'FOOTEREOF'
          </tbody>
        </table>
      </div>
    </div>

    <footer><p>&copy; 2026 PNC. OS Engineering.</p></footer>
  </div>
</div>

<script>
  const rows=Array.from(document.querySelectorAll('#tb tr'));

  // Populate location dropdown dynamically from data
  const locSet=new Set();
  rows.forEach(r=>{const l=r.querySelectorAll('td')[2];if(l&&l.textContent.trim())locSet.add(l.textContent.trim());});
  const locSel=document.getElementById('locF');
  Array.from(locSet).sort().forEach(l=>{const o=document.createElement('option');o.value=l;o.textContent=l;locSel.appendChild(o);});

  document.getElementById('cb').textContent='Showing '+rows.length+' of '+rows.length+' hosts';

  function ft(){
    const q  =document.getElementById('search').value.toLowerCase();
    const env=document.getElementById('envF').value.toLowerCase();
    const typ=document.getElementById('typF').value.toLowerCase();
    const os =document.getElementById('osF').value.toLowerCase();
    const loc=document.getElementById('locF').value.toLowerCase();
    let v=0;
    rows.forEach(r=>{
      const c=r.querySelectorAll('td');
      const host =c[0] ?c[0].textContent.toLowerCase():'';
      const type =c[1] ?c[1].textContent.toLowerCase():'';
      const locat=c[2] ?c[2].textContent.toLowerCase():'';
      const enval=c[4] ?c[4].textContent.toLowerCase():'';
      const osval=c[6] ?c[6].textContent.toLowerCase():'';
      const ipval=c[23]?c[23].textContent.toLowerCase():'';
      const full =r.textContent.toLowerCase();
      const show=(!q  ||host.includes(q)||ipval.includes(q)||full.includes(q))
               &&(!env||enval.includes(env))
               &&(!typ||type.includes(typ))
               &&(!os ||osval.includes(os))
               &&(!loc||locat.includes(loc));
      r.style.display=show?'':'none';
      if(show)v++;
    });
    document.getElementById('cb').textContent='Showing '+v+' of '+rows.length+' hosts';
  }
</script>
</body>
</html>
FOOTEREOF

rm -f "$TMPDAT"
echo "HTML table written to: $OUT"
