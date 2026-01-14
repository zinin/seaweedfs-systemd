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

# Generate drop-in file content
generate_dropin_content() {
    local service_id="$1"
    cat <<EOF
# Managed by seaweedfs-deps.sh - DO NOT EDIT
# Source: seaweedfs@${service_id}.service

[Unit]
Requires=seaweedfs@${service_id}.service
After=seaweedfs@${service_id}.service
EOF
}

# Create drop-in file for a unit
create_dropin() {
    local unit="$1"
    local service_id="$2"
    local dry_run="${3:-false}"

    # Ensure unit ends with .service
    [[ "$unit" == *.service ]] || unit="${unit}.service"

    local dropin_dir="$DROPIN_DIR_BASE/${unit}.d"
    local dropin_file="$dropin_dir/$DROPIN_FILENAME"

    if [[ "$dry_run" == "true" ]]; then
        echo "Would create: $dropin_file"
        echo "--- Content ---"
        generate_dropin_content "$service_id"
        echo "---------------"
    else
        echo "Creating: $dropin_file"
        mkdir -p "$dropin_dir"
        generate_dropin_content "$service_id" > "$dropin_file"
    fi
}

# Parse XML and process dependents
process_config() {
    local config="$1"
    local dry_run="${2:-false}"

    # Get all service IDs that have dependents
    local service_ids
    service_ids=$(xmlstarlet sel -N x="$NS" \
        -t -m "//x:service[x:dependents]" -v "x:id" -n "$config" 2>/dev/null || true)

    if [[ -z "$service_ids" ]]; then
        echo "No services with dependents found in config"
        return
    fi

    while IFS= read -r service_id; do
        [[ -z "$service_id" ]] && continue
        echo ""
        echo "Processing service: $service_id"

        # Get units for this service
        local units
        units=$(xmlstarlet sel -N x="$NS" \
            -t -m "//x:service[x:id='$service_id']/x:dependents/x:unit" -v "." -n "$config")

        while IFS= read -r unit; do
            [[ -z "$unit" ]] && continue
            create_dropin "$unit" "$service_id" "$dry_run"
        done <<< "$units"
    done <<< "$service_ids"
}

case "$COMMAND" in
    clean)
        clean_dropins false
        echo "Running: systemctl daemon-reload"
        systemctl daemon-reload
        echo "Done"
        ;;
    apply)
        if [[ -z "$CONFIG_PATH" ]]; then
            echo "Error: config path required for $COMMAND"
            usage
        fi
        if [[ ! -f "$CONFIG_PATH" ]]; then
            echo "Error: Config file not found: $CONFIG_PATH"
            exit 1
        fi
        echo "Applying dependencies from: $CONFIG_PATH"
        clean_dropins false
        process_config "$CONFIG_PATH" false
        echo ""
        echo "Running: systemctl daemon-reload"
        systemctl daemon-reload
        echo "Done"
        ;;
    check)
        if [[ -z "$CONFIG_PATH" ]]; then
            echo "Error: config path required for $COMMAND"
            usage
        fi
        if [[ ! -f "$CONFIG_PATH" ]]; then
            echo "Error: Config file not found: $CONFIG_PATH"
            exit 1
        fi
        echo "Checking dependencies from: $CONFIG_PATH (dry-run)"
        echo ""
        echo "=== Files to remove ==="
        clean_dropins true
        echo ""
        echo "=== Files to create ==="
        process_config "$CONFIG_PATH" true
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        usage
        ;;
esac
