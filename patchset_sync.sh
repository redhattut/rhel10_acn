#!/bin/bash

# =============================================================
# patchset_sync.sh
# Backs up existing HTML files from the web directory to the
# backup folder, then rsyncs updated files from lmrg10aa.
# Log: /usr/local/midweb/RHEL/patchset/rsync.log
# =============================================================

set -euo pipefail

WEB_DIR="/usr/local/midweb/RHEL/patchset"
BACKUP_DIR="${WEB_DIR}/backup"
LOG="${WEB_DIR}/rsync.log"
SOURCE="lmrg10aa:/opt/app/Sat_Report/reports/"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

log "======================================================"
log "Patchset sync started"

# --- Step 1: Backup existing HTML files before overwriting ---
log "Backing up existing HTML files to ${BACKUP_DIR}/${TIMESTAMP}/"
mkdir -p "${BACKUP_DIR}/${TIMESTAMP}"

shopt -s nullglob
html_files=("${WEB_DIR}"/index.html "${WEB_DIR}"/patchset_*.html)

if [[ ${#html_files[@]} -gt 0 ]]; then
    cp -v "${html_files[@]}" "${BACKUP_DIR}/${TIMESTAMP}/" >> "$LOG" 2>&1
    log "Backup complete: ${#html_files[@]} file(s) copied to ${BACKUP_DIR}/${TIMESTAMP}/"
else
    log "No existing HTML files found to back up — first run or clean directory."
fi

# --- Step 2: Rsync from source, HTML files only ---
log "Starting rsync from ${SOURCE}"
rsync -avz \
    --include='index.html' \
    --include='patchset_*.html' \
    --exclude='*' \
    "$SOURCE" \
    "$WEB_DIR/" >> "$LOG" 2>&1

log "Rsync complete"
log "======================================================"
