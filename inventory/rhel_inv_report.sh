#!/bin/bash
# =============================================================================
# rhel_inv_report.sh — Inventory report and HTML page generator
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

# --- Validate ------------------------------------------------------------------
if [[ ! -f "$INVENTORYDATA" ]]; then
    log ERROR "INVENTORYDATA not found: $INVENTORYDATA"; exit 1
fi
mkdir -p "$WEBDIR"

RECCOUNT=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
log INFO "Generating reports from $INVENTORYDATA ($RECCOUNT records)"
log INFO "Publishing to: $WEBDIR"

DATESTAMP=$(date)
YEAR=$(date +%Y)

# =============================================================================
# Intermediate data — single awk pass, all four files at once
# Fields: 1=Host 2=Type 3=OS 21=Location 26=AppCode 27=Env 28=BuildDate
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
# Summary counts — single awk pass using OS_VERSIONS from conf
# =============================================================================
log INFO "Computing summary counts"

# Build OS count variables dynamically from OS_VERSIONS array in conf
# Each version becomes OS_COUNT_X_Y (dots replaced with underscores)
OS_AWK_COUNTS=""
OS_AWK_PRINTF=""
for ver in "${OS_VERSIONS[@]}"; do
    varname="OS_${ver//./_}"
    OS_AWK_COUNTS+="    if (\$3==\"${ver}\") ${varname}++
"
    OS_AWK_PRINTF+="    printf \"${varname}=%d\\n\", ${varname}+0
"
done

eval "$(awk -v awkos="$OS_AWK_COUNTS" -v awkpr="$OS_AWK_PRINTF" \
    'BEGIN{virt=0;phys=0;fail=0;ernd=0;euat=0;eqa=0;eprod=0
           lgf0=0;lgf1=0;lgf2=0}
    !/^#/{
        if ($2=="Virt") virt++
        else if ($2=="Phys") phys++
        if ($2=="SSHFAIL"||$3=="SSHFAIL") fail++
        if ($27=="RND")  ernd++
        if ($27=="UAT")  euat++
        if ($27=="QA")   eqa++
        if ($27=="PROD") eprod++
        if ($21~/GF0/) lgf0++
        if ($21~/GF1/) lgf1++
        if ($21~/GF2/) lgf2++
    }
    END{
        printf "VIRTUAL_SERVERS=%d\n",  virt
        printf "PHYSICAL_SERVERS=%d\n", phys
        printf "CLOUD_SERVERS=%d\n",    0
        printf "SSHFAIL=%d\n",          fail
        printf "ENV_RND=%d\n",  ernd
        printf "ENV_UAT=%d\n",  euat
        printf "ENV_QA=%d\n",   eqa
        printf "ENV_PROD=%d\n", eprod
        printf "LOC_GF0=%d\n",  lgf0
        printf "LOC_GF1=%d\n",  lgf1
        printf "LOC_GF2=%d\n",  lgf2
    }' "$INVENTORYDATA")"

# OS counts — separate pass using dynamic awk built from OS_VERSIONS
eval "$(awk '{
'"$OS_AWK_COUNTS"'
}
END{
'"$OS_AWK_PRINTF"'
}' "$INVENTORYDATA")"

log INFO "Virtual: $VIRTUAL_SERVERS  Physical: $PHYSICAL_SERVERS  SSH failures: $SSHFAIL"

# =============================================================================
# Shared HTML helpers
# IMPORTANT: log() must NEVER be called inside HTML-generating functions
# since their stdout is redirected to the HTML file.
# =============================================================================

# Fix 1,2,6,7,8: header width matches body — use max-width:100% on outer
# container but a consistent inner wrapper for the body content.
# The header spans full width; the content div constrains to match.

html_head() {
    cat << EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${1}</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
EOF
}

# html_header: header width matches the body content width
# Uses a wrapper div so header and body are the same width
html_header() {
    local subtitle="$1"
    local ts; ts=$(date)
    cat << EOF

  <header style="border-radius:0;margin-bottom:0">
    <h1>Red Hat Linux Inventory and Deployment Reports</h1>
    <p>${subtitle} &nbsp;&middot;&nbsp; Last updated: ${ts} &nbsp;&middot;&nbsp; <a href="index.html" style="color:#93c5fd;text-decoration:none">&#8592; Dashboard</a></p>
  </header>
  <div class="container">
EOF
}

html_foot() {
    cat << EOF
    <footer><p>&copy; ${YEAR} PNC. OS Engineering.</p></footer>
  </div>
</body>
</html>
EOF
}

# =============================================================================
# RPT_Main — index.html
# Fix 1: header width matches body — both inside same .page-wrap
# Fix 5: OS versions driven from OS_SERIES config
# =============================================================================
RPT_Main() {
    html_head "Linux Inventory and Deployment Reports"

    local ts; ts=$(date)
    cat << EOF

  <header style="border-radius:0;margin-bottom:0">
    <h1>Red Hat Linux Inventory and Deployment Reports</h1>
    <p>Last updated: ${ts}</p>
  </header>
  <div class="container">

    <div class="card">
      <h2>Server Overview</h2>
      <div class="stats-grid">
        <div class="stat-item"><h3>Virtual Servers</h3><p>${VIRTUAL_SERVERS}</p></div>
        <div class="stat-item"><h3>Physical Servers</h3><p>${PHYSICAL_SERVERS}</p></div>
        <div class="stat-item"><h3>Cloud Servers</h3><p>${CLOUD_SERVERS}</p></div>
        <div class="stat-item warning">
          <h3>SSHFAIL</h3><p>${SSHFAIL}</p>
          <div class="details">Unable to retrieve system data</div>
        </div>
      </div>
    </div>

    <div class="card">
      <h2>Operating Systems</h2>
      <div class="os-grid">
EOF

    # Build OS grid from OS_SERIES config — easy to add/remove series
    for series_entry in "${OS_SERIES[@]}"; do
        local series_label="${series_entry%%:*}"
        local series_vers="${series_entry##*:}"
        echo "        <div class=\"os-category\">"
        echo "          <h3>${series_label}</h3>"
        IFS=',' read -ra vers <<< "$series_vers"
        for ver in "${vers[@]}"; do
            local varname="OS_${ver//./_}"
            local count="${!varname:-0}"
            echo "          <div class=\"os-version\"><span>RHEL ${ver}</span><span>${count}</span></div>"
        done
        echo "        </div>"
    done

    cat << EOF
      </div>
    </div>

    <div class="card">
      <h2>Environments</h2>
      <div class="stats-grid">
        <div class="stat-item"><h3>RND</h3><p>${ENV_RND}</p></div>
        <div class="stat-item"><h3>UAT</h3><p>${ENV_UAT}</p></div>
        <div class="stat-item"><h3>QA</h3><p>${ENV_QA}</p></div>
        <div class="stat-item"><h3>PROD</h3><p>${ENV_PROD}</p></div>
      </div>
    </div>

    <div class="card">
      <h2>Server Locations</h2>
      <div class="stats-grid">
        <div class="stat-item"><h3>GF0</h3><p>${LOC_GF0}</p></div>
        <div class="stat-item"><h3>GF1</h3><p>${LOC_GF1}</p></div>
        <div class="stat-item"><h3>GF2</h3><p>${LOC_GF2}</p></div>
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
              <li><a href="${INVENTDATATEXT}">Text Format</a></li>
              <li><a href="${INVENTDATAHTML}">HTML Table</a></li>
              <li><a href="${INVENTDATACSV}">Spreadsheet</a></li>
              <li><a href="historical_data">Recent Spreadsheets</a></li>
            </ul>
          </div>
          <div class="resource-subcategory">
            <h4>Specialized Inventories</h4>
            <ul class="resource-list">
              <li><a href="$(basename "$PACKAGEDATA")">Linux Package Inventory Spreadsheet</a></li>
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
            <li><a href="${DEPLOYDATACSV##*/}">Detailed Deployment Spreadsheet</a></li>
          </ul>
        </div>
      </div>
    </div>

    <footer><p>&copy; ${YEAR} PNC. OS Engineering.</p></footer>
  </div>
</body>
</html>
EOF
}

# =============================================================================
# RPT_Release_detail — Releases.html
# =============================================================================
RPT_Release_detail() {
    local GRAND
    GRAND=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
    html_head "RHEL Release Detail"
    html_header "Release detail"
    cat << 'TBLSTART'
    <div class="card">
      <h2>RHEL release counts</h2>
      <table style="width:100%;border-collapse:collapse;font-size:.875rem">
        <thead><tr style="border-bottom:1px solid var(--border-color)">
          <th style="text-align:left;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase">Release</th>
          <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase">Count</th>
        </tr></thead>
        <tbody>
TBLSTART

    awk '!/^#/{print $3}' "$INVENTORYDATA" | sort | uniq -c | sort -rn \
    | while read -r TOT REL; do
        [[ "${REL:0:1}" == "S" ]] && LABEL="SuSE $REL" || LABEL="RHEL $REL"
        echo "          <tr style=\"border-bottom:1px solid #f1f5f9\">"
        echo "            <td style=\"padding:8px 12px\">$LABEL</td>"
        echo "            <td style=\"padding:8px 12px;text-align:right;font-weight:600\">$TOT</td>"
        echo "          </tr>"
    done

    cat << EOF
          <tr style="border-top:2px solid var(--border-color);background:var(--primary-bg)">
            <td style="padding:8px 12px;font-weight:600">Grand Total</td>
            <td style="padding:8px 12px;text-align:right;font-weight:600">$GRAND</td>
          </tr>
        </tbody></table>
    </div>
EOF
    html_foot
}

# =============================================================================
# RPT_by_Location — Location.html  (Fix 6: header width)
# =============================================================================
RPT_by_Location() {
    html_head "Inventory by Datacenter"
    html_header "Inventory by datacenter"
    echo '    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:1rem;margin-bottom:1.5rem">'

    awk '!/^\?/{print $1}' "$LOCDATAPLAT" | sort -u \
    | while read -r LOC; do
        [[ -z "$LOC" ]] && continue
        STOTAL=$(grep -c "^$LOC " "$LOCDATAPLAT" 2>/dev/null || echo 0)
        STOTAL=$(( STOTAL + 0 ))
        [[ $STOTAL -eq 0 ]] && continue

        echo "      <div class=\"card\" style=\"margin-bottom:0\">"
        echo "        <h2>${LOC} &nbsp;<span style=\"font-size:.8rem;font-weight:400;color:var(--text-secondary)\">${STOTAL} hosts</span></h2>"

        echo "        <div style=\"font-size:.7rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em;margin-bottom:.4rem\">Platform</div>"
        grep "^$LOC " "$LOCDATAPLAT" | awk '{print $2}' | sort | uniq -c \
        | sort -rn \
        | while read -r TOT PLAT; do
            echo "        <div style=\"display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid #f1f5f9;font-size:.875rem\"><span>${PLAT}</span><span style=\"font-weight:600\">${TOT}</span></div>"
        done

        echo "        <div style=\"font-size:.7rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.05em;margin:.7rem 0 .4rem\">OS Versions</div>"
        grep "^$LOC " "$LOCDATAREL" | awk '{print $2}' | sort | uniq -c \
        | sort -rn \
        | while read -r TOT REL; do
            [[ -z "$REL" ]] && continue
            echo "        <div style=\"display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid #f1f5f9;font-size:.875rem\"><span>RHEL ${REL}</span><span style=\"font-weight:600\">${TOT}</span></div>"
        done

        echo "        <div style=\"display:flex;justify-content:space-between;padding:6px 0;margin-top:4px;font-size:.875rem;font-weight:600\"><span>Total</span><span>${STOTAL}</span></div>"
        echo "      </div>"
    done

    echo '    </div>'
    html_foot
}
# =============================================================================
# RPT_by_Mnemonic — Application.html
# =============================================================================
RPT_by_Mnemonic() {
    local GRAND
    GRAND=$(grep -v "^#" "$INVENTORYDATA" | wc -l)

    html_head "Inventory by Application Code"
    html_header "Inventory by application code"

    cat << 'APPSTART'
    <div class="card">
      <h2>Inventory by application code</h2>
      <div style="margin-bottom:1rem;display:flex;align-items:center;gap:12px">
        <input type="text" id="appSearch" placeholder="Filter by app code..."
               oninput="filterApp()"
               style="padding:6px 10px;font-size:.875rem;border:1px solid var(--border-color);border-radius:.5rem;background:var(--card-bg);color:var(--text-primary);font-family:inherit;outline:none;width:220px">
        <span id="appCount" style="font-size:.8rem;color:var(--text-secondary)"></span>
      </div>
      <table style="width:100%;border-collapse:collapse;font-size:.875rem" id="appTable">
        <thead><tr style="border-bottom:1px solid var(--border-color)">
          <th style="text-align:left;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;cursor:pointer" onclick="sortApp(0)">App Code &#8597;</th>
          <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;cursor:pointer" onclick="sortApp(1)">Total &#8597;</th>
          <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase">Virt</th>
          <th style="text-align:right;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase">Phys</th>
          <th style="text-align:left;padding:8px 12px;font-size:.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase">OS Versions</th>
        </tr></thead>
        <tbody id="appBody">
APPSTART

    awk '!/^#/{print $26}' "$INVENTORYDATA" | sort -u \
    | while read -r APP; do
        [[ -z "$APP" || "$APP" == "n/a" ]] && continue
        STOTAL=$(grep -c "^$APP " "$APPDATAPLAT" 2>/dev/null || echo 0)
        STOTAL=$(( STOTAL + 0 ))
        VIRT=$(grep "^$APP " "$APPDATAPLAT" | awk '$2=="Virt"' | wc -l)
        PHYS=$(grep "^$APP " "$APPDATAPLAT" | awk '$2=="Phys"' | wc -l)
        APPLO=$(echo "$APP" | tr '[:upper:]' '[:lower:]')

        # Format: "RHEL 9.7 [2], RHEL 8.10 [1]" — readable inline list
        OS_LIST=$(grep "^$APP " "$APPDATAREL" | awk '{print $2}' \
            | sort | uniq -c | sort -rn | head -5 \
            | awk 'BEGIN{sep=""} {printf "%sRHEL %s [%s]", sep, $2, $1; sep=", "}')

        echo "          <tr style=\"border-bottom:1px solid #f1f5f9\" data-app=\"$APPLO\" data-total=\"$STOTAL\">"
        echo "            <td style=\"padding:8px 12px;font-weight:500\">$APP</td>"
        echo "            <td style=\"padding:8px 12px;text-align:right;font-weight:600\">$STOTAL</td>"
        echo "            <td style=\"padding:8px 12px;text-align:right;color:var(--text-secondary)\">$VIRT</td>"
        echo "            <td style=\"padding:8px 12px;text-align:right;color:var(--text-secondary)\">$PHYS</td>"
        echo "            <td style=\"padding:8px 12px;font-size:.8rem;color:var(--text-secondary)\">$OS_LIST</td>"
        echo "          </tr>"
    done

    cat << EOF
          <tr style="border-top:2px solid var(--border-color);background:var(--primary-bg)">
            <td style="padding:8px 12px;font-weight:600">Grand Total</td>
            <td style="padding:8px 12px;text-align:right;font-weight:600">$GRAND</td>
            <td colspan="3"></td>
          </tr>
        </tbody></table>
    </div>
    <script>
      const appRows=Array.from(document.querySelectorAll('#appBody tr[data-app]'));
      document.getElementById('appCount').textContent=appRows.length+' application codes';
      let sortDir=1;
      function sortApp(col){
        sortDir*=-1;
        appRows.sort((a,b)=>{
          const va=a.querySelectorAll('td')[col].textContent.trim();
          const vb=b.querySelectorAll('td')[col].textContent.trim();
          return col===0?va.localeCompare(vb)*sortDir:(parseInt(vb)-parseInt(va))*sortDir;
        });
        const tb=document.getElementById('appBody');
        appRows.forEach(r=>tb.insertBefore(r,tb.lastElementChild));
      }
      function filterApp(){
        const q=document.getElementById('appSearch').value.toLowerCase();
        let v=0;
        appRows.forEach(r=>{const s=!q||r.dataset.app.includes(q);r.style.display=s?'':'none';if(s)v++;});
        document.getElementById('appCount').textContent=v+' of '+appRows.length+' application codes';
      }
    </script>
EOF
    html_foot
}

# _render_deploy_card — shared helper for monthly and annual cards
# Fix 8: one card per month/year, deployment count on right, proper layout
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

    cat << EOF
      <div class="month-card">
        <div class="month-header">
          <h2>${heading}</h2>
          <span class="total-deployments">${total} Total Deployments</span>
        </div>
        <div class="deployment-details">
          <div class="deployment-section">
            <h3>Server Type</h3>
            <ul class="version-list">
EOF
    [[ $virt  -gt 0 ]] && echo "              <li class=\"version-item\"><span class=\"version-name\">Virtual</span><span class=\"version-count\">${virt}</span></li>"
    [[ $phys  -gt 0 ]] && echo "              <li class=\"version-item\"><span class=\"version-name\">Physical</span><span class=\"version-count\">${phys}</span></li>"
    [[ $cloud -gt 0 ]] && echo "              <li class=\"version-item\"><span class=\"version-name\">Cloud</span><span class=\"version-count\">${cloud}</span></li>"
    cat << 'VERSSTART'
            </ul>
          </div>
          <div class="deployment-section">
            <h3>RHEL Versions</h3>
            <ul class="version-list">
VERSSTART
    awk '{print $4}' "$datafile" | sort | uniq -c | sort -rn \
    | while read -r cnt ver; do
        [[ -z "$cnt" || -z "$ver" ]] && continue
        echo "              <li class=\"version-item\"><span class=\"version-name\">RHEL ${ver}</span><span class=\"version-count\">${cnt}</span></li>"
    done
    cat << 'CARDEND'
            </ul>
          </div>
        </div>
      </div>
CARDEND
}

# =============================================================================
# RPT_Deployment_Monthly — Fix 8: one card per row, matching screenshot layout
# =============================================================================
RPT_Deployment_Monthly() {
    local current_year current_month
    current_year=$(date +%Y)
    current_month=$(date +%m)

    html_head "Monthly Red Hat Linux Deployment Report"
    html_header "Monthly deployment report"

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo '<div class="card"><p style="color:var(--text-secondary)">Deployment data not yet available.</p></div>'
        html_foot; return
    fi

    # One card per row — stack vertically like the screenshot
    echo '    <div style="display:flex;flex-direction:column;gap:1.5rem">'

    for (( i=0; i<12; i++ )); do
        local month=$(( current_month - i ))
        local year=$current_year
        while [[ $month -le 0 ]]; do month=$(( month+12 )); year=$(( year-1 )); done
        month=$(printf "%02d" $month)
        local month_name
        month_name=$(date -d "${year}-${month}-01" '+%B' 2>/dev/null || echo "Month $month")

        local _mdtmp
        _mdtmp=$(mktemp /tmp/rhel_mdata.XXXXXX)
        awk -v p="${year}-${month}" '$1 ~ p' "$DEPLOYMENTDATA" > "$_mdtmp"
        if [[ ! -s "$_mdtmp" ]]; then rm -f "$_mdtmp"; continue; fi

        _render_deploy_card "${month_name} ${year}" "$_mdtmp"
        rm -f "$_mdtmp"
    done

    echo '    </div>'
    html_foot
}

# =============================================================================
# RPT_Deployment_Annual — Fix 8: one card per row
# =============================================================================
RPT_Deployment_Annual() {
    html_head "Annual Red Hat Linux Deployment Report"
    html_header "Annual deployment report — all years"

    if [[ ! -f "$DEPLOYMENTDATA" ]]; then
        echo '<div class="card"><p style="color:var(--text-secondary)">Deployment data not yet available.</p></div>'
        html_foot; return
    fi

    echo '    <div style="display:flex;flex-direction:column;gap:1.5rem">'

    local _ytmp
    _ytmp=$(mktemp /tmp/rhel_years.XXXXXX)
    awk -F- '$1~/^[0-9]{4}$/{print $1}' "$DEPLOYMENTDATA" | sort -ru > "$_ytmp"

    while read -r year; do
        local _ydtmp
        _ydtmp=$(mktemp /tmp/rhel_ydata.XXXXXX)
        grep "^${year}-" "$DEPLOYMENTDATA" > "$_ydtmp"
        if [[ ! -s "$_ydtmp" ]]; then rm -f "$_ydtmp"; continue; fi

        _render_deploy_card "${year}" "$_ydtmp"
        rm -f "$_ydtmp"
    done < "$_ytmp"
    rm -f "$_ytmp"

    echo '    </div>'
    html_foot
}

# =============================================================================
# Main — generate all reports
# =============================================================================
log SECTION "Generating HTML reports"

RPT_Main       > "$WEBDIR/index.html"
log INFO "index.html done"

RPT_by_Location > "$WEBDIR/Location.html"
log INFO "Location.html done"

RPT_by_Mnemonic > "$WEBDIR/Application.html"
log INFO "Application.html done"

RPT_Release_detail > "$WEBDIR/Releases.html"
log INFO "Releases.html done"

RPT_Deployment_Annual > "$WEBDIR/Annual_Redhat_Linux_Depoloyment_Report.html"
log INFO "Annual deployment report done"

RPT_Deployment_Monthly > "$WEBDIR/Monthly_Redhat_Linux_Depoloyment_Report.html"
log INFO "Monthly deployment report done"

# Non-responsive host list
awk '!/^#/ && $2=="?" {print $1}' "$INVENTORYDATA" | sort > "$WEBDIR/$LOSTLIST"
LOSTCOUNT=$(wc -l < "$WEBDIR/$LOSTLIST")
log INFO "Non-responsive hosts: $LOSTCOUNT — $WEBDIR/$LOSTLIST"

log SECTION "rhel_inv_report.sh complete"
exit 0
