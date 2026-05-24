#!/bin/bash
# Midrange_Mod_Report.sh
#
# Original behaviour preserved 100%:
#   - Accepts -m (mail) and -h <hosts_file> flags
#   - Auto-generates hosts list from RHEL_INVENTORY.dat when no -h given
#   - Runs RHEL_data_gather.sh on all hosts via pssh in one pass
#   - Produces Midrange_Mod_Report.csv (same path, same 13-column order)
#   - Archives CSV, prunes after DAYS_TO_KEEP, generates Midrange_Mod/index.html
#   - Optionally mails the CSV
#
# New in this version:
#   - Same pssh run also writes /tmp/compare_<host>.json on each remote host
#   - Wrapper scps those JSON files → /data/MRGeng/Compare/data/<host>.json
#   - JSON files are always overwritten — no archive
#   - Unreachable/failed hosts get a stub JSON written locally
#   - The -h <hosts_file> flag applies to BOTH outputs simultaneously
#
# Parser design: RHEL_data_gather.sh tags every output line with the hostname
#   CSV_DATA:<hostname>:<csv_fields>
#   JSON_WRITTEN:<hostname>:/tmp/compare_<hostname>.json
# This makes parsing safe against pssh --inline-stdout interleaving output
# from multiple hosts in parallel — no fragile state machine needed.
#
# Usage:
#   ./Midrange_Mod_Report.sh [-m] [-h <hosts_file>]

# ── Configuration ─────────────────────────────────────────────────────────────
MAIL_ON=false
SCRIPTS_DIR="/data/MRGeng/Midrange_Mod_Report"
CUSTOM_HOSTS_FILE=""
DEFAULT_HOSTS_FILE="$SCRIPTS_DIR/rhel_hosts.txt"

INPUT_FILE="$SCRIPTS_DIR/RHEL_data_gather.log"
OUTPUT_CSV="/usr/local/midweb/RHEL/Midrange_Mod_Report.csv"

# Real directory inside the web root — no symlink, no httpd config changes needed.
# httpd serves JSON files directly. Must be world-readable (see chmod 644 below).
COMPARE_DATA_DIR="/usr/local/midweb/RHEL/compare/data"

ARCHIVE_DIR="/usr/local/midweb/RHEL/Midrange_Mod/archive"
INDEX_FILE="/usr/local/midweb/RHEL/Midrange_Mod/index.html"
DAYS_TO_KEEP=31

PSSH_BIN="/usr/local/pssh/bin/pssh"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
SSH_TIMEOUT=30
PARALLEL=75

# ── Parse options ─────────────────────────────────────────────────────────────
while getopts ":mh:" opt; do
    case "$opt" in
        m) MAIL_ON=true ;;
        h) CUSTOM_HOSTS_FILE="$OPTARG" ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# ── Determine hosts file ──────────────────────────────────────────────────────
if [[ -n "$CUSTOM_HOSTS_FILE" ]]; then
    HOSTS_FILE="$CUSTOM_HOSTS_FILE"
    echo "$(date "+%a %b %d %T %Z %Y"): Using custom hosts file: $HOSTS_FILE"
else
    HOSTS_FILE="$DEFAULT_HOSTS_FILE"
    echo "$(date "+%a %b %d %T %Z %Y"): Generating default hosts list at: $HOSTS_FILE"
    cat /usr/local/pnc/bin/RHEL_Inventory/data/RHEL_INVENTORY.dat \
        | awk '{print $1}' > "$HOSTS_FILE"
fi

mkdir -p "$COMPARE_DATA_DIR"

# ── Run gather script on all hosts via pssh ───────────────────────────────────
echo "$(date "+%a %b %d %T %Z %Y"): Running RHEL_data_gather.sh on all hosts"

cat "$SCRIPTS_DIR/RHEL_data_gather.sh" \
    | sudo "$PSSH_BIN" \
        -I --inline-stdout \
        -p $PARALLEL \
        -t $SSH_TIMEOUT \
        -l root \
        -h "$HOSTS_FILE" \
        bash > "$INPUT_FILE"

echo "$(date "+%a %b %d %T %Z %Y"): Finished gathering. Result in: $INPUT_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
write_unreachable_json() {
    local host="$1"
    local reason="${2:-Host unreachable or SSH failed during pssh collection}"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S')"
    cat > "${COMPARE_DATA_DIR}/${host}.json" <<STUB
{
  "host":         "${host}",
  "collected_at": "${ts}",
  "reachable":    false,
  "error":        "${reason}"
}
STUB
    chmod 644 "${COMPARE_DATA_DIR}/${host}.json"
    echo "$(date "+%a %b %d %T %Z %Y"): Unreachable stub written for ${host}"
}

scp_json_back() {
    local host="$1"
    local remote_path="$2"
    local dest="${COMPARE_DATA_DIR}/${host}.json"

    scp $SSH_OPTS "root@${host}:${remote_path}" "$dest" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "$(date "+%a %b %d %T %Z %Y"): JSON collected: ${host} → ${dest}"
        ssh $SSH_OPTS "root@${host}" "rm -f ${remote_path}" 2>/dev/null
        chmod 644 "$dest"
    else
        echo "$(date "+%a %b %d %T %Z %Y"): WARN — scp failed for ${host}, writing stub"
        write_unreachable_json "$host" "scp of JSON failed after successful pssh run"
    fi
}

# ── Parse pssh log — tag-based, interleave-safe ───────────────────────────────
# RHEL_data_gather.sh emits two tagged line types:
#
#   CSV_DATA:<hostname>:<13-col-csv-row>
#   JSON_WRITTEN:<hostname>:/tmp/compare_<hostname>.json
#
# pssh also emits header lines for each host:
#   [N] HH:MM:SS [SUCCESS] hostname
#   [N] HH:MM:SS [FAILURE] hostname ...
#
# We parse by line prefix — no assumptions about ordering between hosts.
# All CSV_DATA lines go to the CSV. All JSON_WRITTEN lines trigger an scp.
# All FAILURE lines get a placeholder CSV row and an unreachable JSON stub.

echo "$(date "+%a %b %d %T %Z %Y"): Generating CSV from $INPUT_FILE"

echo "Host,Location,Mnemonic,Environment,OS Version,Authentication Method,OUD Query,AD Query,pnc_join_ad,Nsswitch,KRB5 Keytab,xqvsmlinauthscan Sudo,xqmrglineng Sudo" \
    > "$OUTPUT_CSV"

CSV_WRITTEN=0
JSON_COLLECTED=0
FAILED=0

# Track which hosts we saw FAILURE for (to avoid double-processing)
declare -A FAILED_HOSTS

while IFS= read -r line; do

    # ── CSV data line ─────────────────────────────────────────────────────────
    # Format: CSV_DATA:<hostname>:<csv_row>
    if [[ "$line" == CSV_DATA:*:* ]]; then
        # Strip the CSV_DATA:<hostname>: prefix — the rest is the actual CSV row
        csv_row="${line#CSV_DATA:}"       # removes "CSV_DATA:"
        csv_row="${csv_row#*:}"           # removes "<hostname>:"
        echo "$csv_row" >> "$OUTPUT_CSV"
        CSV_WRITTEN=$((CSV_WRITTEN + 1))
        continue
    fi

    # ── JSON ready — scp it back ──────────────────────────────────────────────
    # Format: JSON_WRITTEN:<hostname>:/tmp/compare_<hostname>.json
    if [[ "$line" == JSON_WRITTEN:*:* ]]; then
        rest="${line#JSON_WRITTEN:}"      # removes "JSON_WRITTEN:"
        host="${rest%%:*}"               # everything before first remaining ":"
        remote_path="${rest#*:}"         # everything after first remaining ":"
        scp_json_back "$host" "$remote_path"
        JSON_COLLECTED=$((JSON_COLLECTED + 1))
        continue
    fi

    # ── pssh FAILURE header ───────────────────────────────────────────────────
    # Format: [N] HH:MM:SS [FAILURE] hostname ...
    if [[ "$line" =~ \[FAILURE\] ]]; then
        # hostname is the token immediately after [FAILURE]
        failed_host=$(echo "$line" | grep -oP '\[FAILURE\]\s+\K\S+')
        if [[ -n "$failed_host" && -z "${FAILED_HOSTS[$failed_host]}" ]]; then
            FAILED_HOSTS[$failed_host]=1
            echo "$failed_host,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a" \
                >> "$OUTPUT_CSV"
            write_unreachable_json "$failed_host"
            FAILED=$((FAILED + 1))
        fi
        continue
    fi

    # All other lines (pssh headers, blank lines) are ignored

done < "$INPUT_FILE"

# ── Remove any stray blank/malformed CSV lines ────────────────────────────────
sed -i '/^[[:space:]]*$/d' "$OUTPUT_CSV"

# ── Summary ───────────────────────────────────────────────────────────────────
echo "$(date "+%a %b %d %T %Z %Y"): CSV Report generation complete"
echo "$(date "+%a %b %d %T %Z %Y"): CSV rows written  : $CSV_WRITTEN"
echo "$(date "+%a %b %d %T %Z %Y"): JSON files written: $JSON_COLLECTED"
echo "$(date "+%a %b %d %T %Z %Y"): Failed hosts      : $FAILED"
echo "$(date "+%a %b %d %T %Z %Y"): CSV saved to $OUTPUT_CSV"
echo "$(date "+%a %b %d %T %Z %Y"): JSON saved to $COMPARE_DATA_DIR"
echo "================BEGIN REPORT================"
cat "$OUTPUT_CSV"
echo "================END REPORT=================="

# ── Optional mail ─────────────────────────────────────────────────────────────
if $MAIL_ON; then
    echo "$(date "+%a %b %d %T %Z %Y"): Mailing the CSV report"
    echo "Midrange Mod Report Generated on $(date "+%m/%d/%Y %H:%M:%S")" \
        | sudo mailx -s "Weekly Midrange Mod Report" \
            -a "$OUTPUT_CSV" \
            anup.neupane@pnc.com
fi

# ── Archive CSV ───────────────────────────────────────────────────────────────
mkdir -p "$ARCHIVE_DIR"
CURRENT_DATE=$(date +%m-%d-%Y)
ARCHIVE_FILE="$ARCHIVE_DIR/Midrange_Mod_Report_${CURRENT_DATE}.csv"

if [ -f "$OUTPUT_CSV" ]; then
    cp "$OUTPUT_CSV" "$ARCHIVE_FILE"
    echo "$(date "+%a %b %d %T %Z %Y"): Archived CSV to: $ARCHIVE_FILE"
else
    echo "$(date "+%a %b %d %T %Z %Y"): Warning: $OUTPUT_CSV not found for archiving"
fi

DELETED_COUNT=$(find "$ARCHIVE_DIR" -name "Midrange_Mod_Report_*.csv" \
    -type f -mtime +$DAYS_TO_KEEP -delete -print | wc -l)
if [ "$DELETED_COUNT" -gt 0 ]; then
    echo "$(date "+%a %b %d %T %Z %Y"): Pruned $DELETED_COUNT archive(s) older than $DAYS_TO_KEEP days"
fi

# ── Generate Midrange_Mod/index.html (your existing CSS preserved) ────────────
echo "$(date "+%a %b %d %T %Z %Y"): Generating archive index page"
CURRENT_TIMESTAMP=$(date "+%a %b %d %I:%M:%S %p %Z %Y")

cat > "$INDEX_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Midrange Mod Reports - Archive</title>
    <style>
        :root {
            --primary-bg: #f8f9fc;
            --card-bg: #ffffff;
            --header-bg: #1e293b;
            --border-color: #e2e8f0;
            --text-primary: #334155;
            --text-secondary: #64748b;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Inter', sans-serif;
            background-color: var(--primary-bg);
            color: var(--text-primary);
            line-height: 1.5;
            padding: 1rem;
        }
        .container { max-width: 1280px; margin: 0 auto; }
        header {
            background: var(--header-bg);
            border-radius: 0.75rem;
            padding: 1.5rem;
            margin-bottom: 1.5rem;
            color: white;
        }
        header h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 0.5rem; }
        header p { color: #94a3b8; font-size: 13px; }
        .card {
            background-color: var(--card-bg);
            border-radius: 0.75rem;
            border: 1px solid var(--border-color);
            padding: 1.5rem;
            margin-bottom: 1.5rem;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .card h2 { font-size: 1.25rem; font-weight: 600; margin-bottom: 1rem; color: var(--text-primary); }
        .back-link {
            display: inline-block;
            margin-bottom: 1rem;
            color: #2563eb;
            text-decoration: none;
            font-size: 0.875rem;
            padding: 0.5rem 1rem;
            background-color: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 0.5rem;
            transition: all 0.2s ease;
        }
        .back-link:hover { background-color: #f8fafc; border-color: #cbd5e1; }
        .archive-list { list-style: none; padding: 0; }
        .archive-item {
            padding: 1rem;
            margin-bottom: 0.5rem;
            background-color: #f8fafc;
            border-radius: 0.5rem;
            border: 1px solid var(--border-color);
            transition: all 0.2s ease;
        }
        .archive-item:hover {
            background-color: #f1f5f9;
            border-color: #cbd5e1;
            transform: translateX(2px);
        }
        .archive-item a {
            text-decoration: none;
            color: var(--text-primary);
            display: flex;
            align-items: center;
            font-size: 0.875rem;
        }
        .archive-item a:hover { color: #2563eb; }
        .file-icon { margin-right: 0.75rem; color: var(--text-secondary); font-size: 1.125rem; }
        .file-name { flex: 1; }
        .file-date { margin-left: auto; color: var(--text-secondary); font-size: 0.8125rem; }
        .no-files { text-align: center; padding: 2rem; color: var(--text-secondary); font-size: 0.875rem; }
        footer { text-align: center; padding: 1rem; color: var(--text-secondary); font-size: 0.875rem; margin-top: 2rem; }
    </style>
</head>
<body>
    <div class="container">
        <a href="../" class="back-link">&#8592; Back to Home</a>
        <header>
            <h1>Midrange Mod Reports - Archive</h1>
            <p>Last updated: $CURRENT_TIMESTAMP</p>
        </header>
        <div class="card">
            <h2>Report Archive</h2>
            <ul class="archive-list">
HTMLEOF

if [ -d "$ARCHIVE_DIR" ] && \
   [ -n "$(ls -A "$ARCHIVE_DIR"/Midrange_Mod_Report_*.csv 2>/dev/null)" ]; then
    find "$ARCHIVE_DIR" -name "Midrange_Mod_Report_*.csv" -type f \
        -printf "%T@ %p\n" 2>/dev/null \
        | sort -rn \
        | while read -r ts filepath; do
            filename=$(basename "$filepath")
            file_size=$(du -h "$filepath" 2>/dev/null | cut -f1)
            cat >> "$INDEX_FILE" << ITEM
                <li class="archive-item">
                    <a href="archive/$filename" download>
                        <span class="file-icon">&#128196;</span>
                        <span class="file-name">$filename</span>
                        <span class="file-date">$file_size</span>
                    </a>
                </li>
ITEM
        done
else
    echo '                <li class="no-files">No archived reports available yet.</li>' \
        >> "$INDEX_FILE"
fi

cat >> "$INDEX_FILE" << HTMLCLOSE
            </ul>
        </div>
        <footer>&copy; $(date +%Y) PNC. OS Engineering.</footer>
    </div>
</body>
</html>
HTMLCLOSE

echo "$(date "+%a %b %d %T %Z %Y"): Archive index generated at: $INDEX_FILE"
echo "================END ARCHIVE================"
