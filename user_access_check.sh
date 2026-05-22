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

  max=0
  for g in "${groups[@]}"; do (( ${#g} > max )) && max=${#g}; done

  for g in "${groups[@]}"; do
    access="No"

    if [[ "$g" == *"@"* ]]; then
      # AD group: query regular group database, members in 4th field
      src="AD "
      members=$(getent group "$g" 2>/dev/null | awk -F: '{print $4}')
      if [[ -n "$members" ]]; then
        # Match user verbatim, or as user@domain (some AD setups list either form)
        dom="${g#*@}"
        if echo "$members" | tr ',' '\n' | grep -qxE "${acc}|${acc}@${dom}"; then
          access="Yes"
        fi
      fi
    else
      # OUD group: query netgroup database, entries look like (host,user,domain)
      src="OUD"
      if getent netgroup "$g" 2>/dev/null | grep -q "[(,]${acc}[,)]"; then
        access="Yes"
      fi
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