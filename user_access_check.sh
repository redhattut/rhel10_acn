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

  # Parse conf: collect "type:name" tokens (oud:foo or ad:bar) in file order, deduped.
  # Skip comments, blank lines, and the final catch-all "- : ALL : ALL" deny.
  mapfile -t entries < <(
      awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
          # Look only at the users field (2nd colon-separated field)
          n = split($0, f, ":")
          if (n < 2) next
          users = f[2]

          # Skip the ALL catch-all
          check = users
          gsub(/[[:space:]]/, "", check)
          if (check == "ALL") next

          # Pull AD groups (parenthesized) first, then strip them from the field
          while (match(users, /\([^)]+\)/)) {
            tok = substr(users, RSTART+1, RLENGTH-2)
            print "ad:" tok
            users = substr(users, 1, RSTART-1) substr(users, RSTART+RLENGTH)
          }

          # Now scan what remains for OUD netgroups (@name)
          while (match(users, /@[A-Za-z0-9._-]+/)) {
            tok = substr(users, RSTART+1, RLENGTH-1)
            print "oud:" tok
            users = substr(users, RSTART+RLENGTH)
          }
        }
      ' "$conf" | awk '!seen[$0]++'
    )

  # Pad to longest group name for clean alignment
  max=0
  for e in "${entries[@]}"; do
    name="${e#*:}"
    (( ${#name} > max )) && max=${#name}
  done

  for e in "${entries[@]}"; do
    type="${e%%:*}"
    name="${e#*:}"
    access="No"

    if [[ "$type" == "oud" ]]; then
      src="OUD"
      # OUD netgroup: entries are (host,user,domain) triples
      if getent netgroup "$name" 2>/dev/null | grep -q "[(,]${acc}[,)]"; then
        access="Yes"
      fi
    else
      src="AD "
      # AD group: members in 4th field of group entry, comma-separated
      members=$(getent group "$name" 2>/dev/null | awk -F: '{print $4}')
      if [[ -n "$members" ]]; then
        dom="${name#*@}"
        if echo "$members" | tr ',' '\n' | grep -qxE "${acc}|${acc}@${dom}"; then
          access="Yes"
        fi
      fi
    fi

    printf "  Member of: %-*s  [ %-3s ]  [ %s ]\n" "$max" "$name" "$access" "$src"
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