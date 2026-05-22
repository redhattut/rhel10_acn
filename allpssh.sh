allpssh() {
    local hostfile="./hosts.txt"

    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>  or  allpssh -- <command>"; return 1; }

    # Strip optional leading "--" separator
    [[ "$1" == "--" ]] && shift
    [[ $# -eq 0 ]] && { echo "Usage: allpssh <command>"; return 1; }

    [[ ! -r "$hostfile" ]] && { echo "hosts file not found: $hostfile" >&2; return 1; }

    # Encode the command so quotes/special chars survive intact through pssh + remote shell
    local encoded
    encoded=$(printf '%s\0' "$@" | base64 -w0)

    # Remote wrapper: decode the args back into an array, then exec them with proper quoting.
    local remote='set -- ; readarray -d "" -t a < <(base64 -d <<<"'"$encoded"'"); bash -c "$(printf "%q " "${a[@]}")"'

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