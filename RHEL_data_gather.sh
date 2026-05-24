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
NFS_COUNT=$(df -hT 2>/dev/null | grep -cE '\bnfs\b|\bnfs4\b' || echo 0)
CIFS_COUNT=$(df -hT 2>/dev/null | grep -c '\bcifs\b' || echo 0)

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

# ═════════════════════════════════════════════════════════════════════════════
# Write JSON file to /tmp on the remote host
# ═════════════════════════════════════════════════════════════════════════════
JSON_FILE="/tmp/compare_${HOSTNAME}.json"

{
    # Build JSON using printf — safe when script is piped through pssh.
    # Heredocs can be terminated early if a variable value contains the
    # delimiter string on its own line. printf has no such risk.
    printf '{
'
    printf '  "host":         "%s",
'  "$(je "$HOSTNAME")"
    printf '  "collected_at": "%s",
'  "$COLLECTED_AT"
    printf '  "reachable":    true,
'
    printf '  "data": {
'
    printf '    "location":      "%s",
'  "$(je "$LOCATION")"
    printf '    "environment":   "%s",
'  "$(je "$ENVIRONMENT")"
    printf '    "mnemonic":      "%s",
'  "$(je "$MNEMONIC")"
    printf '    "timezone":      "%s",
'  "$(je "$TIMEZONE")"
    printf '    "cpu":           "%s",
'  "$(je "$CPU")"
    printf '    "cores":         "%s",
'  "$(je "$CORES")"
    printf '    "sockets":       "%s",
'  "$(je "$SOCKETS")"
    printf '    "memory":        "%s",
'  "$(je "$MEMORY")"
    printf '    "rhel_version":  "%s",
'  "$(je "$RHEL_RELEASE")"
    printf '    "kernel":        "%s",
'  "$(je "$KERNEL")"
    printf '    "selinux":       "%s",
'  "$(je "$SELINUX")"
    printf '    "hugepages":     "%s",
'  "$(je "$HUGEPAGES")"
    printf '    "resolv_search": "%s",
'  "$(je "$RESOLV_SEARCH")"
    printf '    "resolv_ns":     "%s",
'  "$(je "$RESOLV_NS")"
    printf '    "nfs_count":     %s,
'   "$NFS_COUNT"
    printf '    "cifs_count":    %s,
'   "$CIFS_COUNT"
    printf '    "volumes":       [%s],
'  "${VOLUMES_JSON_INNER}"
    printf '    "auth_method": {"oud": "%s", "ad": "%s"},
'            "$(je "$SSSD")" "$(je "$SSSD")"
    printf '    "auth_query":  {"oud": "%s", "ad": "%s"},
'            "$(je "$LDAP_QUERY")" "$(je "$AD_QUERY")"
    printf '    "services":    {"sssd": "%s", "sshd": "%s"}
'            "$(je "$SSSD_SVC")" "$(je "$SSHD_SVC")"
    printf '  }
'
    printf '}
'
} > "$JSON_FILE"

# ═════════════════════════════════════════════════════════════════════════════
# OUTPUT — tagged lines to stdout
# Each line is prefixed HOST:<hostname>: so the wrapper can parse by content,
# not by position — safe against pssh parallel interleaving.
# ═════════════════════════════════════════════════════════════════════════════

# CSV line (13 columns, unchanged format)
echo "CSV_DATA:${HOSTNAME}:${HOSTNAME},${LOCATION},${MNEMONIC},${ENVIRONMENT},${RHEL_RELEASE},${SSSD},${LDAP_QUERY},${AD_QUERY},${DUAL_AUTH_PKG},${NSSWITCH},${KRB5_KEYTAB},${XQVSMLINAUTHSCAN_SUDO},${XQMRGLINENG_SUDO}"

# Signal that JSON is ready for scp
echo "JSON_WRITTEN:${HOSTNAME}:${JSON_FILE}"
