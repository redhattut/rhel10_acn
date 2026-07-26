#!/bin/bash
# =============================================================================
# rhel_remote_scan.sh — Per-host data collection (runs remotely via pssh)
# =============================================================================
# Replaces: RHEL_inventory_scan_script.sh
#           RHEL_IDinventory_script.sh
#           RHEL_DBinventory_script.sh
#           RHEL_pkginventory_script.sh
#
# This script is piped into pssh via stdin (cat script | pssh -I ...).
# It runs entirely on the remote host under bash and produces tagged output
# lines on stdout. The jumpbox-side rhel_filter_scan.sh reads that stream
# and splits it into four separate data files by tag prefix.
#
# Output line format:
#   INV|<data...>     one line — full system inventory record (space-delimited)
#   ID|<data...>      one or more lines — user/group/netgroup records
#   DB|<data...>      one line — comma-separated Oracle SID list (or empty)
#   PKG|<data...>     one line per installed RPM — host,name,version,release,date
#
# All tags use | as delimiter so they survive the pssh --inline-stdout
# header lines (which start with "hostname: ") without collision.
#
# NOTE: this script must be self-contained — no sourcing of external files,
# no assumptions about PATH beyond /bin:/usr/bin:/sbin:/usr/sbin.
# =============================================================================

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# =============================================================================
# Hostname resolution
# =============================================================================
# Handles the "node*" special case where generic hostnames like "node" are
# used on certain systems — resolve the real hostname via reverse DNS.

MYNAME="${HOSTNAME/.*/}"
if [[ "${MYNAME}" =~ ^node$ ]]; then
    # Source PNC_PROVISION_CONFIG if available to get FINALIPADDR
    [[ -f /boot/PNC_PROVISION_CONFIG ]] && . /boot/PNC_PROVISION_CONFIG
    if [[ -n "$FINALIPADDR" ]]; then
        RESOLVED=$(host "$FINALIPADDR" 2>/dev/null | awk '{print $NF}')
        HOST="${RESOLVED/.*/}"
    fi
    HOST="${HOST:-$MYNAME}"
else
    HOST="$MYNAME"
fi

# =============================================================================
# OS / Release detection
# =============================================================================

RREC=$(head -1 /etc/redhat-release 2>/dev/null)
if [[ -n "$RREC" ]]; then
    release=$(echo "${RREC/*release /}" | awk '{print $1}')
    version=$(echo "${RREC/*Update /}")
    if [[ "$version" = "$RREC" ]]; then
        version=""
    else
        version=$(echo ".$version" | awk -F'\)' '{print $1}')
    fi
else
    # SuSE fallback
    RREC=$(cat /etc/SuSE-release 2>/dev/null)
    if [[ -n "$RREC" ]]; then
        release=$(echo "$RREC" | awk '{print $2}')
        release="${release/-*}-"
        version="${RREC/*= }"
    fi
fi

RELEASE="${release}${version}"
[[ -z "$RELEASE" ]] && RELEASE="?"

# =============================================================================
# Kernel and architecture
# =============================================================================

UNAME=$(uname -rm 2>/dev/null)
KERNEL="${UNAME/ *}"
ARCH="${UNAME/* }"

# =============================================================================
# Uptime (days)
# =============================================================================

UPTIME=$(uptime 2>/dev/null)
if [[ "${UPTIME/ days/}" = "$UPTIME" ]]; then
    UPDAYS=0
else
    UPDAYS="${UPTIME/*up /}"
    UPDAYS="${UPDAYS/ days*/}"
fi

# =============================================================================
# CPU information
# =============================================================================

CPUINFO=$(cat /proc/cpuinfo 2>/dev/null)

CPU_THREADCOUNT=$(echo "$CPUINFO" | grep "^processor" | wc -l)
CPU_THREADCOUNT="${CPU_THREADCOUNT// /}"

# Physical core count — use core id + physical id if available, else threads
if echo "$CPUINFO" | grep -q "^core "; then
    CPUCOUNT=$(echo "$CPUINFO" \
        | egrep -e "^core id|^physical" \
        | xargs -l2 echo \
        | sort -u \
        | wc -l)
else
    CPUCOUNT=$CPU_THREADCOUNT
fi
CPUCOUNT="${CPUCOUNT// /}"

# Socket count
CPU_SOCKETCOUNT=$(echo "$CPUINFO" | grep "physical id" | sort -u | wc -l)
CPU_SOCKETCOUNT="${CPU_SOCKETCOUNT// /}"

# Virtual or physical detection
if [[ $CPU_SOCKETCOUNT -eq 0 ]]; then
    PV="Virt"
else
    lspci 2>/dev/null | grep -q 'VMware\ PCI'
    if [[ $? -eq 0 ]]; then
        PV="Virt"
    else
        PV="Phys"
    fi
fi

# CPU type (model name, cleaned up)
CPU_TYPE=$(echo "$CPUINFO" | grep "^model name" | head -1 | awk -F: '{print $2}')
CPU_TYPE=$(echo $CPU_TYPE)            # collapse whitespace
CPU_TYPE="${CPU_TYPE// /_}"           # spaces to underscores for field safety
CPU_TYPE="${CPU_TYPE:-n/a}"

# CPU speed — rounded to nearest 10 MHz
CPU_SPEED=$(echo "$CPUINFO" | grep "^cpu MHz" | head -1 | awk -F: '{print $2}')
CPU_SPEED="${CPU_SPEED/ /}"
CPU_SPEED=$(echo "(($CPU_SPEED+5)/10)*10" | bc 2>/dev/null)
CPU_SPEED="${CPU_SPEED:-0}"

# =============================================================================
# Memory (MB)
# =============================================================================

MEMORY=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))

# =============================================================================
# Hardware — vendor, model, serial (dmidecode)
# =============================================================================

SERVERHWINFO=$(dmidecode 2>/dev/null \
    | egrep -e 'Product Name:|Manufacturer:|Serial Number:' \
    | head -3)

HW_MANUFACTURER=$(echo "$SERVERHWINFO" \
    | grep "Manufacturer:" \
    | awk -F: '{print $2}')
HW_MANUFACTURER=$(echo $HW_MANUFACTURER)   # trim whitespace
HW_MANUFACTURER="${HW_MANUFACTURER//# /}"
HW_MANUFACTURER="${HW_MANUFACTURER// /_}"
HW_MANUFACTURER="${HW_MANUFACTURER//,/}"
HW_MANUFACTURER="${HW_MANUFACTURER:=n/a}"

HW_MODEL=$(echo "$SERVERHWINFO" \
    | grep "Product Name:" \
    | awk -F: '{print $2}' \
    | xargs echo)
HW_MODEL="${HW_MODEL//# /}"
HW_MODEL="${HW_MODEL// /_}"
HW_MODEL="${HW_MODEL//,/}"
HW_MODEL="${HW_MODEL:=n/a}"

HW_SERIAL=$(echo "$SERVERHWINFO" \
    | grep "Serial Number:" \
    | awk -F: '{print $2}' \
    | xargs echo)
HW_SERIAL="${HW_SERIAL// /_}"
HW_SERIAL="${HW_SERIAL:=n/a}"

# =============================================================================
# PNC_PROVISION_CONFIG — all fields sourced from here
# =============================================================================

# Source the file quietly; it exports variables we use directly
. /boot/PNC_PROVISION_CONFIG > /dev/null 2>&1

BUILDTYPE="${BUILDTYPE:-n/a}"
DBTYPE="${DBTYPE:-n/a}"
LOCATION="${LOCATION:-n/a}"
CIDEVICE="${CIDEVICE:-n/a}"
VCENTER="${VCENTER:-n/a}"
ENVIRONMENT="${ENVIRONMENT:-n/a}"

# BuildDate — prefer PROVISIONDATE from config (modern SOE hosts)
# Falls back to n/a; rhel_inv_collect.sh will fill from RHEL_DEPLOYMENTS.dat
# for legacy hosts that predate this field
BUILDDATE="${PROVISIONDATE:-n/a}"

# AppCode — not in PNC_PROVISION_CONFIG, derived from hostname convention:
# l<appcode><nn><site> e.g. lmrg10ia → mrg, lpay20tdz → pay
# Strip leading single letter, take all lowercase letters before first digit
APPCODE=$(echo "$HOST" | sed 's/^[a-z]//' | grep -o '^[a-z]*')
APPCODE="${APPCODE:-n/a}"

# =============================================================================
# Syslog-ng service status
# =============================================================================

case $RELEASE in
    [789]*|[789][0-9]*)
        SYSLOG=$(systemctl is-active syslog-ng 2>/dev/null)
        ;;
    6*)
        sout=$(service syslog-ng status 2>/dev/null)
        case "$sout" in
            *[OK]*)     SYSLOG="active"  ;;
            *[FAILED]*) SYSLOG="failed"  ;;
            *)          SYSLOG="unknown" ;;
        esac
        ;;
    *)
        SYSLOG="unknown"
        ;;
esac

# =============================================================================
# VMware Tools
# =============================================================================

VMWTOOLS=$(/usr/sbin/vmtoolsd -v 2>/dev/null \
    | awk -Fversion '{print $2}' \
    | awk '{print $1}')

if [[ -z "$VMWTOOLS" ]]; then
    VMWTOOLS=$(rpm -q -a \
        | grep -i vmware \
        | grep -i tools \
        | head -1 \
        | xargs rpm -q -i 2>/dev/null \
        | grep "^Version" \
        | awk -F: '{print $2}' \
        | awk '{print $1}')
    VMWTOOLS="${VMWTOOLS:=n/a}"
fi

# Is vmtoolsd or vmware-guestd actually running?
ps -fA | grep -v grep | egrep -e "vmtoolsd|vmware-guestd" > /dev/null
if [[ $? -eq 0 ]]; then
    VMTOOLSRUNNING="Y"
else
    VMTOOLSRUNNING="N"
fi

# =============================================================================
# Last Avamar backup date
# =============================================================================

LASTBACKUPDATE=$(ls -t \
    /usr/local/avamar/var/Daily*.log \
    /usr/local/avamar/var/clientlogs/Daily*.log \
    2>/dev/null \
    | head -1 \
    | xargs grep "END" 2>/dev/null \
    | tail -1 \
    | awk -F" log " '{print $2}' \
    | awk '{print $1}')
LASTBACKUPDATE="${LASTBACKUPDATE:-UNKNOWN}"

# =============================================================================
# Primary IP address
# =============================================================================

case $RELEASE in
    [789]*)
        NETDEVICE=$(/sbin/ip -o route \
            | grep "^default" \
            | head -1 \
            | awk '{print $5}')
        IPADDR=$(/sbin/ifconfig "$NETDEVICE" \
            | grep "inet " \
            | awk '{print $2}')
        ;;
    *)
        NETDEVICE=$(/sbin/ip -o route \
            | grep "^default" \
            | awk '{print $NF}')
        IPADDR=$(/sbin/ifconfig "$NETDEVICE" \
            | grep "inet addr" \
            | awk -F"inet addr" '{print $2}' \
            | awk -F"/" '{print $1}')
        ;;
esac
IPADDR="${IPADDR:-n/a}"

# =============================================================================
# OUTPUT — INV tag (system inventory record)
# =============================================================================
# Fields (space-delimited, matching original RHEL_inventory_scan_script output):
#   PV RELEASE KERNEL ARCH MEMORY CPU_SOCKETCOUNT CPUCOUNT CPU_THREADCOUNT
#   CPU_TYPE CPU_SPEED HW_MANUFACTURER HW_MODEL HW_SERIAL SYSLOG UPDAYS
#   VMWTOOLS VMTOOLSRUNNING LASTBACKUPDATE IPADDR LOCATION CIDEVICE VCENTER
#   BUILDTYPE DBTYPE

# INV| output — 28 space-delimited fields after the tag:
# Host(1) Type(2) OS(3) Kernel(4) Arch(5) Memory(6) CPUSockets(7) CPUCores(8)
# CPUThreads(9) CPUType(10) CPUSpeed(11) HWVendor(12) HWModel(13) Serial(14)
# Syslog(15) Uptime(16) VMToolsVer(17) VMToolsRun(18) LastBackup(19) IP(20)
# Location(21) CIDevice(22) vCenter(23) BuildType(24) DBType(25)
# AppCode(26) Environment(27) BuildDate(28)
#
# AppCode, Environment, BuildDate are appended at the end so existing
# field positions 1-25 remain identical to legacy for backward compatibility.
echo "INV|${HOST} ${PV} ${RELEASE} ${KERNEL} ${ARCH} ${MEMORY} ${CPU_SOCKETCOUNT} ${CPUCOUNT} ${CPU_THREADCOUNT} ${CPU_TYPE} ${CPU_SPEED} ${HW_MANUFACTURER} ${HW_MODEL} ${HW_SERIAL} ${SYSLOG} ${UPDAYS} ${VMWTOOLS} ${VMTOOLSRUNNING} ${LASTBACKUPDATE} ${IPADDR} ${LOCATION} ${CIDEVICE} ${VCENTER} ${BUILDTYPE} ${DBTYPE} ${APPCODE} ${ENVIRONMENT} ${BUILDDATE}"

# =============================================================================
# OUTPUT — ID tag (users, groups, netgroups, AD groups)
# =============================================================================

# Local users from /etc/passwd  →  hostname-USER-user:uid:gid,...
awk -F: '{print $1":"$3","$4","}' /etc/passwd \
    | xargs echo "${HOST}-USER-" \
    | sed 's/ //g' \
    | while read -r idline; do
        echo "ID|${idline}"
    done

# Local groups from /etc/group  →  hostname-GROUP-group,...
awk -F: '{print $1","}' /etc/group \
    | xargs echo "${HOST}-GROUP-" \
    | sed 's/ //g' \
    | while read -r idline; do
        echo "ID|${idline}"
    done

# Netgroups from login-access.conf  →  hostname-NETGROUP-netgroup,...
if [[ -f /etc/security/login-access.conf ]]; then
    grep -v "^#" /etc/security/login-access.conf \
        | grep "^+" \
        | grep "@" \
        | awk -F@ '{print $2}' \
        | awk '{print $1","}' \
        | xargs echo "${HOST}-NETGROUP-" \
        | sed 's/ //g' \
        | while read -r idline; do
            echo "ID|${idline}"
        done

    # AD groups from login-access.conf  →  hostname-ADGROUP-adgroup,...
    grep -v "^#" /etc/security/login-access.conf \
        | grep "^+" \
        | grep "(" \
        | awk -F'(' '{print $2}' \
        | awk -F')' '{print $1","}' \
        | xargs echo "${HOST}-ADGROUP-" \
        | sed 's/ //g' \
        | while read -r idline; do
            echo "ID|${idline}"
        done
fi

# =============================================================================
# OUTPUT — DB tag (Oracle SID list)
# =============================================================================

# Find ora_pmon_ processes to identify running Oracle SIDs
SIDS=$(ps -ef \
    | grep ora_pmon_ \
    | egrep -v "pmon_[+-]|grep|sed" \
    | awk '{print $NF}' \
    | sed 's/ora_pmon_//' \
    | xargs echo -n \
    | sed -e 's/ /,/g' -e 's/,$//')

# Only emit a DB line if SIDs were found
if [[ -n "$SIDS" ]]; then
    echo "DB|${HOST} ${SIDS}"
fi

# =============================================================================
# OUTPUT — PKG tag (RPM package inventory)
# =============================================================================
# One PKG line per installed RPM:
#   PKG|hostname,pkgname,version,release,installdate

rpm -qa --queryformat '%{NAME} %{VERSION} %{RELEASE} %{installtime}\n' \
    2>/dev/null \
    | sort -k 1,1 -u \
    | while read -r a b c d; do
        [[ -z "$a" ]] && continue
        installdate=$(date +%m/%d/%Y_%T -d "@${d}" 2>/dev/null)
        echo "PKG|${HOST},${a},${b},${c},${installdate}"
    done
# =============================================================================
# OUTPUT — UPG tag (RHEL 8 to 9 upgrade eligibility)
# =============================================================================
# One UPG line per host:
#   UPG|hostname,location,mnemonic,environment,os_display,eligibility,comments
#
# Eligibility values:
#   ELIGIBLE    — passes all checks, ready to upgrade
#   CONDITIONAL — rootvg < 22 GB; eligible after disk expansion
#   INELIGIBLE  — hard blocker (previous upgrade, low /boot, DB server, not RHEL 8)
#
# ─────────────────────────────────────────────────────────────────────────────
# ELIGIBILITY CRITERIA — edit each numbered section to change the rules.
# Priority order: lower number = checked/reported first in comments.
# ─────────────────────────────────────────────────────────────────────────────

_upg_host="$HOST"
_upg_loc="${LOCATION:-Unknown}"
_upg_loc="${_upg_loc//Greenfield-/}"    # strip Greenfield- prefix
_upg_mnemo=$(echo "$HOST" | sed 's/^[a-z]//' | grep -o '^[a-z]*' | tr '[:lower:]' '[:upper:]')
_upg_mnemo="${_upg_mnemo:-Unknown}"
_upg_env="${ENVIRONMENT:-Unknown}"
_upg_os="Unknown"
_upg_status="ELIGIBLE"
_upg_issue=""
_upg_pri=99

_upg_set_issue() {
    local msg="$1" pri="$2"
    if [[ -z "$_upg_issue" || "$pri" -lt "$_upg_pri" ]]; then
        _upg_issue="$msg"
        _upg_pri="$pri"
        _upg_status="INELIGIBLE"
    fi
}

# ── Criterion 1: OS version — must be RHEL 8.x ─────────────────────────────
_upg_ver=""
if [[ -f /etc/redhat-release ]]; then
    _upg_ver=$(grep -oP 'release \K[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "")
fi

if [[ "$_upg_ver" =~ ^7\. ]]; then
    # RHEL 7: exit silently — no UPG line emitted
    exit 0
elif [[ "$_upg_ver" =~ ^8\. ]]; then
    _upg_os="RHEL 8"
elif [[ "$_upg_ver" =~ ^9\. ]]; then
    _upg_os="RHEL 9"
    _upg_set_issue "Already running RHEL 9" 1
elif [[ -n "$_upg_ver" ]]; then
    _upg_os="RHEL $_upg_ver"
    _upg_set_issue "Not RHEL 8 — found RHEL $_upg_ver" 1
else
    _upg_os="Unknown"
    _upg_set_issue "Unable to detect OS version" 1
fi

# ── Criterion 2: No previous upgrade (7→8 leapp) ───────────────────────────
if [[ -f /etc/os_upgrade ]]; then
    _upg_set_issue "Previous RHEL 7 to 8 upgrade detected — not eligible for second in-place upgrade" 2
fi

# ── Criterion 3: /boot partition space — minimum 1024 MB (2 GB required) ───
_upg_boot=$(df -m /boot 2>/dev/null | awk 'NR==2 {print $4}')
_upg_boot="${_upg_boot:-0}"
if [[ "$_upg_boot" -lt 1024 ]]; then
    _upg_set_issue "Low /boot space — ${_upg_boot}MB free, 2GB required" 3
fi

# ── Criterion 4: Not a DB server — DBTYPE must be unset ────────────────────
if grep -q "^DBTYPE=.\+[^[:space:]]" /boot/PNC_PROVISION_CONFIG 2>/dev/null; then
    _upg_set_issue "Database servers are not certified for RHEL 9 in-place upgrade" 4
fi

# ── Criterion 5: rootvg free space — minimum 22 GB ─────────────────────────
# NOTE: < 22 GB is CONDITIONAL (disk expansion needed), not hard INELIGIBLE.
# These hosts are counted as eligible in the KPI rate.
_upg_rootvg=$(vgs --noheadings --units g --nosuffix rootvg 2>/dev/null | awk '{printf "%d", $7}')
_upg_rootvg="${_upg_rootvg:-0}"
if [[ "$_upg_status" == "ELIGIBLE" && "$_upg_rootvg" -lt 22 ]]; then
    _upg_status="CONDITIONAL"
    _upg_issue="Disk expansion required — rootvg ${_upg_rootvg}G free, 22G needed. Expand rootvg then request upgrade."
fi

# ── Final status ─────────────────────────────────────────────────────────────
if [[ "$_upg_status" == "ELIGIBLE" ]]; then
    _upg_issue="Meets all requirements"
fi

echo "UPG|${_upg_host},${_upg_loc},${_upg_mnemo},${_upg_env},${_upg_os},${_upg_status},${_upg_issue}"
