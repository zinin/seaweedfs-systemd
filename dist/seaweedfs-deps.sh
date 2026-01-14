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
DEFAULT_CONFIG="/etc/seaweedfs/services.xml"

usage() {
    echo "Usage: $0 <command> [config_path]"
    echo ""
    echo "Commands:"
    echo "  apply [config.xml]  - Create systemd drop-in files (default: $DEFAULT_CONFIG)"
    echo "  check [config.xml]  - Show what would be done (dry-run)"
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

# Get all service IDs from config
get_all_service_ids() {
    local config="$1"
    xmlstarlet sel -N x="$NS" \
        -t -m "//x:service/x:id" -v "." -n "$config" 2>/dev/null | sort -u
}

# Validate that all service references exist
validate_service_refs() {
    local config="$1"
    local valid_ids
    valid_ids=$(get_all_service_ids "$config")
    local errors=0

    # Get all service references in dependencies
    local refs
    refs=$(xmlstarlet sel -N x="$NS" \
        -t -m "//x:dependencies/x:service" -v "." -n "$config" 2>/dev/null || true)

    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        if ! echo "$valid_ids" | grep -qx "$ref"; then
            echo "Error: Unknown service reference: $ref"
            errors=$((errors + 1))
        fi
    done <<< "$refs"

    return $errors
}

# Validate external unit references (warning only)
validate_external_units() {
    local config="$1"
    local warnings=0

    # Get all external unit references
    local units
    units=$(xmlstarlet sel -N x="$NS" \
        -t -m "//x:dependencies/x:unit | //x:dependents/x:unit" -v "." -n "$config" 2>/dev/null | sort -u || true)

    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        # Add .service suffix if not present and not a .target
        local unit_name="$unit"
        [[ "$unit_name" != *.service && "$unit_name" != *.target ]] && unit_name="${unit}.service"

        if ! systemctl list-unit-files "$unit_name" &>/dev/null; then
            echo "Warning: Unit not found: $unit_name (may be generated dynamically)"
            warnings=$((warnings + 1))
        fi
    done <<< "$units"

    return 0  # Warnings don't fail
}

# Detect cycles in service dependencies using DFS
detect_cycles() {
    local config="$1"
    local -A visiting=()
    local -A visited=()
    local -a path=()
    local has_cycle=0

    # Get all service IDs
    local service_ids
    service_ids=$(get_all_service_ids "$config")

    # DFS function
    dfs() {
        local node="$1"

        if [[ -n "${visiting[$node]:-}" ]]; then
            # Found cycle - reconstruct path
            local cycle_start=0
            local cycle_path=""
            for p in "${path[@]}"; do
                if [[ "$p" == "$node" ]]; then
                    cycle_start=1
                fi
                if [[ $cycle_start -eq 1 ]]; then
                    [[ -n "$cycle_path" ]] && cycle_path+=" → "
                    cycle_path+="$p"
                fi
            done
            cycle_path+=" → $node"
            echo "Error: Cycle detected: $cycle_path"
            has_cycle=1
            return 1
        fi

        if [[ -n "${visited[$node]:-}" ]]; then
            return 0
        fi

        visiting[$node]=1
        path+=("$node")

        # Get dependencies of this service
        local deps
        deps=$(xmlstarlet sel -N x="$NS" \
            -t -m "//x:service[x:id='$node']/x:dependencies/x:service" -v "." -n "$config" 2>/dev/null || true)

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            dfs "$dep" || true
        done <<< "$deps"

        unset 'path[-1]'
        unset "visiting[$node]"
        visited[$node]=1
        return 0
    }

    # Run DFS from each node
    while IFS= read -r service_id; do
        [[ -z "$service_id" ]] && continue
        dfs "$service_id" || true
    done <<< "$service_ids"

    return $has_cycle
}

if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
CONFIG_PATH="${2:-$DEFAULT_CONFIG}"

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
