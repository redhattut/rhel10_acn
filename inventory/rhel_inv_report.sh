#!/bin/bash
# =============================================================================
# rhel_inv_report.sh — Inventory report and HTML page generator
# =============================================================================
# Generates:
#   config.js                                       — live KPI data for app.js
#   index.html                                      — Infrastructure Summary
#   deployments.html                                — Deployment Activity
#   Monthly_Redhat_Linux_Depoloyment_Report.html    — 12-month history
#   Annual_Redhat_Linux_Depoloyment_Report.html     — all-years history
#   Location.html                                   — Inventory by datacenter
#   Application.html                                — Inventory by app code
#   Releases.html                                   — OS release detail
#   history.html                                    — Historical download archive
#
# All HTML pages use style.css + config.js + app.js.
# style.css and app.js are static assets copied to WEBDIR by rhel_inv_run.sh.
# config.js is overwritten every run with live data from this script.
#
# Test mode: all output goes to ${BASE_DIR}/test/webdir/ (set by rhel_inv_run.sh
# exports before calling this script).
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found" >&2
    exit 1
fi
. "$CONF"
. "$(dirname "$0")/rhel_utils.sh"

export LC_NUMERIC=en_US.ISO8859-1
export LC_TIME=en_US.ISO8859-1

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# --- Validate ----------------------------------------------------------------
if [[ ! -f "$INVENTORYDATA" ]]; then
    log ERROR "INVENTORYDATA not found: $INVENTORYDATA"; exit 1
fi
mkdir -p "$WEBDIR"

RECCOUNT=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
log INFO "Generating reports from $INVENTORYDATA ($RECCOUNT records)"
log INFO "Publishing to: $WEBDIR"

YEAR=$(date +%Y)
UPDATED_HUMAN=$(date '+%b %-d, %Y')
DEPLOY_CSV_BASE="${DEPLOYDATACSV##*/}"
PKG_CSV_BASE=$(basename "${PACKAGEDATA:-RHEL_PACKAGES_v2.csv}")

# =============================================================================
# Intermediate data — single awk pass producing four lookup files
# .dat fields: $1=Host $2=Type(Virt/Phys) $3=OS $21=Location
#              $26=AppCode $27=Env $28=BuildDate
# =============================================================================
log INFO "Building intermediate data files"
rm -f "$APPDATAPLAT" "$APPDATAREL" "$LOCDATAPLAT" "$LOCDATAREL"

awk -v lp="$LOCDATAPLAT" -v lr="$LOCDATAREL" \
    -v ap="$APPDATAPLAT" -v ar="$APPDATAREL" \
    '!/^#/ {
        print $21 " " $2  >> lp
        print $21 " " $3  >> lr
        print $26 " " $2  >> ap
        print $26 " " $3  >> ar
    }' "$INVENTORYDATA"

log INFO "Intermediate files built"

# =============================================================================
# Summary counts — single awk pass
# =============================================================================
log INFO "Computing summary counts"

# Build dynamic awk snippets from OS_VERSIONS config array
OS_AWK_COUNTS=""
OS_AWK_PRINTF=""
for ver in "${OS_VERSIONS[@]}"; do
    varname="OS_${ver//./_}"
    OS_AWK_COUNTS+="    if (\$3==\"${ver}\") ${varname}++
"
    OS_AWK_PRINTF+="    printf \"${varname}=%d\\n\", ${varname}+0
"
done

eval "$(awk \
    'BEGIN{total=0;virt=0;phys=0;cloud=0;fail=0
           ernd=0;euat=0;eqa=0;eprod=0
           lgf0=0;lgf1=0;lgf2=0;lazce=0;laze2=0}
    !/^#/{
        total++
        loc=$21
        sub(/^Greenfield-/,"",loc)
        if (loc=="AZCE"||loc=="AZE2") cloud++
        else if ($2=="Virt") virt++
        else if ($2=="Phys") phys++
        if ($2=="SSHFAIL"||$3=="SSHFAIL") fail++
        if ($27=="RND")  ernd++
        if ($27=="UAT")  euat++
        if ($27=="QA")   eqa++
        if ($27=="PROD") eprod++
        if (loc=="GF0")  lgf0++
        if (loc=="GF1")  lgf1++
        if (loc=="GF2")  lgf2++
        if (loc=="AZCE") lazce++
        if (loc=="AZE2") laze2++
    }
    END{
        printf "TOTAL_HOSTS=%d\n",    total
        printf "VIRTUAL_SERVERS=%d\n", virt
        printf "PHYSICAL_SERVERS=%d\n",phys
        printf "CLOUD_SERVERS=%d\n",   cloud
        printf "SSHFAIL=%d\n",         fail
        printf "ENV_RND=%d\n",  ernd
        printf "ENV_UAT=%d\n",  euat
        printf "ENV_QA=%d\n",   eqa
        printf "ENV_PROD=%d\n", eprod
        printf "LOC_GF0=%d\n",  lgf0
        printf "LOC_GF1=%d\n",  lgf1
        printf "LOC_GF2=%d\n",  lgf2
        printf "LOC_AZCE=%d\n", lazce
        printf "LOC_AZE2=%d\n", laze2
    }' "$INVENTORYDATA")"

eval "$(awk '{
'"$OS_AWK_COUNTS"'
}
END{
'"$OS_AWK_PRINTF"'
}' "$INVENTORYDATA")"

log INFO "Virtual: $VIRTUAL_SERVERS  Physical: $PHYSICAL_SERVERS  Cloud: $CLOUD_SERVERS  SSH failures: $SSHFAIL"

# =============================================================================
# config.js — RHEL versions JSON fragment
# =============================================================================
RHEL_VERSIONS_JSON=""
for ver in "${OS_VERSIONS[@]}"; do
    varname="OS_${ver//./_}"
    count="${!varname:-0}"
    major="${ver%%.*}"
    [[ -n "$RHEL_VERSIONS_JSON" ]] && RHEL_VERSIONS_JSON+=","
    RHEL_VERSIONS_JSON+="
    { \"version\": \"${ver}\", \"count\": ${count}, \"major\": ${major} }"
done

# =============================================================================
# config.js — historical CSV file list (newest first, up to 14 entries)
# =============================================================================
HIST_JSON_ROWS=""
if [[ -d "${WEBDIR}/historical_data" ]]; then
    while IFS= read -r fpath; do
        [[ -z "$fpath" ]] && continue
        fname=$(basename "$fpath")
        fsize=$(du -sh "$fpath" 2>/dev/null | cut -f1)
        fts=$(stat -c '%y' "$fpath" 2>/dev/null | awk '{print $1, $2}' | cut -c1-16)
        fts_human=$(date -d "$fts" '+%b %-d, %Y %-I:%M %p %Z' 2>/dev/null || echo "$fts")
        [[ -n "$HIST_JSON_ROWS" ]] && HIST_JSON_ROWS+=","
        HIST_JSON_ROWS+="
    { \"filename\": \"${fname}\", \"timestamp\": \"${fts_human}\", \"size\": \"${fsize}\", \"href\": \"historical_data/${fname}\" }"
    done < <(find "${WEBDIR}/historical_data" -maxdepth 1 -name "*.csv" \
             -printf '%T@ %p\n' 2>/dev/null \
             | sort -rn | awk '{print $2}' | head -14)
fi

# =============================================================================
# config.js — locations JSON fragment (from LOCATIONS array in conf)
# Each location count is the matching LOC_XXX variable computed above.
# =============================================================================
LOCATIONS_JSON=""
for loc_code in "${LOCATIONS[@]}"; do
    varname="LOC_${loc_code//-/_}"   # e.g. AZCE → LOC_AZCE, AZE2 → LOC_AZE2
    count="${!varname:-0}"
    [[ -n "$LOCATIONS_JSON" ]] && LOCATIONS_JSON+=","
    LOCATIONS_JSON+="
    { \"name\": \"${loc_code}\", \"count\": ${count} }"
done

# =============================================================================
# config.js — externalLinks JSON fragment (from EXTERNAL_LINKS array in conf)
# Format per entry: "Label|href"
# =============================================================================
EXTLINKS_JSON=""
for entry in "${EXTERNAL_LINKS[@]}"; do
    label="${entry%%|*}"
    href="${entry##*|}"
    [[ -n "$EXTLINKS_JSON" ]] && EXTLINKS_JSON+=","
    EXTLINKS_JSON+="
    { \"label\": \"${label}\", \"href\": \"${href}\" }"
done

# =============================================================================
# Write config.js
# =============================================================================
log INFO "Generating config.js"

cat > "${WEBDIR}/config.js" << CONFIGEOF
window.RHEL_CONFIG = {
  site: {
    title:        "${SITE_TITLE:-RHEL Operations}",
    subtitle:     "${SITE_SUBTITLE:-Inventory & Deployment}",
    organization: "${SITE_ORG:-OS Engineering · PNC}",
    updated:      "${UPDATED_HUMAN}"
  },
  totals: {
    totalHosts:   ${TOTAL_HOSTS},
    virtual:      ${VIRTUAL_SERVERS},
    physical:     ${PHYSICAL_SERVERS},
    cloud:        ${CLOUD_SERVERS},
    sshFailures:  ${SSHFAIL}
  },
  rhelVersions: [${RHEL_VERSIONS_JSON}
  ],
  environments: [
    { "name": "PROD", "count": ${ENV_PROD} },
    { "name": "QA",   "count": ${ENV_QA}   },
    { "name": "UAT",  "count": ${ENV_UAT}  },
    { "name": "RND",  "count": ${ENV_RND}  }
  ],
  locations: [${LOCATIONS_JSON}
  ],
  downloads: {
    latestInventoryCsv: "${INVENTDATACSV}",
    inventoryText:      "${INVENTDATATEXT}",
    inventoryHtml:      "${INVENTDATAHTML}",
    packageInventory:   "${PKG_CSV_BASE}",
    midrangeInventory:  "Midrange_INVENTORY.csv",
    deploymentCsv:      "${DEPLOY_CSV_BASE}"
  },
  externalLinks: [${EXTLINKS_JSON}
  ],
  historicalFiles: [${HIST_JSON_ROWS}
  ]
};
CONFIGEOF

log INFO "config.js written"

# =============================================================================
# Shared helpers
# =============================================================================

# _sidebar <active-page>
# active-page: index | deployments | inventory | history | "" (none)
_sidebar() {
    local active="$1"
    local a_idx="" a_dep="" a_inv="" a_his=""
    case "$active" in
        index)       a_idx=" active" ;;
        deployments) a_dep=" active" ;;
        inventory)   a_inv=" active" ;;
        history)     a_his=" active" ;;
    esac

    cat << SIDEEOF
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
      <a href="index.html" class="side-link${a_idx}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/>
          <rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/>
        </svg>
        <span>Infrastructure Summary</span>
      </a>
      <a href="deployments.html" class="side-link${a_dep}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 3v18h18"/><path d="M7 14l4-4 3 3 5-6"/>
        </svg>
        <span>Deployments</span>
      </a>
      <a href="inventory.html" class="side-link${a_inv}">
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
    <a href="history.html" class="side-link${a_his}">
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
    <a class="side-link" href="${DEPLOY_CSV_BASE}" download>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>
      </svg>
      <span>Deployment CSV</span>
    </a>
    <div class="side-status">
      <span class="dot"></span>
      <span data-site-updated>Updated ${UPDATED_HUMAN}</span>
    </div>
  </div>
</aside>
SIDEEOF
}

# _html_head <title>
_html_head() {
    cat << HEADEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>${1}</title>
  <link rel="stylesheet" href="style.css">
  <script src="config.js" defer></script>
  <script src="app.js" defer></script>
</head>
<body>
<div class="app-shell">
HEADEOF
}

# _html_foot — closes content-shell, app-shell, body, html
_html_foot() {
    cat << FOOTEOF
<footer class="foot"><span>&copy; ${YEAR} PNC &middot; OS Engineering</span></footer>
</div><!-- /content-shell -->
</div><!-- /app-shell -->
</body>
</html>
FOOTEOF
}

# =============================================================================
# RPT_Main — index.html
# =============================================================================
RPT_Main() {
    _html_head "RHEL Operations — Infrastructure Summary"
    _sidebar "index"

    cat << MAINEOF
<div class="content-shell">
<main class="page">

  <div class="page-head">
    <h1>Infrastructure Summary</h1>
    <p>Current RHEL inventory, platform distribution, and operational status across managed environments.</p>
  </div>

  <section class="kpis">
    <div class="kpi">
      <span class="ic ic-blue">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="4" width="18" height="16" rx="1.5"/>
          <line x1="3" y1="9" x2="21" y2="9"/>
          <line x1="9" y1="9" x2="9" y2="20"/>
        </svg>
      </span>
      <span class="meta">
        <span class="num" data-kpi="virtual">${VIRTUAL_SERVERS}</span>
        <span class="lab">Virtual servers</span>
      </span>
    </div>
    <div class="kpi">
      <span class="ic ic-violet">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/>
          <rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/>
        </svg>
      </span>
      <span class="meta">
        <span class="num" data-kpi="physical">${PHYSICAL_SERVERS}</span>
        <span class="lab">Physical servers</span>
      </span>
    </div>
    <div class="kpi">
      <span class="ic ic-teal">&#9729;</span>
      <span class="meta">
        <span class="num" data-kpi="cloud">${CLOUD_SERVERS}</span>
        <span class="lab">Cloud servers</span>
      </span>
    </div>
    <div class="kpi alert">
      <span class="ic ic-red">!</span>
      <span class="meta">
        <span class="num" data-kpi="ssh">${SSHFAIL}</span>
        <span class="lab">Hosts unreachable by SSH</span>
      </span>
    </div>
  </section>

  <section class="row split">
    <div class="card">
      <div class="card-head">
        <span class="chip chip-blue">#</span>
        <h2>RHEL by version</h2>
        <span class="sub">major release</span>
      </div>
      <div class="donut-wrap">
        <div class="donut" data-rhel-donut>
          <div class="donut-center">
            <span class="big" data-classified-total>${TOTAL_HOSTS}</span>
            <span class="cap">classified hosts</span>
          </div>
        </div>
        <div class="donut-legend" data-rhel-major-legend></div>
      </div>
    </div>
    <div class="card">
      <div class="card-head">
        <span class="chip chip-teal">#</span>
        <h2>RHEL OS by minor version</h2>
        <span class="sub">share of classified hosts</span>
      </div>
      <div class="bars" data-minor-versions></div>
    </div>
  </section>

  <section class="row halves">
    <div class="card">
      <div class="card-head">
        <span class="chip chip-violet">&#9638;</span>
        <h2>Environments</h2>
        <span class="sub">share of total hosts</span>
      </div>
      <div class="bars" data-environments></div>
    </div>
    <div class="card">
      <div class="card-head">
        <span class="chip chip-green">&#8982;</span>
        <h2>Datacenters</h2>
        <span class="sub">share of total hosts</span>
      </div>
      <div class="bars" data-locations></div>
    </div>
  </section>

  <section class="card">
    <div class="card-head">
      <span class="chip chip-amber">&#8681;</span>
      <h2>Data &amp; reports</h2>
      <span class="sub">downloads and report pages</span>
    </div>
    <div class="res-grid">
      <div class="res-col">
        <h3>Raw formats</h3>
        <ul class="res-list">
          <li><a href="${INVENTDATATEXT}" download>Text inventory<span class="ar">&#8594;</span></a></li>
          <li><a data-latest-inventory href="${INVENTDATACSV}" download>Inventory CSV<span class="ar">&#8594;</span></a></li>
          <li><a href="${PKG_CSV_BASE}" download>Package inventory CSV<span class="ar">&#8594;</span></a></li>
          <li><a href="Midrange_INVENTORY.csv" download>Midrange inventory CSV<span class="ar">&#8594;</span></a></li>
        </ul>
      </div>
      <div class="res-col">
        <h3>Inventory reports</h3>
        <ul class="res-list">
          <li><a href="Location.html">By datacenter<span class="ar">&#8594;</span></a></li>
          <li><a href="Application.html">By application code<span class="ar">&#8594;</span></a></li>
          <li><a href="Releases.html">Release detail<span class="ar">&#8594;</span></a></li>
        </ul>
      </div>
      <div class="res-col">
        <h3>Deployment reports</h3>
        <ul class="res-list">
          <li><a href="deployments.html">Monthly deployments<span class="ar">&#8594;</span></a></li>
          <li><a href="Annual_Redhat_Linux_Depoloyment_Report.html">Annual deployments<span class="ar">&#8594;</span></a></li>
          <li><a href="${DEPLOY_CSV_BASE}" download>Deployment CSV<span class="ar">&#8594;</span></a></li>
        </ul>
      </div>
    </div>
  </section>

</main>
MAINEOF
    _html_foot
}

# =============================================================================
# RPT_History — history.html
# =============================================================================
RPT_History() {
    _html_head "RHEL Operations — Historical Inventory"
    _sidebar "history"

    cat << HISTEOF
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Historical Inventory Downloads</h1>
    <p>Recent timestamped RHEL inventory CSV snapshots available for download.</p>
  </div>
  <section class="card">
    <div class="card-head">
      <span class="chip chip-amber">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 12a9 9 0 1 0 3-6.7L3 8"/>
          <path d="M3 3v5h5"/><path d="M12 7v5l3 2"/>
        </svg>
      </span>
      <h2>RHEL inventory archive</h2>
      <span class="sub">newest first</span>
    </div>
    <div class="history-note">
      The newest file is also available from <strong>Latest Inventory CSV</strong> in the sidebar.
    </div>
    <div class="history-wrap">
      <table class="history-table">
        <thead><tr>
          <th>Status</th>
          <th>Filename</th>
          <th>Generated</th>
          <th>Size</th>
          <th></th>
        </tr></thead>
        <tbody data-history-rows></tbody>
      </table>
    </div>
  </section>
</main>
HISTEOF
    _html_foot
}

# =============================================================================
# RPT_Release_detail — Releases.html
# =============================================================================
RPT_Release_detail() {
    local GRAND
    GRAND=$(grep -v "^#" "$INVENTORYDATA" | wc -l)

    _html_head "RHEL Operations — Release Detail"
    _sidebar ""

    cat << RELEOF
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Release Detail</h1>
    <p>Counts of hosts by RHEL release version.</p>
  </div>
  <section class="card">
    <div class="card-head">
      <span class="chip chip-teal">#</span>
      <h2>RHEL release counts</h2>
      <span class="sub">${GRAND} total hosts</span>
    </div>
    <table style="width:100%;border-collapse:collapse">
      <thead><tr>
        <th style="text-align:left;padding:.8rem .9rem;font-size:.72rem;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.03em;background:#f6f9fe;border-bottom:1px solid var(--line)">Release</th>
        <th style="text-align:right;padding:.8rem .9rem;font-size:.72rem;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.03em;background:#f6f9fe;border-bottom:1px solid var(--line)">Count</th>
      </tr></thead>
      <tbody>
RELEOF

    awk '!/^#/{print $3}' "$INVENTORYDATA" | sort | uniq -c | sort -rn \
    | while read -r TOT REL; do
        [[ "${REL:0:1}" == "S" ]] && LABEL="SuSE $REL" || LABEL="RHEL $REL"
        echo "        <tr><td style=\"padding:.7rem .9rem;border-bottom:1px solid var(--line-soft);font-size:.84rem\">${LABEL}</td><td style=\"padding:.7rem .9rem;text-align:right;font-weight:650;border-bottom:1px solid var(--line-soft);font-size:.84rem\">${TOT}</td></tr>"
    done

    cat << RELBEOF
        <tr style="border-top:2px solid var(--line)">
          <td style="padding:.7rem .9rem;font-weight:700;color:var(--ink)">Grand Total</td>
          <td style="padding:.7rem .9rem;text-align:right;font-weight:700;color:var(--ink)">${GRAND}</td>
        </tr>
      </tbody>
    </table>
  </section>
</main>
RELBEOF
    _html_foot
}

# =============================================================================
# RPT_by_Location — Location.html
# =============================================================================
RPT_by_Location() {
    _html_head "RHEL Operations — Inventory by Datacenter"
    _sidebar ""

    cat << LOCEOF
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Inventory by Datacenter</h1>
    <p>Host counts and OS distribution per datacenter location.</p>
  </div>
  <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:1.4rem">
LOCEOF

    awk '!/^\?/{print $1}' "$LOCDATAPLAT" | sort -u \
    | while read -r LOC; do
        [[ -z "$LOC" ]] && continue
        STOTAL=$(grep -c "^$LOC " "$LOCDATAPLAT" 2>/dev/null || echo 0)
        STOTAL=$(( STOTAL + 0 ))
        [[ $STOTAL -eq 0 ]] && continue

        echo "    <div class=\"card\">"
        echo "      <div class=\"card-head\">"
        echo "        <span class=\"chip chip-teal\" style=\"width:auto;padding:0 .65rem;font-size:.8rem;font-weight:700\">${LOC}</span>"
        echo "        <h2 style=\"font-size:.95rem\">${LOC}</h2>"
        echo "        <span class=\"sub\">${STOTAL} hosts</span>"
        echo "      </div>"

        echo "      <div style=\"font-size:.68rem;font-weight:750;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.5rem\">Platform</div>"
        grep "^$LOC " "$LOCDATAPLAT" | awk '{print $2}' | sort | uniq -c | sort -rn \
        | while read -r TOT PLAT; do
            echo "      <div style=\"display:flex;justify-content:space-between;padding:.4rem 0;border-bottom:1px solid var(--line-soft);font-size:.84rem\"><span style=\"color:var(--text)\">${PLAT}</span><span style=\"font-weight:650;color:var(--ink)\">${TOT}</span></div>"
        done

        echo "      <div style=\"font-size:.68rem;font-weight:750;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin:.85rem 0 .5rem\">OS Versions</div>"
        grep "^$LOC " "$LOCDATAREL" | awk '{print $2}' | sort | uniq -c | sort -rn \
        | while read -r TOT REL; do
            [[ -z "$REL" ]] && continue
            echo "      <div style=\"display:flex;justify-content:space-between;padding:.4rem 0;border-bottom:1px solid var(--line-soft);font-size:.84rem\"><span style=\"color:var(--text)\">RHEL ${REL}</span><span style=\"font-weight:650;color:var(--ink)\">${TOT}</span></div>"
        done

        echo "      <div style=\"display:flex;justify-content:space-between;padding:.5rem 0;margin-top:.3rem;font-size:.88rem;font-weight:700;color:var(--ink)\"><span>Total</span><span>${STOTAL}</span></div>"
        echo "    </div>"
    done

    cat << LOCBEOF
  </div>
</main>
LOCBEOF
    _html_foot
}

# =============================================================================
# RPT_by_Mnemonic — Application.html
# =============================================================================
RPT_by_Mnemonic() {
    local GRAND
    GRAND=$(grep -v "^#" "$INVENTORYDATA" | wc -l)

    _html_head "RHEL Operations — Inventory by Application Code"
    _sidebar ""

    cat << APPEOF2
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Inventory by Application Code</h1>
    <p>Host counts, platform split, and OS versions grouped by application mnemonic.</p>
  </div>
  <section class="card">
    <div class="card-head">
      <span class="chip chip-violet">&#9638;</span>
      <h2>Application codes</h2>
      <span class="sub" id="appCount"></span>
    </div>
    <div class="controls" style="margin-bottom:1rem">
      <input type="text" id="appSearch" placeholder="Filter by app code&#8230;" oninput="filterApp()" style="min-width:220px">
    </div>
    <div class="tbl-card">
      <div class="tbl-wrap">
        <table id="appTable" style="width:100%">
          <thead><tr>
            <th onclick="sortApp(0)" style="cursor:pointer">App Code &#8597;</th>
            <th onclick="sortApp(1)" style="cursor:pointer;text-align:right">Total &#8597;</th>
            <th style="text-align:right">Virt</th>
            <th style="text-align:right">Phys</th>
            <th>OS Versions</th>
          </tr></thead>
          <tbody id="appBody">
APPEOF2

    awk '!/^#/{print $26}' "$INVENTORYDATA" | sort -u \
    | while read -r APP; do
        [[ -z "$APP" || "$APP" == "n/a" ]] && continue
        STOTAL=$(grep -c "^$APP " "$APPDATAPLAT" 2>/dev/null || echo 0)
        STOTAL=$(( STOTAL + 0 ))
        VIRT=$(grep "^$APP " "$APPDATAPLAT" | awk '$2=="Virt"' | wc -l)
        PHYS=$(grep "^$APP " "$APPDATAPLAT" | awk '$2=="Phys"' | wc -l)
        APPLO=$(echo "$APP" | tr '[:upper:]' '[:lower:]')
        OS_LIST=$(grep "^$APP " "$APPDATAREL" | awk '{print $2}' \
            | sort | uniq -c | sort -rn | head -5 \
            | awk 'BEGIN{sep=""} {printf "%sRHEL %s [%s]", sep, $2, $1; sep=", "}')
        echo "            <tr data-app=\"${APPLO}\" data-total=\"${STOTAL}\">"
        echo "              <td style=\"font-weight:600;color:var(--ink)\">${APP}</td>"
        echo "              <td style=\"text-align:right;font-weight:700\">${STOTAL}</td>"
        echo "              <td style=\"text-align:right\" class=\"sub\">${VIRT}</td>"
        echo "              <td style=\"text-align:right\" class=\"sub\">${PHYS}</td>"
        echo "              <td class=\"sub\">${OS_LIST}</td>"
        echo "            </tr>"
    done

    cat << APPJSEOF
            <tr style="border-top:2px solid var(--line)">
              <td style="font-weight:700;color:var(--ink)">Grand Total</td>
              <td style="text-align:right;font-weight:700">${GRAND}</td>
              <td colspan="3"></td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </section>
</main>
<footer class="foot"><span>&copy; ${YEAR} PNC &middot; OS Engineering</span></footer>
</div><!-- /content-shell -->
</div><!-- /app-shell -->
<script>
(function(){
  const rows = Array.from(document.querySelectorAll('#appBody tr[data-app]'));
  const countEl = document.getElementById('appCount');
  if (countEl) countEl.textContent = rows.length + ' application codes';
  let sortDir = 1;
  window.sortApp = function(col) {
    sortDir *= -1;
    rows.sort(function(a, b) {
      const va = a.querySelectorAll('td')[col].textContent.trim();
      const vb = b.querySelectorAll('td')[col].textContent.trim();
      return col === 0 ? va.localeCompare(vb) * sortDir
                       : (parseInt(va) - parseInt(vb)) * sortDir;
    });
    const tb = document.getElementById('appBody');
    rows.forEach(function(r){ tb.insertBefore(r, tb.lastElementChild); });
  };
  window.filterApp = function() {
    const q = (document.getElementById('appSearch').value || '').toLowerCase();
    let v = 0;
    rows.forEach(function(r) {
      const show = !q || r.dataset.app.includes(q);
      r.hidden = !show;
      if (show) v++;
    });
    if (countEl) countEl.textContent = v + ' of ' + rows.length + ' application codes';
  };
})();
</script>
</body>
</html>
APPJSEOF
}

# =============================================================================
# _render_deploy_card <heading> <datafile>
# Shared helper for all deployment report pages
# =============================================================================
_render_deploy_card() {
    local heading="$1"
    local datafile="$2"

    local total=0 virt=0 phys=0 cloud=0
    eval "$(awk 'BEGIN{t=0;v=0;p=0;c=0}
        /Microsoft_Corporation/{c++;t++;next}
        $3=="Virt"{v++;t++;next}
        $3=="Phys"{p++;t++;next}
        {t++}
        END{printf "total=%d virt=%d phys=%d cloud=%d",t,v,p,c}' "$datafile")"

    local maxcnt=1
    maxcnt=$(awk '{print $4}' "$datafile" | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
    [[ $maxcnt -lt 1 ]] && maxcnt=1

    cat << DEOF
    <section class="card">
      <div class="month-head">
        <h2>${heading}</h2>
        <span class="total"><b>${total}</b> deployments</span>
      </div>
      <div class="month-grid">
        <div>
          <h3>Server type</h3>
          <div class="dlist">
DEOF

    local virt_pct=100
    local phys_pct=0; [[ $total -gt 0 ]] && phys_pct=$(awk -v n="$phys" -v d="$total" 'BEGIN{printf "%.1f", n/d*100}')
    local cloud_pct=0; [[ $total -gt 0 ]] && cloud_pct=$(awk -v n="$cloud" -v d="$total" 'BEGIN{printf "%.1f", n/d*100}')

    [[ $virt  -gt 0 ]] && echo "            <div class=\"drow\"><div class=\"drow-top\"><span class=\"nm\">Virtual</span><span class=\"ct\">${virt}</span></div><div class=\"track\"><span style=\"width:${virt_pct}%;background:var(--indigo)\"></span></div></div>"
    [[ $phys  -gt 0 ]] && echo "            <div class=\"drow\"><div class=\"drow-top\"><span class=\"nm\">Physical</span><span class=\"ct\">${phys}</span></div><div class=\"track\"><span style=\"width:${phys_pct}%;background:var(--violet)\"></span></div></div>"
    [[ $cloud -gt 0 ]] && echo "            <div class=\"drow\"><div class=\"drow-top\"><span class=\"nm\">Cloud</span><span class=\"ct\">${cloud}</span></div><div class=\"track\"><span style=\"width:${cloud_pct}%;background:var(--teal)\"></span></div></div>"

    cat << 'DEOF2'
          </div>
        </div>
        <div>
          <h3>RHEL versions</h3>
          <div class="dlist">
DEOF2

    local _maxcnt="$maxcnt"
    awk -v mx="$_maxcnt" '{print $4}' "$datafile" | sort | uniq -c | sort -rn \
    | while read -r cnt ver; do
        [[ -z "$cnt" || -z "$ver" ]] && continue
        local major="${ver%%.*}"
        local pct; pct=$(awk -v n="$cnt" -v d="$_maxcnt" 'BEGIN{printf "%.1f", n/d*100}')
        echo "            <div class=\"drow\"><div class=\"drow-top\"><span class=\"nm\">RHEL ${ver}</span><span class=\"ct\">${cnt}</span></div><div class=\"track\"><span style=\"width:${pct}%;background:var(--v${major})\"></span></div></div>"
    done

    cat << 'DEOF3'
          </div>
        </div>
      </div>
    </section>
DEOF3
}

# =============================================================================
# RPT_Deployments_Monthly — deployments.html (last 3 months + bar chart)
# =============================================================================
RPT_Deployments_Monthly() {
    local current_year current_month
    current_year=$(date +%Y)
    current_month=$(date +%m)

    _html_head "RHEL Operations — Deployments"
    _sidebar "deployments"

    cat << DEPHEOF
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Deployment Activity</h1>
    <p>New RHEL builds registered across managed environments during the last three months.</p>
  </div>
DEPHEOF

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo "  <section class=\"card\"><p style=\"color:var(--muted)\">Deployment data not yet available.</p></section>"
        echo "</main>"
        _html_foot
        return
    fi

    # Gather last 3 months' totals for bar chart
    local -a month_labels month_counts
    local max_cnt=1
    for (( i=0; i<3; i++ )); do
        local m=$(( current_month - i ))
        local y=$current_year
        while [[ $m -le 0 ]]; do m=$(( m+12 )); y=$(( y-1 )); done
        local mpad; mpad=$(printf "%02d" $m)
        local mname; mname=$(date -d "${y}-${mpad}-01" '+%B' 2>/dev/null || echo "Month $mpad")
        local cnt; cnt=$(awk -v p="${y}-${mpad}" 'BEGIN{n=0} $1~p{n++} END{print n}' "$DEPLOYMENTDATA")
        month_labels+=("${mname} ${y}")
        month_counts+=("$cnt")
        [[ $cnt -gt $max_cnt ]] && max_cnt=$cnt
    done
    [[ $max_cnt -lt 1 ]] && max_cnt=1

    # Find peak index
    local peak_idx=0 peak_val=0
    for (( i=0; i<3; i++ )); do
        [[ ${month_counts[$i]} -gt $peak_val ]] && { peak_val=${month_counts[$i]}; peak_idx=$i; }
    done

    # Bar chart
    echo "  <section class=\"card\" style=\"margin-bottom:1.4rem\">"
    echo "    <div class=\"card-head\">"
    echo "      <span class=\"chip chip-blue\"><svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"18\" y1=\"20\" x2=\"18\" y2=\"10\"/><line x1=\"12\" y1=\"20\" x2=\"12\" y2=\"4\"/><line x1=\"6\" y1=\"20\" x2=\"6\" y2=\"14\"/></svg></span>"
    echo "      <h2>Monthly build volume</h2>"
    echo "      <span class=\"sub\">total deployments</span>"
    echo "    </div>"
    echo "    <div class=\"chart\">"
    for (( i=0; i<3; i++ )); do
        local pct; pct=$(awk -v n="${month_counts[$i]}" -v d="$max_cnt" 'BEGIN{printf "%.1f", n/d*100}')
        local peak_cls=""
        [[ $i -eq $peak_idx ]] && peak_cls=" peak"
        echo "      <div class=\"col${peak_cls}\"><div class=\"colbar-wrap\"><div class=\"colbar\" style=\"height:${pct}%\"><span class=\"colval\">${month_counts[$i]}</span></div></div><span class=\"collabel\">${month_labels[$i]}</span></div>"
    done
    echo "    </div>"
    echo "  </section>"
    echo ""
    echo "  <div class=\"months\">"

    for (( i=0; i<3; i++ )); do
        local m=$(( current_month - i ))
        local y=$current_year
        while [[ $m -le 0 ]]; do m=$(( m+12 )); y=$(( y-1 )); done
        local mpad; mpad=$(printf "%02d" $m)
        local mname; mname=$(date -d "${y}-${mpad}-01" '+%B' 2>/dev/null || echo "Month $mpad")
        local _mdtmp; _mdtmp=$(mktemp /tmp/rhel_mdata.XXXXXX)
        awk -v p="${y}-${mpad}" '$1~p' "$DEPLOYMENTDATA" > "$_mdtmp"
        [[ -s "$_mdtmp" ]] && _render_deploy_card "${mname} ${y}" "$_mdtmp"
        rm -f "$_mdtmp"
    done

    echo "  </div>"
    echo "</main>"
    _html_foot
}

# =============================================================================
# RPT_Deployment_Monthly_Full — Monthly_Redhat_Linux_Depoloyment_Report.html
# =============================================================================
RPT_Deployment_Monthly_Full() {
    local current_year current_month
    current_year=$(date +%Y)
    current_month=$(date +%m)

    _html_head "RHEL Operations — Monthly Deployment Report"
    _sidebar ""

    cat << MFEOF
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Monthly Deployment Report</h1>
    <p>New RHEL builds by month — last 12 months.</p>
  </div>
  <div class="months">
MFEOF

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo "    <section class=\"card\"><p style=\"color:var(--muted)\">Deployment data not yet available.</p></section>"
    else
        for (( i=0; i<12; i++ )); do
            local m=$(( current_month - i ))
            local y=$current_year
            while [[ $m -le 0 ]]; do m=$(( m+12 )); y=$(( y-1 )); done
            local mpad; mpad=$(printf "%02d" $m)
            local mname; mname=$(date -d "${y}-${mpad}-01" '+%B' 2>/dev/null || echo "Month $mpad")
            local _mdtmp; _mdtmp=$(mktemp /tmp/rhel_mdata.XXXXXX)
            awk -v p="${y}-${mpad}" '$1~p' "$DEPLOYMENTDATA" > "$_mdtmp"
            [[ -s "$_mdtmp" ]] && _render_deploy_card "${mname} ${y}" "$_mdtmp"
            rm -f "$_mdtmp"
        done
    fi

    echo "  </div>"
    echo "</main>"
    _html_foot
}

# =============================================================================
# RPT_Deployment_Annual — Annual_Redhat_Linux_Depoloyment_Report.html
# =============================================================================
RPT_Deployment_Annual() {
    _html_head "RHEL Operations — Annual Deployment Report"
    _sidebar ""

    cat << AEOF
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Annual Deployment Report</h1>
    <p>New RHEL builds aggregated by year — full history from ${DEPLOYMENTDATA##*/}.</p>
  </div>
  <div class="months">
AEOF

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo "    <section class=\"card\"><p style=\"color:var(--muted)\">Deployment data not yet available.</p></section>"
    else
        local _ytmp; _ytmp=$(mktemp /tmp/rhel_years.XXXXXX)
        awk -F- '$1~/^[0-9]{4}$/{print $1}' "$DEPLOYMENTDATA" | sort -ru > "$_ytmp"
        while read -r year; do
            local _ydtmp; _ydtmp=$(mktemp /tmp/rhel_ydata.XXXXXX)
            grep "^${year}-" "$DEPLOYMENTDATA" > "$_ydtmp"
            [[ -s "$_ydtmp" ]] && _render_deploy_card "${year}" "$_ydtmp"
            rm -f "$_ydtmp"
        done < "$_ytmp"
        rm -f "$_ytmp"
    fi

    echo "  </div>"
    echo "</main>"
    _html_foot
}

# =============================================================================
# Main — generate all reports
# =============================================================================
log SECTION "Generating HTML reports and config.js"

RPT_Main                      > "${WEBDIR}/index.html"
log INFO "index.html done"

RPT_History                   > "${WEBDIR}/history.html"
log INFO "history.html done"

RPT_by_Location               > "${WEBDIR}/Location.html"
log INFO "Location.html done"

RPT_by_Mnemonic               > "${WEBDIR}/Application.html"
log INFO "Application.html done"

RPT_Release_detail            > "${WEBDIR}/Releases.html"
log INFO "Releases.html done"

RPT_Deployments_Monthly       > "${WEBDIR}/deployments.html"
log INFO "deployments.html done"

RPT_Deployment_Monthly_Full   > "${WEBDIR}/Monthly_Redhat_Linux_Depoloyment_Report.html"
log INFO "Monthly deployment report done"

RPT_Deployment_Annual         > "${WEBDIR}/Annual_Redhat_Linux_Depoloyment_Report.html"
log INFO "Annual deployment report done"

# Non-responsive host list
awk '!/^#/ && $2=="?" {print $1}' "$INVENTORYDATA" | sort > "${WEBDIR}/${LOSTLIST}"
LOSTCOUNT=$(wc -l < "${WEBDIR}/${LOSTLIST}")
log INFO "Non-responsive hosts: $LOSTCOUNT — ${WEBDIR}/${LOSTLIST}"

log SECTION "rhel_inv_report.sh complete"
exit 0
