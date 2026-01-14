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

# Remove all seaweedfs drop-in files
clean_dropins() {
    local dry_run="${1:-false}"
    local found=0

    echo "Searching for seaweedfs drop-in files..."

    for dropin in "$DROPIN_DIR_BASE"/*.service.d/"$DROPIN_FILENAME"; do
        [[ -e "$dropin" ]] || continue
        found=1
        if [[ "$dry_run" == "true" ]]; then
            echo "Would remove: $dropin"
        else
            echo "Removing: $dropin"
            rm -f "$dropin"
            # Remove empty parent directory
            local parent_dir
            parent_dir=$(dirname "$dropin")
            rmdir --ignore-fail-on-non-empty "$parent_dir" 2>/dev/null || true
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "No seaweedfs drop-in files found"
    fi
}

case "$COMMAND" in
    clean)
        clean_dropins false
        echo "Running: systemctl daemon-reload"
        systemctl daemon-reload
        echo "Done"
        ;;
    apply|check)
        if [[ -z "$CONFIG_PATH" ]]; then
            echo "Error: config path required for $COMMAND"
            usage
        fi
        if [[ ! -f "$CONFIG_PATH" ]]; then
            echo "Error: Config file not found: $CONFIG_PATH"
            exit 1
        fi
        echo "Config: $CONFIG_PATH"
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        usage
        ;;
esac
