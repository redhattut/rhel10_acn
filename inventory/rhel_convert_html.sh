#!/bin/bash
# =============================================================================
# rhel_convert_html.sh — Convert RHEL_INVENTORY CSV to styled HTML table
# =============================================================================
# Reads the enriched CSV (32 comma-separated fields) from stdin.
# Writes a styled HTML table to the output file passed as $1.
#
# Uses the new RHEL Fleet Dashboard style (style.css + config.js + app.js).
# The sidebar, stat chips, pill badges, OS badges, and status indicators all
# use CSS classes from style.css exactly — no inline overrides to the design.
#
# CSV column order (matches CSV_HEADER in rhel_inv_collect.sh):
#  1=Host  2=Type  3=Location  4=App Code  5=Environment  6=Build Date
#  7=OS  8=Kernel  9=Architecture  10=Memory(MB)  11=CPU Sockets
#  12=CPU Cores  13=CPU Threads  14=CPU Type  15=CPU Speed
#  16=Server Vendor  17=Server Model  18=Serial Num  19=Syslog-ng
#  20=Uptime(days)  21=VMToolsVer  22=VMToolsRun  23=LastBackupDate
#  24=IP Address  25=CI Device  26=vCenter server  27=BuildType  28=DBType
#  29=CMDB Support Group  30=CMDB Install Status
#  31=CMDB Desired Operational State  32=Fed Enclave
#
# Usage: cat "$INVENTDATACSV" | ./rhel_convert_html.sh "$WEBDIR/inventory.html"
# =============================================================================

OUT="$1"
if [[ -z "$OUT" ]]; then
    echo "Usage: $0 <output_html_file>" >&2
    exit 1
fi

# Source config so we have INVENTDATACSV, DEPLOY_CSV_BASE, UPDATED_HUMAN, etc.
CONF="$(dirname "$0")/rhel_inv.conf"
[[ -f "$CONF" ]] && . "$CONF"

FOOTER_COMPANY="${SITE_FOOTER_COMPANY:-PNC}"
FOOTER_ORG="${SITE_FOOTER_ORG:-IaaS - Data Center Infrastructure - Linux Engineering}"
DEPLOY_CSV_BASE="${DEPLOYDATACSV##*/}"
UPDATED_HUMAN=$(date '+%b %-d, %Y')

# Write stdin to temp file — allows multiple reads
TMPCSV=$(mktemp /tmp/rhel_inv_html.XXXXXX)
cat > "$TMPCSV"

# Stats from CSV (skip comment/header line starting with #)
TOTAL_HOSTS=$(grep -v "^#" "$TMPCSV" | wc -l)
VIRT_COUNT=$(awk  -F, '!/^#/ && $2=="Virt"'              "$TMPCSV" | wc -l)
PHYS_COUNT=$(awk  -F, '!/^#/ && $2=="Phys"'              "$TMPCSV" | wc -l)
CLOUD_COUNT=$(awk -F, '!/^#/ && $2=="Cloud"'             "$TMPCSV" | wc -l)
FAIL_COUNT=0
_fc=$(grep -cE "^[^#].*,(SSHFAIL|SSHFAIL,)" "$TMPCSV" 2>/dev/null) || _fc=0
FAIL_COUNT=$(( ${_fc:-0} + 0 ))

cat > "$OUT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>RHEL Operations — Host Inventory</title>
  <link rel="stylesheet" href="style.css">
  <script src="config.js" defer></script>
  <script src="app.js" defer></script>
</head>
<body>
<div class="app-shell">

<aside class="sidebar">
  <div class="side-brand">
    <span class="brand-mark">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <rect x="3" y="4" width="18" height="16" rx="1.5"/>
        <line x1="3" y1="9" x2="21" y2="9"/>
        <line x1="9" y1="9" x2="9" y2="20"/>
      </svg>
    </span>
    <span class="brand-text">
      <b data-site-title>RHEL Operations</b>
      <span data-site-subtitle>Inventory &amp; Deployment</span>
    </span>
  </div>
  <nav class="side-nav" aria-label="Primary navigation">
    <div class="nav-group">
      <div class="nav-label">Operations</div>
      <a href="index.html" class="side-link">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/>
          <rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/>
        </svg>
        <span>Red Hat Linux Summary</span>
      </a>
      <a href="Monthly_Redhat_Linux_Depoloyment_Report.html" class="side-link">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 3v18h18"/><path d="M7 14l4-4 3 3 5-6"/>
        </svg>
        <span>Deployments</span>
      </a>
      <a href="${INVENTDATAHTML}" class="side-link active">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="4" width="18" height="16" rx="1.5"/>
          <line x1="3" y1="9" x2="21" y2="9"/>
          <line x1="9" y1="9" x2="9" y2="20"/>
        </svg>
        <span>Host Inventory</span>
      </a>
    </div>
    <div class="nav-group">
      <div class="nav-label">External Tools</div>
      <div data-external-links></div>
    </div>
  </nav>
  <div class="side-bottom">
    <div class="nav-label">Data &amp; Reports</div>
    <a href="history.html" class="side-link">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M3 12a9 9 0 1 0 3-6.7L3 8"/>
        <path d="M3 3v5h5"/><path d="M12 7v5l3 2"/>
      </svg>
      <span>Historical Inventory</span>
    </a>
    <a class="side-link" data-latest-inventory href="${INVENTDATACSV}" download>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>
      </svg>
      <span>Latest Inventory CSV</span>
    </a>
    <a class="side-link" href="Midrange_Mod/index.html">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/>
        <rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/>
      </svg>
      <span>Midrange Mod Reports</span>
    </a>
    <div class="side-status">
      <span class="dot"></span>
      <span data-site-updated>Updated ${UPDATED_HUMAN}</span>
    </div>
  </div>
</aside>

<div class="content-shell">
<main class="page">

  <div class="page-head">
    <h1>Host inventory</h1>
    <p>Per-host configuration and CMDB state. Search, filter, or download the latest inventory extract.</p>
  </div>

  <div class="statline">
    <span class="chip-stat"><b>${TOTAL_HOSTS}</b> total hosts</span>
    <span class="chip-stat"><b>${VIRT_COUNT}</b> virtual</span>
    <span class="chip-stat"><b>${PHYS_COUNT}</b> physical</span>
    <span class="chip-stat"><b>${CLOUD_COUNT}</b> cloud</span>
    <span class="chip-stat warn"><b>${FAIL_COUNT}</b> SSH failures</span>
  </div>

  <div class="controls">
    <input type="text" id="search"
           placeholder="Search host, IP, or anything&#8230;"
           oninput="ft()"
           style="min-width:240px;flex:1 1 240px;max-width:380px">
    <select id="envF" onchange="ft()">
      <option value="">All environments</option>
      <option>PROD</option><option>UAT</option>
      <option>QA</option><option>RND</option>
    </select>
    <select id="typF" onchange="ft()">
      <option value="">All types</option>
      <option>Virt</option><option>Phys</option><option>Cloud</option>
    </select>
    <select id="osF" onchange="ft()">
      <option value="">All OS versions</option>
HTMLEOF

# Populate OS version options dynamically from config OS_VERSIONS array
if [[ -f "$CONF" ]]; then
    for ver in "${OS_VERSIONS[@]}"; do
        echo "      <option>${ver}</option>" >> "$OUT"
    done
fi

cat >> "$OUT" << HTMLEOF2
    </select>
    <select id="locF" onchange="ft()">
      <option value="">All locations</option>
HTMLEOF2

# Populate location options from LOCATIONS conf array (same source as config.js)
if [[ -f "$CONF" ]]; then
    for loc_code in "${LOCATIONS[@]}"; do
        echo "      <option>${loc_code}</option>" >> "$OUT"
    done
fi

cat >> "$OUT" << HTMLEOF3
    </select>
    <div class="inventory-actions">
      <a class="button compact" data-latest-inventory href="${INVENTDATACSV}" download>Download CSV</a>
    </div>
  </div>

  <div class="tbl-card">
    <div class="tbl-wrap">
      <table id="t" style="min-width:2300px">
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
          <th>Last Backup</th>
          <th>IP Address</th>
          <th>CI Device</th>
          <th>vCenter</th>
          <th>Build Type</th>
          <th>DB Type</th>
          <th>CMDB Support Group</th>
          <th>Install Status</th>
          <th>Op State</th>
          <th>Fed Enclave</th>
        </tr></thead>
        <tbody id="tb">
HTMLEOF3

# =============================================================================
# Generate table rows from CSV — 32 comma-delimited fields
# Uses CSS classes from style.css exactly:
#   .pill-virt / .pill-phys              — Type column
#   .pill-prod / .pill-uat / .pill-qa / .pill-rnd  — Environment
#   .pill-fed / .pill-nonfed             — Fed Enclave
#   .osb.v7 / .osb.v8 / .osb.v9         — OS version badge
#   .st.st-ok / .st.st-fail / .st.st-unk — Syslog-ng status
#   .sub                                 — muted secondary text
# =============================================================================
grep -v "^#" "$TMPCSV" | awk -F, '
function pill_type(v) {
    if (v == "Virt")  return "<span class=\"pill pill-virt\">Virt</span>"
    if (v == "Phys")  return "<span class=\"pill pill-phys\">Phys</span>"
    if (v == "Cloud") return "<span class=\"pill pill-virt\" style=\"background:#e3f7f4;color:#0f8f85\">Cloud</span>"
    return v
}
function pill_env(v) {
    lv = tolower(v)
    if (lv == "prod") return "<span class=\"pill pill-prod\">"v"</span>"
    if (lv == "uat")  return "<span class=\"pill pill-uat\">"v"</span>"
    if (lv == "qa")   return "<span class=\"pill pill-qa\">"v"</span>"
    if (lv == "rnd")  return "<span class=\"pill pill-rnd\">"v"</span>"
    return v
}
function osb(v) {
    major = substr(v, 1, 1)
    if (major == "7") return "<span class=\"osb v7\">"v"</span>"
    if (major == "8") return "<span class=\"osb v8\">"v"</span>"
    if (major == "9") return "<span class=\"osb v9\">"v"</span>"
    return v
}
function syslog_st(v) {
    if (v == "active")  return "<span class=\"st st-ok\">active</span>"
    if (v == "failed")  return "<span class=\"st st-fail\">failed</span>"
    return "<span class=\"st st-unk\">"v"</span>"
}
function pill_fed(v) {
    if (v == "Fed")     return "<span class=\"pill pill-fed\">Fed</span>"
    if (v == "Non-Fed") return "<span class=\"pill pill-nonfed\">Non-Fed</span>"
    return v
}
{
    host=$1;  typ=$2;   loc=$3;   app=$4;   env=$5;   bdate=$6
    os=$7;    ker=$8;   arch=$9;  mem=$10;  skt=$11;  cores=$12
    thr=$13;  cput=$14; cpus=$15; vend=$16; model=$17; serial=$18
    syslog=$19; uptime=$20; vmtver=$21; vmtrun=$22; lastbkp=$23
    ip=$24;   cidev=$25; vcenter=$26; btype=$27; dbtype=$28
    cmdbsg=$29; inst=$30; opstate=$31; fed=$32

    printf "<tr>\n"
    printf "  <td>%s</td>\n",             host
    printf "  <td>%s</td>\n",             pill_type(typ)
    printf "  <td>%s</td>\n",             loc
    printf "  <td>%s</td>\n",             app
    printf "  <td>%s</td>\n",             pill_env(env)
    printf "  <td>%s</td>\n",             bdate
    printf "  <td>%s</td>\n",             osb(os)
    printf "  <td class=\"sub\">%s</td>\n", ker
    printf "  <td>%s</td>\n",             arch
    printf "  <td>%s</td>\n",             mem
    printf "  <td>%s</td>\n",             skt
    printf "  <td>%s</td>\n",             cores
    printf "  <td>%s</td>\n",             thr
    printf "  <td class=\"sub\">%s</td>\n", cput
    printf "  <td>%s</td>\n",             cpus
    printf "  <td>%s</td>\n",             vend
    printf "  <td class=\"sub\">%s</td>\n", model
    printf "  <td class=\"sub\">%s</td>\n", serial
    printf "  <td>%s</td>\n",             syslog_st(syslog)
    printf "  <td>%s</td>\n",             uptime
    printf "  <td>%s</td>\n",             vmtver
    printf "  <td>%s</td>\n",             vmtrun
    printf "  <td class=\"sub\">%s</td>\n", lastbkp
    printf "  <td>%s</td>\n",             ip
    printf "  <td>%s</td>\n",             cidev
    printf "  <td class=\"sub\">%s</td>\n", vcenter
    printf "  <td>%s</td>\n",             btype
    printf "  <td class=\"sub\">%s</td>\n", dbtype
    printf "  <td>%s</td>\n",             cmdbsg
    printf "  <td>%s</td>\n",             inst
    printf "  <td>%s</td>\n",             opstate
    printf "  <td>%s</td>\n",             pill_fed(fed)
    printf "</tr>\n"
}' >> "$OUT"

cat >> "$OUT" << 'FOOTEREOF'
        </tbody>
      </table>
    </div>
  </div>

  <!-- Count badge + pagination — below the table -->
  <div class="pg-bar">
    <span class="count-badge" id="cb"></span>
    <div class="pg-nav" id="pgNav"></div>
    <div class="pg-size-wrap">
      Show: <select id="pgSize" onchange="pgResize()">
        <option value="50" selected>50</option>
        <option value="100">100</option>
        <option value="250">250</option>
      </select> per page
    </div>
  </div>

</main>
FOOTEREOF
# Footer with conf-driven text (can't use variables inside single-quoted heredoc)
echo "<footer class=\"foot\"><span>&copy; $(date +%Y) ${FOOTER_COMPANY} &middot; ${FOOTER_ORG}</span></footer>" >> "$OUT"
cat >> "$OUT" << 'FOOTEREOF2'
</div><!-- /content-shell -->
</div><!-- /app-shell -->

<style>
.pg-bar{display:flex;align-items:center;gap:1rem;flex-wrap:wrap;padding:.85rem 0 .25rem;font-size:.82rem;color:var(--muted)}
.pg-nav{display:flex;align-items:center;gap:.3rem;margin-left:auto}
.pg-btn{display:inline-flex;align-items:center;justify-content:center;min-width:34px;height:34px;padding:0 .5rem;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text);font-size:.82rem;font-weight:600;cursor:pointer;text-decoration:none;transition:background .12s,border-color .12s,color .12s}
.pg-btn:hover{background:#f4f8ff;border-color:#cdd9f5;color:var(--blue)}
.pg-btn.active{background:var(--blue);border-color:var(--blue);color:#fff}
.pg-btn.disabled{opacity:.35;pointer-events:none}
.pg-ellipsis{padding:0 .35rem;color:var(--muted)}
.pg-size-wrap{display:flex;align-items:center;gap:.4rem}
.pg-size-wrap select{padding:.3rem .5rem;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--ink);font-size:.8rem}
</style>

<script>
(function () {
  const PAGE_SIZE_DEFAULT = 50;
  let pageSize = PAGE_SIZE_DEFAULT;
  let currentPage = 1;

  // All rows in the table
  const allRows = Array.from(document.querySelectorAll('#tb tr'));

  // Filtered rows after applying search/dropdowns
  let filtered = allRows.slice();

  const cb      = document.getElementById('cb');
  const pgNav   = document.getElementById('pgNav');
  const pgSzSel = document.getElementById('pgSize');

  // ---- Filter logic --------------------------------------------------------
  window.ft = function () {
    const q   = (document.getElementById('search')?.value  || '').trim().toLowerCase();
    const env = (document.getElementById('envF')?.value    || '').toLowerCase();
    const typ = (document.getElementById('typF')?.value    || '').toLowerCase();
    const os  = (document.getElementById('osF')?.value     || '').toLowerCase();
    const loc = (document.getElementById('locF')?.value    || '').toLowerCase();

    filtered = allRows.filter(function(r) {
      const c = r.querySelectorAll('td');
      return (!q   || r.textContent.toLowerCase().includes(q))
          && (!env  || (c[4]  && c[4].textContent.trim().toLowerCase()  === env))
          && (!typ  || (c[1]  && c[1].textContent.trim().toLowerCase()  === typ))
          && (!os   || (c[6]  && c[6].textContent.trim().toLowerCase()  === os))
          && (!loc  || (c[2]  && c[2].textContent.trim().toLowerCase()  === loc));
    });

    currentPage = 1;
    render();
  };

  // ---- Page-size change ----------------------------------------------------
  window.pgResize = function () {
    pageSize = parseInt(pgSzSel.value, 10) || PAGE_SIZE_DEFAULT;
    currentPage = 1;
    render();
  };

  // ---- Render a page -------------------------------------------------------
  function render() {
    const total    = filtered.length;
    const pages    = Math.max(1, Math.ceil(total / pageSize));
    if (currentPage > pages) currentPage = pages;
    const start    = (currentPage - 1) * pageSize;
    const end      = Math.min(start + pageSize, total);

    // Show/hide all rows
    allRows.forEach(function(r) { r.hidden = true; });
    filtered.slice(start, end).forEach(function(r) { r.hidden = false; });

    // Count badge
    if (cb) {
      cb.innerHTML = 'Showing <b>' + (total === 0 ? 0 : start + 1) + '&ndash;' + end
                   + '</b> of <b>' + total.toLocaleString('en-US') + '</b> all servers';
    }

    // Pagination buttons
    renderPager(pages);
  }

  // ---- Build pager ---------------------------------------------------------
  function renderPager(pages) {
    if (!pgNav) return;
    const cur = currentPage;

    // Decide which page numbers to show: always first, last, cur-1..cur+1
    const show = new Set([1, pages, cur, cur - 1, cur + 1].filter(p => p >= 1 && p <= pages));
    const nums = Array.from(show).sort(function(a,b){return a-b;});

    let html = '';
    // Prev arrow
    html += '<button class="pg-btn' + (cur <= 1 ? ' disabled' : '') + '" onclick="pgGo(' + (cur-1) + ')">&#8249;</button>';

    let prev = 0;
    nums.forEach(function(n) {
      if (n - prev > 1) html += '<span class="pg-ellipsis">&hellip;</span>';
      html += '<button class="pg-btn' + (n === cur ? ' active' : '') + '" onclick="pgGo(' + n + ')">' + n + '</button>';
      prev = n;
    });

    // Next arrow
    html += '<button class="pg-btn' + (cur >= pages ? ' disabled' : '') + '" onclick="pgGo(' + (cur+1) + ')">&#8250;</button>';

    pgNav.innerHTML = html;
  }

  // ---- Go to page ----------------------------------------------------------
  window.pgGo = function(n) {
    const pages = Math.max(1, Math.ceil(filtered.length / pageSize));
    currentPage = Math.max(1, Math.min(n, pages));
    render();
    // Scroll table into view
    const tbl = document.querySelector('.tbl-card');
    if (tbl) tbl.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  // ---- Initial render ------------------------------------------------------
  ft();
})();
</script>
</body>
</html>
FOOTEREOF2

rm -f "$TMPCSV"
