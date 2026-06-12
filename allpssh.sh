allpssh() {
    local hostfile="./hosts.txt"
    local dry_run=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run) dry_run=1; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: allpssh [-d|--dry-run] '<command>'

The command MUST be wrapped in single quotes so nothing expands locally.

Examples:
  allpssh 'hostname -f'
  allpssh 'lvs | grep OLD'
  allpssh 'hostnamectl set-hostname $(hostname -f)'
  allpssh 'awk -F: '\''{print $1}'\'' /etc/passwd'
  allpssh -d 'rm -f /tmp/staging_*'    # dry-run

Flags:
  -d, --dry-run    Show what would run on each host, but don't run it
  -h, --help       Show this help
EOF
                return 0
                ;;
            --) shift; break ;;
            -*) echo "Unknown flag: $1 (try -h)" >&2; return 1 ;;
            *)  break ;;
        esac
    done

    [[ $# -eq 0 ]] && { echo "Usage: allpssh [-d] '<command>'  (try -h for help)" >&2; return 1; }
    [[ ! -r "$hostfile" ]] && { echo "hosts file not found: $hostfile" >&2; return 1; }

    if [[ $# -gt 1 ]]; then
        # Recover the literal typed command from history (before shell expansion)
        local typed
        typed=$(HISTTIMEFORMAT= history 1 2>/dev/null | sed 's/^[[:space:]]*[0-9]\+[[:space:]]*//')
        typed="${typed#allpssh }"
        typed="${typed#-d }"
        typed="${typed#--dry-run }"

        # Pick the cleanest safe quoting:
        # - No single quotes in command: wrap in single quotes (readable).
        # - Contains single quotes: use bash's @Q expansion (always correct).
        # - History unavailable: fall back to joined args.
        local typed_safe
        if [[ -z "$typed" ]]; then
            typed_safe="'$*'"
        elif [[ "$typed" == *"'"* ]]; then
            typed_safe="${typed@Q}"
        else
            typed_safe="'$typed'"
        fi

        cat >&2 <<EOF
ERROR: allpssh received $# arguments. Wrap your entire command in single quotes.

You probably meant:
  allpssh $typed_safe
EOF
        return 1
    fi

    local cmd="$1"

    if [[ $dry_run -eq 1 ]]; then
        echo "=== DRY RUN - would execute on each host in $hostfile ==="
        echo
        echo "Command (as remote bash will receive it):"
        echo "  $cmd"
        echo
        echo "Hosts targeted:"
        grep -vE '^\s*(#|$)' "$hostfile" | sed 's/^/  /'
        echo
        local nhosts
        nhosts=$(grep -cvE '^\s*(#|$)' "$hostfile")
        echo "Total: $nhosts host(s). Re-run without -d to execute."
        return 0
    fi

    local tmp
    tmp=$(mktemp)

    {
        printf '%s\n' '__out=$(mktemp)'
        printf '%s\n' '__rc=0'
        printf '%s\n' "{ $cmd ; } >\"\$__out\" 2>&1 || __rc=\$?"
        printf '%s\n' 'if [[ $__rc -ne 0 ]]; then'
        printf '%s\n' '  echo "__ALLPSSH_STATUS__:FAILED (rc=$__rc)"'
        printf '%s\n' 'else'
        printf '%s\n' '  echo "__ALLPSSH_STATUS__:SUCCESS (rc=0)"'
        printf '%s\n' 'fi'
        printf '%s\n' 'cat "$__out"'
        printf '%s\n' 'rm -f "$__out"'
        printf '%s\n' 'exit 0'
    } > "$tmp"

    sudo /usr/local/pssh/bin/pssh \
        -h "$hostfile" \
        -p 75 \
        -t 30 \
        --inline-stdout \
        -l root \
        -I \
        -O StrictHostKeyChecking=no \
        -O UserKnownHostsFile=/dev/null \
        -O GlobalKnownHostsFile=/dev/null \
        -O LogLevel=ERROR \
        -O BatchMode=yes \
        -x "-T -q" \
        -- bash < "$tmp" 2>&1 \
      | awk '
          /^\[[0-9]+\] [0-9:]+ \[SUCCESS\] / {
              pending_host = $NF
              next
          }
          /^\[[0-9]+\] [0-9:]+ \[FAILURE\] / {
              print $4 " >> UNREACHABLE"
              next
          }
          /^__ALLPSSH_STATUS__:/ {
              status = substr($0, index($0,":")+1)
              print pending_host " >> " status
              pending_host = ""
              next
          }
          { print }
        '

    rm -f "$tmp"
}