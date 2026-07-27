#!/bin/bash
# =============================================================================
# rhel_inv_report.sh — Inventory report and HTML page generator
# =============================================================================
# Generates:
#   config.js                                       — live KPI data for app.js
#   index.html                                      — Red Hat Linux Summary
#   Monthly_Redhat_Linux_Depoloyment_Report.html    — Deployment activity (bar chart + 12 months)
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
PKG_CSV_BASE=$(basename "${PACKAGEDATA:-RHEL_PACKAGES.csv}")

# Footer text — sourced from conf; fall back gracefully if not set
FOOTER_COMPANY="${SITE_FOOTER_COMPANY:-PNC}"
FOOTER_ORG="${SITE_FOOTER_ORG:-IaaS - Data Center Infrastructure - Linux Engineering}"

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
        if ($3 == "?") next
        loc = $21
        sub(/^[Gg]reenfield-/, "", loc)
        print loc " " $2  >> lp
        print loc " " $3  >> lr
        if ($26 != "n/a" && $26 != "") {
            print $26 " " $2  >> ap
            print $26 " " $3  >> ar
        }
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

# Build dynamic awk snippets from LOCATIONS array
LOC_AWK_INIT=""
LOC_AWK_COUNTS=""
LOC_AWK_PRINTF=""
for loc_code in "${LOCATIONS[@]}"; do
    varname="LOC_${loc_code//-/_}"
    LOC_AWK_INIT+="${varname}=0;"
    LOC_AWK_COUNTS+="        if (loc==\"${loc_code}\") ${varname}++
"
    LOC_AWK_PRINTF+="    printf \"${varname}=%d\\n\", ${varname}+0
"
done

eval "$(awk \
    'BEGIN{total=0;virt=0;phys=0;cloud=0;fail=0
           ernd=0;euat=0;eqa=0;eprod=0
           '"$LOC_AWK_INIT"'}
    !/^#/{
        if ($3 == "?") next
        total++
        loc=$21
        sub(/^Greenfield-/,"",loc)
        if ($2 ~ /^SSHFAIL/ || $2 ~ /^TIMEOUT/) { fail++ }
        else if (loc=="AZCE"||loc=="AZE2") cloud++
        else if ($2=="Virt") virt++
        else if ($2=="Phys") phys++
        if ($27=="RND")  ernd++
        if ($27=="UAT")  euat++
        if ($27=="QA")   eqa++
        if ($27=="PROD") eprod++
'"$LOC_AWK_COUNTS"'
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
'"$LOC_AWK_PRINTF"'
    }' "$INVENTORYDATA")"

eval "$(awk '!/^#/ && $3 != "?" {
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
    organization: "${SITE_ORG:-IaaS · PNC}",
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
    local a_idx="" a_dep="" a_inv="" a_his="" a_mid=""
    case "$active" in
        index)       a_idx=" active" ;;
        deployments) a_dep=" active" ;;
        inventory)   a_inv=" active" ;;
        history)     a_his=" active" ;;
        midrange)    a_mid=" active" ;;
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
        <span>Red Hat Linux Summary</span>
      </a>
      <a href="Monthly_Redhat_Linux_Depoloyment_Report.html" class="side-link${a_dep}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 3v18h18"/><path d="M7 14l4-4 3 3 5-6"/>
        </svg>
        <span>Deployments</span>
      </a>
      <a href="${INVENTDATAHTML}" class="side-link${a_inv}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="4" width="18" height="16" rx="1.5"/>
          <line x1="3" y1="9" x2="21" y2="9"/>
          <line x1="9" y1="9" x2="9" y2="20"/>
        </svg>
        <span>Host Inventory</span>
      </a>
      <a href="history.html" class="side-link${a_his}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 12a9 9 0 1 0 3-6.7L3 8"/>
          <path d="M3 3v5h5"/><path d="M12 7v5l3 2"/>
        </svg>
        <span>Historical Inventory</span>
      </a>
      <a href="Midrange_Mod/index.html" class="side-link${a_mid}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M2 20h20"/><path d="M4 20V10l8-6 8 6v10"/>
          <path d="M10 20v-6h4v6"/>
        </svg>
        <span>Midrange Mod Reports</span>
      </a>
    </div>
    <div class="nav-group">
      <div class="nav-label">External Tools</div>
      <div data-external-links></div>
    </div>
  </nav>
  <div class="side-bottom">
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
<footer class="foot"><span>&copy; ${YEAR} ${FOOTER_COMPANY} &middot; ${FOOTER_ORG}</span></footer>
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
    _html_head "RHEL Operations — Red Hat Linux Summary"
    _sidebar "index"

    cat << MAINEOF
<div class="content-shell">
<main class="page">

  <div class="page-head">
    <h1>Red Hat Linux Summary</h1>
    <p>Current RHEL inventory, platform distribution, and operational status across managed environments.</p>
  </div>

  <section class="kpis">
    <div class="kpi total">
      <span class="ic ic-green">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="2" y="3" width="20" height="14" rx="2"/>
          <line x1="8" y1="21" x2="16" y2="21"/>
          <line x1="12" y1="17" x2="12" y2="21"/>
        </svg>
      </span>
      <span class="meta">
        <span class="num" data-kpi="total">${TOTAL_HOSTS}</span>
        <span class="lab">Total managed servers</span>
      </span>
    </div>
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
        <span class="lab">Hosts unreachable (SSH)</span>
      </span>
    </div>
  </section>

  <section class="row split" style="align-items:stretch">
    <div class="card" style="display:flex;flex-direction:column;justify-content:center">
      <div class="card-head">
        <span class="chip chip-blue">#</span>
        <h2>RHEL by version</h2>
        <span class="sub">major release</span>
      </div>
      <div class="donut-wrap" style="justify-content:center">
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

  <section class="row halves" style="align-items:stretch">
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
          <li><a href="Monthly_Redhat_Linux_Depoloyment_Report.html">Monthly deployments<span class="ar">&#8594;</span></a></li>
          <li><a href="Annual_Redhat_Linux_Depoloyment_Report.html">Annual deployments<span class="ar">&#8594;</span></a></li>
          <li><a href="Midrange_Mod/index.html">Midrange Mod Reports<span class="ar">&#8594;</span></a></li>
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
      The newest file is also available from the <strong>Data &amp; reports</strong> section on the summary page.
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

    local _loc_list=("${LOCATIONS[@]}" "n/a")
    for LOC in "${_loc_list[@]}"; do
        [[ -z "$LOC" ]] && continue
        STOTAL=$(grep -c "^$LOC " "$LOCDATAPLAT" 2>/dev/null || true)
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
    GRAND=$(awk '!/^#/ && $3 != "?" && $26 != "n/a" && $26 != ""' "$INVENTORYDATA" | wc -l)

    # Build series metadata from OS_SERIES conf array
    # Each entry: "Label:ver1,ver2,..."  e.g. "RHEL 8.x Series:8.8,8.10"
    # We extract: series label (shortened to "RHEL 8", "RHEL 9")
    # and the comma-separated version list for counting
    local -a SERIES_LABELS SERIES_VERS
    for entry in "${OS_SERIES[@]}"; do
        local slabel="${entry%%:*}"
        local svers="${entry##*:}"
        # Shorten "RHEL 8.x Series" → "RHEL 8", "RHEL 9.x Series" → "RHEL 9"
        local sshort; sshort=$(echo "$slabel" | sed 's/\.x Series//')
        SERIES_LABELS+=("$sshort")
        SERIES_VERS+=("$svers")
    done
    local NSERIES=${#SERIES_LABELS[@]}

    # Build CSV for Application.html download — written to WEBDIR
    local APP_CSV="${WEBDIR}/Application.csv"
    {
        # Header
        printf "App Code,Total,Virt,Phys,Cloud"
        for (( s=0; s<NSERIES; s++ )); do
            printf ",%s" "${SERIES_LABELS[$s]}"
        done
        printf "\n"

        awk '{print $1}' "$APPDATAPLAT" | sort -u \
        | while read -r APP; do
            [[ -z "$APP" ]] && continue
            local STOTAL; STOTAL=$(grep -c "^$APP " "$APPDATAPLAT" 2>/dev/null || true)
            STOTAL=$(( STOTAL + 0 ))
            [[ $STOTAL -eq 0 ]] && continue
            local VIRT; VIRT=$(awk -v a="$APP" '$1==a && $2=="Virt"' "$APPDATAPLAT" | wc -l)
            local PHYS; PHYS=$(awk -v a="$APP" '$1==a && $2=="Phys"' "$APPDATAPLAT" | wc -l)
            local CLOUD; CLOUD=$(awk -v a="$APP" '$1==a && $2=="Cloud"' "$APPDATAPLAT" | wc -l)
            printf "%s,%d,%d,%d,%d" "$APP" "$STOTAL" "$VIRT" "$PHYS" "$CLOUD"
            for (( s=0; s<NSERIES; s++ )); do
                local vers="${SERIES_VERS[$s]}"
                local cnt
                cnt=$(awk -v a="$APP" -v vlist="$vers" '
                    BEGIN { n=split(vlist,v,","); for(i=1;i<=n;i++) ok[v[i]]=1 }
                    $1==a && ($2 in ok)
                ' "$APPDATAREL" | wc -l)
                printf ",%d" "$cnt"
            done
            printf "\n"
        done
    } > "$APP_CSV"
    log INFO "Application CSV written: $APP_CSV" >&2

    _html_head "RHEL Operations — Inventory by Application Code"
    _sidebar ""

    # Build thead series columns
    local SERIES_TH=""
    for (( s=0; s<NSERIES; s++ )); do
        SERIES_TH+="            <th onclick=\"sortApp($((s+5)))\" style=\"cursor:pointer;text-align:right\">${SERIES_LABELS[$s]} &#8597;</th>\n"
    done

    cat << APPEOF2
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Inventory by Application Code</h1>
    <p>Host counts, platform split, and OS version distribution grouped by application mnemonic.</p>
  </div>
  <section class="card">
    <div class="card-head">
      <span class="chip chip-violet">&#9638;</span>
      <h2>Application codes</h2>
      <span class="sub" id="appCount"></span>
    </div>
    <div class="controls" style="margin-bottom:1rem">
      <input type="text" id="appSearch" placeholder="Filter by app code&#8230;" oninput="filterApp()" style="min-width:220px">
      <a class="button compact" href="Application.csv" download style="margin-left:auto">Download CSV</a>
    </div>
    <div class="tbl-card">
      <div class="tbl-wrap">
        <table id="appTable" style="width:100%">
          <thead><tr>
            <th onclick="sortApp(0)" style="cursor:pointer">App Code &#8597;</th>
            <th onclick="sortApp(1)" style="cursor:pointer;text-align:right">Total &#8597;</th>
            <th onclick="sortApp(2)" style="cursor:pointer;text-align:right">Virt &#8597;</th>
            <th onclick="sortApp(3)" style="cursor:pointer;text-align:right">Phys &#8597;</th>
            <th onclick="sortApp(4)" style="cursor:pointer;text-align:right">Cloud &#8597;</th>
APPEOF2

    # Emit series column headers
    for (( s=0; s<NSERIES; s++ )); do
        echo "            <th onclick=\"sortApp($((s+5)))\" style=\"cursor:pointer;text-align:right\">${SERIES_LABELS[$s]} &#8597;</th>"
    done

    echo "          </tr></thead>"
    echo "          <tbody id=\"appBody\">"

    awk '{print $1}' "$APPDATAPLAT" | sort -u \
    | while read -r APP; do
        [[ -z "$APP" ]] && continue
        local STOTAL; STOTAL=$(grep -c "^$APP " "$APPDATAPLAT" 2>/dev/null || true)
        STOTAL=$(( STOTAL + 0 ))
        [[ $STOTAL -eq 0 ]] && continue
        local VIRT; VIRT=$(awk -v a="$APP" '$1==a && $2=="Virt"' "$APPDATAPLAT" | wc -l)
        local PHYS; PHYS=$(awk -v a="$APP" '$1==a && $2=="Phys"' "$APPDATAPLAT" | wc -l)
        local CLOUD; CLOUD=$(awk -v a="$APP" '$1==a && $2=="Cloud"' "$APPDATAPLAT" | wc -l)
        local APPLO; APPLO=$(echo "$APP" | tr '[:upper:]' '[:lower:]')

        echo "            <tr data-app=\"${APPLO}\" data-total=\"${STOTAL}\">"
        echo "              <td style=\"font-weight:600;color:var(--ink)\">${APP}</td>"
        echo "              <td style=\"text-align:right;font-weight:700\">${STOTAL}</td>"
        echo "              <td style=\"text-align:right\" class=\"sub\">${VIRT}</td>"
        echo "              <td style=\"text-align:right\" class=\"sub\">${PHYS}</td>"
        echo "              <td style=\"text-align:right\" class=\"sub\">${CLOUD}</td>"

        for (( s=0; s<NSERIES; s++ )); do
            local vers="${SERIES_VERS[$s]}"
            local cnt
            cnt=$(awk -v a="$APP" -v vlist="$vers" '
                BEGIN { n=split(vlist,v,","); for(i=1;i<=n;i++) ok[v[i]]=1 }
                $1==a && ($2 in ok)
            ' "$APPDATAREL" | wc -l)
            echo "              <td style=\"text-align:right\" class=\"sub\">${cnt}</td>"
        done
        echo "            </tr>"
    done

    # Grand total row — series totals
    local GT_COLS=""
    for (( s=0; s<NSERIES; s++ )); do
        local vers="${SERIES_VERS[$s]}"
        local tcnt
        tcnt=$(awk -v vlist="$vers" '
            BEGIN { n=split(vlist,v,","); for(i=1;i<=n;i++) ok[v[i]]=1 }
            $2 in ok
        ' "$APPDATAREL" | wc -l)
        GT_COLS+="              <td style=\"text-align:right;font-weight:700\">${tcnt}</td>\n"
    done

    local GT_VIRT GT_PHYS GT_CLOUD
    GT_VIRT=$(awk '$2=="Virt"'  "$APPDATAPLAT" | wc -l)
    GT_PHYS=$(awk '$2=="Phys"'  "$APPDATAPLAT" | wc -l)
    GT_CLOUD=$(awk '$2=="Cloud"' "$APPDATAPLAT" | wc -l)

    cat << APPJSEOF
            <tr style="border-top:2px solid var(--line)">
              <td style="font-weight:700;color:var(--ink)">Grand Total</td>
              <td style="text-align:right;font-weight:700">${GRAND}</td>
              <td style="text-align:right;font-weight:700">${GT_VIRT}</td>
              <td style="text-align:right;font-weight:700">${GT_PHYS}</td>
              <td style="text-align:right;font-weight:700">${GT_CLOUD}</td>
$(printf '%b' "$GT_COLS")            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </section>
</main>
<footer class="foot"><span>&copy; ${YEAR} ${FOOTER_COMPANY} &middot; ${FOOTER_ORG}</span></footer>
</div><!-- /content-shell -->
</div><!-- /app-shell -->
<script>
(function(){
  const rows = Array.from(document.querySelectorAll('#appBody tr[data-app]'));
  const countEl = document.getElementById('appCount');
  if (countEl) countEl.textContent = rows.length + ' application codes';
  const sortDirs = {};
  window.sortApp = function(col) {
    const dir = sortDirs[col] = -(sortDirs[col] || 1);
    rows.sort(function(a, b) {
      const va = a.querySelectorAll('td')[col].textContent.trim();
      const vb = b.querySelectorAll('td')[col].textContent.trim();
      return col === 0 ? va.localeCompare(vb) * dir
                       : (parseInt(va)||0 - (parseInt(vb)||0)) * dir;
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
# RPT_Deployment_Monthly_Full — Monthly_Redhat_Linux_Depoloyment_Report.html
# Primary deployments page: bar chart (last 3 months) + full 12-month history
# =============================================================================
RPT_Deployment_Monthly_Full() {
    local current_year current_month
    current_year=$(date +%Y)
    current_month=$(date +%m)

    _html_head "RHEL Operations — Monthly Deployment Report"
    _sidebar "deployments"

    cat << MFEOF
<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Monthly Deployment Report</h1>
    <p>New RHEL builds registered across managed environments — last 12 months.</p>
  </div>
MFEOF

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo "  <section class=\"card\"><p style=\"color:var(--muted)\">Deployment data not yet available.</p></section>"
        echo "</main>"
        _html_foot
        return
    fi

    # Bar chart — last 3 months
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

    local peak_idx=0 peak_val=0
    for (( i=0; i<3; i++ )); do
        [[ ${month_counts[$i]} -gt $peak_val ]] && { peak_val=${month_counts[$i]}; peak_idx=$i; }
    done

    echo "  <section class=\"card\" style=\"margin-bottom:1.4rem\">"
    echo "    <div class=\"card-head\">"
    echo "      <span class=\"chip chip-blue\"><svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"18\" y1=\"20\" x2=\"18\" y2=\"10\"/><line x1=\"12\" y1=\"20\" x2=\"12\" y2=\"4\"/><line x1=\"6\" y1=\"20\" x2=\"6\" y2=\"14\"/></svg></span>"
    echo "      <h2>Monthly build volume</h2>"
    echo "      <span class=\"sub\">last 3 months</span>"
    echo "    </div>"
    echo "    <div class=\"chart\">"
    for (( i=0; i<3; i++ )); do
        local cpct; cpct=$(awk -v n="${month_counts[$i]}" -v d="$max_cnt" 'BEGIN{printf "%.1f", n/d*100}')
        local peak_cls=""
        [[ $i -eq $peak_idx ]] && peak_cls=" peak"
        echo "      <div class=\"col${peak_cls}\"><div class=\"colbar-wrap\"><div class=\"colbar\" style=\"height:${cpct}%\"><span class=\"colval\">${month_counts[$i]}</span></div></div><span class=\"collabel\">${month_labels[$i]}</span></div>"
    done
    echo "    </div>"
    echo "  </section>"
    echo ""
    echo "  <div class=\"months\">"

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
AEOF

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo "  <section class=\"card\"><p style=\"color:var(--muted)\">Deployment data not yet available.</p></section>"
        echo "</main>"
        _html_foot
        return
    fi

    # Collect all years newest-first
    local _ytmp; _ytmp=$(mktemp /tmp/rhel_years.XXXXXX)
    awk -F- '$1~/^[0-9]{4}$/{print $1}' "$DEPLOYMENTDATA" | sort -ru > "$_ytmp"

    # Bar chart — last 3 years
    local -a bar_labels bar_counts
    local max_cnt=1
    local yr_idx=0
    while read -r year && [[ $yr_idx -lt 3 ]]; do
        local cnt; cnt=$(grep -c "^${year}-" "$DEPLOYMENTDATA" 2>/dev/null || echo 0)
        cnt=$(( cnt + 0 ))
        bar_labels+=("$year")
        bar_counts+=("$cnt")
        [[ $cnt -gt $max_cnt ]] && max_cnt=$cnt
        yr_idx=$(( yr_idx + 1 ))
    done < "$_ytmp"
    [[ $max_cnt -lt 1 ]] && max_cnt=1

    local peak_idx=0 peak_val=0
    for (( i=0; i<${#bar_counts[@]}; i++ )); do
        [[ ${bar_counts[$i]} -gt $peak_val ]] && { peak_val=${bar_counts[$i]}; peak_idx=$i; }
    done

    echo "  <section class=\"card\" style=\"margin-bottom:1.4rem\">"
    echo "    <div class=\"card-head\">"
    echo "      <span class=\"chip chip-blue\"><svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"18\" y1=\"20\" x2=\"18\" y2=\"10\"/><line x1=\"12\" y1=\"20\" x2=\"12\" y2=\"4\"/><line x1=\"6\" y1=\"20\" x2=\"6\" y2=\"14\"/></svg></span>"
    echo "      <h2>Annual build volume</h2>"
    echo "      <span class=\"sub\">last 3 years</span>"
    echo "    </div>"
    echo "    <div class=\"chart\">"
    for (( i=0; i<${#bar_labels[@]}; i++ )); do
        local apct; apct=$(awk -v n="${bar_counts[$i]}" -v d="$max_cnt" 'BEGIN{printf "%.1f", n/d*100}')
        local peak_cls=""
        [[ $i -eq $peak_idx ]] && peak_cls=" peak"
        echo "      <div class=\"col${peak_cls}\"><div class=\"colbar-wrap\"><div class=\"colbar\" style=\"height:${apct}%\"><span class=\"colval\">${bar_counts[$i]}</span></div></div><span class=\"collabel\">${bar_labels[$i]}</span></div>"
    done
    echo "    </div>"
    echo "  </section>"
    echo ""
    echo "  <div class=\"months\">"

    # All year cards
    while read -r year; do
        local _ydtmp; _ydtmp=$(mktemp /tmp/rhel_ydata.XXXXXX)
        grep "^${year}-" "$DEPLOYMENTDATA" > "$_ydtmp"
        [[ -s "$_ydtmp" ]] && _render_deploy_card "${year}" "$_ydtmp"
        rm -f "$_ydtmp"
    done < "$_ytmp"
    rm -f "$_ytmp"

    echo "  </div>"
    echo "</main>"
    _html_foot
}

# =============================================================================
# RPT_Midrange_Archive — Midrange_Mod/index.html
# =============================================================================
# Generates a styled archive index page for the Midrange Mod Report CSVs.
# Matches the look of history.html (historical inventory downloads).
# Also writes style.css and app.js into Midrange_Mod/ so it is self-contained.
#
# The Midrange_Mod_Report.sh script writes its CSVs to:
#   ${WEBDIR}/Midrange_Mod/archive/Midrange_Mod_Report_*.csv
# This page lists them newest-first with download links.
# =============================================================================
RPT_Midrange_Archive() {
    local MMDIR="${WEBDIR}/Midrange_Mod"
    local MMARCHIVE="${MMDIR}/archive"
    mkdir -p "$MMDIR"

    # Stage style.css and app.js into Midrange_Mod/ so the page renders
    # correctly when opened directly — it must be self-contained.
    for _asset in style.css app.js; do
        [[ -f "${WEBDIR}/${_asset}" ]] && \
            cp -p "${WEBDIR}/${_asset}" "${MMDIR}/${_asset}" 2>/dev/null
    done

    local OUT="${MMDIR}/index.html"

    # Build file list JSON for app.js data-history-rows (reuse same pattern)
    local HIST_ROWS=""
    if [[ -d "$MMARCHIVE" ]]; then
        local idx=0
        while IFS= read -r fpath; do
            [[ -z "$fpath" ]] && continue
            local fname; fname=$(basename "$fpath")
            local fsize; fsize=$(du -sh "$fpath" 2>/dev/null | cut -f1)
            local fts_h; fts_h=$(stat -c '%y' "$fpath" 2>/dev/null \
                | awk '{print $1, $2}' | cut -c1-16 \
                | xargs -I{} date -d "{}" '+%b %-d, %Y %-I:%M %p %Z' 2>/dev/null)
            [[ $idx -gt 0 ]] && HIST_ROWS+=","
            HIST_ROWS+="
    { \"filename\": \"${fname}\", \"timestamp\": \"${fts_h}\", \"size\": \"${fsize}\", \"href\": \"archive/${fname}\" }"
            idx=$(( idx + 1 ))
        done < <(find "$MMARCHIVE" -maxdepth 1 -name "*.csv" \
                 -printf '%T@ %p\n' 2>/dev/null \
                 | sort -rn | awk '{print $2}' | head -60)
    fi

    # Write a minimal local config.js so the sidebar brand/updated text renders
    cat > "${MMDIR}/config.js" << MMCFGEOF
window.RHEL_CONFIG = {
  site: {
    title:        "${SITE_TITLE:-RHEL Operations}",
    subtitle:     "${SITE_SUBTITLE:-Inventory & Deployment}",
    organization: "${SITE_ORG:-IaaS · PNC}",
    updated:      "${UPDATED_HUMAN}"
  },
  totals:       { totalHosts:0, virtual:0, physical:0, cloud:0, sshFailures:0 },
  rhelVersions: [], environments: [], locations: [],
  downloads:    { latestInventoryCsv: "../${INVENTDATACSV}" },
  externalLinks: [${EXTLINKS_JSON}
  ],
  historicalFiles: [${HIST_ROWS}
  ]
};
MMCFGEOF

    # Write index.html
    cat > "$OUT" << MMEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>RHEL Operations — Midrange Mod Reports</title>
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
      <a href="../index.html" class="side-link">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/>
          <rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/>
        </svg>
        <span>Red Hat Linux Summary</span>
      </a>
      <a href="../Monthly_Redhat_Linux_Depoloyment_Report.html" class="side-link">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 3v18h18"/><path d="M7 14l4-4 3 3 5-6"/>
        </svg>
        <span>Deployments</span>
      </a>
      <a href="../${INVENTDATAHTML}" class="side-link">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="3" y="4" width="18" height="16" rx="1.5"/>
          <line x1="3" y1="9" x2="21" y2="9"/>
          <line x1="9" y1="9" x2="9" y2="20"/>
        </svg>
        <span>Host Inventory</span>
      </a>
      <a href="../history.html" class="side-link">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 12a9 9 0 1 0 3-6.7L3 8"/>
          <path d="M3 3v5h5"/><path d="M12 7v5l3 2"/>
        </svg>
        <span>Historical Inventory</span>
      </a>
      <a href="index.html" class="side-link active">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M2 20h20"/><path d="M4 20V10l8-6 8 6v10"/>
          <path d="M10 20v-6h4v6"/>
        </svg>
        <span>Midrange Mod Reports</span>
      </a>
    </div>
    <div class="nav-group">
      <div class="nav-label">External Tools</div>
      <div data-external-links></div>
    </div>
  </nav>
  <div class="side-bottom">
    <div class="side-status">
      <span class="dot"></span>
      <span data-site-updated>Updated ${UPDATED_HUMAN}</span>
    </div>
  </div>
</aside>

<div class="content-shell">
<main class="page">
  <div class="page-head">
    <h1>Midrange Mod Reports</h1>
    <p>Archived Midrange Mod Report CSV files — newest first. Generated by Midrange_Mod_Report.sh.</p>
  </div>
  <section class="card">
    <div class="card-head">
      <span class="chip chip-amber">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 12a9 9 0 1 0 3-6.7L3 8"/>
          <path d="M3 3v5h5"/><path d="M12 7v5l3 2"/>
        </svg>
      </span>
      <h2>Report archive</h2>
      <span class="sub">newest first</span>
    </div>
    <div class="history-note">
      Files are generated by <strong>Midrange_Mod_Report.sh</strong> and archived to
      <code style="font-size:.8rem;background:#f3f6fc;padding:2px 6px;border-radius:5px">Midrange_Mod/archive/</code>.
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
<footer class="foot"><span>&copy; ${YEAR} ${FOOTER_COMPANY} &middot; ${FOOTER_ORG}</span></footer>
</div><!-- /content-shell -->
</div><!-- /app-shell -->
</body>
</html>
MMEOF

    log INFO "Midrange_Mod/index.html written (${MMDIR})"
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

RPT_Deployment_Monthly_Full   > "${WEBDIR}/Monthly_Redhat_Linux_Depoloyment_Report.html"
log INFO "Monthly_Redhat_Linux_Depoloyment_Report.html done"

RPT_Deployment_Annual         > "${WEBDIR}/Annual_Redhat_Linux_Depoloyment_Report.html"
log INFO "Annual_Redhat_Linux_Depoloyment_Report.html done"

RPT_Midrange_Archive
log INFO "Midrange_Mod/index.html done"

# =============================================================================
# RPT_Upgrade — Upgrade/index.html + Upgrade/style.css
# =============================================================================
RPT_Upgrade() {
    local _upg_dir="${UPGRADE_WEB_DIR:-${WEBDIR}/Upgrade}"
    mkdir -p "$_upg_dir"
    local _updated; _updated=$(date '+%b %d, %Y')

    cat > "${_upg_dir}/style.css" << 'UPGCSS'
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --bg: #f3f6fc; --card: #ffffff; --line: #e7edf6; --line-soft: #eef2f9;
  --ink: #1d2840; --text: #46546e; --muted: #8693ab; --faint: #aab5c8;
  --blue: #3b6ef0; --indigo: #5b6ef5; --violet: #8b5cf6;
  --teal: #14b3a6; --green: #21b573; --amber: #f5a623; --red: #ec4055;
  --radius: 16px; --radius-md: 12px; --radius-sm: 9px;
  --shadow: 0 1px 2px rgba(17,28,53,.04), 0 6px 20px rgba(17,28,53,.06);
  --shadow-sm: 0 1px 2px rgba(17,28,53,.05), 0 2px 8px rgba(17,28,53,.05);
  --sans: system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
}
body { font-family:var(--sans); font-size:14px; line-height:1.55; color:var(--text); background:var(--bg); -webkit-font-smoothing:antialiased; min-height:100vh; }
a { color:inherit; text-decoration:none; }
.page { max-width:1400px; margin:0 auto; padding:2rem 1.75rem 3rem; }
.page-header { background:linear-gradient(135deg,#1e3a6e,#2d5edc,#4a3fa0); border-radius:var(--radius); padding:2rem 2.2rem 1.8rem; margin-bottom:1.6rem; color:#fff; }
.header-top { display:flex; align-items:flex-start; justify-content:space-between; gap:1.5rem; flex-wrap:wrap; margin-bottom:1.4rem; }
.header-title h1 { font-size:1.75rem; font-weight:750; letter-spacing:-.02em; line-height:1.2; }
.header-title p { font-size:.88rem; opacity:.8; margin-top:.35rem; }
.header-actions { display:flex; gap:.6rem; flex-wrap:wrap; align-items:center; }
.btn { display:inline-flex; align-items:center; gap:.45rem; padding:.6rem 1.15rem; border-radius:var(--radius-sm); font-size:.83rem; font-weight:650; cursor:pointer; transition:.14s ease; border:1px solid transparent; white-space:nowrap; font-family:inherit; }
.btn svg { width:14px; height:14px; flex:0 0 auto; }
.btn-request { background:var(--green); color:#fff; border-color:rgba(255,255,255,.2); }
.btn-request:hover { background:#1a9e62; }
.btn-docs { background:rgba(255,255,255,.15); color:#fff; border-color:rgba(255,255,255,.3); }
.btn-docs:hover { background:rgba(255,255,255,.25); }
.btn-faq { background:rgba(255,255,255,.15); color:#fff; border-color:rgba(255,255,255,.3); }
.btn-faq:hover { background:rgba(255,255,255,.25); }
.header-kpis { display:grid; grid-template-columns:repeat(4,1fr); gap:.85rem; }
.hkpi { background:rgba(255,255,255,.12); border:1px solid rgba(255,255,255,.2); border-radius:var(--radius-md); padding:1rem 1.2rem; }
.hkpi .num { display:block; font-size:1.9rem; font-weight:780; color:#fff; letter-spacing:-.03em; line-height:1; }
.hkpi.eligible  .num { color:#6ee7b7; }
.hkpi.ineligible .num { color:#f87171; }
.hkpi.rate       .num { color:#c4b5fd; }
.hkpi .lab { display:block; font-size:.76rem; color:rgba(255,255,255,.7); margin-top:.3rem; }
.criteria-panel { background:var(--card); border:1px solid var(--line); border-radius:var(--radius); box-shadow:var(--shadow-sm); margin-bottom:1.4rem; overflow:hidden; }
.criteria-toggle { display:flex; align-items:center; gap:.75rem; width:100%; padding:1rem 1.4rem; background:none; border:none; cursor:pointer; text-align:left; font-family:inherit; transition:.14s ease; }
.criteria-toggle:hover { background:#f8faff; }
.criteria-toggle strong { font-size:.9rem; font-weight:700; color:var(--ink); }
.criteria-toggle .ct-sub { font-size:.79rem; color:var(--muted); font-weight:400; }
.criteria-toggle .ct-chevron { margin-left:auto; color:var(--muted); font-size:.75rem; font-weight:600; }
.criteria-body { display:none; padding:1.1rem 1.4rem 1.3rem; border-top:1px solid var(--line); }
.criteria-body.open { display:block; }
.criteria-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:.7rem; }
.criteria-item { padding:.8rem 1rem; background:var(--bg); border-radius:var(--radius-sm); border:1px solid var(--line); }
.criteria-item.conditional-note { border-color:#f5dba0; background:#fdf7ec; }
.criteria-item.conditional-note .ci-label { color:#92400e; }
.ci-label { font-size:.83rem; font-weight:700; color:var(--ink); margin-bottom:.2rem; }
.ci-detail { font-size:.76rem; color:var(--muted); line-height:1.45; }
.ci-detail a { color:var(--blue); text-decoration:underline; }
.controls { background:var(--card); border:1px solid var(--line); border-radius:var(--radius); box-shadow:var(--shadow-sm); padding:1rem 1.2rem; margin-bottom:1rem; display:flex; gap:.75rem; flex-wrap:wrap; align-items:center; }
.search-wrap { flex:1 1 260px; position:relative; }
.search-wrap svg { position:absolute; left:.8rem; top:50%; transform:translateY(-50%); width:15px; height:15px; color:var(--muted); pointer-events:none; }
.search-wrap input { width:100%; padding:.6rem .8rem .6rem 2.3rem; border:1px solid var(--line); border-radius:var(--radius-sm); font-size:.86rem; color:var(--ink); background:var(--bg); font-family:inherit; transition:.14s ease; }
.search-wrap input:focus { outline:none; border-color:var(--blue); background:#fff; box-shadow:0 0 0 3px rgba(59,110,240,.1); }
.filter-select { padding:.6rem .9rem; border:1px solid var(--line); border-radius:var(--radius-sm); font-size:.84rem; color:var(--ink); background:var(--card); cursor:pointer; font-family:inherit; }
.filter-select:focus { outline:none; border-color:var(--blue); }
.dl-btn { display:inline-flex; align-items:center; gap:.4rem; padding:.6rem 1rem; border-radius:var(--radius-sm); font-size:.82rem; font-weight:650; background:var(--blue); color:#fff; border:none; cursor:pointer; transition:.14s ease; font-family:inherit; }
.dl-btn:hover { background:#2d5edc; }
.dl-btn svg { width:14px; height:14px; }
.results-count { font-size:.8rem; color:var(--muted); margin-left:auto; white-space:nowrap; }
.table-card { background:var(--card); border:1px solid var(--line); border-radius:var(--radius); box-shadow:var(--shadow); overflow:hidden; }
.table-scroll { overflow-x:auto; }
table { width:100%; border-collapse:collapse; }
thead { position:sticky; top:0; z-index:2; }
th { background:linear-gradient(135deg,var(--indigo),var(--violet)); color:#fff; padding:11px 13px; text-align:left; font-size:.75rem; font-weight:700; text-transform:uppercase; letter-spacing:.06em; cursor:pointer; user-select:none; white-space:nowrap; }
th:hover { filter:brightness(1.08); }
.sort-arrow { opacity:.35; margin-left:.3rem; font-size:.65rem; }
th.sort-active .sort-arrow { opacity:1; }
td { padding:10px 13px; border-bottom:1px solid var(--line-soft); font-size:.84rem; color:var(--text); vertical-align:middle; }
tr:last-child td { border-bottom:none; }
tr:hover td { background:#f8faff; }
.host-cell { font-weight:650; color:var(--ink); font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace; font-size:.8rem; min-width:140px; white-space:nowrap; }
.badge { display:inline-flex; align-items:center; gap:.3rem; padding:.28rem .7rem; border-radius:999px; font-size:.75rem; font-weight:700; white-space:nowrap; }
.badge-eligible    { background:#dcf5e7; color:#14532d; }
.badge-conditional { background:#fef3c7; color:#78350f; }
.badge-ineligible  { background:#fecdd3; color:#7f1d1d; }
.badge-unknown     { background:#f1f5f9; color:#64748b; }
.os-badge { padding:.22rem .55rem; border-radius:6px; font-size:.74rem; font-weight:700; white-space:nowrap; }
.os-rhel8 { background:#dbeafe; color:#1e40af; }
.os-rhel9 { background:#fef9c3; color:#854d0e; }
.os-other { background:#f1f5f9; color:#64748b; }
.comment-cell { min-width:280px; font-size:.8rem; color:var(--muted); line-height:1.4; white-space:normal; word-break:break-word; }
.comment-cell.issue       { color:#7f1d1d; font-weight:600; }
.comment-cell.conditional { color:#78350f; font-weight:600; }
.comment-cell.unknown     { color:#64748b; font-style:italic; }
.pagination { display:flex; align-items:center; justify-content:space-between; padding:.9rem 1.3rem; border-top:1px solid var(--line); background:#fbfcff; gap:1rem; flex-wrap:wrap; }
.page-info { font-size:.8rem; color:var(--muted); }
.page-btns { display:flex; gap:.3rem; flex-wrap:wrap; }
.page-btn { padding:.38rem .72rem; border:1px solid var(--line); border-radius:8px; font-size:.8rem; color:var(--text); background:var(--card); cursor:pointer; transition:.12s ease; font-family:inherit; }
.page-btn:hover:not([disabled]) { border-color:var(--blue); color:var(--blue); }
.page-btn.active { background:var(--blue); color:#fff; border-color:var(--blue); }
.page-btn[disabled] { opacity:.35; cursor:not-allowed; }
.foot { display:flex; justify-content:space-between; flex-wrap:wrap; gap:.5rem; font-size:.79rem; color:var(--muted); padding:1.5rem 0 2.5rem; margin-top:.5rem; }
.foot a { color:var(--blue); }
@media(max-width:900px) { .header-kpis { grid-template-columns:repeat(2,1fr); } }
@media(max-width:600px) { .header-top { flex-direction:column; } }
UPGCSS
    log INFO "Upgrade/style.css written"

    cat > "${_upg_dir}/index.html" << UPGHT
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>RHEL 8 to 9 Upgrade Eligibility Report</title>
<link rel="stylesheet" href="style.css"/>
</head>
<body>
<div class="page">
  <header class="page-header">
    <div class="header-top">
      <div class="header-title">
        <h1>RHEL 8 &rarr; 9 Upgrade Eligibility</h1>
        <p>Daily eligibility assessment across all managed RHEL 8 servers &mdash; including Fed enclave. Updated nightly.</p>
      </div>
      <div class="header-actions">
        <a href="${UPGRADE_REQUEST_URL:-#}" target="_blank" rel="noopener" class="btn btn-request">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="17 11 12 6 7 11"/><line x1="12" y1="18" x2="12" y2="6"/></svg>
          Request Upgrade
        </a>
        <a href="${UPGRADE_DOCS_URL:-#}" target="_blank" rel="noopener" class="btn btn-docs">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
          Documentation
        </a>
        <a href="${UPGRADE_FAQ_URL:-#}" target="_blank" rel="noopener" class="btn btn-faq">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
          FAQ
        </a>
      </div>
    </div>
    <div class="header-kpis">
      <div class="hkpi"><span class="num" id="kpiTotal">&mdash;</span><span class="lab">Total RHEL 8 servers</span></div>
      <div class="hkpi eligible"><span class="num" id="kpiElig">&mdash;</span><span class="lab">Eligible for upgrade</span></div>
      <div class="hkpi ineligible"><span class="num" id="kpiInelig">&mdash;</span><span class="lab">Ineligible</span></div>
      <div class="hkpi rate"><span class="num" id="kpiRate">&mdash;</span><span class="lab">Eligibility rate</span></div>
    </div>
  </header>

  <div class="criteria-panel">
    <button class="criteria-toggle" onclick="toggleCriteria()">
      <strong>Eligibility Criteria</strong>
      <span class="ct-sub">&nbsp;&mdash; checks run nightly on every RHEL 8 host</span>
      <span class="ct-chevron" id="criteriaChevron">Show &#9662;</span>
    </button>
    <div class="criteria-body" id="criteriaBody">
      <div class="criteria-grid">
        <div class="criteria-item">
          <div class="ci-label">1. OS Version &mdash; Must be RHEL 8.x</div>
          <div class="ci-detail">RHEL 7, RHEL 9, and unknown versions are excluded. RHEL 7 hosts exit silently without producing output.</div>
        </div>
        <div class="criteria-item">
          <div class="ci-label">2. No Previous Upgrade &mdash; /etc/os_upgrade must be absent</div>
          <div class="ci-detail">Hosts previously upgraded from RHEL 7 to 8 via leapp are not eligible for a second in-place upgrade.</div>
        </div>
        <div class="criteria-item">
          <div class="ci-label">3. /boot Partition &mdash; Minimum 1,024 MB (2 GB required)</div>
          <div class="ci-detail">Insufficient /boot space is the most common hard blocker. The upgrade process requires at least 2 GB free.</div>
        </div>
        <div class="criteria-item">
          <div class="ci-label">4. Not a DB Server &mdash; DBTYPE must be unset</div>
          <div class="ci-detail">Servers with DBTYPE set in /boot/PNC_PROVISION_CONFIG are not yet certified for RHEL 9 in-place upgrade.</div>
        </div>
        <div class="criteria-item conditional-note">
          <div class="ci-label">&#9889; Conditional &mdash; rootvg free space &lt; 22 GB</div>
          <div class="ci-detail">These servers are upgrade-eligible once the volume group is expanded. <a href="${UPGRADE_DISK_REQUEST_URL:-#}" target="_blank" rel="noopener">Submit a disk expansion request</a> first, then request the upgrade. Counted toward the eligibility rate.</div>
        </div>
      </div>
    </div>
  </div>

  <div class="controls">
    <div class="search-wrap">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
      <input type="text" id="searchInput" placeholder="Search by host, datacenter, mnemonic, environment, or comments&hellip;"/>
    </div>
    <select class="filter-select" id="eligFilter">
      <option value="">All Eligibility</option>
      <option value="ELIGIBLE">Eligible</option>
      <option value="CONDITIONAL">Conditional</option>
      <option value="INELIGIBLE">Ineligible</option>
      <option value="UNKNOWN">Unknown (unreachable)</option>
    </select>
    <button class="dl-btn" onclick="window.location.href='RHEL8-9_Upgrade_Eligibility_Report.csv'">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
      Download CSV
    </button>
    <span class="results-count" id="resultsCount"></span>
  </div>

  <div class="table-card">
    <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th onclick="sortTable('Host')" id="th-Host">Host<span class="sort-arrow">&#9650;</span></th>
            <th onclick="sortTable('Datacenter')" id="th-Datacenter">Datacenter<span class="sort-arrow">&#9650;</span></th>
            <th onclick="sortTable('Mnemonic')" id="th-Mnemonic">Mnemonic<span class="sort-arrow">&#9650;</span></th>
            <th onclick="sortTable('Environment')" id="th-Environment">Environment<span class="sort-arrow">&#9650;</span></th>
            <th onclick="sortTable('OS')" id="th-OS">OS<span class="sort-arrow">&#9650;</span></th>
            <th onclick="sortTable('Eligibility')" id="th-Eligibility">Eligibility<span class="sort-arrow">&#9650;</span></th>
            <th>Comments</th>
          </tr>
        </thead>
        <tbody id="tableBody"></tbody>
      </table>
    </div>
    <div class="pagination">
      <span class="page-info" id="pageInfo"></span>
      <div class="page-btns" id="pageBtns"></div>
    </div>
  </div>

  <footer class="foot">
    <span>RHEL 8 &rarr; 9 Upgrade Eligibility Report &mdash; IaaS &middot; Linux Engineering</span>
    <span>Updated ${_updated} &nbsp;|&nbsp; <a href="RHEL8-9_Upgrade_Eligibility_Report.csv">Download CSV</a></span>
  </footer>
</div>
<script src="upgrade_data.js"></script>
<script>
const PAGE_SIZE=50;
let filteredData=[...serverData].sort((a,b)=>a.Host.localeCompare(b.Host));
let currentPage=1,sortCol='Host',sortDir='asc';
function updateKPIs(){
  const r8=serverData.filter(r=>r.OS==='RHEL 8');
  const t=r8.length,e=r8.filter(r=>r.Eligibility==='ELIGIBLE'||r.Eligibility==='CONDITIONAL').length;
  const i=r8.filter(r=>r.Eligibility==='INELIGIBLE').length;
  const rt=t>0?Math.round(e/t*100):0;
  document.getElementById('kpiTotal').textContent=t.toLocaleString();
  document.getElementById('kpiElig').textContent=e.toLocaleString();
  document.getElementById('kpiInelig').textContent=i.toLocaleString();
  document.getElementById('kpiRate').textContent=rt+'%';
}
function toggleCriteria(){
  const b=document.getElementById('criteriaBody'),c=document.getElementById('criteriaChevron');
  const o=b.classList.toggle('open');c.innerHTML=o?'Hide &#9652;':'Show &#9662;';
}
function sortTable(col){
  document.querySelectorAll('th').forEach(t=>t.classList.remove('sort-active'));
  if(sortCol===col){sortDir=sortDir==='asc'?'desc':'asc';}else{sortCol=col;sortDir='asc';}
  const th=document.getElementById('th-'+col);
  if(th){th.classList.add('sort-active');th.querySelector('.sort-arrow').innerHTML=sortDir==='asc'?'&#9650;':'&#9660;';}
  filteredData.sort((a,b)=>{const va=(a[col]||'').toLowerCase(),vb=(b[col]||'').toLowerCase();return sortDir==='asc'?va.localeCompare(vb):vb.localeCompare(va);});
  currentPage=1;render();
}
function applyFilters(){
  const q=document.getElementById('searchInput').value.toLowerCase();
  const eli=document.getElementById('eligFilter').value;
  filteredData=serverData.filter(r=>{
    const mq=!q||Object.values(r).some(v=>v.toLowerCase().includes(q));
    const me=!eli||r.Eligibility===eli;
    return mq&&me;
  });
  filteredData.sort((a,b)=>{const va=(a[sortCol]||'').toLowerCase(),vb=(b[sortCol]||'').toLowerCase();return sortDir==='asc'?va.localeCompare(vb):vb.localeCompare(va);});
  currentPage=1;render();
}
function badgeHTML(e){
  if(e==='ELIGIBLE')return'<span class="badge badge-eligible">&#10003; ELIGIBLE</span>';
  if(e==='CONDITIONAL')return'<span class="badge badge-conditional">&#9889; CONDITIONAL</span>';
  if(e==='INELIGIBLE')return'<span class="badge badge-ineligible">&#10007; INELIGIBLE</span>';
  return'<span class="badge badge-unknown">? UNKNOWN</span>';
}
function osBadge(os){
  if(os==='RHEL 8')return'<span class="os-badge os-rhel8">RHEL 8</span>';
  if(os==='RHEL 9')return'<span class="os-badge os-rhel9">RHEL 9</span>';
  return'<span class="os-badge os-other">'+os+'</span>';
}
function commentClass(e){
  if(e==='CONDITIONAL')return'comment-cell conditional';
  if(e==='INELIGIBLE')return'comment-cell issue';
  if(e==='UNKNOWN')return'comment-cell unknown';
  return'comment-cell';
}
function render(){
  const total=filteredData.length,tp=Math.max(1,Math.ceil(total/PAGE_SIZE));
  currentPage=Math.min(currentPage,tp);
  const s=(currentPage-1)*PAGE_SIZE,en=Math.min(s+PAGE_SIZE,total);
  document.getElementById('resultsCount').textContent=total===0?'No results':'Showing '+(s+1).toLocaleString()+'–'+en.toLocaleString()+' of '+total.toLocaleString()+' servers';
  document.getElementById('tableBody').innerHTML=filteredData.slice(s,en).map(r=>'<tr><td class="host-cell">'+r.Host+'</td><td>'+r.Datacenter+'</td><td>'+r.Mnemonic+'</td><td>'+r.Environment+'</td><td>'+osBadge(r.OS)+'</td><td>'+badgeHTML(r.Eligibility)+'</td><td class="'+commentClass(r.Eligibility)+'">'+r.Comments+'</td></tr>').join('')||'<tr><td colspan="7" style="text-align:center;padding:2rem;color:var(--muted)">No servers match your filters.</td></tr>';
  document.getElementById('pageInfo').textContent=total===0?'':'Page '+currentPage+' of '+tp;
  const c=document.getElementById('pageBtns');
  if(tp<=1){c.innerHTML='';return;}
  const btns=[];
  btns.push('<button class="page-btn" '+(currentPage===1?'disabled':'')+' onclick="goPage('+(currentPage-1)+')">&lsaquo;</button>');
  let s2=Math.max(1,currentPage-3),e2=Math.min(tp,s2+6);
  if(e2-s2<6)s2=Math.max(1,e2-6);
  if(s2>1){btns.push('<button class="page-btn" onclick="goPage(1)">1</button>');if(s2>2)btns.push('<span style="padding:.38rem .4rem;color:var(--muted)">&hellip;</span>');}
  for(let i=s2;i<=e2;i++)btns.push('<button class="page-btn'+(i===currentPage?' active':'')+'" onclick="goPage('+i+')">'+i+'</button>');
  if(e2<tp){if(e2<tp-1)btns.push('<span style="padding:.38rem .4rem;color:var(--muted)">&hellip;</span>');btns.push('<button class="page-btn" onclick="goPage('+tp+')">'+tp+'</button>');}
  btns.push('<button class="page-btn" '+(currentPage===tp?'disabled':'')+' onclick="goPage('+(currentPage+1)+')">&rsaquo;</button>');
  c.innerHTML=btns.join('');
}
function goPage(p){currentPage=p;render();window.scrollTo({top:0,behavior:'smooth'});}
document.getElementById('searchInput').addEventListener('input',applyFilters);
document.getElementById('eligFilter').addEventListener('change',applyFilters);
document.getElementById('th-Host').classList.add('sort-active');
updateKPIs();render();
</script>
</body>
</html>
UPGHT
    log INFO "Upgrade/index.html written"
    log INFO "Upgrade web dir: $_upg_dir"
}

RPT_Upgrade
log INFO "Upgrade/index.html done"

# Non-responsive host list
awk '!/^#/ && ($2=="SSHFAIL" || $3=="SSHFAIL") {print $1}' "$INVENTORYDATA" | sort > "${WEBDIR}/${LOSTLIST}"
LOSTCOUNT=$(wc -l < "${WEBDIR}/${LOSTLIST}")
log INFO "Non-responsive hosts: $LOSTCOUNT — ${WEBDIR}/${LOSTLIST}"

log SECTION "rhel_inv_report.sh complete"
exit 0
