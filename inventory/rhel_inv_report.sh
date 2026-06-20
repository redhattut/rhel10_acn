#!/bin/bash
# =============================================================================
# rhel_inv_report.sh — Inventory report and HTML page generator
# =============================================================================
# Generates all HTML reports for the RHEL_v2 web directory.
# All pages use style.css (same stylesheet as index.html).
#
# Produces:
#   index.html                                    main dashboard
#   RHEL_INVENTORY.html                           full host table (via rhel_convert_html.sh)
#   Releases.html                                 per-release count detail
#   Location.html                                 inventory by datacenter
#   Application.html                              inventory by app mnemonic
#   Monthly_Redhat_Linux_Depoloyment_Report.html  last 12 months of deployments
#   Annual_Redhat_Linux_Depoloyment_Report.html   all-years deployment history
#   RHEL_nonresponsive_v2.txt                     hosts where field 2 = "?"
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

# --- Validate inputs ----------------------------------------------------------
if [[ ! -f "$INVENTORYDATA" ]]; then
    log ERROR "INVENTORYDATA not found: $INVENTORYDATA"
    exit 1
fi
if [[ ! -d "$WEBDIR" ]]; then
    mkdir -p "$WEBDIR"
    log INFO "Created WEBDIR: $WEBDIR"
fi

RECCOUNT=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
log INFO "Generating reports from $INVENTORYDATA ($RECCOUNT records)"
log INFO "Publishing to: $WEBDIR"

# =============================================================================
# Shared HTML fragments
# =============================================================================
html_head() {
    local title="$1"
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title}</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
EOF
}

html_header() {
    local subtitle="$1"
    cat <<EOF
  <header>
    <h1>Red Hat Linux Inventory and Deployment Reports</h1>
    <p>${subtitle} &nbsp;&middot;&nbsp; Last updated: $(date) &nbsp;&middot;&nbsp; <a href="index.html" style="color:#93c5fd;text-decoration:none">&#8592; Dashboard</a></p>
  </header>
  <div class="container">
EOF
}

html_foot() {
    cat <<EOF
    <footer><p>&copy; $(date +%Y) PNC. OS Engineering.</p></footer>
  </div>
</body>
</html>
EOF
}

# =============================================================================
# Intermediate data — built once, shared across all report functions
# =============================================================================
log INFO "Building intermediate data files"
rm -f "$APPDATAPLAT" "$APPDATAREL" "$LOCDATAPLAT" "$LOCDATAREL"

while read -r hostname PLATFORM LOCATION APPCODE ENVIRONMENT BUILDDATE \
           RELEASE rest; do
    echo "$LOCATION $PLATFORM"        >> "$LOCDATAPLAT"
    echo "$LOCATION ${RELEASE/.*\/}"  >> "$LOCDATAREL"
    echo "$APPCODE  $PLATFORM"        >> "$APPDATAPLAT"
    echo "$APPCODE  $RELEASE"         >> "$APPDATAREL"
done < <(grep -v "^#" "$INVENTORYDATA")
log INFO "Intermediate files built"

# =============================================================================
# Summary counts
# =============================================================================
log INFO "Computing summary counts"

VIRTUAL_SERVERS=$(grep -v "Microsoft_Corporation" "$INVENTORYDATA" | awk '$2=="Virt"' | wc -l)
PHYSICAL_SERVERS=$(grep -v "Microsoft_Corporation" "$INVENTORYDATA" | awk '$2=="Phys"' | wc -l)
CLOUD_SERVERS=$(grep -i "Microsoft_Corporation" "$INVENTORYDATA" | wc -l)
SSHFAIL=$(grep -c "SSHFAIL" "$INVENTORYDATA" 2>/dev/null || echo 0)
SSHFAIL=${SSHFAIL:-0}

# OS counts (field 3 = RELEASE in .dat)
RHEL_79=$(awk  '{print $3}' "$INVENTORYDATA" | grep -c "^7\.9$"  || echo 0)
RHEL_88=$(awk  '{print $3}' "$INVENTORYDATA" | grep -c "^8\.8$"  || echo 0)
RHEL_89=$(awk  '{print $3}' "$INVENTORYDATA" | grep -c "^8\.9$"  || echo 0)
RHEL_810=$(awk '{print $3}' "$INVENTORYDATA" | grep -c "^8\.10$" || echo 0)
RHEL_95=$(awk  '{print $3}' "$INVENTORYDATA" | grep -c "^9\.5$"  || echo 0)
RHEL_96=$(awk  '{print $3}' "$INVENTORYDATA" | grep -c "^9\.6$"  || echo 0)
RHEL_97=$(awk  '{print $3}' "$INVENTORYDATA" | grep -c "^9\.7$"  || echo 0)
RHEL_98=$(awk  '{print $3}' "$INVENTORYDATA" | grep -c "^9\.8$"  || echo 0)

# Environment counts (field 27 = ENVIRONMENT)
ENV_RND=$(awk  '{print $27}' "$INVENTORYDATA" | grep -c "^RND$"  || echo 0)
ENV_UAT=$(awk  '{print $27}' "$INVENTORYDATA" | grep -c "^UAT$"  || echo 0)
ENV_QA=$(awk   '{print $27}' "$INVENTORYDATA" | grep -c "^QA$"   || echo 0)
ENV_PROD=$(awk '{print $27}' "$INVENTORYDATA" | grep -c "^PROD$" || echo 0)

# Location counts (field 21 = LOCATION)
LOC_GF0=$(awk '{print $21}' "$INVENTORYDATA" | grep -c "GF0" || echo 0)
LOC_GF1=$(awk '{print $21}' "$INVENTORYDATA" | grep -c "GF1" || echo 0)
LOC_GF2=$(awk '{print $21}' "$INVENTORYDATA" | grep -c "GF2" || echo 0)

log INFO "Virtual: $VIRTUAL_SERVERS  Physical: $PHYSICAL_SERVERS  Cloud: $CLOUD_SERVERS  SSH failures: $SSHFAIL"

# =============================================================================
# RPT_Main — index.html
# =============================================================================
RPT_Main() {
    log INFO "Generating index.html"
    html_head "Linux Inventory and Deployment Reports"
    cat <<EOF
  <header>
    <h1>Red Hat Linux Inventory and Deployment Reports</h1>
    <p>Last updated: $(date)</p>
  </header>
  <div class="container">

    <div class="card">
      <h2>Server Overview</h2>
      <div class="stats-grid">
        <div class="stat-item"><h3>Virtual Servers</h3><p>$VIRTUAL_SERVERS</p></div>
        <div class="stat-item"><h3>Physical Servers</h3><p>$PHYSICAL_SERVERS</p></div>
        <div class="stat-item"><h3>Cloud Servers</h3><p>$CLOUD_SERVERS</p></div>
        <div class="stat-item warning">
          <h3>SSHFAIL</h3><p>$SSHFAIL</p>
          <div class="details">Unable to retrieve system data</div>
        </div>
      </div>
    </div>

    <div class="card">
      <h2>Operating Systems</h2>
      <div class="os-grid">
        <div class="os-category">
          <h3>RHEL 7.x Series</h3>
          <div class="os-version"><span>RHEL 7.9</span><span>$RHEL_79</span></div>
        </div>
        <div class="os-category">
          <h3>RHEL 8.x Series</h3>
          <div class="os-version"><span>RHEL 8.8</span><span>$RHEL_88</span></div>
          <div class="os-version"><span>RHEL 8.9</span><span>$RHEL_89</span></div>
          <div class="os-version"><span>RHEL 8.10</span><span>$RHEL_810</span></div>
        </div>
        <div class="os-category">
          <h3>RHEL 9.x Series</h3>
          <div class="os-version"><span>RHEL 9.5</span><span>$RHEL_95</span></div>
          <div class="os-version"><span>RHEL 9.6</span><span>$RHEL_96</span></div>
          <div class="os-version"><span>RHEL 9.7</span><span>$RHEL_97</span></div>
          <div class="os-version"><span>RHEL 9.8</span><span>$RHEL_98</span></div>
        </div>
      </div>
    </div>

    <div class="card">
      <h2>Environments</h2>
      <div class="stats-grid">
        <div class="stat-item"><h3>RND</h3><p>$ENV_RND</p></div>
        <div class="stat-item"><h3>UAT</h3><p>$ENV_UAT</p></div>
        <div class="stat-item"><h3>QA</h3><p>$ENV_QA</p></div>
        <div class="stat-item"><h3>PROD</h3><p>$ENV_PROD</p></div>
      </div>
    </div>

    <div class="card">
      <h2>Server Locations</h2>
      <div class="stats-grid">
        <div class="stat-item"><h3>GF0</h3><p>$LOC_GF0</p></div>
        <div class="stat-item"><h3>GF1</h3><p>$LOC_GF1</p></div>
        <div class="stat-item"><h3>GF2</h3><p>$LOC_GF2</p></div>
      </div>
    </div>

    <div class="card">
      <h2>Additional Resources</h2>
      <div class="resources-section">
        <div class="resource-category">
          <h3>Red Hat Server Inventory Data</h3>
          <div class="resource-subcategory">
            <h4>Raw Data Formats</h4>
            <ul class="resource-list">
              <li><a href="RHEL_INVENTORY_v2.txt">Text Format</a></li>
              <li><a href="RHEL_INVENTORY_v2.html">HTML Table</a></li>
              <li><a href="RHEL_INVENTORY_v2.csv">Spreadsheet</a></li>
              <li><a href="historical_data">Recent Spreadsheets</a></li>
            </ul>
          </div>
          <div class="resource-subcategory">
            <h4>Specialized Inventories</h4>
            <ul class="resource-list">
              <li><a href="RHEL_PACKAGES_v2.csv">Linux Package Inventory Spreadsheet</a></li>
              <li><a href="Midrange_INVENTORY.csv">Midrange Inventory Spreadsheet</a></li>
            </ul>
          </div>
        </div>
        <div class="resource-category">
          <h3>Inventory Reports</h3>
          <ul class="resource-list">
            <li><a href="Location.html">Inventory by Datacenter</a></li>
            <li><a href="Application.html">Inventory by Application Code</a></li>
            <li><a href="Releases.html">Release Detail</a></li>
          </ul>
        </div>
        <div class="resource-category">
          <h3>Deployment Reports</h3>
          <ul class="resource-list">
            <li><a href="Monthly_Redhat_Linux_Depoloyment_Report.html">Monthly Red Hat Linux Deployment Report</a></li>
            <li><a href="Annual_Redhat_Linux_Depoloyment_Report.html">Annual Red Hat Linux Deployment Report</a></li>
            <li><a href="RHEL_DEPLOYMENTS_v2.csv">Detailed Deployment Spreadsheet</a></li>
          </ul>
        </div>
      </div>
    </div>

    <footer><p>&copy; $(date +%Y) PNC. OS Engineering.</p></footer>
  </div>
</body>
</html>
EOF
}

# =============================================================================
# RPT_Release_detail — Releases.html
# =============================================================================
RPT_Release_detail() {
    log INFO "Generating Releases.html"
    local GTOTAL=0

    html_head "RHEL Release Detail"
    html_header "Release detail"

    cat <<'TBLSTART'
    <div class="card">
      <h2>RHEL release counts</h2>
      <table style="width:100%;border-collapse:collapse;font-size:.875rem">
        <thead>
          <tr style="border-bottom:1px solid var(--border-color)">
            <th style="text-align:left;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em">Release</th>
            <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em">Count</th>
          </tr>
        </thead>
        <tbody>
TBLSTART

    awk '{print $3}' "$INVENTORYDATA" \
        | grep -v "^#" \
        | sort | uniq -c \
        | sort -rn \
        | while read -r TOT REL; do
            if [[ "${REL:0:1}" == "S" ]]; then
                LABEL="SuSE $REL"
            else
                LABEL="RHEL $REL"
            fi
            GTOTAL=$(( GTOTAL + TOT ))
            echo "          <tr style=\"border-bottom:1px solid #f1f5f9\">"
            echo "            <td style=\"padding:8px 12px\">$LABEL</td>"
            echo "            <td style=\"padding:8px 12px;text-align:right;font-weight:600\">$TOT</td>"
            echo "          </tr>"
        done

    GRAND=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
    cat <<TBLEND
          <tr style="border-top:2px solid var(--border-color);background:var(--primary-bg)">
            <td style="padding:8px 12px;font-weight:600">Grand Total</td>
            <td style="padding:8px 12px;text-align:right;font-weight:600">$GRAND</td>
          </tr>
        </tbody>
      </table>
    </div>
TBLEND

    html_foot
}

# =============================================================================
# RPT_by_Location — Location.html
# =============================================================================
RPT_by_Location() {
    log INFO "Generating Location.html"

    html_head "Inventory by Datacenter"
    html_header "Inventory by datacenter"

    echo '    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:1rem;margin-bottom:1.5rem">'

    local GTOTAL=0

    (grep -v "^?" "$LOCDATAPLAT" | awk '{print $1}' | sort -u; echo "?"; echo "END") \
    | while read -r LOC; do
        [[ "$LOC" == "END" ]] && break
        [[ "$LOC" == "?" ]] && LOCDESC="Unspecified" || LOCDESC="$LOC"
        STOTAL=$(grep "^$LOC " "$LOCDATAPLAT" | wc -l)

        cat <<CARDSTART
      <div class="card" style="margin-bottom:0">
        <h2>$LOCDESC</h2>
        <div style="font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em;margin-bottom:.5rem">Platform</div>
CARDSTART

        grep "^$LOC " "$LOCDATAPLAT" \
            | awk '{print $2}' \
            | sort | uniq -c \
            | while read -r TOT PLAT; do
                cat <<PLATROW
        <div style="display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #f1f5f9;font-size:.875rem">
          <span>$PLAT</span><span style="font-weight:600">$TOT</span>
        </div>
PLATROW
            done

        cat <<VERSSTART
        <div style="font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em;margin:.75rem 0 .5rem">Versions</div>
VERSSTART

        grep "^$LOC " "$LOCDATAREL" \
            | awk '{print $2}' \
            | sort | uniq -c \
            | sort -rn \
            | while read -r TOT REL; do
                [[ -z "$REL" ]] && REL="?"
                cat <<RELROW
        <div style="display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #f1f5f9;font-size:.875rem">
          <span>RHEL $REL</span><span style="font-weight:600">$TOT</span>
        </div>
RELROW
            done

        cat <<CARDEND
        <div style="display:flex;justify-content:space-between;padding:6px 0;margin-top:4px;font-size:.875rem;font-weight:600">
          <span>Total</span><span>$STOTAL</span>
        </div>
      </div>
CARDEND
    done

    echo '    </div>'
    html_foot
}

# =============================================================================
# RPT_by_Mnemonic — Application.html
# =============================================================================
RPT_by_Mnemonic() {
    log INFO "Generating Application.html"

    html_head "Inventory by Application Code"
    html_header "Inventory by application code"

    local GRAND=$(grep -v "^#" "$INVENTORYDATA" | wc -l)

    cat <<'APPSTART'
    <div class="card">
      <h2>Inventory by application code</h2>
      <div style="margin-bottom:1rem">
        <input type="text" id="appSearch" placeholder="Filter by app code..."
               oninput="filterApp()"
               style="padding:6px 10px;font-size:.875rem;border:1px solid var(--border-color);border-radius:.5rem;background:var(--card-bg);color:var(--text-primary);font-family:inherit;outline:none;width:220px">
        <span id="appCount" style="font-size:.8rem;color:var(--text-secondary);margin-left:12px"></span>
      </div>
      <table style="width:100%;border-collapse:collapse;font-size:.875rem" id="appTable">
        <thead>
          <tr style="border-bottom:1px solid var(--border-color)">
            <th style="text-align:left;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em">App Code</th>
            <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em">Total</th>
            <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em">Virt</th>
            <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em">Phys</th>
            <th style="text-align:left;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em">Top OS versions</th>
          </tr>
        </thead>
        <tbody id="appBody">
APPSTART

    grep -v "^???" "$APPDATAPLAT" \
        | awk '{print $1}' \
        | sort -u \
        | while read -r APP; do
            [[ "$APP" == "???" ]] && APPDESC="unspecified" || APPDESC="$APP"
            STOTAL=$(grep "^$APP " "$APPDATAPLAT" | wc -l)
            VIRT=$(grep "^$APP " "$APPDATAPLAT" | awk '$2=="Virt"' | wc -l)
            PHYS=$(grep "^$APP " "$APPDATAPLAT" | awk '$2=="Phys"' | wc -l)
            TOP_OS=$(grep "^$APP " "$APPDATAREL" \
                | awk '{print $2}' \
                | sort | uniq -c | sort -rn \
                | head -3 \
                | awk '{printf "%s×%s  ",$2,$1}')

            cat <<APPROW
          <tr style="border-bottom:1px solid #f1f5f9" data-app="$(echo $APPDESC | tr '[:upper:]' '[:lower:]')">
            <td style="padding:8px 12px;font-weight:500">$APPDESC</td>
            <td style="padding:8px 12px;text-align:right;font-weight:600">$STOTAL</td>
            <td style="padding:8px 12px;text-align:right;color:var(--text-secondary)">$VIRT</td>
            <td style="padding:8px 12px;text-align:right;color:var(--text-secondary)">$PHYS</td>
            <td style="padding:8px 12px;font-size:.8rem;color:var(--text-secondary)">$TOP_OS</td>
          </tr>
APPROW
        done

    cat <<APPEND
          <tr style="border-top:2px solid var(--border-color);background:var(--primary-bg)">
            <td style="padding:8px 12px;font-weight:600">Grand Total</td>
            <td style="padding:8px 12px;text-align:right;font-weight:600">$GRAND</td>
            <td colspan="3"></td>
          </tr>
        </tbody>
      </table>
    </div>
    <script>
      const appRows = Array.from(document.querySelectorAll('#appBody tr[data-app]'));
      document.getElementById('appCount').textContent = appRows.length + ' app codes';
      function filterApp() {
        const q = document.getElementById('appSearch').value.toLowerCase();
        let v = 0;
        appRows.forEach(r => {
          const show = !q || r.dataset.app.includes(q);
          r.style.display = show ? '' : 'none';
          if (show) v++;
        });
        document.getElementById('appCount').textContent = v + ' of ' + appRows.length + ' app codes';
      }
    </script>
APPEND

    html_foot
}

# =============================================================================
# RPT_Deployment_Monthly — Monthly deployment report
# =============================================================================
RPT_Deployment_Monthly() {
    log INFO "Generating Monthly deployment report"

    local current_year current_month
    current_year=$(date +%Y)
    current_month=$(date +%m)

    html_head "Monthly Red Hat Linux Deployment Report"
    html_header "Monthly deployment report"

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo '    <div class="card"><p style="color:var(--text-secondary)">Deployment data not yet available — see README for initial seed step.</p></div>'
        html_foot
        return
    fi

    echo '    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:1rem">'

    for (( i=0; i<12; i++ )); do
        local month=$(( current_month - i ))
        local year=$current_year
        while [[ $month -le 0 ]]; do
            month=$(( month + 12 ))
            year=$(( year - 1 ))
        done
        month=$(printf "%02d" $month)
        local month_name
        month_name=$(date -d "${year}-${month}-01" '+%B' 2>/dev/null || echo "Month $month")
        local date_pattern="${year}-${month}"

        # Write month data to temp file
        local _mdtmp
        _mdtmp=$(mktemp /tmp/rhel_mdata.XXXXXX)
        awk -v p="$date_pattern" '$1 ~ p {print $0}' "$DEPLOYMENTDATA" > "$_mdtmp"
        if [[ ! -s "$_mdtmp" ]]; then rm -f "$_mdtmp"; continue; fi

        # Count with single awk pass — fast even on large deployment files
        local total=0 virt=0 phys=0 cloud=0
        eval "$(awk '
            BEGIN { total=0; virt=0; phys=0; cloud=0 }
            /Microsoft_Corporation/ { cloud++; total++; next }
            $3=="Virt" { virt++; total++; next }
            $3=="Phys" { phys++; total++; next }
            { total++ }
            END { printf "total=%d virt=%d phys=%d cloud=%d
", total, virt, phys, cloud }
        ' "$_mdtmp")"

        cat <<MCARD
      <div class="month-card">
        <div class="month-header">
          <h2>${month_name} ${year}</h2>
          <span class="total-deployments">${total} deployments</span>
        </div>
        <div class="deployment-details">
          <div class="deployment-section">
            <h3>Server type</h3>
            <ul class="version-list">
MCARD

        [[ $virt  -gt 0 ]] && echo "              <li class=\"version-item\"><span class=\"version-name\">Virtual</span><span class=\"version-count\">${virt}</span></li>"
        [[ $phys  -gt 0 ]] && echo "              <li class=\"version-item\"><span class=\"version-name\">Physical</span><span class=\"version-count\">${phys}</span></li>"
        [[ $cloud -gt 0 ]] && echo "              <li class=\"version-item\"><span class=\"version-name\">Cloud</span><span class=\"version-count\">${cloud}</span></li>"

        cat <<MVERS
            </ul>
          </div>
          <div class="deployment-section">
            <h3>RHEL versions</h3>
            <ul class="version-list">
MVERS

        awk '{print $4}' "$_mdtmp" | sort | uniq -c | sort -rn \
        | while read -r count version; do
            [[ -z "$count" || -z "$version" ]] && continue
            echo "              <li class=\"version-item\"><span class=\"version-name\">RHEL ${version}</span><span class=\"version-count\">${count}</span></li>"
        done
        rm -f "$_mdtmp"

        cat <<MEND
            </ul>
          </div>
        </div>
      </div>
MEND
    done

    echo '    </div>'
    html_foot
}

# =============================================================================
# RPT_Deployment_Annual — Annual deployment report
# Replaces RHEL_deployment_RPT_YEARLY.sh — logic inlined here
# =============================================================================
RPT_Deployment_Annual() {
    log INFO "Generating Annual deployment report"

    html_head "Annual Red Hat Linux Deployment Report"
    html_header "Annual deployment report — all years"

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo '    <div class="card"><p style="color:var(--text-secondary)">Deployment data not yet available — see README for initial seed step.</p></div>'
        html_foot
        return
    fi

    echo '    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:1rem">'

    # Get unique years — write to temp file to avoid pipeline subshell scope issues
    local _ytmp
    _ytmp=$(mktemp /tmp/rhel_years.XXXXXX)
    awk -F- '{print $1}' "$DEPLOYMENTDATA" | grep "^[0-9]\{4\}$" | sort -ru > "$_ytmp"

    while read -r year; do
        # Write year data to temp file
        local _ydtmp
        _ydtmp=$(mktemp /tmp/rhel_ydata.XXXXXX)
        grep "^${year}-" "$DEPLOYMENTDATA" > "$_ydtmp"
        [[ ! -s "$_ydtmp" ]] && rm -f "$_ydtmp" && continue

        # Count with single awk pass — fast even on large deployment files
        local total=0 virt=0 phys=0 cloud=0
        eval "$(awk '
            BEGIN { total=0; virt=0; phys=0; cloud=0 }
            /Microsoft_Corporation/ { cloud++; total++; next }
            $3=="Virt" { virt++; total++; next }
            $3=="Phys" { phys++; total++; next }
            { total++ }
            END { printf "total=%d virt=%d phys=%d cloud=%d
", total, virt, phys, cloud }
        ' "$_ydtmp")"

        cat <<YCARD
      <div class="month-card">
        <div class="month-header">
          <h2>${year}</h2>
          <span class="total-deployments">${total} deployments</span>
        </div>
        <div class="deployment-details">
          <div class="deployment-section">
            <h3>Server type</h3>
            <ul class="version-list">
YCARD

        [[ $virt  -gt 0 ]] && echo "              <li class="version-item"><span class="version-name">Virtual</span><span class="version-count">${virt}</span></li>"
        [[ $phys  -gt 0 ]] && echo "              <li class="version-item"><span class="version-name">Physical</span><span class="version-count">${phys}</span></li>"
        [[ $cloud -gt 0 ]] && echo "              <li class="version-item"><span class="version-name">Cloud</span><span class="version-count">${cloud}</span></li>"

        cat <<YVERS
            </ul>
          </div>
          <div class="deployment-section">
            <h3>RHEL versions</h3>
            <ul class="version-list">
YVERS

        awk '{print $4}' "$_ydtmp" | sort | uniq -c | sort -rn         | while read -r count version; do
            [[ -z "$count" || -z "$version" ]] && continue
            echo "              <li class="version-item"><span class="version-name">RHEL ${version}</span><span class="version-count">${count}</span></li>"
        done

        cat <<YEND
            </ul>
          </div>
        </div>
      </div>
YEND
        rm -f "$_ydtmp"
    done < "$_ytmp"
    rm -f "$_ytmp"

    echo '    </div>'
    html_foot
}

# =============================================================================
# Main report logic
# =============================================================================
log SECTION "Generating HTML reports"

RPT_Main       > "$WEBDIR/index.html"
log INFO "index.html done"

RPT_by_Location  > "$WEBDIR/Location.html"
log INFO "Location.html done"

RPT_by_Mnemonic  > "$WEBDIR/Application.html"
log INFO "Application.html done"

RPT_Release_detail > "$WEBDIR/Releases.html"
log INFO "Releases.html done"

set -x  # DEBUG — trace deployment report generation
RPT_Deployment_Annual  > "$WEBDIR/Annual_Redhat_Linux_Depoloyment_Report.html"
set +x
log INFO "Annual deployment report done"

set -x
RPT_Deployment_Monthly > "$WEBDIR/Monthly_Redhat_Linux_Depoloyment_Report.html"
set +x
log INFO "Monthly deployment report done"

# Non-responsive host list
log INFO "Generating non-responsive host list"
awk '{print $1" "$2}' "$INVENTORYDATA" \
    | grep "?$" \
    | awk '{print $1}' \
    | sort > "$WEBDIR/$LOSTLIST"
LOSTCOUNT=$(wc -l < "$WEBDIR/$LOSTLIST")
log INFO "Non-responsive hosts: $LOSTCOUNT — $WEBDIR/$LOSTLIST"

log SECTION "rhel_inv_report.sh complete"
exit 0
