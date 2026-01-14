#!/bin/bash

# Manages systemd drop-in files for services that depend on SeaweedFS mounts
# Usage:
#   ./seaweedfs-deps.sh apply <config.xml>  - Create drop-in files from XML config
#   ./seaweedfs-deps.sh check <config.xml>  - Show what would be done (dry-run)
#   ./seaweedfs-deps.sh clean               - Remove all seaweedfs drop-in files

set -euo pipefail

DROPIN_FILENAME="seaweedfs.conf"
DROPIN_DIR_BASE="/etc/systemd/system"
NS="http://zinin.ru/xml/ns/seaweedfs-systemd"

usage() {
    echo "Usage: $0 <command> [config_path]"
    echo ""
    echo "Commands:"
    echo "  apply <config.xml>  - Create systemd drop-in files from XML config"
    echo "  check <config.xml>  - Show what would be done (dry-run)"
    echo "  clean               - Remove all seaweedfs drop-in files"
    exit 1
}

# Check dependencies
check_deps() {
    if ! command -v xmlstarlet &> /dev/null; then
        echo "Error: xmlstarlet is not installed"
        exit 1
    fi
}

if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
CONFIG_PATH="${2:-}"

check_deps

case "$COMMAND" in
    apply|check|clean)
        echo "Command: $COMMAND"
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        usage
        ;;
esac
