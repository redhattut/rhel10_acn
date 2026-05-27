allpssh() {
    local hostfile="./hosts.txt"

    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>"; return 1; }
    [[ "$1" == "--" ]] && shift
    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>"; return 1; }
    [[ ! -r "$hostfile" ]] && { echo "hosts file not found: $hostfile" >&2; return 1; }

    local cmd
    if [[ $# -eq 1 ]]; then cmd="$1"; else cmd="$*"; fi

    # Write the command to a temp file, pssh ships it as stdin to remote bash.
    # No quoting nightmares - the remote bash just reads the script from stdin.
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$cmd" > "$tmp"

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
              failed[++nf] = host " >> [UNREACHABLE] " reason
              next
          }
          { print }
          END {
              if (nf > 0) {
                  print ""
                  print "=== Unreachable hosts (" nf ") ==="
                  for (i=1; i<=nf; i++) print failed[i]
              }
          }
        '

    rm -f "$tmp"
}