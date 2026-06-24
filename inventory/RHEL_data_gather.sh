#!/bin/bash
# RHEL_data_gather.sh
#
# Runs REMOTELY on each host via pssh (concatenated with rhel_remote_scan.sh
# by the main inventory pipeline -- no separate SSH session needed).
#
# Produces TWO tagged output streams via stdout -- BOTH SINGLE LINE PER RECORD.
#
# CRITICAL: pssh --inline-stdout runs many hosts in parallel and interleaves
# their output. All output MUST be one line per record -- no multi-line output.
#
#   1. MID_MOD_CSV:<hostname>:<csv_fields>
#      Single line, 13-column CSV row for Midrange Mod Report
#
#   2. COMPARE_JSON:<hostname>:<minified_json>
#      Single line, complete JSON object for Server Compare Tool
#      Uses printf to build the entire JSON on one line -- no truncation risk
#      because we use $(je ...) which calls printf internally.
#
# Tag format change from legacy (CSV_DATA / JSON_START / JSON_END):
#   CSV_DATA:      -> MID_MOD_CSV:
#   JSON_START/END -> COMPARE_JSON:   (single line, no start/end markers needed)

# --- default values ----------------------------------------------------------
HOSTNAME=$(hostname -s | cut -d. -f1)
RHEL_RELEASE="n/a"
LOCATION="n/a"
MNEMONIC="n/a"
ENVIRONMENT="n/a"
SSSD="n/a"
AUTH_OUD="NO"
AUTH_AD="NO"
LDAP_QUERY="n/a"
AD_QUERY="n/a"
DUAL_AUTH_PKG="n/a"
NSSWITCH="n/a"
KRB5_KEYTAB="n/a"
XQVSMLINAUTHSCAN_SUDO="n/a"
XQMRGLINENG_SUDO="n/a"
XQMRGLINAAP_SUDO="n/a"
XQLRPLINAUTO_SUDO="n/a"

# --- RHEL release ------------------------------------------------------------
RHEL_RELEASE=$(grep -oP 'release \K[\d\.]+' /etc/redhat-release 2>/dev/null || echo "n/a")

# --- Mnemonic ----------------------------------------------------------------
MNEMONIC=$(hostname -s | cut -c2-4 | tr '[:lower:]' '[:upper:]')

# --- Environment -------------------------------------------------------------
ENVIRONMENT=$(cat /boot/PNC_PROVISION_CONFIG 2>/dev/null \
    | grep ENVIRONMENT | tail -n1 | cut -d'=' -f2)
[ -z "$ENVIRONMENT" ] && ENVIRONMENT="n/a"

# --- Location ----------------------------------------------------------------
LOCATION=$(cat /boot/PNC_PROVISION_CONFIG 2>/dev/null \
    | grep LOCATION | tail -n1 | cut -d'=' -f2)
[ -z "$LOCATION" ] && LOCATION="n/a"

# --- Authentication method (SSSD id_provider) --------------------------------
# Collect all id_provider values from sssd.conf and 50-pncad.conf
if [ -f /etc/sssd/sssd.conf ]; then
    SSSD=$(
        { grep -r ^id_provider /etc/sssd/sssd.conf 2>/dev/null \
              | head -n1 | cut -d"=" -f2 | tr -d ' '
          grep -r ^id_provider /etc/sssd/conf.d/50-pncad.conf 2>/dev/null \
              | head -n1 | cut -d"=" -f2 | tr -d ' '
        } | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//'
    )
    [ -z "$SSSD" ] && SSSD="n/a"
else
    SSSD="n/a"
fi

# OUD: YES if any id_provider value contains "ldap"
if echo "$SSSD" | grep -qi "ldap"; then
    AUTH_OUD="YES"
else
    AUTH_OUD="NO"
fi

# AD: YES if any id_provider value contains "ad"
if echo "$SSSD" | grep -qi "\bad\b"; then
    AUTH_AD="YES"
else
    AUTH_AD="NO"
fi

# --- OUD query (netgroup lookup) ---------------------------------------------
LDAP_QUERY="NO"
for ldap_group in app-mrg-admin; do
    line="$(getent netgroup "$ldap_group" 2>/dev/null || true)"
    [[ -n "$line" ]] && LDAP_QUERY="YES"
done

# --- AD query (group lookup) -------------------------------------------------
AD_QUERY="NO"
for ad_group in GSLunxSP_MRG_AllServerLogin; do
    line="$(getent group "$ad_group" 2>/dev/null || true)"
    [[ -n "$line" ]] && AD_QUERY="YES"
done

# --- Dual auth package -------------------------------------------------------
if rpm -q pnc_join_ad >/dev/null 2>&1; then
    DUAL_AUTH_PKG=$(rpm -q pnc_join_ad)
else
    DUAL_AUTH_PKG="Missing"
fi

# --- nsswitch symlink --------------------------------------------------------
if [[ ! -e /etc/nsswitch.conf ]]; then
    NSSWITCH="Missing"
elif [[ ! -L /etc/nsswitch.conf ]]; then
    NSSWITCH="No symlink"
else
    NSSWITCH="Symlink Present"
fi

# --- KRB5 keytab -------------------------------------------------------------
[[ -f /etc/krb5.keytab ]] && KRB5_KEYTAB="Present" || KRB5_KEYTAB="Missing"

# --- Sudo checks -------------------------------------------------------------
if id xqvsmlinauthscan >/dev/null 2>&1; then
    if timeout 5 sudo -u xqvsmlinauthscan sudo -n true >/dev/null 2>&1; then
        XQVSMLINAUTHSCAN_SUDO="PASS"
    else
        XQVSMLINAUTHSCAN_SUDO="FAIL"
    fi
else
    XQVSMLINAUTHSCAN_SUDO="Missing ID"
fi

if id xqmrglineng >/dev/null 2>&1; then
    if timeout 5 sudo -u xqmrglineng sudo -n true >/dev/null 2>&1; then
        XQMRGLINENG_SUDO="PASS"
    else
        XQMRGLINENG_SUDO="FAIL"
    fi
else
    XQMRGLINENG_SUDO="Missing ID"
fi

if id xqmrglinaap >/dev/null 2>&1; then
    if timeout 5 sudo -u xqmrglinaap sudo -n true >/dev/null 2>&1; then
        XQMRGLINAAP_SUDO="PASS"
    else
        XQMRGLINAAP_SUDO="FAIL"
    fi
else
    XQMRGLINAAP_SUDO="Missing ID"
fi

if id xqlrplinauto >/dev/null 2>&1; then
    if timeout 5 sudo -u xqlrplinauto sudo -n true >/dev/null 2>&1; then
        XQLRPLINAUTO_SUDO="PASS"
    else
        XQLRPLINAUTO_SUDO="FAIL"
    fi
else
    XQLRPLINAUTO_SUDO="Missing ID"
fi

# --- Hardware ----------------------------------------------------------------
# Use values already set by rhel_remote_scan.sh if available in this session,
# otherwise collect independently (standalone execution).
if [[ -z "${CPU:-}" ]]; then
    CPU=$(lscpu 2>/dev/null | grep -E '^CPU\(' | awk -F': +' '{print $2}' | tr -d '\n')
    [ -z "$CPU" ] && CPU="n/a"
fi

if [[ -z "${CORES:-}" ]]; then
    CORES=$(lscpu 2>/dev/null | grep 'Core(s) per socket' | awk '{print $NF}')
    [ -z "$CORES" ] && CORES="n/a"
fi

if [[ -z "${SOCKETS:-}" ]]; then
    SOCKETS=$(lscpu 2>/dev/null | grep 'Socket(s)' | awk '{print $NF}')
    [ -z "$SOCKETS" ] && SOCKETS="n/a"
fi

MEMORY=$(grep MemTotal /proc/meminfo 2>/dev/null \
    | awk '{printf "%.0f GB", $2/1024/1024}')
[ -z "$MEMORY" ] && MEMORY="n/a"

# --- Kernel and SELinux ------------------------------------------------------
KERNEL=$(uname -r)
SELINUX=$(getenforce 2>/dev/null || echo "n/a")

# --- Timezone ----------------------------------------------------------------
TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)

# --- Hugepages ---------------------------------------------------------------
HUGEPAGES=$(grep hugepage /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null \
    | grep -v '^#' | awk -F: '{print $2}' \
    | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')
[ -z "$HUGEPAGES" ] && HUGEPAGES="not set"

# --- Volumes -----------------------------------------------------------------
VOLUMES_JSON_INNER=""
sep=""
while IFS= read -r line; do
    mp=$(echo "$line" | awk '{print $1}')
    sz=$(echo "$line" | awk '{print $2}')
    VOLUMES_JSON_INNER+="${sep}{\"mp\":\"${mp}\",\"sz\":\"${sz}\"}"
    sep=","
done < <(df -hP 2>/dev/null | grep '^/dev' | awk '{print $6" "$2}' | sort)

while IFS= read -r line; do
    sz=$(echo "$line" | awk '{print $1}')
    [ -n "$sz" ] && VOLUMES_JSON_INNER+="${sep}{\"mp\":\"swap\",\"sz\":\"${sz}\"}" && sep=","
done < <(swapon --show=SIZE --noheadings 2>/dev/null)

# --- resolv.conf -------------------------------------------------------------
RESOLV_SEARCH=$(grep '^search' /etc/resolv.conf 2>/dev/null \
    | awk '{$1=""; print $0}' | sed 's/^ //')
[ -z "$RESOLV_SEARCH" ] && RESOLV_SEARCH="n/a"

RESOLV_NS=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null \
    | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
[ -z "$RESOLV_NS" ] && RESOLV_NS="n/a"

# --- NFS / CIFS counts -------------------------------------------------------
NFS_COUNT=$(df -hT 2>/dev/null | grep -cE '\bnfs\b|\bnfs4\b'; true)
CIFS_COUNT=$(df -hT 2>/dev/null | grep -c '\bcifs\b'; true)

# --- Service status ----------------------------------------------------------
SSSD_SVC=$(systemctl is-active sssd 2>/dev/null || echo "inactive")
SSHD_SVC=$(systemctl is-active sshd 2>/dev/null || echo "inactive")

# --- Timestamp ---------------------------------------------------------------
COLLECTED_AT=$(date '+%Y-%m-%dT%H:%M:%S')

# --- JSON escape helper ------------------------------------------------------
# _NL, _CR, _TB: used by je() for bash 4.x compatible substitution.
# $'...' inside ${var//pattern} is unreliable on bash 4.4 (RHEL 7).
_NL=$'\n'
_CR=$'\r'
_TB=$'\t'

je() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//${_NL}/\\n}"
    s="${s//${_CR}/\\r}"
    s="${s//${_TB}/\\t}"
    printf '%s' "$s"
}

# =============================================================================
# OUTPUT -- both via stdout through pssh.
# rhel_filter_scan.sh on the jumphost splits on tag prefixes.
#
# CRITICAL: pssh --inline-stdout runs 75 hosts in parallel and INTERLEAVES
# their output lines. Multi-line output from host A gets mixed with lines from
# host B. Therefore ALL output must be single-line per record.
#
# MID_MOD_CSV:<host>:<csv_row>     -- one line, Midrange Mod CSV row
# COMPARE_JSON:<host>:<json>       -- one line, full JSON object (minified)
# =============================================================================

# CSV line (13 columns)
echo "MID_MOD_CSV:${HOSTNAME}:${HOSTNAME},${LOCATION},${MNEMONIC},${ENVIRONMENT},${RHEL_RELEASE},${SSSD},${LDAP_QUERY},${AD_QUERY},${DUAL_AUTH_PKG},${NSSWITCH},${KRB5_KEYTAB},${XQVSMLINAUTHSCAN_SUDO},${XQMRGLINENG_SUDO},${XQMRGLINAAP_SUDO}"

# JSON -- pre-compute all escaped values into plain variables first.
# This avoids "$(je "$VAR")" nested-quote patterns which cause bash 4.4
# (RHEL 7) to report "unexpected end of file" during script parsing.
_jHOST=$(je "$HOSTNAME")
_jLOC=$(je "$LOCATION")
_jENV=$(je "$ENVIRONMENT")
_jMNEM=$(je "$MNEMONIC")
_jTZ=$(je "$TIMEZONE")
_jCPU=$(je "$CPU")
_jCORES=$(je "$CORES")
_jSOCK=$(je "$SOCKETS")
_jMEM=$(je "$MEMORY")
_jREL=$(je "$RHEL_RELEASE")
_jKERN=$(je "$KERNEL")
_jSEL=$(je "$SELINUX")
_jHUGE=$(je "$HUGEPAGES")
_jRSRCH=$(je "$RESOLV_SEARCH")
_jRNS=$(je "$RESOLV_NS")
_jOUD=$(je "$AUTH_OUD")
_jAD=$(je "$AUTH_AD")
_jLDAP=$(je "$LDAP_QUERY")
_jADQ=$(je "$AD_QUERY")
_jSSD=$(je "$SSSD_SVC")
_jSSH=$(je "$SSHD_SVC")

printf 'COMPARE_JSON:%s:{"host":"%s","collected_at":"%s","reachable":true,"data":{"location":"%s","environment":"%s","mnemonic":"%s","timezone":"%s","cpu":"%s","cores":"%s","sockets":"%s","memory":"%s","rhel_version":"%s","kernel":"%s","selinux":"%s","hugepages":"%s","resolv_search":"%s","resolv_ns":"%s","nfs_count":%s,"cifs_count":%s,"volumes":[%s],"auth_method":{"oud":"%s","ad":"%s"},"auth_query":{"oud":"%s","ad":"%s"},"services":{"sssd":"%s","sshd":"%s"}}}\n'     "$HOSTNAME" "$_jHOST" "$COLLECTED_AT"     "$_jLOC" "$_jENV" "$_jMNEM" "$_jTZ"     "$_jCPU" "$_jCORES" "$_jSOCK" "$_jMEM"     "$_jREL" "$_jKERN" "$_jSEL" "$_jHUGE"     "$_jRSRCH" "$_jRNS"     "$NFS_COUNT" "$CIFS_COUNT" "$VOLUMES_JSON_INNER"     "$_jOUD" "$_jAD" "$_jLDAP" "$_jADQ"     "$_jSSD" "$_jSSH"
