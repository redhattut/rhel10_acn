allpssh_debug() {
    local hostfile="./hosts.txt"

    [[ "$1" == "--" ]] && shift

    local cmd
    if [[ $# -eq 1 ]]; then cmd="$1"; else cmd="$*"; fi

    local encoded
    encoded=$(printf '%s' "$cmd" | base64 -w0)

    local remote='bash -c "$(base64 -d <<<"'"$encoded"'")"'

    echo "=== DEBUG: what we are sending ==="
    echo "Original cmd:    [$cmd]"
    echo "Encoded:         [$encoded]"
    echo "Decoded check:   [$(echo "$encoded" | base64 -d)]"
    echo "Remote wrapper:  [$remote]"
    echo "==================================="
    echo
    echo "=== Running locally to verify the wrapper works ==="
    bash -c "$remote"
    echo
    echo "=== Now running on one host via pssh ==="
    sudo /usr/local/pssh/bin/pssh \
        -h "$hostfile" \
        -p 1 \
        -t 30 \
        --inline-stdout \
        -l root \
        -O StrictHostKeyChecking=no \
        -O UserKnownHostsFile=/dev/null \
        -O LogLevel=ERROR \
        -O BatchMode=yes \
        -x "-T -q" \
        -- bash -c "$remote" 2>&1 | head -30
}