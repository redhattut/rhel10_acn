allpssh() {
    local hostfile="./hosts.txt"

    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>"; return 1; }
    [[ "$1" == "--" ]] && shift
    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>"; return 1; }
    [[ ! -r "$hostfile" ]] && { echo "hosts file not found: $hostfile" >&2; return 1; }

    local cmd
    if [[ $# -eq 1 ]]; then cmd="$1"; else cmd="$*"; fi

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