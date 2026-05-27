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

    # Run command, capture output+rc, then emit status line.
    # CHANGED = exit 0 (with or without output)
    # FAILED  = non-zero exit
    {
        printf '%s\n' '__out=$(mktemp)'
        printf '%s\n' '__rc=0'
        printf '%s\n' "{ $cmd ; } >\"\$__out\" 2>&1 || __rc=\$?"
        printf '%s\n' 'if [[ $__rc -ne 0 ]]; then'
        printf '%s\n' '  echo "FAILED (rc=$__rc)"'
        printf '%s\n' '  cat "$__out"'
        printf '%s\n' 'else'
        printf '%s\n' '  echo "CHANGED"'
        printf '%s\n' '  cat "$__out"'
        printf '%s\n' 'fi'
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
          /^\[[0-9]+\] [0-9:]+ \[SUCCESS\] / { print $NF " >>"; next }
          /^\[[0-9]+\] [0-9:]+ \[FAILURE\] / {
              host = $4
              reason = ""
              for (i=5; i<=NF; i++) reason = reason (i>5?" ":"") $i
              unreachable[++nu] = host " >> [UNREACHABLE] " reason
              next
          }
          { print }
          END {
              if (nu > 0) {
                  print ""
                  print "=== Unreachable hosts (" nu ") ==="
                  for (i=1; i<=nu; i++) print unreachable[i]
              }
          }
        '

    rm -f "$tmp"
}