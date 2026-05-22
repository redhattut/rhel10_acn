REMOTE_SCRIPT=$(cat <<'REMOTE_EOF'
acc="$1"

if ! id "$acc" &>/dev/null; then
  echo "  User '$acc' not found on this host"
  exit 0
fi

conf=/etc/security/login-access.conf
[[ ! -r "$conf" ]] && { echo "  login-access.conf missing or unreadable"; exit 0; }

echo "Group membership for: $acc"
echo

mapfile -t user_groups < <(id -Gn "$acc" | tr ' ' '\n')

# Extract just the (group) tokens referenced in login-access.conf, in file order
mapfile -t conf_groups < <(
  grep -vE '^\s*(#|$)' "$conf" \
    | grep -oE '\([^)]+\)' \
    | tr -d '()' \
    | awk '!seen[$0]++'
)

# Compute padding width across only the groups the user is actually in
max=0
for cg in "${conf_groups[@]}"; do
  for ug in "${user_groups[@]}"; do
    [[ "$ug" == "$cg" ]] && (( ${#cg} > max )) && max=${#cg}
  done
done

found=0
for cg in "${conf_groups[@]}"; do
  # Is the user in this login-access group?
  in_group=0
  for ug in "${user_groups[@]}"; do
    [[ "$ug" == "$cg" ]] && { in_group=1; break; }
  done
  (( in_group == 0 )) && continue
  found=1

  # Classify: AD groups have @domain suffix, otherwise OUD
  if [[ "$cg" == *"@"* ]]; then src="AD "; else src="OUD"; fi

  # First-match-wins evaluation
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
REMOTE_EOF
)