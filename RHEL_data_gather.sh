#!/bin/bash
# RHEL_data_gather.sh
#
# Runs REMOTELY on each host via pssh (piped via stdin by Midrange_Mod_Report.sh).
#
# Produces TWO outputs in one SSH session:
#   1. stdout  → tagged lines consumed by Midrange_Mod_Report.sh
#                CSV_DATA:<hostname>:<csv_fields>
#                JSON_WRITTEN:<hostname>:/tmp/compare_<hostname>.json
#   2. file    → /tmp/compare_<hostname>.json
#                scp'd back to /data/MRGeng/Compare/data/ by the wrapper
#
# Lines are prefixed with hostname so they are self-identifying even when
# pssh --inline-stdout interleaves output from parallel host executions.
#
# CSV column order (unchanged from original):
#   Host, Location, Mnemonic, Environment, OS Version, Authentication Method,
#   OUD Query, AD Query, pnc_join_ad, Nsswitch, KRB5 Keytab,
#   xqvsmlinauthscan Sudo, xqmrglineng Sudo

# ── default values ────────────────────────────────────────────────────────────
HOSTNAME=$(hostname -s)
RHEL_RELEASE="n/a"
LOCATION="n/a"
MNEMONIC="n/a"
ENVIRONMENT="n/a"
SSSD="n/a"
LDAP_QUERY="n/a"
AD_QUERY="n/a"
DUAL_AUTH_PKG="n/a"
NSSWITCH="n/a"
KRB5_KEYTAB="n/a"
XQVSMLINAUTHSCAN_SUDO="n/a"
XQMRGLINENG_SUDO="n/a"

# ── RHEL release ──────────────────────────────────────────────────────────────
RHEL_RELEASE=$(grep -oP 'release \K[\d\.]+' /etc/redhat-release 2>/dev/null || echo "n/a")

# ── Mnemonic ──────────────────────────────────────────────────────────────────
MNEMONIC=$(hostname -s | cut -c2-4 | tr '[:lower:]' '[:upper:]')

# ── Environment ───────────────────────────────────────────────────────────────
ENVIRONMENT=$(cat /boot/PNC_PROVISION_CONFIG 2>/dev/null \
    | grep ENVIRONMENT | tail -n1 | cut -d'=' -f2)
[ -z "$ENVIRONMENT" ] && ENVIRONMENT="n/a"

# ── Location ──────────────────────────────────────────────────────────────────
LOCATION=$(cat /boot/PNC_PROVISION_CONFIG 2>/dev/null \
    | grep LOCATION | tail -n1 | cut -d'=' -f2)
[ -z "$LOCATION" ] && LOCATION="n/a"

# ── Authentication method (SSSD id_provider) ──────────────────────────────────
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

# ── OUD query (netgroup lookup) ───────────────────────────────────────────────
LDAP_QUERY="NO"
for ldap_group in app-mrg-admin; do
    line="$(getent netgroup "$ldap_group" 2>/dev/null || true)"
    [[ -n "$line" ]] && LDAP_QUERY="YES"
done

# ── AD query (group lookup) ───────────────────────────────────────────────────
AD_QUERY="NO"
for ad_group in GSLunxSP_MRG_AllServerLogin; do
    line="$(getent group "$ad_group" 2>/dev/null || true)"
    [[ -n "$line" ]] && AD_QUERY="YES"
done

# ── Dual auth package ─────────────────────────────────────────────────────────
if rpm -q pnc_join_ad >/dev/null 2>&1; then
    DUAL_AUTH_PKG=$(rpm -q pnc_join_ad)
else
    DUAL_AUTH_PKG="Missing"
fi

# ── nsswitch symlink ──────────────────────────────────────────────────────────
if [[ ! -e /etc/nsswitch.conf ]]; then
    NSSWITCH="Missing"
elif [[ ! -L /etc/nsswitch.conf ]]; then
    NSSWITCH="No symlink"
else
    NSSWITCH="Symlink Present"
fi

# ── KRB5 keytab ───────────────────────────────────────────────────────────────
[[ -f /etc/krb5.keytab ]] && KRB5_KEYTAB="Present" || KRB5_KEYTAB="Missing"

# ── Sudo checks ───────────────────────────────────────────────────────────────
if id xqvsmlinauthscan >/dev/null 2>&1; then
    if sudo -u xqvsmlinauthscan sudo -n true >/dev/null 2>&1; then
        XQVSMLINAUTHSCAN_SUDO="PASS"
    else
        XQVSMLINAUTHSCAN_SUDO="FAIL"
    fi
else
    XQVSMLINAUTHSCAN_SUDO="Missing ID"
fi

if id xqmrglineng >/dev/null 2>&1; then
    if sudo -u xqmrglineng sudo -n true >/dev/null 2>&1; then
        XQMRGLINENG_SUDO="PASS"
    else
        XQMRGLINENG_SUDO="FAIL"
    fi
else
    XQMRGLINENG_SUDO="Missing ID"
fi

# ── Hardware ──────────────────────────────────────────────────────────────────
CPU=$(lscpu 2>/dev/null | grep -E '^CPU\(' | awk -F': +' '{print $2}' | tr -d '\n')
[ -z "$CPU" ] && CPU="n/a"

CORES=$(lscpu 2>/dev/null | grep '^Core(s) per socket' | awk '{print $NF}')
[ -z "$CORES" ] && CORES="n/a"

SOCKETS=$(lscpu 2>/dev/null | grep '^Socket(s)' | awk '{print $NF}')
[ -z "$SOCKETS" ] && SOCKETS="n/a"

MEMORY=$(grep MemTotal /proc/meminfo 2>/dev/null \
    | awk '{printf "%.0f GB", $2/1024/1024}')
[ -z "$MEMORY" ] && MEMORY="n/a"

# ── Kernel & SELinux ──────────────────────────────────────────────────────────
KERNEL=$(uname -r)
SELINUX=$(getenforce 2>/dev/null || echo "n/a")

# ── Timezone ──────────────────────────────────────────────────────────────────
TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)

# ── Hugepages ─────────────────────────────────────────────────────────────────
HUGEPAGES=$(grep hugepage /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null \
    | grep -v '^#' | awk -F: '{print $2}' \
    | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')
[ -z "$HUGEPAGES" ] && HUGEPAGES="not set"

# ── Volumes ───────────────────────────────────────────────────────────────────
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

# ── resolv.conf ───────────────────────────────────────────────────────────────
RESOLV_SEARCH=$(grep '^search' /etc/resolv.conf 2>/dev/null \
    | awk '{$1=""; print $0}' | sed 's/^ //')
[ -z "$RESOLV_SEARCH" ] && RESOLV_SEARCH="n/a"

RESOLV_NS=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null \
    | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
[ -z "$RESOLV_NS" ] && RESOLV_NS="n/a"

# ── NFS / CIFS counts ─────────────────────────────────────────────────────────
NFS_COUNT=$(df -hT 2>/dev/null | grep -cE '\bnfs\b|\bnfs4\b'; true)
CIFS_COUNT=$(df -hT 2>/dev/null | grep -c '\bcifs\b'; true)

# ── Service status ────────────────────────────────────────────────────────────
SSSD_SVC=$(systemctl is-active sssd 2>/dev/null || echo "inactive")
SSHD_SVC=$(systemctl is-active sshd 2>/dev/null || echo "inactive")

# ── Timestamp ─────────────────────────────────────────────────────────────────
COLLECTED_AT=$(date '+%Y-%m-%dT%H:%M:%S')

# ── JSON escape helper ────────────────────────────────────────────────────────
je() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}


# OUTPUT — all via stdout through pssh, written to log on the jumphost.
# No scp needed. The wrapper reads the log and assembles files locally.
#
# Two output types:
#   CSV_DATA:<hostname>:<csv_row>
#   JSON_START:<hostname>
#   <json line 1>
#   <json line 2>
#   ...
#   JSON_END:<hostname>
#
# Writing JSON as individual echo lines (not inside $()) avoids shell
# command-substitution truncation that occurs with large single-line output.
# ═════════════════════════════════════════════════════════════════════════════

# CSV line (13 columns, unchanged format)
echo "CSV_DATA:${HOSTNAME}:${HOSTNAME},${LOCATION},${MNEMONIC},${ENVIRONMENT},${RHEL_RELEASE},${SSSD},${LDAP_QUERY},${AD_QUERY},${DUAL_AUTH_PKG},${NSSWITCH},${KRB5_KEYTAB},${XQVSMLINAUTHSCAN_SUDO},${XQMRGLINENG_SUDO}"

# JSON — emitted as multiple lines between start/end markers.
# The wrapper collects lines between JSON_START and JSON_END and writes
# the file locally. No $() capture means no truncation regardless of size.
echo "JSON_START:${HOSTNAME}"
echo "{"
echo "  \"host\":         \"$(je "$HOSTNAME")\","
echo "  \"collected_at\": \"$COLLECTED_AT\","
echo "  \"reachable\":    true,"
echo "  \"data\": {"
echo "    \"location\":      \"$(je "$LOCATION")\","
echo "    \"environment\":   \"$(je "$ENVIRONMENT")\","
echo "    \"mnemonic\":      \"$(je "$MNEMONIC")\","
echo "    \"timezone\":      \"$(je "$TIMEZONE")\","
echo "    \"cpu\":           \"$(je "$CPU")\","
echo "    \"cores\":         \"$(je "$CORES")\","
echo "    \"sockets\":       \"$(je "$SOCKETS")\","
echo "    \"memory\":        \"$(je "$MEMORY")\","
echo "    \"rhel_version\":  \"$(je "$RHEL_RELEASE")\","
echo "    \"kernel\":        \"$(je "$KERNEL")\","
echo "    \"selinux\":       \"$(je "$SELINUX")\","
echo "    \"hugepages\":     \"$(je "$HUGEPAGES")\","
echo "    \"resolv_search\": \"$(je "$RESOLV_SEARCH")\","
echo "    \"resolv_ns\":     \"$(je "$RESOLV_NS")\","
echo "    \"nfs_count\":     ${NFS_COUNT},"
echo "    \"cifs_count\":    ${CIFS_COUNT},"
echo "    \"volumes\":       [${VOLUMES_JSON_INNER}],"
echo "    \"auth_method\": {\"oud\": \"$(je "$SSSD")\", \"ad\": \"$(je "$SSSD")\"},"
echo "    \"auth_query\":  {\"oud\": \"$(je "$LDAP_QUERY")\", \"ad\": \"$(je "$AD_QUERY")\"},"
echo "    \"services\":    {\"sssd\": \"$(je "$SSSD_SVC")\", \"sshd\": \"$(je "$SSHD_SVC")\"}"
echo "  }"
echo "}"
echo "JSON_END:${HOSTNAME}"
