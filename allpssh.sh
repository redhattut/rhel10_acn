allpssh() {
    local hostfile="./hosts.txt"

    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>  or  allpssh -- <command>"; return 1; }

    [[ "$1" == "--" ]] && shift
    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>"; return 1; }

    [[ ! -r "$hostfile" ]] && { echo "hosts file not found: $hostfile" >&2; return 1; }

    # Join all args into a single command string. If only one arg was passed
    # (e.g. allpssh 'lvs | grep OLD'), it's used as-is. If multiple args were
    # passed (e.g. allpssh ls -ltr /etc), they're joined with spaces and the
    # remote bash -c parses the result naturally.
    local cmd
    if [[ $# -eq 1 ]]; then
        cmd="$1"
    else
        cmd="$*"
    fi

    # Base64-encode the whole command string so quotes/special chars survive
    # the trip through pssh and the remote shell.
    local encoded
    encoded=$(printf '%s' "$cmd" | base64 -w0)

    # Remote wrapper: decode the command string, then hand it to bash -c.
    # This means pipes, redirects, globs, $(...), etc. all evaluate on the remote.
    local remote='bash -c "$(base64 -d <<<"'"$encoded"'")"'

    sudo /usr/local/pssh/bin/pssh \
        -h "$hostfile" \
        -p 75 \
        -t 30 \
        --inline-stdout \
        -l root \
        -O StrictHostKeyChecking=no \
        -O UserKnownHostsFile=/dev/null \
        -O GlobalKnownHostsFile=/dev/null \
        -O LogLevel=ERROR \
        -O BatchMode=yes \
        -x "-T -q" \
        -- bash -c "$remote" 2>&1 \
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
}