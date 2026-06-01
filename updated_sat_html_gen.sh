#!/bin/bash

#set -x

set -euo pipefail

cache_root="${cache_root:-/opt/app/Sat_Report/cache}"
report_root="${report_root:-/opt/app/Sat_Report/reports}"

# Create dirs if they don't exist
mkdir -p "$cache_root" "$report_root"

# Function to convert CSV to JavaScript object
csv_to_js_object() {
    local csv_file="$1"
    local object_name="$2"

    if [[ ! -f "$csv_file" || ! -s "$csv_file" ]]; then
        echo "              $object_name: [],"
        return
    fi

    echo "              $object_name: ["

    # Skip header line and process data
    tail -n +2 "$csv_file" | while IFS=',' read -r col1 col2 col3 col4 remainder; do
        # Remove quotes if present
        col1=$(echo "$col1" | sed 's/^"//;s/"$//')
        col2=$(echo "$col2" | sed 's/^"//;s/"$//')
        col3=$(echo "$col3" | sed 's/^"//;s/"$//')
        col4=$(echo "$col4" | sed 's/^"//;s/"$//')

        if [[ "$object_name" == "errata" ]]; then
            # Format: package, severity, id, cves
            echo "              { package: '$col1', severity: '$col2', id: '$col3', cves: '$col4' },"
        else
            # Format: rpm
            echo "          { rpm: '$col1' },"
        fi
    done

    echo "          ],"
}

# Function to convert errata differences to CSV format
process_errata_differences() {
    local current_file="$1"
    local prev_file="$2"
    local output_csv="$3"

    # Generate errata CSV for current
    jq -r '
        (["RPM Name","Red Hat Risk Rating","RHSA ID","CVE ID"]),
        (
        [.results[] | select(
            .errata_id | test("^(FEDORA-|RHBA-|RHEA-)") | not
        ) | [
            (
            .title
            | gsub("^(Critical|Important|Moderate|Low):\\s*";"")
            | gsub("\\s+((security|bug fix|enhancement)\\s+)?update$";"")
            | gsub(","; "")
            | gsub("\\band\\b\\s*"; "")
            | gsub("\\s{2,}"; " ")
            | gsub("^\\s+|\\s+$";"")
            ),
            (.severity | if . == "Critical" then "High" elif . == "Important" then "High" elif . == "Moderate" then "Medium" else . end // ""),
            (.errata_id // ""),
            (if (.cves|type)=="array" then (.cves|map(.cve_id)|join(" ")) else "" end)
        ]]
        | sort_by(.[0])
        | .[]
    ) | @csv' "$current_file" > "$tmp/er_new.csv"

    if [[ -n "$prev_file" && -f "$prev_file" ]]; then
        jq -r '
            (["RPM Name","Red Hat Risk Rating","RHSA ID","CVE ID"]),
            (
            [.results[] | select(
                .errata_id | test("^(FEDORA-|RHBA-|RHEA-)") | not
            ) | [
                (
                .title
                | gsub("^(Critical|Important|Moderate|Low):\\s*";"")
                | gsub("\\s+((security|bug fix|enhancement)\\s+)?update$";"")
                | gsub(","; "")
                | gsub("\\band\\b\\s*"; "")
                | gsub("\\s{2,}"; " ")
                | gsub("^\\s+|\\s+$";"")
                ),
                (.severity | if . == "Critical" then "High" elif . == "Important" then "High" elif . == "Moderate" then "Medium" else . end // ""),
                (.errata_id // ""),
                (if (.cves|type)=="array" then (.cves|map(.cve_id)|join(" ")) else "" end)
            ]]
            | sort_by(.[0])
            | .[]
        ) | @csv' "$prev_file" > "$tmp/er_old.csv"
    else
        echo "RPM Name,Red Hat Risk Rating,RHSA ID,CVE ID" > "$tmp/er_old.csv"
    fi

    # Find differences and create final CSVs
    {
        head -n1 "$tmp/er_new.csv"
        awk -F',' '
            FNR==NR {
                if (FNR > 1) {
                    gsub(/^"|"$/, "", $3)
                    old_ids[$3] = 1
                }
                next
            }
            FNR > 1 {
                new_id=$3
                gsub(/^"|"$/, "", new_id)
                if (!(new_id in old_ids)) {
                    print
                }
            }
        ' "$tmp/er_old.csv" "$tmp/er_new.csv"
    } > "$output_csv"
}

# Function to convert package differences to CSV format
process_package_differences() {
    local current_file="$1"
    local prev_file="$2"
    local output_csv="$3"

    # Generate packages CSV for current
    jq -r '
        (["RPM"]),
        (.results[] | [ (.filename // "") ]
        | @csv
    ' "$current_file" > "$tmp/pkg_new.csv"

    if [[ -n "$prev_file" && -f "$prev_file" ]]; then
        jq -r '
            (["RPM"]),
            (.results[] | [ (.filename // "") ]
            | @csv
        ' "$prev_file" > "$tmp/pkg_old.csv"
    else
        echo "RPM" > "$tmp/pkg_old.csv"
    fi

    # Find differences and create final CSV
    {
        head -n1 "$tmp/pkg_new.csv"
        awk -F',' '
            FNR==NR {
                if (FNR > 1) {
                    gsub(/^"|"$/, "", $1)
                    old_names[$1] = 1
                }
                next
            }
            FNR > 1 {
                new_name=$1
                gsub(/^"|"$/, "", new_name)
                if (!(new_name in old_names)) {
                    print
                }
            }
        ' "$tmp/pkg_old.csv" "$tmp/pkg_new.csv"
    } > "$output_csv"
}

# Function to detect kernel version update between current and previous packages JSON
get_latest_kernel_version() {
    local pkg_json="$1"
    jq -r '
        .results[]
        | select(.filename != null)
        | .filename
        | select(test("^kernel-[0-9].*-[0-9]+\\.[0-9]+\\...*\\.x86_64\\.rpm$"))
        | sub("\\.rpm$"; "")
        | sub("^kernel-"; "")
    ' "$pkg_json" 2>/dev/null | sort -V | tail -1
}

generate_kernel_callout() {
    local current_pkg_json="$1"
    local prev_pkg_json="$2"

    local kernel_current kernel_prev
    kernel_current=$(jq -r '
        .results[]
        | select(.filename != null)
        | .filename
        | select(test("^kernel-[0-9].*-[0-9]+\\.[0-9]+\\...*\\.x86_64\\.rpm$"))
        | sub("\\.rpm$"; "")
        | sub("^kernel-"; "")
    ' "$current_pkg_json" 2>/dev/null | sort -V | tail -1)

    kernel_prev=$(jq -r '
        .results[]
        | select(.filename != null)
        | .filename
        | select(test("^kernel-[0-9].*-[0-9]+\\.[0-9]+\\...*\\.x86_64\\.rpm$"))
        | sub("\\.rpm$"; "")
        | sub("^kernel-"; "")
    ' "$prev_pkg_json" 2>/dev/null | sort -V | tail -1)

    if [[ -n "$kernel_current" && "$kernel_current" != "$kernel_prev" ]]; then
        cat <<HTML
<div class="kernel-callout kernel-updated">
    <span class="kernel-icon">🔔</span>
    <div class="kernel-text">
        <span class="kernel-label">Kernel Update Detected</span>
        <span class="kernel-version">Current: <code>${kernel_current}</code></span>
    </div>
    <span class="kernel-badge">🆕 New Kernel</span>
</div>
HTML
    else
        cat <<HTML
<div class="kernel-callout kernel-none">
    <span class="kernel-icon">✅</span>
    <div class="kernel-text">
        <span class="kernel-label">Kernel Status</span>
        <span class="kernel-version">No new kernel version found this month</span>
    </div>
</div>
HTML
    fi
}

# Function to detect OS minor version from a packages JSON
get_os_version() {
    local pkg_json="$1"
    jq -r '
        .results[]
        | select(.filename != null)
        | .filename
        | select(test("^redhat-release-[0-9]"))
        | select(test("^redhat-release-[0-9]"))
    ' "$pkg_json" 2>/dev/null \
    | grep -oP 'redhat-release-\K[0-9]+\.[0-9]+' \
    | sort -V | tail -1
}

generate_os_version_callout() {
    local current_pkg_json="$1"
    local prev_pkg_json="$2"

    local os_current os_prev
    os_current=$(get_os_version "$current_pkg_json")
    os_prev=""
    if [[ -n "$prev_pkg_json" && -f "$prev_pkg_json" ]]; then
        os_prev=$(get_os_version "$prev_pkg_json")
    fi

    if [[ -n "$os_current" && -n "$os_prev" && "$os_current" != "$os_prev" ]]; then
        echo "<span data-os-curr=\"${os_current}\" data-os-prev=\"${os_prev}\" data-os-changed=\"true\"></span>"
    else
        local display="${os_current:-unknown}"
        echo "<span data-os-curr=\"${display}\" data-os-prev=\"${display}\" data-os-changed=\"false\"></span>"
    fi
}

# Function to generate the HTML for the "Archived Reports" section
generate_archive_links_html() {
    local archive_html
    archive_html=$(
        find "$report_root" -type f -name 'patchset_*.html' ! -name 'index.html' -print0 | {
            declare -A links_by_year
            local files_found=0
            while IFS= read -r -d '' file; do
                files_found=1
                local basename
                basename=$(basename "$file")
                # Regex to capture month and year from filenames
                if [[ $basename =~ patchset_([a-z]+)_([0-9]{4})\.html ]]; then
                    local month="${BASH_REMATCH[1]}"
                    local year="${BASH_REMATCH[2]}"
                    local month_capitalized
                    month_capitalized="$(tr '[:lower:]' '[:upper:]' <<< "${month:0:1}")${month:1}"

                    local link="<a href=\"$basename\" class=\"archive-month-link\">$month_capitalized</a>"
                    links_by_year[$year]+="$link"
                fi
            done

            # If no archive files were found by find, exit the subshell early
            if [[ "$files_found" -eq 0 ]]; then
                exit 0
            fi

            # Sort years in descending order
            local sorted_years
            sorted_years=$(printf "%s\n" "${!links_by_year[@]}" | sort -rn)

            # Build the HTML structure
            cat << 'ARCHIVE_HTML'
<div class="section">
    <h2>🗂 Archived Reports</h2>
    <div class="archive-container">
ARCHIVE_HTML

            for year in $sorted_years; do
                cat <<ARCHIVE_YEAR_HTML
                <div class="archive-year">
                    <button class="archive-year-header">
                        <span>📅 $year</span>
                        <span class="arrow">▼</span>
                    </button>
                    <div class="archive-months">
                        ${links_by_year[$year]}
                    </div>
                </div>
ARCHIVE_YEAR_HTML
            done

            cat << 'ARCHIVE_FOOTER'
    </div>
</div>
ARCHIVE_FOOTER
        }
    )

    # Echo the generated HTML only if it's not empty
    if [[ -n "$archive_html" ]]; then
        echo "$archive_html"
    fi
}

# Function to generate the initial HTML structure, including CSS and the static page layout
generate_html_report() {
    local html_file="$1"
    local month_year="$2"
    local is_current="$3"

    # Determine the display month/year for this report
    local display_month display_year
    if [[ "$is_current" == "true" ]]; then
        display_month=$(date +"%B")
        display_year=$(date +"%Y")
    else
        # month_year is "Month YYYY" for archived reports
        read -r display_month display_year <<< "$month_year"
    fi

    local go_live_date
    go_live_date=$(get_second_tuesday_date "$display_month" "$display_year")

    cat > "$html_file" << 'HTML_HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Red Hat Linux Monthly Patchset Overview</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            background: linear-gradient(135deg, #f0f2f5 0%, #e6e9ed 100%);
            min-height: 100vh;
            padding: 20px;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.98);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            box-shadow: 0 25px 50px rgba(0, 0, 0, 0.1);
            overflow: hidden;
            animation: slideIn 0.8s ease-out;
        }

        @keyframes slideIn {
            from { opacity: 0; transform: translateY(30px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .header {
            background: linear-gradient(135deg, #cc0000 0%, #a30000 100%);
            color: white;
            padding: 40px;
            text-align: center;
            position: relative;
            border-bottom: 5px solid #800000;
        }

        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0, 0, 0, 0.3);
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 15px;
        }

        .header .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }

        .nav-section {
            background: #343a40;
            padding: 15px 30px;
            color: white;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .nav-home {
            background: #007bff;
            color: white;
            padding: 8px 16px;
            border-radius: 5px;
            text-decoration: none;
            font-weight: 600;
            transition: all 0.3s ease;
        }

        .nav-home:hover {
            background: #0056b3;
            transform: translateY(-1px);
        }

        .os-selector {
            display: flex;
            justify-content: center;
            background-color: #e9ecef;
            padding: 10px;
            gap: 10px;
            border-bottom: 1px solid #dee2e6;
        }

        .os-btn {
            padding: 10px 20px;
            font-size: 1em;
            font-weight: 600;
            border: none;
            background-color: transparent;
            color: #495057;
            cursor: pointer;
            border-radius: 8px;
            transition: all 0.3s ease;
        }

        .os-btn:hover {
            background-color: #dee2e6;
            color: #212529;
        }

        .os-btn.active {
            background-color: #007bff;
            color: white;
            box-shadow: 0 4px 10px rgba(0, 123, 255, 0.3);
        }

        .content { padding: 40px; }
        .section { margin-bottom: 40px; }

        .section h2 {
            font-size: 1.8em;
            margin-bottom: 20px;
            color: #1f2937;
            border-bottom: 3px solid #007bff;
            padding-bottom: 10px;
        }

        .patchset-meta-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 18px;
            margin-bottom: 25px;
        }

        .patchset-meta-card {
            background: #f8f9fa;
            padding: 22px 18px;
            border-radius: 12px;
            border: 1px solid #e2e8f0;
            box-shadow: 0 8px 20px rgba(0, 0, 0, 0.05);
            transition: all 0.3s ease;
            position: relative;
            overflow: hidden;
            display: flex;
            flex-direction: column;
            gap: 6px;
        }

        .patchset-meta-card::before {
            content: '';
            position: absolute;
            top: 0; left: 0; right: 0;
            height: 4px;
            background: linear-gradient(90deg, #007bff, #0056b3);
        }

        .patchset-meta-card:hover {
            transform: translateY(-3px);
            box-shadow: 0 12px 25px rgba(0, 0, 0, 0.1);
        }

        .patchset-meta-label {
            font-size: 0.75em;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.6px;
            color: #6c757d;
        }

        .patchset-meta-value {
            font-size: 0.95em;
            font-weight: 600;
            color: #343a40;
            word-break: break-word;
        }

        .patchset-meta-value.kernel-updated    { color: #d39e00; }
        .patchset-meta-value.kernel-none       { color: #6c757d; font-style: italic; font-weight: 400; }
        .patchset-meta-value.os-version-updated { color: #185FA5; }
        .patchset-meta-value.os-version-none   { color: #6c757d; font-style: italic; font-weight: 400; }

        .patchset-meta-divider {
            border: none;
            border-top: 1px solid #e2e8f0;
            margin: 4px 0 20px 0;
        }

        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 18px;
            margin-bottom: 25px;
        }

        .summary-card {
            background: #ffffff;
            padding: 22px 18px;
            border-radius: 12px;
            text-align: center;
            border: 1px solid #e2e8f0;
            box-shadow: 0 8px 20px rgba(0, 0, 0, 0.05);
            transition: all 0.3s ease;
            position: relative;
            overflow: hidden;
            min-height: 110px;
            display: flex;
            flex-direction: column;
            justify-content: center;
        }

        .summary-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 4px;
            background: linear-gradient(90deg, #007bff, #0056b3);
        }

        .summary-card:hover {
            transform: translateY(-3px);
            box-shadow: 0 12px 25px rgba(0, 0, 0, 0.1);
        }

        .summary-card.high::before { background: linear-gradient(90deg, #dc3545, #b21f2d); }
        .summary-card.medium::before { background: linear-gradient(90deg, #ffc107, #d39e00); }
        .summary-card.low::before { background: linear-gradient(90deg, #28a745, #1e7e34); }
        .summary-card.rpms::before { background: linear-gradient(90deg, #17a2b8, #138496); }

        .summary-main-number {
            font-size: 2.4em;
            font-weight: 700;
            margin-bottom: 8px;
            color: #343a40;
        }

        .summary-card.high .summary-main-number { color: #dc3545; }
        .summary-card.medium .summary-main-number { color: #ffc107; }
        .summary-card.low .summary-main-number { color: #28a745; }
        .summary-card.rpms .summary-main-number { color: #17a2b8; }

        .summary-label {
            color: #6c757d;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            font-size: 0.9em;
        }

        .search-container {
            margin: 20px 0;
            display: flex;
            justify-content: flex-end;
            align-items: center;
            gap: 15px;
        }

        .search-box {
            padding: 10px 15px;
            border: 2px solid #dee2e6;
            border-radius: 25px;
            font-size: 0.9em;
            width: 250px;
            outline: none;
            transition: all 0.3s ease;
        }

        .search-box:focus {
            border-color: #007bff;
            box-shadow: 0 0 0 3px rgba(0, 123, 255, 0.1);
        }

        .download-btn {
            background: linear-gradient(135deg, #28a745 0%, #20c997 100%);
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 25px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 0.9em;
            box-shadow: 0 4px 12px rgba(40, 167, 69, 0.3);
        }

        .download-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(40, 167, 69, 0.4);
        }

        .table-container {
            background: white;
            border-radius: 15px;
            overflow-x: auto;
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.05);
            margin: 20px 0;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            min-width: 800px;
        }

        th {
            background: #343a40;
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: 600;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            cursor: pointer;
            user-select: none;
        }

        th:hover { background: #495057; }

        th .sort-arrow {
            display: inline-block;
            margin-left: 5px;
            font-size: 0.8em;
            opacity: 0.5;
        }

        th.sort-asc .sort-arrow::after { content: '▲'; opacity: 1; }
        th.sort-desc .sort-arrow::after { content: '▼'; opacity: 1; }
        th:not(.sort-asc):not(.sort-desc) .sort-arrow::after { content: '▲▼'; }

        td {
            padding: 12px 15px;
            border-bottom: 1px solid #e5e7eb;
        }

        tbody tr:hover td { background-color: #f8f9fa; }

        .severity-badge {
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 0.8em;
            font-weight: 700;
            color: white;
            text-transform: uppercase;
            min-width: 90px;
            display: inline-block;
        }

        .severity-high { background-color: #dc3545; }
        .severity-medium { background-color: #ffc107; color: #000 }
        .severity-low { background-color: #28a745; }
        .severity-unknown { background-color: #6c757d; }

        .cve-list.expandable {
            cursor: pointer;
            color: #007bff;
            text-decoration: underline;
            text-decoration-style: dotted;
        }

        .cve-list.expandable.expanded {
            white-space: normal;
            word-break: break-all;
            text-decoration: none;
            color: #333;
            cursor: default;
        }

        .footer {
            background: #343a40;
            padding: 30px;
            text-align: center;
            color: #adb5bd;
            border-top: 5px solid #000;
        }

        .footer-generated {
            margin-top: 6px;
            font-size: 0.82em;
            opacity: 0.6;
        }

        .pagination-controls {
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px 0;
            gap: 8px;
        }

        .pagination-btn {
            border: 1px solid #dee2e6;
            background-color: #fff;
            color: #007bff;
            padding: 8px 14px;
            border-radius: 5px;
            cursor: pointer;
            font-weight: 600;
        }

        .pagination-btn:hover { background-color: #e9ecef; }
        .pagination-btn.active { background-color: #007bff; color: white; border-color: #007bff; }
        .pagination-btn:disabled { color: #6c757d; background-color: #e9ecef; cursor: not-allowed; }

        .archive-year {
            border-bottom: 1px solid #dee2e6;
        }

        .archive-year:last-child {
            border-bottom: none;
        }

        .archive-year-header {
            width: 100%;
            background-color: #f8f9fa;
            padding: 18px 25px;
            border: none;
            text-align: left;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 1.2em;
            font-weight: 600;
            color: #343a40;
            transition: background-color 0.3s ease;
        }

        .archive-year-header:hover {
            background-color: #e9ecef;
        }

        .archive-year-header .arrow {
            font-size: 1em;
            transition: transform 0.3s ease;
        }

        .archive-year-header.active .arrow {
            transform: rotate(180deg);
        }

        .archive-months {
            padding: 0;
            background-color: #fff;
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
            max-height: 0;
            overflow: hidden;
            transition: max-height 0.4s ease-out, padding 0.4s ease-out;
        }

        .archive-months.show {
            max-height: 500px;
            padding: 20px 25px;
        }

        .archive-month-link {
            display: block;
            text-decoration: none;
            color: #007bff;
            background-color: #f0f7ff;
            padding: 10px 15px;
            border-radius: 8px;
            text-align: center;
            font-weight: 600;
            border: 1px solid #bde0ff;
            transition: all 0.3s ease;
        }

        .archive-month-link:hover {
            background-color: #007bff;
            color: white;
            transform: translateY(-2px);
            box-shadow: 0 4px 10px rgba(0, 123, 255, 0.2);
        }

        @media (max-width: 768px) {
            body { padding: 10px; }
            .container { border-radius: 15px; }
            .header h1 { font-size: 1.8em; }
            .content { padding: 20px; }
            .summary-grid, .meta-grid { grid-template-columns: 1fr; }
            .os-selector { flex-wrap: wrap; }
        }

        /* Kernel Version Callout */
        .kernel-callout {
            margin-top: 20px;
            margin-bottom: 24px;
            padding: 18px 22px;
            border-radius: 12px;
            display: flex;
            align-items: center;
            gap: 16px;
            font-size: 1em;
            font-weight: 600;
            border: 2px solid;
            position: relative;
            overflow: hidden;
        }

        .kernel-callout.kernel-updated {
            background: linear-gradient(135deg, #fff3cd 0%, #ffe69c 100%);
            border-color: #ffc107;
            color: #664d03;
            box-shadow: 0 6px 20px rgba(255, 193, 7, 0.3);
        }

        .kernel-callout.kernel-updated::before {
            content: '';
            position: absolute;
            left: 0; top: 0; bottom: 0;
            width: 5px;
            background: linear-gradient(180deg, #ffc107, #fd7e14);
        }

        .kernel-callout.kernel-none {
            background: linear-gradient(135deg, #f8f9fa 0%, #e9ecef 100%);
            border-color: #abd5bd;
            color: #495057;
            box-shadow: 0 4px 12px rgba(0,0,0,0.06);
        }

        .kernel-callout.kernel-none::before {
            content: '';
            position: absolute;
            left: 0; top: 0; bottom: 0;
            width: 5px;
            background: #abd5bd;
        }

        .kernel-callout .kernel-icon { font-size: 1.8em; flex-shrink: 0; }
        .kernel-callout .kernel-text { display: flex; flex-direction: column; gap: 3px; }
        .kernel-callout .kernel-label {
            font-size: 0.75em;
            text-transform: uppercase;
            letter-spacing: 1px;
            opacity: 0.75;
            font-weight: 700;
        }

        .kernel-callout .kernel-version { font-size: 1.05em; font-weight: 700; }
        .kernel-callout.kernel-updated .kernel-badge {
            margin-left: auto;
            background: #ffc107;
            color: #000;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.78em;
            font-weight: 800;
            letter-spacing: 0.5px;
            text-transform: uppercase;
            white-space: nowrap;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Red Hat Linux Monthly Patchset Overview</h1>
        </div>
HTML_HEADER

    # Add navigation bar for archived reports only
    if [[ "$is_current" != "true" ]]; then
        cat >> "$html_file" << 'NAV_SECTION'
        <div class="nav-section">
            <a href="index.html" class="nav-home">Back to Current Patchset</a>
        </div>
NAV_SECTION
    fi

    # Static HTML - OS selector (quoted heredoc, no expansion needed)
    cat >> "$html_file" << 'HTML_MIDDLE_TOP'
        <!-- OS Selector -->
        <div class="os-selector" id="osSelector">
            <!-- Buttons will be generated by JavaScript -->
        </div>

        <div class="content">
            <div class="section">
                <h2>📋 Summary</h2>
HTML_MIDDLE_TOP

    # Patchset meta cards = unquoted so shell variables expand
    cat >> "$html_file" << HTML_META_CARDS
                <div class="patchset-meta-grid">
                    <div class="patchset-meta-card">
                        <span class="patchset-meta-label">📅 Patchset Month</span>
                        <span class="patchset-meta-value">${display_month} ${display_year}</span>
                    </div>
                    <div class="patchset-meta-card">
                        <span class="patchset-meta-label">🗓 Patch Release Date</span>
                        <span class="patchset-meta-value">${go_live_date}</span>
                    </div>
                    <div class="patchset-meta-card">
                        <span class="patchset-meta-label">🐧 New Kernel</span>
                        <span class="patchset-meta-value kernel-none" id="summaryKernelValue">-</span>
                    </div>
                    <div class="patchset-meta-card">
                        <span class="patchset-meta-label">🖥 OS Version</span>
                        <span class="patchset-meta-value os-version-none" id="summaryOSVersionValue">-</span>
                    </div>
                </div>
                <hr class="patchset-meta-divider">
HTML_META_CARDS

    # Summary section + errata/packages tables
    cat >> "$html_file" << 'HTML_MIDDLE_BOTTOM'
                <div class="summary-grid">
                    <div class="summary-card">
                        <div id="summaryTotalErrata" class="summary-main-number" data-target="0">0</div>
                        <div class="summary-label">New Errata</div>
                    </div>
                    <div class="summary-card high">
                        <div id="summaryHigh" class="summary-main-number" data-target="0">0</div>
                        <div class="summary-label">High</div>
                    </div>
                    <div class="summary-card medium">
                        <div id="summaryMedium" class="summary-main-number" data-target="0">0</div>
                        <div class="summary-label">Medium</div>
                    </div>
                    <div class="summary-card low">
                        <div id="summaryLow" class="summary-main-number" data-target="0">0</div>
                        <div class="summary-label">Low</div>
                    </div>
                    <div class="summary-card rpms">
                        <div id="summaryRpms" class="summary-main-number" data-target="0">0</div>
                        <div class="summary-label">New Packages</div>
                    </div>
                </div>
            </div>

        <div class="section">
            <h2>🛡 New Erratas</h2>
            <div class="search-container">
                <input type="text" id="errataSearchBox" class="search-box" placeholder="Search errata...">
                <button id="downloadErrataBtn" class="download-btn">⬇ Download CSV</button>
            </div>
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th data-column="package" class="sortable">RPM Name <span class="sort-arrow"></span></th>
                            <th data-column="severity" class="sortable">Red Hat Risk Rating<span class="sort-arrow"></span></th>
                            <th data-column="id" class="sortable">RHSA ID <span class="sort-arrow"></span></th>
                            <th data-column="cves" class="sortable">CVE ID <span class="sort-arrow"></span></th>
                        </tr>
                    </thead>
                    <tbody id="errataTableBody"></tbody>
                </table>
            </div>
            <div id="errataPaginationControls" class="pagination-controls"></div>
        </div>

        <div class="section">
            <h2>📦 New Packages</h2>
            <div class="search-container">
                <input type="text" id="packageSearchBox" class="search-box" placeholder="Search packages...">
                <button id="downloadPackageBtn" class="download-btn">⬇ Download CSV</button>
            </div>
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th data-column="rpm" class="sortable">RPM <span class="sort-arrow"></span></th>
                        </tr>
                    </thead>
                    <tbody id="packageTableBody"></tbody>
                </table>
            </div>
            <div id="packagePaginationControls" class="pagination-controls"></div>
        </div>
HTML_MIDDLE_BOTTOM
}

# Main function to process data for a given month and generate a complete HTML report
process_month_data() {
    local target_month="$1"
    local target_year="$2"
    local html_file="$3"
    local is_current="$4"

    local month_year_display
    if [[ "$is_current" == "true" ]]; then
        month_year_display="current"
    else
        month_year_display="$target_month $target_year"
    fi

    generate_html_report "$html_file" "$month_year_display" "$is_current"

    # Append the dynamic JavaScript data and rest of the HTML/JS logic to the file
    {
        echo "          const allOSData = {"

    (
        # Process each content view by looking for JSON files
        for cv_name in "RHEL9_current" "RHEL8_current" "RHEL8.8"; do

            # Find the JSON files recursively within the cache root directory.
            local current_errata_json
            current_errata_json=$(find "$cache_root" -type f -name "Report_${cv_name}_${target_month}_${target_year}_ERRATA.json" | head -n 1)
            current_packages_json=$(find "$cache_root" -type f -name "Report_${cv_name}_${target_month}_${target_year}_PACKAGES.json" | head -n 1)

            # Only proceed if the main JSON files for the month exist.
            if [[ -n "$current_errata_json" && -f "$current_errata_json" && -n "$current_packages_json" && -f "$current_packages_json" ]]; then
                local cv_display_name
                cv_display_name=$(translate_cv_name "$cv_name")

                local prev_month prev_year
                read -r prev_month prev_year <<< "$(get_previous_month_year "$target_month" "$target_year")"

                local prev_errata_json
                prev_errata_json=$(find "$cache_root" -type f -name "Report_${cv_name}_${prev_month}_${prev_year}_ERRATA.json" | head -n 1)
                local prev_packages_json
                prev_packages_json=$(find "$cache_root" -type f -name "Report_${cv_name}_${prev_month}_${prev_year}_PACKAGES.json" | head -n 1)

                # ---- DEBUG ----
                echo "# ---- Processing ${cv_display_name} for ${target_month} ${target_year} ---" >&2
                echo "#      Comparing ERRATA:" >&2
                echo "#        CURRENT: ${current_errata_json}" >&2
                if [[ -n "$prev_errata_json" && -f "$prev_errata_json" ]]; then
                    echo "#        PREVIOUS: ${prev_errata_json}" >&2
                else
                    echo "#        PREVIOUS: Not found. Comparing aganist empty baseline." >&2
                fi
                echo "#      Comparing PACKAGES:" >&2
                echo "#        CURRENT: ${current_packages_json}" >&2
                if [[ -n "$prev_packages_json" && -f "$prev_packages_json" ]]; then
                    echo "#        PREVIOUS: ${prev_packages_json}" >&2
                else
                    echo "#        PREVIOUS: Not found. Comparing aganist empty baseline." >&2
                fi
                # ---- ENG DEBUG ----

                # Convert JSON data to CSV format for process differences
                local tmp_errata_csv
                tmp_errata_csv=$(mktemp)
                local tmp_packages_csv
                tmp_packages_csv=$(mktemp)

                process_errata_differences "$current_errata_json" "$prev_errata_json" "$tmp_errata_csv"
                process_package_differences "$current_packages_json" "$prev_packages_json" "$tmp_packages_csv"

                # Generate kernel callout HTML for this Content View
                local kernel_callout
                kernel_callout=$(generate_kernel_callout "$current_packages_json" "${prev_packages_json:-}")

                # Escape for use inside a JS single-quoted string
                local kernel_callout_escaped
                kernel_callout_escaped=$(echo "$kernel_callout" | tr -d '\n' | sed "s/'/\\\\\'/g")

                # OS version callout
                local os_version_callout
                os_version_callout=$(generate_os_version_callout "$current_packages_json" "${prev_packages_json:-}")

                local os_version_callout_escaped
                os_version_callout_escaped=$(echo "$os_version_callout" | tr -d '\n' | sed "s/'/\\\\\'/g")

                local report_name_prefix="${cv_display_name}_${target_month}_${target_year}"
                cp "$tmp_errata_csv" "$report_root/${report_name_prefix}_ERRATA_diff.csv"
                cp "$tmp_packages_csv" "$report_root/${report_name_prefix}_PACKAGES_diff.csv"
                echo "#                -> Saved diff reports to $report_root/${report_name_prefix}_*_diff.csv" >&2
                echo "#-------------------------------------------" >&2

                # Echo the JavaScript object for this Content View
                echo "              \"$cv_display_name\": {"
                echo "                  month: \"$target_month $target_year\","
                echo "                  kernelCallout: '${kernel_callout_escaped}',"
                echo "                  osVersionCallout: '${os_version_callout_escaped}',"
                csv_to_js_object "$tmp_errata_csv" "errata"
                csv_to_js_object "$tmp_packages_csv" "packages"
                echo "              },"

                # Cleanup temp files
                rm -f "$tmp_errata_csv" "$tmp_packages_csv"
            fi
        done
    ) | sed '$ s/,$//'

    # Close JavaScript data object and add the rest of the script
    cat << 'HTML_FOOTER'
};
// =========================================================================

// --- Global Variables ---
let errataTable, packageTable;
const osSelector = document.getElementById('osSelector');

// --- Table Management Class ---
class TableManager {
    constructor(data, tableBodyId, paginationId, rowsPerPage = 10) {
        this.originalData = [...data];
        this.filteredData = [...data];
        this.tableBody = document.getElementById(tableBodyId);
        this.paginationControls = document.getElementById(paginationId);
        this.rowsPerPage = rowsPerPage;
        this.currentPage = 1;
        this.sortColumn = '';
        this.sortDirection = '';
    }

    updateData(newData) {
        this.originalData = [...newData];
        this.filter('');
        this.sortColumn = ''; // Reset sort
        this.sortDirection = '';
        this.updateSortHeaders();
    }

    render() {
        this.displayPage();
        this.setupPagination();
    }

    displayPage() {
        this.tableBody.innerHTML = '';
        const start = (this.currentPage - 1) * this.rowsPerPage;
        const end = start + this.rowsPerPage;
        const paginatedItems = this.filteredData.slice(start, end);
        paginatedItems.forEach(item => {
            const row = document.createElement('tr');
            row.innerHTML = this.createRowHTML(item);
            this.tableBody.appendChild(row);
        });

        // Add click handlers for CVE expansion after rows are rendered
        this.tableBody.querySelectorAll('.cve-list.expandable').forEach(elem => {
            elem.addEventListener('click', (e) => {
                const element = e.currentTarget;
                const isExpanded = element.classList.toggle('expanded');
                if (isExpanded) {
                    element.textContent = element.dataset.fullCves;
                } else {
                    const cves = element.dataset.fullCves.split(/, ?/);
                    element.textContent = `${element.dataset.collapsedCves} ... (${cves.length - 2} more)`;
                }
            });
        });
    }

    createRowHTML(item) { throw new Error("Must be implemented by subclass"); }

    setupPagination() {
        this.paginationControls.innerHTML = '';
        const pageCount = Math.ceil(this.filteredData.length / this.rowsPerPage);
        if (pageCount <= 1) return;
        const createBtn = (text, onClick, isDisabled = false, isActive = false) => {
            const btn = document.createElement('button');
            btn.className = 'pagination-btn';
            btn.innerText = text;
            btn.disabled = isDisabled;
            if (isActive) btn.classList.add('active');
            btn.addEventListener('click', onClick);
            return btn;
        };
        this.paginationControls.appendChild(createBtn('Previous', () => { this.currentPage--; this.render(); }, this.currentPage === 1));

        // Simplified pagination numbers
        for (let i = 1; i <= pageCount; i++) {
            if (i === this.currentPage || i === 1 || i === pageCount || (i >= this.currentPage - 1 && i <= this.currentPage + 1)) {
                this.paginationControls.appendChild(createBtn(i, () => { this.currentPage = i; this.render(); }, false, i === this.currentPage));
            } else if (i === this.currentPage - 2 || i === this.currentPage + 2) {
                this.paginationControls.appendChild(createBtn('...', () => {}, true));
            }
        }

        this.paginationControls.appendChild(createBtn('Next', () => { this.currentPage++; this.render(); }, this.currentPage === pageCount));
    }

    filter(searchTerm) {
        const term = searchTerm.toLowerCase();
        this.filteredData = this.originalData.filter(item => this.matchesSearch(item, term));
        this.currentPage = 1;
        this.render();
    }

    matchesSearch(item, term) { throw new Error("Must be implemented by subclass"); }

    sort(column) {
        this.sortDirection = (this.sortColumn === column && this.sortDirection === 'asc') ? 'desc' : 'asc';
        this.sortColumn = column;
        this.filteredData.sort((a, b) => {
            const aVal = this.getSortValue(a, column);
            const bVal = this.getSortValue(b, column);
            if (aVal < bVal) return this.sortDirection === 'asc' ? -1 : 1;
            if (aVal > bVal) return this.sortDirection === 'asc' ? 1 : -1;
            return 0;
        });
        this.updateSortHeaders();
        this.currentPage = 1;
        this.render();
    }

    getSortValue(item, column) { throw new Error("Must be implemented by subclass"); }

    updateSortHeaders() {
        const headers = this.tableBody.closest('table').querySelectorAll('th.sortable');
        headers.forEach(header => {
            header.classList.remove('sort-asc', 'sort-desc');
            if (header.dataset.column === this.sortColumn) {
                header.classList.add(`sort-${this.sortDirection}`);
            }
        });
    }
}

// --- CVE Formatting Helper ---
function formatCVEs(cveString, maxVisible = 2) {
    if (!cveString || cveString === 'N/A') return `<span>${cveString || 'N/A'}</span>`;
    const cves = cveString.split(/, ?/);
    if (cves.length <= maxVisible) {
        return `<span>${cveString}</span>`;
    }
    const visible = cves.slice(0, maxVisible).join(', ');
    const remaining = cves.length - maxVisible;
    return `<span class="cve-list expandable" data-full-cves="${cveString}" data-collapsed-cves="${visible}">${visible} ... (${remaining} more)</span>`;
}

// --- Errata Table Manager ---
class ErrataTableManager extends TableManager {
    createRowHTML(item) {
        const severityClass = `severity-${item.severity.toLowerCase()}`;
        return `
            <td><strong>${item.package}</strong></td>
            <td><span class="severity-badge ${severityClass}">${item.severity}</span></td>
            <td><strong>${item.id}</strong></td>
            <td>${formatCVEs(item.cves, 2)}</td>
        `;
    }
    matchesSearch(item, term) {
        return Object.values(item).some(val => String(val).toLowerCase().includes(term));
    }
    getSortValue(item, column) {
        if (column === 'severity') {
            const order = { 'high': 3, 'medium': 2, 'low': 1, 'unknown': 0 };
            return order[item.severity.toLowerCase()] || 0;
        }
        return (item[column] || '').toLowerCase();
    }
}

// --- Package Table Manager ---
class PackageTableManager extends TableManager {
    createRowHTML(item) { return `<td><code>${item.rpm}</code></td>`; }
    matchesSearch(item, term) { return item.rpm.toLowerCase().includes(term); }
    getSortValue(item, column) { return item.rpm.toLowerCase(); }
}

// --- Helper Functions ---
function exportToCSV(data, filename, headers, osName) {
    // Get the month from the current OS data context
    const osData = allOSData[osName];
    const month = osData?.month || new Date().toLocaleString('default', { month: 'long' });  // fallback to current month

    // Create proper filename
    let downloadFilename;
    if (filename.includes('ERRATA')) {
        downloadFilename = `${osName}-${month}_ERRATA.csv`;
    } else {
        downloadFilename = `${osName}-${month}_PACKAGES.csv`;
    }

    // Create CSV content with correct headers
    let csvContent;
    if (filename.includes('ERRATA')) {
        csvContent = 'RPM Name,Red Hat Risk Rating,RHSA ID,CVE ID\n';
        data.forEach(row => {
            const values = [
                row.package || '',
                row.severity || '',
                row.id || '',
                row.cves || ''
            ].map(value => {
                if (String(value).includes(',')) return `"${value}"`;
                return value;
            });
            csvContent += values.join(',') + '\n';
        });
    } else {
        csvContent = 'RPM\n';
        data.forEach(row => {
            csvContent += `${row.rpm || ''}\n`;
        });
    }

    // Create and download file
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = downloadFilename;
    link.click();
}

function animateSummaryNumber(element, target) {
    let current = 0;
    const duration = 1000;
    const stepTime = 16;
    const steps = duration / stepTime;
    const increment = target / steps;

    const update = () => {
        current += increment;
        if (current < target) {
            element.innerText = Math.ceil(current).toLocaleString();
            requestAnimationFrame(update);
        } else {
            element.innerText = target.toLocaleString();
        }
    };
    update();
}

function updateSummary(osData) {
    const counts = { high: 0, medium: 0, low: 0, unknown: 0 };
    osData.errata.forEach(e => {
        counts[e.severity.toLowerCase()] = (counts[e.severity.toLowerCase()] || 0) + 1;
    });

    animateSummaryNumber(document.getElementById('summaryTotalErrata'), osData.errata.length);
    animateSummaryNumber(document.getElementById('summaryHigh'), counts.high);
    animateSummaryNumber(document.getElementById('summaryMedium'), counts.medium);
    animateSummaryNumber(document.getElementById('summaryLow'), counts.low);
    animateSummaryNumber(document.getElementById('summaryRpms'), osData.packages.length);
}

function displayOSData(osName) {
    const data = allOSData[osName];
    if (!data) return;

    // Update tables
    errataTable.updateData(data.errata);
    packageTable.updateData(data.packages);

    // Update Summary
    updateSummary(data);

    // Update active button
    document.querySelectorAll('.os-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.os === osName);
    });

    // Update kernel value in summary meta card
    const kernelEl = document.getElementById('summaryKernelValue');
    if (kernelEl) {
        if (data.kernelCallout && data.kernelCallout.includes('kernel-updated')) {
            const match = data.kernelCallout.match(/<code>(.*?)<\/code>/);
            kernelEl.textContent = match ? match[1] : 'Updated';
            kernelEl.className = 'patchset-meta-value kernel-updated';
        } else {
            kernelEl.textContent = 'No new kernel detected';
            kernelEl.className = 'patchset-meta-value kernel-none';
        }
    }

    // Update OS version value in summary meta card
    const osEl = document.getElementById('summaryOSVersionValue');
    if (osEl && data.osVersionCallout) {
        const tmp = document.createElement('div');
        tmp.innerHTML = data.osVersionCallout;
        const span = tmp.querySelector('span[data-os-curr]');
        if (span) {
            const changed   = span.dataset.osChanged === 'true';
            const curr      = span.dataset.osCurr;
            const prev      = span.dataset.osPrev;
            if (changed) {
                osEl.textContent    = `${prev} \u2192 ${curr}`;
                osEl.className      = 'patchset-meta-value os-version-updated';
            } else {
                osEl.textContent    = `${curr} \u2014 no change`;
                osEl.className      = 'patchset-meta-value os-version-none';
            }
        }
    }

    // Reset search fields
    document.getElementById('errataSearchBox').value = '';
    document.getElementById('packageSearchBox').value = '';
}

// --- Initialization ---
function init() {

    // Create OS selector buttons
    Object.keys(allOSData).forEach(osName => {
        const button = document.createElement('button');
        button.className = 'os-btn';
        button.textContent = osName;
        button.dataset.os = osName;
        button.addEventListener('click', () => displayOSData(osName));
        osSelector.appendChild(button);
    });

    // Initilize table managers with empty data initially
    errataTable = new ErrataTableManager([], 'errataTableBody', 'errataPaginationControls');
    packageTable = new PackageTableManager([], 'packageTableBody', 'packagePaginationControls');

    // Load initial data
    const initialOS = Object.keys(allOSData)[0];
    if(initialOS) {
        displayOSData(initialOS);
    }

    // Setup search boxes
    document.getElementById('errataSearchBox').addEventListener('input', (e) => errataTable.filter(e.target.value));
    document.getElementById('packageSearchBox').addEventListener('input', (e) => packageTable.filter(e.target.value));

    // Setup CSV download buttons
    document.getElementById('downloadErrataBtn').addEventListener('click', () => {
        const currentOS = document.querySelector('.os-btn.active')?.dataset.os;
        if (currentOS) {
            exportToCSV(errataTable.originalData, 'ERRATA.csv', [], currentOS);
        }
    });
    document.getElementById('downloadPackageBtn').addEventListener('click', () => {
        const currentOS = document.querySelector('.os-btn.active')?.dataset.os;
        if (currentOS) {
            exportToCSV(packageTable.originalData, 'PACKAGES.csv', [], currentOS);
        }
    });

    // Setup sortable headers
    document.querySelectorAll('th.sortable').forEach(header => {
        header.addEventListener('click', () => {
            const table = header.closest('table');
            const column = header.dataset.column;
            if (table.querySelector('#errataTableBody')) errataTable.sort(column);
            else if (table.querySelector('#packageTableBody')) packageTable.sort(column);
        });
    });
    // Accordion logic for archives
    document.querySelectorAll('.archive-year-header').forEach(header => {
        header.addEventListener('click', function () {
            this.classList.toggle('active');
            this.nextElementSibling.classList.toggle('show');
        });
    });
    // Open the first archive year by default
    const firstAccordionHeader = document.querySelector('.archive-year-header');
    if (firstAccordionHeader) { firstAccordionHeader.click(); }
}

init();
});
    </script>
</body>
</html>
HTML_FOOTER
    } >> "$html_file"
}

# Generate and append the archive section only for the main report.
if [[ "$is_current" == "true" ]]; then
    generate_archive_links_html >> "$html_file"
fi

cat >> "$html_file" << HTML_FOOTER_START
        </div>
        <div class="footer">
            <div class="logo">🔒 Data gathered from Red Hat Satellite</div>
            <div>Generated on $(date)</div>
        </div>
    </div>

    <script>
document.addEventListener('DOMContentLoaded', function() {

    // =========================================================================
    // DATA SOURCE - Generated by bash script
    // =========================================================================
HTML_FOOTER_START
}

# Translate internal content view names to more user-friendly display names
translate_cv_name() {
    local full_name="$1"
    case "$full_name" in
        "RHEL9_current") echo "RHEL9" ;;
        "RHEL8_current") echo "RHEL8" ;;
        "RHEL8.8") echo "RHEL8.8" ;;
        *) echo "$full_name" ;;   # fallback to original name
    esac
}

# Function to get second Tuesday of a given month/year
get_second_tuesday_date() {
    local month="$1"
    local year="$2"
    local first_day_of_week
    first_day_of_week=$(date -d "$month 1 $year" +%u)

    local days_until_first_tuesday=$(( (2 - first_day_of_week + 7) % 7 ))
    local days_until_second_tuesday=$(( days_until_first_tuesday + 7 ))

    date -d "$month 1 $year +${days_until_second_tuesday} days" +"%B %-d, %Y"
}

# Function to get previous month name
get_previous_month_year() {
    local month="$1"
    local year="$2"
    # This command correctly handles year rollovers
    date -d "$month 1 $year -1 month" +"%B %Y"
}

# Function to get available months from cache directory
get_available_month_years() {
    local month_years=()
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            local basename
            basename=$(basename "$file")
            # Extract month and year from filename
            if [[ $basename =~ _([A-Za-z]+)_([0-9]{4})_ERRATA\.json$ ]]; then
                local month="${BASH_REMATCH[1]}"
                local year="${BASH_REMATCH[2]}"
                month_years+=("$month $year")
            fi
        fi
    done < <(find "$cache_root" -type f -name "*_*_ERRATA.json" -print0)
    # Return unique, sorted list of "Month Year" strings.
    printf '%s\n' "${month_years[@]}" | sort -u -k2,2n -k1,1M
}

# Main execution
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Processing satellite reports..."

# Get current month
current_month=$(date +"%B")
current_year=$(date +"%Y")

mapfile -t available_month_years < <(get_available_month_years)

for month_year in "${available_month_years[@]}"; do
    read -r month year <<< "$month_year"

    if [[ "$month" == "$current_month" && "$year" == "$current_year" ]]; then
        continue
    fi

    read -r prev_month prev_year <<< "$(get_previous_month_year "$month" "$year")"

    if ! find "$cache_root" -type f -name "*_${prev_month}_${prev_year}_ERRATA.json" -print0 | read -r -d $'\0'; then
        echo "Skipping archive report for $month $year: No data found for the previous month ($prev_month $prev_year) to compare aganist."
        continue
    fi

    month_lower=$(echo "$month" | tr '[:upper:]' '[:lower:]')
    archive_filename="patchset_${month_lower}_${year}.html"
    archive_filepath="$report_root/$archive_filename"

    if [[ -f "$archive_filepath" ]]; then
        echo "Skipping archive report for $month $year: File already exists."
        continue
    fi

    echo "Generating archive report for $month $year: $archive_filepath"
    process_month_data "$month" "$year" "$archive_filepath" "false"
done

main_report_file="$report_root/index.html"
echo "Generating current month report: $main_report_file"
process_month_data "$current_month" "$current_year" "$main_report_file" "true"

echo "Report generation completed!"
echo "Main report: $main_report_file"
echo "Archive reports generated in: $report_root/"

# ============================================================
# JSON Cache Cleanup
# Retention policy: current month + 5 complete past months
# = 6 months of JSON total on disk.
# Anything older is deleted here, AFTER all HTML has been
# written, so there is no risk of removing a file still needed
# by this run.
#
# Owner: sat_html_gen.sh is the sole owner of JSON lifecycle.
# The Ansible playbook no longer performs any JSON deletion.
# ============================================================
cleanup_old_json_cache() {
    local months_to_keep=6
    local valid_months=()

    # Build the list of valid "Month Year" strings to keep.
    # seq 0 = current month, seq 5 = 5 months ago.
    for i in $(seq 0 $((months_to_keep - 1))); do
        valid_months+=("$(date -d "$i months ago" '+%B %Y')")
    done

    echo "$(date): JSON cache cleanup — retaining: ${valid_months[*]}"

    # Walk every JSON file across all CV subdirectories
    while IFS= read -r -d '' json_file; do
        local basename
        basename=$(basename "$json_file")

        # Expected filename pattern:
        #   Report_{CVname}_{Month}_{Year}_{TYPE}.json
        #   e.g. Report_RHEL9_current_May_2026_ERRATA.json
        if [[ $basename =~ _([A-Za-z]+)_([0-9]{4})_(ERRATA|PACKAGES)\.json$ ]]; then
            local file_month="${BASH_REMATCH[1]}"
            local file_year="${BASH_REMATCH[2]}"
            local file_month_year="$file_month $file_year"

            local keep=false
            for valid in "${valid_months[@]}"; do
                if [[ "$file_month_year" == "$valid" ]]; then
                    keep=true
                    break
                fi
            done

            if [[ "$keep" == false ]]; then
                echo "$(date): Removing expired JSON cache: $basename"
                rm -f "$json_file"
            fi
        else
            # Filename does not match the expected pattern — leave it untouched
            echo "$(date): Skipping unrecognized file during cleanup: $basename"
        fi
    done < <(find "$cache_root" -type f -name "*.json" -print0)

    echo "$(date): JSON cache cleanup complete."
}

cleanup_old_json_cache
