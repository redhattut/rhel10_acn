#!/bin/bash
# check-login-access.sh - Login access check via login-access.conf
# Usage:
#   ./check-login-access.sh userID              (run on current host)
#   ./check-login-access.sh userID -h host1
#   ./check-login-access.sh userID -f hosts.txt

set -u

# ---------- Remote mode: when invoked over SSH with --run, just do the check ----------
if [[ "${1:-}" == "--run" ]]; then
  acc="${2:-}"
  [[ -z "$acc" ]] && { echo "  (no userID provided)"; exit 1; }

  if ! id "$acc" &>/dev/null; then
    echo "  User '$acc' not found on this host"
    exit 0
  fi

  conf=/etc/security/login-access.conf
  [[ ! -r "$conf" ]] && { echo "  login-access.conf missing or unreadable"; exit 0; }

  echo "Group membership for: $acc"
  echo

  mapfile -t user_groups < <(id -Gn "$acc" | tr ' ' '\n')

  mapfile -t conf_groups < <(
    grep -vE '^\s*(#|$)' "$conf" \
      | grep -oE '\([^)]+\)' \
      | tr -d '()' \
      | awk '!seen[$0]++'
  )

  max=0
  for cg in "${conf_groups[@]}"; do
    for ug in "${user_groups[@]}"; do
      [[ "$ug" == "$cg" ]] && (( ${#cg} > max )) && max=${#cg}
    done
  done

  found=0
  for cg in "${conf_groups[@]}"; do
    in_group=0
    for ug in "${user_groups[@]}"; do
      [[ "$ug" == "$cg" ]] && { in_group=1; break; }
    done
    (( in_group == 0 )) && continue
    found=1

    if [[ "$cg" == *"@"* ]]; then src="AD "; else src="OUD"; fi

    access="No"
    while IFS=':' read -r perm users origins; do
      [[ -z "$perm" || "${perm:0:1}" == "#" ]] && continue
      perm=$(echo "$perm" | tr -d '[:space:]')
      [[ "$perm" != "+" && "$perm" != "-" ]] && continue

      hit=""
      for tok in $users; do
        case "$tok" in
          ALL)    hit=1; break ;;
          "$acc") hit=1; break ;;
          \(*\))
            gn="${tok#(}"; gn="${gn%)}"
            [[ "$gn" == "$cg" ]] && { hit=1; break; }
            ;;
        esac
      done

      if [[ -n "$hit" ]]; then
        [[ "$perm" == "+" ]] && access="Yes" || access="No"
        break
      fi
    done < "$conf"

    printf "  Member of: %-*s  [ %-3s ]  [ %s ]\n" "$max" "$cg" "$access" "$src"
  done

  (( found == 0 )) && echo "  (user is not in any group referenced by login-access.conf)"
  exit 0
fi

# ---------- Driver mode: parse args, dispatch to local / ssh / pssh ----------
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

# No host flags: run locally on the jumphost itself
if [[ -z "$HOST" && -z "$HOSTFILE" ]]; then
  exec "$SELF" --run "$ACC"
fi

# Single remote host
if [[ -n "$HOST" ]]; then
  echo "${HOST} >>"
  ssh $SSH_OPTS "$HOST" "bash -s -- --run '$ACC'" < "$SELF" 2>/dev/null \
    || echo "  ssh failed (timeout or auth)"
  echo
  exit 0
fi

# Multi-host via pssh
command -v pssh &>/dev/null || { echo "pssh not found (dnf install pssh)" >&2; exit 1; }

pssh -h "$HOSTFILE" -p 50 -t 15 --inline-stdout \
     -O "ConnectTimeout=5" -O "BatchMode=yes" -O "StrictHostKeyChecking=accept-new" \
     -I -- bash -s -- --run "$ACC" < "$SELF" 2>/dev/null \
  | awk '
      /^\[[0-9]+\] [0-9:]+ \[SUCCESS\] / { print $NF " >>"; next }
      /^\[[0-9]+\] [0-9:]+ \[FAILURE\] / { print $NF " >>"; print "  ssh failed"; next }
      { print }
    '