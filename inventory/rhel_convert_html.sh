#!/bin/bash
# =============================================================================
# rhel_convert_html.sh — Convert RHEL_INVENTORY CSV to HTML shell + data JS
# =============================================================================
# Reads the enriched CSV (32 comma-separated fields) from stdin.
# Writes TWO files:
#
#   <output_html>          — Page shell (sidebar, controls, empty tbody), ~40KB.
#                            Never contains data rows. Loads instantly.
#   <output_html>.data.js  — All row data as a JS array, ~8-10MB for 22k hosts.
#                            Fetched once by the browser and cached. The page JS
#                            slices 50 rows at a time into the DOM on demand.
#
# This keeps the browser from parsing 22k DOM nodes at load time — the old
# single-file approach produced a 21MB HTML file that locked the browser.
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
# Usage: cat "$INVENTDATACSV" | ./rhel_convert_html.sh "$WEBDIR/$INVENTDATAHTML"
# =============================================================================

OUT="$1"
if [[ -z "$OUT" ]]; then
    echo "Usage: $0 <output_html_file>" >&2
    exit 1
fi

# Data JS file lives alongside the HTML — same name + .data.js
DATA_JS="${OUT}.data.js"
DATA_JS_BASE="$(basename "$DATA_JS")"

# Source config
CONF="$(dirname "$0")/rhel_inv.conf"
[[ -f "$CONF" ]] && . "$CONF"

FOOTER_COMPANY="${SITE_FOOTER_COMPANY:-PNC}"
FOOTER_ORG="${SITE_FOOTER_ORG:-IaaS - Data Center Infrastructure - Linux Engineering}"
DEPLOY_CSV_BASE="${DEPLOYDATACSV##*/}"
UPDATED_HUMAN=$(date '+%b %-d, %Y')
YEAR=$(date +%Y)

# Write stdin to temp file — need two passes (stats + data JS)
TMPCSV=$(mktemp /tmp/rhel_inv_html.XXXXXX)
cat > "$TMPCSV"

# Stats from CSV
TOTAL_HOSTS=$(grep -v "^#" "$TMPCSV" | wc -l)
VIRT_COUNT=$(awk  -F, '!/^#/ && $2=="Virt"'  "$TMPCSV" | wc -l)
PHYS_COUNT=$(awk  -F, '!/^#/ && $2=="Phys"'  "$TMPCSV" | wc -l)
CLOUD_COUNT=$(awk -F, '!/^#/ && $2=="Cloud"' "$TMPCSV" | wc -l)
FAIL_COUNT=0
_fc=$(awk -F, '!/^#/ && ($2=="SSHFAIL" || $7=="SSHFAIL")' "$TMPCSV" | wc -l)
FAIL_COUNT=$(( ${_fc:-0} + 0 ))

# =============================================================================
# Write data JS file — one awk pass, escapes only what JSON requires
# Each row becomes a JS array element: ["field1","field2",...]
# The page JS reads RHEL_INV_DATA and slices/renders on demand.
# =============================================================================
{
    echo "/* RHEL Inventory data — generated $(date) */"
    echo "/* ${TOTAL_HOSTS} hosts */"
    echo "window.RHEL_INV_DATA = ["

    grep -v "^#" "$TMPCSV" | awk -F, '
    function esc(s,    r) {
        # Escape backslash first, then double-quote, then newline/tab
        r = s
        gsub(/\\/, "\\\\", r)
        gsub(/"/, "\\\"", r)
        gsub(/\n/, "\\n", r)
        gsub(/\t/, "\\t", r)
        return r
    }
    {
        printf "[\"" esc($1) "\",\"" esc($2) "\",\"" esc($3) "\",\""
        printf esc($4) "\",\"" esc($5) "\",\"" esc($6) "\",\""
        printf esc($7) "\",\"" esc($8) "\",\"" esc($9) "\",\""
        printf esc($10) "\",\"" esc($11) "\",\"" esc($12) "\",\""
        printf esc($13) "\",\"" esc($14) "\",\"" esc($15) "\",\""
        printf esc($16) "\",\"" esc($17) "\",\"" esc($18) "\",\""
        printf esc($19) "\",\"" esc($20) "\",\"" esc($21) "\",\""
        printf esc($22) "\",\"" esc($23) "\",\"" esc($24) "\",\""
        printf esc($25) "\",\"" esc($26) "\",\"" esc($27) "\",\""
        printf esc($28) "\",\"" esc($29) "\",\"" esc($30) "\",\""
        printf esc($31) "\",\"" esc($32) "\"],\n"
    }'

    echo "];"
} > "$DATA_JS"

# =============================================================================
# Write HTML shell — no data rows, loads instantly
# =============================================================================
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
  <!-- Inventory row data — fetched once, cached by browser -->
  <script src="${DATA_JS_BASE}" defer></script>
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
    <a href="Midrange_Mod/index.html" class="side-link">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/>
        <rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/>
      </svg>
      <span>Midrange Mod Reports</span>
    </a>
    <a class="side-link" data-latest-inventory href="${INVENTDATACSV}" download>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>
      </svg>
      <span>Latest Inventory CSV</span>
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

# OS version options from conf
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

# Location options from conf
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
          <th>Host</th><th>Type</th><th>Location</th><th>App Code</th>
          <th>Environment</th><th>Build Date</th><th>OS</th><th>Kernel</th>
          <th>Architecture</th><th>Memory&nbsp;(MB)</th><th>CPU&nbsp;Sockets</th>
          <th>CPU&nbsp;Cores</th><th>CPU&nbsp;Threads</th><th>CPU Type</th>
          <th>CPU&nbsp;Speed</th><th>Server Vendor</th><th>Server Model</th>
          <th>Serial Num</th><th>Syslog-ng</th><th>Uptime&nbsp;(days)</th>
          <th>VMTools Ver</th><th>VMTools Run</th><th>Last Backup</th>
          <th>IP Address</th><th>CI Device</th><th>vCenter</th>
          <th>Build Type</th><th>DB Type</th><th>CMDB Support Group</th>
          <th>Install Status</th><th>Op State</th><th>Fed Enclave</th>
        </tr></thead>
        <tbody id="tb"></tbody>
      </table>
    </div>
  </div>

  <!-- Count + pagination below the table -->
  <div class="pg-bar">
    <span class="count-badge" id="cb">Loading&#8230;</span>
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
<footer class="foot"><span>&copy; ${YEAR} ${FOOTER_COMPANY} &middot; ${FOOTER_ORG}</span></footer>
</div><!-- /content-shell -->
</div><!-- /app-shell -->

<style>
.pg-bar{display:flex;align-items:center;gap:1rem;flex-wrap:wrap;padding:.85rem 0 .25rem;font-size:.82rem;color:var(--muted)}
.pg-nav{display:flex;align-items:center;gap:.3rem;margin-left:auto}
.pg-btn{display:inline-flex;align-items:center;justify-content:center;min-width:34px;height:34px;padding:0 .5rem;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text);font-size:.82rem;font-weight:600;cursor:pointer;text-decoration:none;transition:background .12s,border-color .12s,color .12s}
.pg-btn:hover{background:#f4f8ff;border-color:#cdd9f5;color:var(--blue)}
.pg-btn.active{background:var(--blue);border-color:var(--blue);color:#fff}
.pg-btn.disabled{opacity:.35;pointer-events:none;cursor:default}
.pg-ellipsis{padding:0 .35rem;color:var(--muted)}
.pg-size-wrap{display:flex;align-items:center;gap:.4rem}
.pg-size-wrap select{padding:.3rem .5rem;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--ink);font-size:.8rem}
</style>

<script>
// =============================================================================
// Inventory table — data-driven, DOM-minimal pagination
// All row data lives in RHEL_INV_DATA (loaded from .data.js).
// Only the current page's rows ever exist in the DOM.
// =============================================================================
(function () {

  // CSS class helpers for pill/badge rendering
  function pillType(v) {
    if (v === 'Virt')  return '<span class="pill pill-virt">Virt</span>';
    if (v === 'Phys')  return '<span class="pill pill-phys">Phys</span>';
    if (v === 'Cloud') return '<span class="pill pill-virt" style="background:#e3f7f4;color:#0f8f85">Cloud</span>';
    return esc(v);
  }
  function pillEnv(v) {
    var m = {'prod':'pill-prod','uat':'pill-uat','qa':'pill-qa','rnd':'pill-rnd'};
    var k = v.toLowerCase();
    return m[k] ? '<span class="pill ' + m[k] + '">' + esc(v) + '</span>' : esc(v);
  }
  function osb(v) {
    var mj = v.charAt(0);
    if (mj === '7' || mj === '8' || mj === '9')
      return '<span class="osb v' + mj + '">' + esc(v) + '</span>';
    return esc(v);
  }
  function syslogSt(v) {
    if (v === 'active')  return '<span class="st st-ok">active</span>';
    if (v === 'failed')  return '<span class="st st-fail">failed</span>';
    return '<span class="st st-unk">' + esc(v) + '</span>';
  }
  function pillFed(v) {
    if (v === 'Fed')     return '<span class="pill pill-fed">Fed</span>';
    if (v === 'Non-Fed') return '<span class="pill pill-nonfed">Non-Fed</span>';
    return esc(v);
  }
  function esc(s) {
    return String(s)
      .replace(/&/g,'&amp;').replace(/</g,'&lt;')
      .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }
  function sub(s) { return '<span class="sub">' + esc(s) + '</span>'; }

  function buildRow(r) {
    // r is a 32-element array from RHEL_INV_DATA
    return '<tr>'
      + '<td>'          + esc(r[0])     + '</td>'   // Host
      + '<td>'          + pillType(r[1])+ '</td>'   // Type
      + '<td>'          + esc(r[2])     + '</td>'   // Location
      + '<td>'          + esc(r[3])     + '</td>'   // App Code
      + '<td>'          + pillEnv(r[4]) + '</td>'   // Environment
      + '<td>'          + esc(r[5])     + '</td>'   // Build Date
      + '<td>'          + osb(r[6])     + '</td>'   // OS
      + '<td>'          + sub(r[7])     + '</td>'   // Kernel
      + '<td>'          + esc(r[8])     + '</td>'   // Architecture
      + '<td>'          + esc(r[9])     + '</td>'   // Memory
      + '<td>'          + esc(r[10])    + '</td>'   // CPU Sockets
      + '<td>'          + esc(r[11])    + '</td>'   // CPU Cores
      + '<td>'          + esc(r[12])    + '</td>'   // CPU Threads
      + '<td>'          + sub(r[13])    + '</td>'   // CPU Type
      + '<td>'          + esc(r[14])    + '</td>'   // CPU Speed
      + '<td>'          + esc(r[15])    + '</td>'   // Server Vendor
      + '<td>'          + sub(r[16])    + '</td>'   // Server Model
      + '<td>'          + sub(r[17])    + '</td>'   // Serial Num
      + '<td>'          + syslogSt(r[18])+'</td>'   // Syslog-ng
      + '<td>'          + esc(r[19])    + '</td>'   // Uptime
      + '<td>'          + esc(r[20])    + '</td>'   // VMTools Ver
      + '<td>'          + esc(r[21])    + '</td>'   // VMTools Run
      + '<td>'          + sub(r[22])    + '</td>'   // Last Backup
      + '<td>'          + esc(r[23])    + '</td>'   // IP Address
      + '<td>'          + esc(r[24])    + '</td>'   // CI Device
      + '<td>'          + sub(r[25])    + '</td>'   // vCenter
      + '<td>'          + esc(r[26])    + '</td>'   // Build Type
      + '<td>'          + sub(r[27])    + '</td>'   // DB Type
      + '<td>'          + esc(r[28])    + '</td>'   // CMDB Support Group
      + '<td>'          + esc(r[29])    + '</td>'   // Install Status
      + '<td>'          + esc(r[30])    + '</td>'   // Op State
      + '<td>'          + pillFed(r[31])+ '</td>'   // Fed Enclave
      + '</tr>';
  }

  var PAGE_SIZE = 50;
  var currentPage = 1;
  var filtered = [];

  var tb     = document.getElementById('tb');
  var cb     = document.getElementById('cb');
  var pgNav  = document.getElementById('pgNav');
  var pgSz   = document.getElementById('pgSize');

  // Wait for data file to load (deferred script), then initialise
  function init() {
    if (typeof window.RHEL_INV_DATA === 'undefined') {
      cb.textContent = 'Loading data\u2026';
      setTimeout(init, 100);
      return;
    }
    ft();
  }

  // ---- Filter ---------------------------------------------------------------
  window.ft = function () {
    if (typeof window.RHEL_INV_DATA === 'undefined') return;

    var q   = (document.getElementById('search').value  || '').trim().toLowerCase();
    var env = (document.getElementById('envF').value    || '').toLowerCase();
    var typ = (document.getElementById('typF').value    || '').toLowerCase();
    var os  = (document.getElementById('osF').value     || '').toLowerCase();
    var loc = (document.getElementById('locF').value    || '').toLowerCase();

    filtered = window.RHEL_INV_DATA.filter(function(r) {
      if (env && r[4].toLowerCase()  !== env) return false;
      if (typ && r[1].toLowerCase()  !== typ) return false;
      if (os  && r[6].toLowerCase()  !== os)  return false;
      if (loc && r[2].toLowerCase()  !== loc) return false;
      if (q) {
        // Search across all 32 fields joined — fast single-pass
        return r.join('\x00').toLowerCase().indexOf(q) !== -1;
      }
      return true;
    });

    currentPage = 1;
    render();
  };

  // ---- Page size change -----------------------------------------------------
  window.pgResize = function () {
    PAGE_SIZE = parseInt(pgSz.value, 10) || 50;
    currentPage = 1;
    render();
  };

  // ---- Render current page --------------------------------------------------
  function render() {
    var total  = filtered.length;
    var pages  = Math.max(1, Math.ceil(total / PAGE_SIZE));
    if (currentPage > pages) currentPage = pages;

    var start  = (currentPage - 1) * PAGE_SIZE;
    var end    = Math.min(start + PAGE_SIZE, total);
    var slice  = filtered.slice(start, end);

    // Build all row HTML in one string — single innerHTML write, much faster
    // than appending individual rows
    tb.innerHTML = slice.map(buildRow).join('');

    // Count badge
    cb.innerHTML = 'Showing <b>' + (total === 0 ? 0 : start + 1)
                 + '&ndash;' + end + '</b> of <b>'
                 + total.toLocaleString('en-US') + '</b> hosts';

    renderPager(pages);
  }

  // ---- Pager ----------------------------------------------------------------
  function renderPager(pages) {
    var cur  = currentPage;
    var show = {};
    [1, pages, cur - 1, cur, cur + 1].forEach(function(p) {
      if (p >= 1 && p <= pages) show[p] = true;
    });
    var nums = Object.keys(show).map(Number).sort(function(a,b){return a-b;});

    var html = '<button class="pg-btn' + (cur <= 1 ? ' disabled' : '')
             + '" onclick="pgGo(' + (cur-1) + ')">&#8249;</button>';
    var prev = 0;
    nums.forEach(function(n) {
      if (n - prev > 1) html += '<span class="pg-ellipsis">&hellip;</span>';
      html += '<button class="pg-btn' + (n === cur ? ' active' : '')
            + '" onclick="pgGo(' + n + ')">' + n + '</button>';
      prev = n;
    });
    html += '<button class="pg-btn' + (cur >= pages ? ' disabled' : '')
          + '" onclick="pgGo(' + (cur+1) + ')">&#8250;</button>';

    pgNav.innerHTML = html;
  }

  // ---- Go to page -----------------------------------------------------------
  window.pgGo = function(n) {
    var pages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
    currentPage = Math.max(1, Math.min(n, pages));
    render();
    var tbl = document.querySelector('.tbl-card');
    if (tbl) tbl.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  init();
})();
</script>
</body>
</html>
HTMLEOF3

rm -f "$TMPCSV"
