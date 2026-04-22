#!/bin/bash
set -euo pipefail

mode="${STUB_COMPARE_XSD_MODE:-unknown-nfs}"

if [[ "$#" -eq 0 ]]; then
    case "$mode" in
        unknown-nfs)
            cat <<'EOF'
SeaweedFS: store billions of files and serve them fast!

The commands are:
    server      start a master server, a volume server, and optionally a filer and a S3 gateway
    nfs         start NFS server backed by SeaweedFS filer
    shell       run interactive administrative commands

Use "weed help [command]" for more information about a command.
EOF
            ;;
        known-excluded-only)
            cat <<'EOF'
SeaweedFS: store billions of files and serve them fast!

The commands are:
    server      start a master server, a volume server, and optionally a filer and a S3 gateway
    shell       run interactive administrative commands

Use "weed help [command]" for more information about a command.
EOF
            ;;
        unknown-dotted)
            cat <<'EOF'
SeaweedFS: store billions of files and serve them fast!

The commands are:
    filer.rebalance start filer rebalance worker

Use "weed help [command]" for more information about a command.
EOF
            ;;
    esac
    exit 0
fi

if [[ "$1" == "help" && "$2" == "server" ]]; then
    cat <<'EOF'
Usage: weed server -dir=/data

Default Parameters:
  -dir string
        data directory
EOF
    exit 0
fi

if [[ "$1" == "help" && "$2" == "nfs" ]]; then
    cat <<'EOF'
Usage: weed nfs -filer=localhost:8888 -port=2049

  Start NFS server backed by SeaweedFS filer.

Default Parameters:
  -filer string
        filer address
  -port int
        nfs port
EOF
    exit 0
fi

if [[ "$1" == "help" && "$2" == "filer.rebalance" ]]; then
    cat <<'EOF'
Usage: weed filer.rebalance -filer=localhost:8888

  Start filer rebalance worker.

Default Parameters:
  -filer string
        filer address
EOF
    exit 0
fi

if [[ "$1" == "help" && "$2" == "shell" ]]; then
    cat <<'EOF'
Usage: weed shell

  Run interactive administrative commands.
EOF
    exit 0
fi

exit 1
