#!/bin/bash
# =============================================================================
# rhel_inv_report.sh — Inventory report and HTML page generator
# =============================================================================
# Replaces: RHEL_versions_RPT.sh
#
# Produces the following files in WEBDIR:
#   index.html                              main dashboard (server overview,
#                                           OS counts, environments, locations,
#                                           resource links)
#   Releases.html                           per-release count detail
#   Location.html                           inventory by datacenter
#   Application.html                        inventory by app mnemonic
#   Monthly_Redhat_Linux_Deployment_Report.html
#   Annual_Redhat_Linux_Deployment_Report.html (via rhel_deploy_rpt_yearly.sh)
#   RHEL_nonresponsive.txt                  hosts where field 2 = "?"
#
# All HTML output preserves the original visual structure and file names
# exactly so existing bookmarks and downstream consumers are unaffected.
# HTML modernization is deferred to a later phase.
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found" >&2
    exit 1
fi
. "$CONF"

# --- Source utility library -------------------------------------------------
UTILS="$(dirname "$0")/rhel_utils.sh"
if [[ ! -f "$UTILS" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_utils.sh not found at ${UTILS}" >&2
    exit 1
fi
. "$UTILS"

export LC_NUMERIC=en_US.ISO8859-1
export LC_TIME=en_US.ISO8859-1

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# --- Validate input ----------------------------------------------------------
if [[ ! -f "$INVENTORYDATA" ]]; then
    log ERROR "INVENTORYDATA not found: $INVENTORYDATA"
    exit 1
fi

if [[ ! -d "$WEBDIR" ]]; then
    log ERROR "WEBDIR not found: $WEBDIR"
    exit 1
fi

RECCOUNT=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
log INFO "Generating reports from $INVENTORYDATA ($RECCOUNT records)"
log INFO "Publishing to: $WEBDIR"

# =============================================================================
# Intermediate data files — built once, used by multiple report functions
# =============================================================================

log INFO "Building intermediate data files"

rm -f "$APPDATAPLAT" "$APPDATAREL" "$LOCDATAPLAT" "$LOCDATAREL"

# Read inventory and populate four intermediate files:
#   LOCDATAPLAT : "LOCATION PLATFORM"   one line per host
#   LOCDATAREL  : "LOCATION RELEASE"    one line per host (major.minor only)
#   APPDATAPLAT : "APPCODE  PLATFORM"   one line per host
#   APPDATAREL  : "APPCODE  RELEASE"    one line per host

while read -r hostname PLATFORM LOCATION APPCODE ENVIRONMENT BUILDDATE RELEASE rest; do
    echo "$LOCATION $PLATFORM"              >> "$LOCDATAPLAT"
    echo "$LOCATION ${RELEASE/.*\/}"        >> "$LOCDATAREL"
    echo "$APPCODE  $PLATFORM"              >> "$APPDATAPLAT"
    echo "$APPCODE  $RELEASE"               >> "$APPDATAREL"
done < <(grep -v "^#" "$INVENTORYDATA")

log INFO "Intermediate files built"

# =============================================================================
# Summary counts used by RPT_Main
# =============================================================================

log INFO "Computing summary counts"

VIRTUAL_SERVERS=$(grep -v Microsoft_Corporation "$INVENTORYDATA" \
    | awk '{print $2}' | grep -i Virt | wc -l)
PHYSICAL_SERVERS=$(grep -v Microsoft_Corporation "$INVENTORYDATA" \
    | awk '{print $2}' | grep -i Phys | wc -l)
CLOUD_SERVERS=$(grep -i Microsoft_Corporation "$INVENTORYDATA" | wc -l)
SSHFAIL=$(grep -i SSHFAIL "$INVENTORYDATA" | wc -l)

# OS version counts (field 7 = RELEASE)
RHEL_79=$(awk  '{print $7}' "$INVENTORYDATA" | grep  7\.9  | wc -l)
RHEL_88=$(awk  '{print $7}' "$INVENTORYDATA" | grep  8\.8  | wc -l)
RHEL_89=$(awk  '{print $7}' "$INVENTORYDATA" | grep  8\.9  | wc -l)
RHEL_810=$(awk '{print $7}' "$INVENTORYDATA" | grep  8\.10 | wc -l)
RHEL_95=$(awk  '{print $7}' "$INVENTORYDATA" | grep  9\.5  | wc -l)
RHEL_96=$(awk  '{print $7}' "$INVENTORYDATA" | grep  9\.6  | wc -l)
RHEL_97=$(awk  '{print $7}' "$INVENTORYDATA" | grep  9\.7  | wc -l)

# Environment counts (field 5 = ENVIRONMENT)
ENV_RND=$(awk  '{print $5}' "$INVENTORYDATA" | grep RND  | wc -l)
ENV_UAT=$(awk  '{print $5}' "$INVENTORYDATA" | grep UAT  | wc -l)
ENV_QA=$(awk   '{print $5}' "$INVENTORYDATA" | grep QA   | wc -l)
ENV_PROD=$(awk '{print $5}' "$INVENTORYDATA" | grep PROD | wc -l)

# Location counts (field 3 = LOCATION)
LOC_GF0=$(awk '{print $3}' "$INVENTORYDATA" | grep GF0 | wc -l)
LOC_GF1=$(awk '{print $3}' "$INVENTORYDATA" | grep GF1 | wc -l)
LOC_GF2=$(awk '{print $3}' "$INVENTORYDATA" | grep GF2 | wc -l)

log INFO "Virtual: $VIRTUAL_SERVERS  Physical: $PHYSICAL_SERVERS  Cloud: $CLOUD_SERVERS  SSH failures: $SSHFAIL"

# =============================================================================
# RPT_Main — index.html (main dashboard)
# =============================================================================

RPT_Main() {
    log INFO "Generating index.html"
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Linux Inventory and Deployment Reports</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <div class="container">
    <header>
      <h1>Red Hat Linux Inventory and Deployment Reports</h1>
      <p>Last updated: $(date)</p>
    </header>

    <div class="card">
      <h2>Server Overview</h2>
      <div class="stats-grid">
        <div class="stat-item">
          <h3>Virtual Servers</h3>
          <p>$VIRTUAL_SERVERS</p>
        </div>
        <div class="stat-item">
          <h3>Physical Servers</h3>
          <p>$PHYSICAL_SERVERS</p>
        </div>
        <div class="stat-item">
          <h3>Cloud Servers</h3>
          <p>$CLOUD_SERVERS</p>
        </div>
        <div class="stat-item warning">
          <h3>SSHFAIL</h3>
          <p>$SSHFAIL</p>
          <div class="details">Unable to retrieve system data</div>
        </div>
      </div>
    </div>

    <div class="card">
      <h2>Operating Systems</h2>
      <div class="os-grid">
        <div class="os-category">
          <h3>RHEL 7.x Series</h3>
          <div class="os-version">
            <span>RHEL 7.9</span><span>$RHEL_79</span>
          </div>
        </div>
        <div class="os-category">
          <h3>RHEL 8.x Series</h3>
          <div class="os-version">
            <span>RHEL 8.8</span><span>$RHEL_88</span>
          </div>
          <div class="os-version">
            <span>RHEL 8.9</span><span>$RHEL_89</span>
          </div>
          <div class="os-version">
            <span>RHEL 8.10</span><span>$RHEL_810</span>
          </div>
        </div>
        <div class="os-category">
          <h3>RHEL 9.x Series</h3>
          <div class="os-version">
            <span>RHEL 9.5</span><span>$RHEL_95</span>
          </div>
          <div class="os-version">
            <span>RHEL 9.6</span><span>$RHEL_96</span>
          </div>
          <div class="os-version">
            <span>RHEL 9.7</span><span>$RHEL_97</span>
          </div>
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

    <div class="container">
      <h2>Additional Resources</h2>
      <div class="resources-section">
        <div class="resource-category">
          <h3>Red Hat Server Inventory Data</h3>
          <div class="resource-subcategory">
            <h4>Raw Data Formats</h4>
            <ul class="resource-list">
              <li><a href="https://mrgmaster.pncint.net/RHEL/RHEL_INVENTORY.txt">Text Format</a></li>
              <li><a href="https://mrgmaster.pncint.net/RHEL/RHEL_INVENTORY.html">HTML Table</a></li>
              <li><a href="https://mrgmaster.pncint.net/RHEL/RHEL_INVENTORY.csv">Spreadsheet</a></li>
              <li><a href="https://mrgmaster.pncint.net/RHEL/historical_data">Recent Spreadsheets</a></li>
            </ul>
          </div>
          <div class="resource-subcategory">
            <h4>Specialized Inventories</h4>
            <ul class="resource-list">
              <li><a href="https://mrgmaster.pncint.net/RHEL/RHEL_PACKAGES.csv">Linux Package Inventory Spreadsheet</a></li>
              <li><a href="https://mrgmaster.pncint.net/RHEL/Midrange_INVENTORY.csv">Midrange Inventory Spreadsheet</a></li>
              <li><a href="https://mrgmaster.pncint.net/RHEL/Midrange_Mod">Midrange Mod Reports</a></li>
            </ul>
          </div>
        </div>

        <div class="resource-category">
          <h3>Inventory Reports</h3>
          <ul class="resource-list">
            <li><a href="https://mrgmaster.pncint.net/RHEL/Location.html">Inventory by Datacenter</a></li>
            <li><a href="https://mrgmaster.pncint.net/RHEL/Application.html">Inventory by Application Code</a></li>
          </ul>
        </div>

        <div class="resource-category">
          <h3>Deployment Reports</h3>
          <ul class="resource-list">
            <li><a href="https://mrgmaster.pncint.net/RHEL/Monthly_Redhat_Linux_Depoloyment_Report.html">Monthly Red Hat Linux Deployment Report</a></li>
            <li><a href="https://mrgmaster.pncint.net/RHEL/Annual_Redhat_Linux_Depoloyment_Report.html">Annual Red Hat Linux Deployment Report</a></li>
            <li><a href="https://mrgmaster.pncint.net/RHEL/RHEL_DEPLOYMENTS.csv">Detailed Deployment Spreadsheet</a></li>
          </ul>
        </div>
      </div>

      <footer>
        <p>&copy; $(date +%Y) PNC. OS Engineering.</p>
      </footer>
    </div>
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

    echo "<html>"
    echo "<head><font size=10>Red Hat Inventory Report - RHEL Release detail</font></head>"
    echo "<body>"
    echo "<br>"
    echo "Last updated $(date)"
    echo "<br><br><br>"
    echo "<font size=5><pre>"

    (awk '{print $7}' "$INVENTORYDATA" | sort | uniq -c; echo "END") \
    | while read -r TOT REL; do
        if [[ "$TOT" = "END" ]]; then
            echo ""
            printf "%-12s %6d\n" "Grand Total" "$GTOTAL"
            break
        fi
        let GTOTAL=GTOTAL+TOT
        if [[ -z "$REL" ]]; then
            REL="undetermined"
        elif [[ "${REL:0:1}" = "S" ]]; then
            REL="SuSE $REL"
        else
            REL="RHEL $REL"
        fi
        printf "%-12s %6d\n" "$REL" "$TOT"
    done

    echo "</pre></body>"
    echo "</html>"
}

# =============================================================================
# RPT_by_Location — Location.html
# =============================================================================

RPT_by_Location() {
    log INFO "Generating Location.html"
    local GTOTAL=0

    echo "<html>"
    echo "<head><font size=10>Red Hat Inventory Report - by Datacenter</font></head>"
    echo "<body><br>"
    echo "Last updated $(date)"
    echo "<br><br><br>"
    echo "<font size=5><pre>"

    (grep -v "^?" "$LOCDATAPLAT" \
        | awk '{print $1}' \
        | sort -u; echo "?"; echo "END") \
    | while read -r LOC; do
        if [[ "$LOC" = "END" ]]; then
            echo ""
            printf "%-18s %6d\n" "Grand Total" "$GTOTAL"
            break
        fi
        if [[ "$LOC" = "?" ]]; then
            LOCDESC="unspecified"
        else
            LOCDESC="$LOC"
        fi
        STOTAL=$(grep "^$LOC " "$LOCDATAPLAT" | wc -l)
        printf "%-18s %6d\n" "$LOCDESC" "$STOTAL"
        let GTOTAL=GTOTAL+STOTAL

        # Platform breakdown
        grep "^$LOC " "$LOCDATAPLAT" \
            | awk '{print $2}' \
            | sort | uniq -c \
            | while read -r TOT PLAT; do
                printf "   %-10s %6d\n" "$PLAT" "$TOT"
            done

        echo ""
        echo "   Versions"
        grep "^$LOC " "$LOCDATAREL" \
            | awk '{print $2}' \
            | sort | uniq -c \
            | while read -r TOT REL; do
                [[ -z "$REL" ]] && REL="?"
                printf "   %-10s %6d\n" "RHEL $REL" "$TOT"
            done
        echo ""
    done

    echo "</pre></body></html>"
}

# =============================================================================
# RPT_by_Mnemonic — Application.html
# =============================================================================

RPT_by_Mnemonic() {
    log INFO "Generating Application.html"
    local GTOTAL=0

    echo "<html>"
    echo "<head><font size=10>Red Hat Inventory Report - by Application code</font></head>"
    echo "<body><br>"
    echo "Last updated $(date)"
    echo "<br><br><br>"
    echo "<font size=5><pre>"

    (grep -v "^???" "$APPDATAPLAT" \
        | awk '{print $1}' \
        | sort -u; echo "???"; echo "END") \
    | while read -r APP; do
        if [[ "$APP" = "END" ]]; then
            echo ""
            printf "%-18s %6d\n" "Grand Total" "$GTOTAL"
            break
        fi
        if [[ "$APP" = "???" ]]; then
            APPDESC="unspecified"
        else
            APPDESC="$APP"
        fi
        STOTAL=$(grep "^$APP " "$APPDATAPLAT" | wc -l)
        printf "%-18s %6d\n" "$APPDESC" "$STOTAL"
        let GTOTAL=GTOTAL+STOTAL

        grep "^$APP " "$APPDATAPLAT" \
            | awk '{print $2}' \
            | sort | uniq -c \
            | while read -r TOT PLAT; do
                printf "   %-10s %6d\n" "$PLAT" "$TOT"
            done

        echo ""
        echo "   Versions"
        grep "^$APP " "$APPDATAREL" \
            | awk '{print $2}' \
            | sort | uniq -c \
            | while read -r TOT REL; do
                [[ -z "$REL" ]] && REL="?"
                printf "   %-10s %6d\n" "RHEL $REL" "$TOT"
            done
        echo ""
    done

    echo "</pre></body></html>"
}

# =============================================================================
# RPT_Deployment_Annual — Annual_Redhat_Linux_Depoloyment_Report.html
# =============================================================================

RPT_Deployment_Annual() {
    log INFO "Generating Annual deployment report"
    (
    echo "<html>"
    echo "<head><font size=10>Annual Red Hat Linux Deployment report</font></head>"
    echo "<body><br>"
    echo "Last updated $(date)"
    echo "<br><br><br>"
    echo "<font size=5><pre>"
    if [[ -x "${PGMDIR}/rhel_deploy_rpt_yearly.sh" ]]; then
        "${PGMDIR}/rhel_deploy_rpt_yearly.sh"
    else
        log WARN "rhel_deploy_rpt_yearly.sh not found — annual report body will be empty"
    fi
    echo "</pre></body>"
    echo "</html>"
    ) > "$WEBDIR/Annual_Redhat_Linux_Depoloyment_Report.html"
}

# =============================================================================
# RPT_Deployment_Monthly — Monthly_Redhat_Linux_Depoloyment_Report.html
# =============================================================================

RPT_Deployment_Monthly() {
    log INFO "Generating Monthly deployment report"

    local current_year
    local current_month
    current_year=$(date +%Y)
    current_month=$(date +%m)

    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Monthly Red Hat Linux Deployment Report</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <div class="container">
    <header>
      <h1>Monthly Red Hat Linux Deployment Report</h1>
      <p>Last updated: $(date)</p>
    </header>
EOF

    # Generate a card for each of the last 12 months
    for (( i=0; i<12; i++ )); do
        local month=$(( current_month - i ))
        local year=$current_year

        while [[ $month -le 0 ]]; do
            month=$(( month + 12 ))
            year=$(( year - 1 ))
        done

        month=$(printf "%02d" $month)
        local month_name
        month_name=$(date -d "${year}-${month}-01" '+%B')
        local date_pattern="${year}-${month}"

        # Pull all deployment records for this month
        local month_data
        month_data=$(awk -v pattern="$date_pattern" '$1 ~ pattern {print $0}' "$DEPLOYMENTDATA")

        [[ -z "$month_data" ]] && continue

        local total_deployments
        total_deployments=$(echo "$month_data" | wc -l)

        local cloud_count
        cloud_count=$(echo "$month_data" | grep -c "Microsoft_Corporation" || true)
        local virtual_count
        virtual_count=$(echo "$month_data" \
            | grep -v "Microsoft_Corporation" \
            | awk '$3 == "Virt" {count++} END {print count+0}')
        local physical_count
        physical_count=$(echo "$month_data" \
            | grep -v "Microsoft_Corporation" \
            | awk '$3 == "Phys" {count++} END {print count+0}')

        local rhel_versions
        rhel_versions=$(echo "$month_data" \
            | awk '{print $4}' \
            | sort | uniq -c \
            | sort -rn)

        cat <<EOF
    <div class="month-card">
      <div class="month-header">
        <h2>${month_name} ${year}</h2>
        <span class="total-deployments">${total_deployments} Total Deployments</span>
      </div>
      <div class="deployment-details">
        <div class="deployment-section">
          <h3>Server Type</h3>
          <ul class="version-list">
EOF

        [[ $virtual_count  -gt 0 ]] && \
            echo "            <li class=\"version-item\"><span class=\"version-name\">Virtual</span><span class=\"version-count\">${virtual_count}</span></li>"
        [[ $physical_count -gt 0 ]] && \
            echo "            <li class=\"version-item\"><span class=\"version-name\">Physical</span><span class=\"version-count\">${physical_count}</span></li>"
        [[ $cloud_count    -gt 0 ]] && \
            echo "            <li class=\"version-item\"><span class=\"version-name\">Cloud</span><span class=\"version-count\">${cloud_count}</span></li>"

        cat <<EOF
          </ul>
        </div>
        <div class="deployment-section">
          <h3>RHEL Versions</h3>
          <ul class="version-list">
EOF

        while read -r count version; do
            [[ -z "$count" || -z "$version" ]] && continue
            echo "            <li class=\"version-item\"><span class=\"version-name\">RHEL ${version}</span><span class=\"version-count\">${count}</span></li>"
        done <<< "$rhel_versions"

        cat <<EOF
          </ul>
        </div>
      </div>
    </div>
EOF
    done

    cat <<EOF
  </div>
</body>
</html>
EOF
}

# =============================================================================
# Main report logic — generate all reports
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

RPT_Deployment_Annual
log INFO "Annual deployment report done"

RPT_Deployment_Monthly > "$WEBDIR/Monthly_Redhat_Linux_Depoloyment_Report.html"
log INFO "Monthly deployment report done"

# Non-responsive host list — hosts where field 2 contains "?"
log INFO "Generating non-responsive host list"
awk '{print $1" "$2}' "$INVENTORYDATA" \
    | grep "?$" \
    | awk '{print $1}' \
    | sort > "$WEBDIR/$LOSTLIST"
LOSTCOUNT=$(wc -l < "$WEBDIR/$LOSTLIST")
log INFO "Non-responsive hosts: $LOSTCOUNT written to $WEBDIR/$LOSTLIST"

# =============================================================================
log SECTION "rhel_inv_report.sh complete"
# =============================================================================

exit 0
