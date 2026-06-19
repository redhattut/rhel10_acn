#!/bin/bash
# =============================================================================
# rhel_inv_consolidate.sh — Midrange inventory consolidation report
# =============================================================================
# Replaces: Inventory_Consolidation.sh
#
# Reads RHEL_INVENTORY.dat and produces Midrange_INVENTORY.csv in WEBDIR.
#
# The Midrange CSV has a different column layout from RHEL_INVENTORY.csv:
#   Host, Type, Location, App Code, Environment, Build Date, Parent, OS,
#   OS Version, OS Release, Kernel, Architecture, Cluster Version,
#   CPU Sockets, CPU Cores, CPU Threads, CPU Type, CPU Speed,
#   Server Vendor, Server Model, Serial Number, Uptime(days), Firmware
#
# Mapping from RHEL_INVENTORY.dat fields (1-indexed, space-delimited):
#   $1  = Host
#   $2  = Type (PV — Virt/Phys)
#   $3  = Location
#   $4  = App Code
#   $5  = Environment
#   $6  = Build Date
#   $7  = OS (RHEL release string e.g. 9.3)
#   $8  = Kernel
#   $9  = Architecture
#   $10 = Memory(MB)     — not in Midrange CSV
#   $11 = CPU Sockets
#   $12 = CPU Cores
#   $13 = CPU Threads
#   $14 = CPU Type
#   $15 = CPU Speed
#   $16 = Server Vendor
#   $17 = Server Model
#   $18 = Serial Num
#   $19 = Syslog-ng      — not in Midrange CSV
#   $20 = Uptime(days)
#   ... remaining fields not mapped to Midrange CSV
#
# Hardcoded Midrange values:
#   OS            = "RHEL"     (Midrange only tracks RHEL systems)
#   OS Version    = n/a        (was Cluster Version in old schema)
#   Cluster Version = n/a
#   Firmware      = n/a
# =============================================================================

cd "$(dirname "$0")" || exit 1

CONF="$(dirname "$0")/rhel_inv.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  [ERROR]   rhel_inv.conf not found" >&2
    exit 1
fi
. "$CONF"

log() {
    local level="$1"; shift
    printf '%s  [%-7s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

MIDRANGE_CSV="${WEBDIR}/Midrange_INVENTORY.csv"

# --- Validate input ----------------------------------------------------------
if [[ ! -f "$INVENTORYDATA" ]]; then
    log ERROR "RHEL_INVENTORY.dat not found: $INVENTORYDATA"
    exit 1
fi

RECCOUNT=$(grep -v "^#" "$INVENTORYDATA" | wc -l)
log INFO "Reading $RECCOUNT records from $INVENTORYDATA"
log INFO "Writing Midrange CSV to: $MIDRANGE_CSV"

# --- Write header ------------------------------------------------------------
echo "Host,Type,Location,App Code,Environment,Build Date,Parent,OS,OS Version,OS Release,Kernel,Architecture,Cluster Version,CPU Sockets,CPU Cores,CPU Threads,CPU Type,CPU Speed,Server Vendor,Server Model,Serial Number,Uptime(days),Firmware" \
    > "$MIDRANGE_CSV"

# --- Build CSV rows ----------------------------------------------------------
# Skip comment lines (lines starting with #)
# Column mapping — see header above for field positions
{
    grep -v "^#" "$INVENTORYDATA" \
    | awk '{
        print $1","         \
              $2","         \
              $3","         \
              $4","         \
              $5","         \
              $6","         \
              "n/a,"        \
              "RHEL,"       \
              $7","         \
              "n/a,"        \
              $8","         \
              $9","         \
              "n/a,"        \
              $11","        \
              $12","        \
              $13","        \
              $14","        \
              $15","        \
              $16","        \
              $17","        \
              $18","        \
              $20","        \
              "n/a"
    }'
} | sort >> "$MIDRANGE_CSV"

OUTCOUNT=$(wc -l < "$MIDRANGE_CSV")
# Subtract 1 for header line
log INFO "Midrange CSV complete — $(( OUTCOUNT - 1 )) records written"

exit 0
