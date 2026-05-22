#!/bin/bash
# check-login-access.sh - Login access check via login-access.conf
# Usage:
#   ./check-login-access.sh userID              (run on current host)
#   ./check-login-access.sh userID -h host1
#   ./check-login-access.sh userID -f hosts.txt

set -u

# ---------- Remote mode ----------
if [[ "${1:-}" == "--run" ]]; then
  acc="${2:-}"
  [[ -z "$acc" ]] && { echo "  (no userID provided)"; exit 1; }

  conf=/etc/security/login-access.conf
  [[ ! -r "$conf" ]] && { echo "  login-access.conf missing or unreadable"; exit 0; }

  echo "Group membership for: $acc"
  echo

  # Extract (group) tokens from login-access.conf, in file order, deduped
  mapfile -t groups < <(
    grep -vE '^\s*(#|$)' "$conf" \
      | grep -oE '\([^)]+\)' \
      | tr -d '()' \
      | awk '!seen[$0]++'
  )

  # Pad to longest group name for clean column alignment
  max=0
  for g in "${groups[@]}"; do (( ${#g} > max )) && max=${#g}; done

  for g in "${groups[@]}"; do
    # Classify by name shape: AD groups have @domain, OUD groups don't
    if [[ "$g" == *"@"* ]]; then src="AD "; else src="OUD"; fi

    # Membership check via getent. The 4th field of group entry is comma-separated members.
    members=$(getent group "$g" 2>/dev/null | awk -F: '{print $4}')
    access="No"

    # Direct match: user appears verbatim in members
    if [[ -n "$members" ]] && echo "$members" | tr ',' '\n' | grep -qx "$acc"; then
      access="Yes"
    fi

    # AD domain-qualified match: members may list user as "user@domain"
    if [[ "$access" == "No" && "$g" == *"@"* ]]; then
      dom="${g#*@}"
      if [[ -n "$members" ]] && echo "$members" | tr ',' '\n' | grep -qx "${acc}@${dom}"; then
        access="Yes"
      fi
    fi

    # Netgroup fallback (rare in login-access.conf but the original honored it)
    if [[ "$access" == "No" ]] && getent netgroup "$g" 2>/dev/null | grep -q "[(,]${acc}[,)]"; then
      access="Yes"
    fi

    printf "  Member of: %-*s  [ %-3s ]  [ %s ]\n" "$max" "$g" "$access" "$src"
  done
  exit 0
fi

# ---------- Driver mode ----------
ACC=""; HOST=""; HOSTFILE=""
ACC="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) HOST="$2"; shift 2 ;;
    -f) HOSTFILE="$2"; shift 2 ;;
    *)  echo "Usage: $0 <userID> [-h host | -f hostfile]" >&2; exit 2 ;;
  esac
done

[[ -z "$ACC" ]] && { echo "Usage: $0 <userID> [-h host | -f hostfile]" >&2; exit 2; }

SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
SELF="$(readlink -f "$0")"

if [[ -z "$HOST" && -z "$HOSTFILE" ]]; then
  exec "$SELF" --run "$ACC"
fi

if [[ -n "$HOST" ]]; then
  echo "${HOST} >>"
  ssh $SSH_OPTS "$HOST" "bash -s -- --run '$ACC'" < "$SELF" 2>/dev/null \
    || echo "  ssh failed (timeout or auth)"
  echo
  exit 0
fi

command -v pssh &>/dev/null || { echo "pssh not found (dnf install pssh)" >&2; exit 1; }

pssh -h "$HOSTFILE" -p 50 -t 15 --inline-stdout \
     -O "ConnectTimeout=5" -O "BatchMode=yes" -O "StrictHostKeyChecking=accept-new" \
     -I -- bash -s -- --run "$ACC" < "$SELF" 2>/dev/null \
  | awk '
      /^\[[0-9]+\] [0-9:]+ \[SUCCESS\] / { print $NF " >>"; next }
      /^\[[0-9]+\] [0-9:]+ \[FAILURE\] / { print $NF " >>"; print "  ssh failed"; next }
      { print }
    '