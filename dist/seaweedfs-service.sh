#!/bin/bash

# This script launches SeaweedFS services based on XML configuration
# It parses the XML config file and extracts service-specific arguments for the weed binary
# Usage: ./seaweedfs-service.sh <service_id> [config_path]
#   service_id: ID of the service from XML config
#   config_path: Optional path to XML config (default: /etc/seaweedfs/services.xml)

set -euo pipefail

NS="http://zinin.ru/xml/ns/seaweedfs-systemd"

# Validate service ID: only allow safe characters for XPath injection prevention
validate_service_id() {
    local id=$1
    if [[ ! "$id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Error: Invalid service ID '$id'"
        return 1
    fi
}

# Validate unix user/group name
validate_unix_name() {
    local name=$1 field=$2
    if [[ -n "$name" && ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Invalid $field '$name'"
        exit 1
    fi
}

# Function to build command arguments from XML into ARGS array
build_args() {
    local args_path=$1
    ARGS=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ARGS+=("$line")
    done < <(xmlstarlet sel -N x="$NS" \
        -t -m "//x:service[x:id='$SERVICE_ID']/x:$args_path/*" \
        -v "concat('-', local-name(), '=', .)" -n "$CONFIG_PATH")
}

# Get mount directory for mount service type
get_mount_dir() {
    xmlstarlet sel -N x="$NS" \
        -t -v "//x:service[x:id='$SERVICE_ID']/x:mount-args/x:dir" "$CONFIG_PATH"
}

# True for an xs:boolean "true" or "1"
is_true() {
    [[ "$1" == "true" || "$1" == "1" ]]
}

# gRPC port of a weed component: explicit -*.port.grpc, else HTTP port + 10000 (weed's rule)
grpc_port() {
    local http=$1 grpc=$2
    if [[ "$grpc" -gt 0 ]]; then
        echo "$grpc"
    else
        echo $((http + 10000))
    fi
}

# Ports a `weed server` listens on once it serves: HTTP and gRPC of the master and
# the volume server (unless disabled) and of the filer (if enabled: by -filer, or by
# -s3, -sftp, -iam, -webdav, -mq.broker or -mq.agent, which turn it on in weed).
# Reads ARGS built by build_args; defaults are weed's.
server_ready_ports() {
    local master=true volume=true filer=false filer_implied=false
    local master_port=9333 master_grpc=0 volume_port=8080 volume_grpc=0 filer_port=8888 filer_grpc=0
    local arg
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            -master=*) master=${arg#*=} ;;
            -master.port=*) master_port=${arg#*=} ;;
            -master.port.grpc=*) master_grpc=${arg#*=} ;;
            -volume=*) volume=${arg#*=} ;;
            -volume.port=*) volume_port=${arg#*=} ;;
            -volume.port.grpc=*) volume_grpc=${arg#*=} ;;
            -filer=*) filer=${arg#*=} ;;
            -filer.port=*) filer_port=${arg#*=} ;;
            -filer.port.grpc=*) filer_grpc=${arg#*=} ;;
            -s3=* | -sftp=* | -iam=* | -webdav=* | -mq.broker=* | -mq.agent=*)
                if is_true "${arg#*=}"; then
                    filer_implied=true
                fi
                ;;
        esac
    done

    local -a ports=()
    if is_true "$master"; then
        ports+=("$master_port" "$(grpc_port "$master_port" "$master_grpc")")
    fi
    if is_true "$volume"; then
        ports+=("$volume_port" "$(grpc_port "$volume_port" "$volume_grpc")")
    fi
    if is_true "$filer" || [[ "$filer_implied" == "true" ]]; then
        ports+=("$filer_port" "$(grpc_port "$filer_port" "$filer_grpc")")
    fi
    echo "${ports[*]}"
}

# Seconds a server may take to listen on its ports: SEAWEEDFS_READY_TIMEOUT, default 45.
# With the 3.5 s before the wait and the XML parsing it stays below the unit's
# TimeoutStartSec=60. Anything but whole seconds falls back to 45 with a warning.
ready_timeout() {
    local timeout=${SEAWEEDFS_READY_TIMEOUT:-45}
    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        echo "Warning: SEAWEEDFS_READY_TIMEOUT='$timeout' is not a number of seconds, using 45" >&2
        timeout=45
    fi
    echo $((10#$timeout))
}

# Wait until every given TCP port listens on some address. Exits 1 if weed dies meanwhile.
# After ready_timeout seconds of wall-clock time gives up with a warning, and the caller
# reports ready anyway, as before this check: a slow server must not fail and take its
# dependents down with it.
wait_for_ports() {
    local pid=$1
    shift
    local timeout
    timeout=$(ready_timeout)

    if ! command -v ss &>/dev/null; then
        echo "Warning: ss not found, not waiting for ports: $*"
        return 0
    fi

    # Wall-clock time, microseconds (EPOCHREALTIME's separator follows the locale):
    # slow passes under boot load must not stretch the wait past TimeoutStartSec
    local start=${EPOCHREALTIME/[.,]/}
    local waited listening port
    local -a missing
    while true; do
        listening=$(ss -Hltn 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' || true)
        missing=()
        for port in "$@"; do
            grep -qxF -- "$port" <<< "$listening" || missing+=("$port")
        done
        waited=$(( (${EPOCHREALTIME/[.,]/} - start) / 1000000 ))
        if [[ ${#missing[@]} -eq 0 ]]; then
            echo "Ports listening after ${waited}s: $*"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Error: weed process died while waiting for ports"
            exit 1
        fi
        if (( waited >= timeout )); then
            echo "Warning: ports not listening after ${timeout}s: ${missing[*]}; reporting ready anyway"
            return 0
        fi
        sleep 1
    done
}

# Value of -NAME= in ARGS (the last one wins, as in weed), else DEFAULT
server_arg() {
    local name=$1 value=$2 arg
    for arg in "${ARGS[@]}"; do
        if [[ "$arg" == "-$name="* ]]; then
            value=${arg#*=}
        fi
    done
    echo "$value"
}

# Address to reach a server's HTTP ports: its -ip.bind, 127.0.0.1 when it binds all
# addresses, and -ip when -ip.bind is empty (weed then binds to the -ip address)
server_http_host() {
    local bind
    bind=$(server_arg ip.bind "")
    if [[ -z "$bind" ]]; then
        bind=$(server_arg ip "")
    fi
    case "$bind" in
        "" | 0.0.0.0 | :: | "[::]") echo "127.0.0.1" ;;
        *:*) echo "[$bind]" ;;
        *) echo "$bind" ;;
    esac
}

# Does /cluster/status of the master at HOST:PORT name a raft leader?
master_has_leader() {
    local host=$1 port=$2 status
    status=$(curl -s -m 2 "http://${host}:${port}/cluster/status" 2>/dev/null) || return 1
    [[ "$status" =~ \"Leader\":\"[^\"]+\" ]]
}

# Number of volumes in a volume server's /status JSON on stdin; -1 if it is not that JSON
count_local_volumes() {
    python3 -c '
import json, sys
try:
    print(len(json.load(sys.stdin).get("Volumes") or []))
except (ValueError, AttributeError):
    print(-1)
'
}

# Volumes the master knows for the volume server on PORT, from /dir/status JSON on stdin;
# -1 if that volume server is not registered
count_master_volumes() {
    python3 -c '
import json, sys
suffix = ":" + sys.argv[1]
try:
    topology = json.load(sys.stdin).get("Topology") or {}
except (ValueError, AttributeError):
    print(-1)
    sys.exit(0)
for dc in topology.get("DataCenters") or []:
    for rack in dc.get("Racks") or []:
        for node in rack.get("DataNodes") or []:
            if str(node.get("Url", "")).endswith(suffix):
                print(int(node.get("Volumes") or 0))
                sys.exit(0)
print(-1)
' "$1"
}

# Does the master at HOST:MASTER_PORT know all volumes of the volume server at
# HOST:VOLUME_PORT? Until it does, reads of those volumes fail with "volume N not found".
volume_registered() {
    local host=$1 master_port=$2 volume_port=$3 status topology local_count master_count
    status=$(curl -s -m 2 "http://${host}:${volume_port}/status" 2>/dev/null) || return 1
    topology=$(curl -s -m 2 "http://${host}:${master_port}/dir/status" 2>/dev/null) || return 1
    local_count=$(count_local_volumes <<< "$status")
    master_count=$(count_master_volumes "$volume_port" <<< "$topology")
    [[ "$local_count" -ge 0 && "$master_count" -ge "$local_count" ]]
}

# A server's data is readable only once its master has a raft leader and knows the
# volumes of its volume server. Until then a read fails with "volume N not found", and
# weed mount keeps that answer for about 30 s: on a reboot on 2026-11-11 nginx could not
# read its certificates for 45 s although every port listened. Waits for both within the
# same ready_timeout as the ports, counted from START_US (EPOCHREALTIME without its
# separator); exits 1 if weed dies. A server without a master of its own has nothing to
# wait for here.
wait_for_server_data() {
    local pid=$1 start_us=$2
    if ! is_true "$(server_arg master true)"; then
        return 0
    fi
    local cmd
    for cmd in curl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Warning: $cmd not found, not waiting for the master leader and volumes"
            return 0
        fi
    done

    local timeout host master_port volume_port with_volume=false leader waited
    timeout=$(ready_timeout)
    host=$(server_http_host)
    master_port=$(server_arg master.port 9333)
    volume_port=$(server_arg volume.port 8080)
    if is_true "$(server_arg volume true)"; then
        with_volume=true
    fi
    while true; do
        leader=false
        if master_has_leader "$host" "$master_port"; then
            leader=true
            if [[ "$with_volume" == "false" ]] || volume_registered "$host" "$master_port" "$volume_port"; then
                waited=$(( (${EPOCHREALTIME/[.,]/} - start_us) / 1000000 ))
                if [[ "$with_volume" == "true" ]]; then
                    echo "Master has a leader and knows the volumes after ${waited}s"
                else
                    echo "Master has a leader after ${waited}s"
                fi
                return 0
            fi
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Error: weed process died while waiting for the master"
            exit 1
        fi
        waited=$(( (${EPOCHREALTIME/[.,]/} - start_us) / 1000000 ))
        if (( waited >= timeout )); then
            if [[ "$leader" == "true" ]]; then
                echo "Warning: master does not know all volumes of $host:$volume_port after ${timeout}s; reporting ready anyway"
            else
                echo "Warning: master has no leader after ${timeout}s; reporting ready anyway"
            fi
            return 0
        fi
        sleep 1
    done
}

# Wait for service to be ready and send systemd notification
wait_for_ready() {
    local pid=$1
    local service_type=$2

    # Check that process started successfully
    sleep 0.5
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Error: weed process died immediately"
        exit 1
    fi

    if [[ "$service_type" == "mount" ]]; then
        local mount_dir
        mount_dir=$(get_mount_dir)

        if [[ -z "$mount_dir" ]]; then
            echo "Error: mount dir not found in config"
            kill "$pid" 2>/dev/null
            exit 1
        fi

        echo "Waiting for mount point: $mount_dir"
        for i in {1..30}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "Error: weed process died while waiting for mount"
                exit 1
            fi
            if mountpoint -q "$mount_dir"; then
                echo "Mount point ready after ${i}s"
                systemd-notify --ready
                return 0
            fi
            sleep 1
        done

        echo "Error: mount point $mount_dir not ready after 30s"
        kill "$pid" 2>/dev/null
        exit 1
    else
        # For other service types, wait 3 seconds
        sleep 3
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Error: weed process died before ready"
            exit 1
        fi
        # A server is ready once its master, volume and filer listen and its master has
        # a leader and knows the volumes: units ordered after it (mount, filer.sync)
        # connect right away, and reads through the mount find the volumes.
        # Both waits share one ready_timeout.
        if [[ "$service_type" == "server" ]]; then
            local start_us=${EPOCHREALTIME/[.,]/}
            local -a ports
            read -r -a ports <<< "$(server_ready_ports)"
            if [[ ${#ports[@]} -gt 0 ]]; then
                wait_for_ports "$pid" "${ports[@]}"
            fi
            wait_for_server_data "$pid" "$start_us"
        fi
        systemd-notify --ready
    fi
}

# Run weed binary with proper signal handling
run_weed() {
    # Start weed in background
    if [[ -n "$RUN_DIR" ]]; then
        (cd "$RUN_DIR" && exec "${CMD[@]}") &
    else
        "${CMD[@]}" &
    fi
    WEED_PID=$!

    # Setup signal handler for graceful shutdown
    trap 'echo "Received signal, stopping weed..."; kill $WEED_PID 2>/dev/null; wait $WEED_PID; exit $?' SIGTERM SIGINT

    # Wait for ready and notify systemd
    wait_for_ready "$WEED_PID" "$SERVICE_TYPE"

    # Wait for weed to exit
    wait $WEED_PID
}

main() {
    # Default configuration path (can be overridden via environment variables)
    CONFIG_PATH="${2:-${SEAWEEDFS_CONFIG_PATH:-/etc/seaweedfs/services.xml}}"
    SCHEMA_PATH="${SEAWEEDFS_SCHEMA_PATH:-/opt/seaweedfs/seaweedfs-systemd.xsd}"
    SERVICE_ID="${1:-}"
    WEED_BINARY="${SEAWEEDFS_WEED_BINARY:-/opt/seaweedfs/weed}"

    # Check if xmlstarlet is installed
    if ! command -v xmlstarlet &> /dev/null; then
        echo "Error: xmlstarlet is not installed. Please install it using: sudo apt-get install xmlstarlet"
        exit 1
    fi

    # Check if xmllint is installed
    if ! command -v xmllint &> /dev/null; then
        echo "Error: xmllint is not installed. Please install it using: sudo apt-get install libxml2-utils"
        exit 1
    fi

    # Validate input parameters
    if [[ -z "$SERVICE_ID" ]]; then
        echo "Usage: $0 <service_id> [config_path]"
        exit 1
    fi

    # Sanitize SERVICE_ID
    if ! validate_service_id "$SERVICE_ID"; then
        exit 1
    fi

    # Check if config file exists
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "Error: Config file not found at $CONFIG_PATH"
        exit 1
    fi

    # Check if schema file exists
    if [[ ! -f "$SCHEMA_PATH" ]]; then
        echo "Error: Schema file not found at $SCHEMA_PATH"
        exit 1
    fi

    # Check if weed binary exists and is executable
    if [[ ! -x "$WEED_BINARY" ]]; then
        echo "Error: Weed binary not found or not executable at $WEED_BINARY"
        exit 1
    fi

    # Validate XML against schema
    if ! xmllint --noout --schema "$SCHEMA_PATH" "$CONFIG_PATH"; then
        echo "Error: XML configuration file does not conform to the schema."
        exit 1
    fi

    # Get service type (|| true: xmlstarlet returns 1 when XPath matches nothing)
    SERVICE_TYPE=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:type" "$CONFIG_PATH" || true)

    if [[ -z "$SERVICE_TYPE" ]]; then
        echo "Error: Service with ID '$SERVICE_ID' not found in config"
        exit 1
    fi

    # Validate SERVICE_TYPE (defense-in-depth: protects against XPath injection if xmllint stubbed)
    if [[ ! "$SERVICE_TYPE" =~ ^[a-zA-Z][a-zA-Z0-9.]*$ ]]; then
        echo "Error: Invalid service type '$SERVICE_TYPE'"
        exit 1
    fi

    # Get run-user and run-group (|| true: optional elements)
    RUN_USER=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-user" "$CONFIG_PATH" || true)
    RUN_GROUP=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-group" "$CONFIG_PATH" || true)

    # Validate RUN_USER/RUN_GROUP
    validate_unix_name "$RUN_USER" "run-user"
    validate_unix_name "$RUN_GROUP" "run-group"

    # Error on partial sudo config (silent root execution is dangerous)
    if [[ -n "$RUN_USER" && -z "$RUN_GROUP" ]] || [[ -z "$RUN_USER" && -n "$RUN_GROUP" ]]; then
        echo "Error: Both run-user and run-group must be set together"
        exit 1
    fi

    # Get run-dir, config-dir, and logs-dir if specified (|| true: optional elements)
    RUN_DIR=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-dir" "$CONFIG_PATH" || true)
    CONFIG_DIR=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:config-dir" "$CONFIG_PATH" || true)
    LOGS_DIR=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:logs-dir" "$CONFIG_PATH" || true)

    # Build service-specific arguments: type "filer.backup" -> element "filer-backup-args"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    build_args "$ARGS_ELEMENT"

    # Build command array
    CMD=()
    if [[ -n "$RUN_USER" && -n "$RUN_GROUP" ]]; then
        CMD+=(sudo -u "$RUN_USER" -g "$RUN_GROUP" --)
    fi
    CMD+=("$WEED_BINARY")
    [[ -n "$CONFIG_DIR" ]] && CMD+=(-config_dir "$CONFIG_DIR")
    [[ -n "$LOGS_DIR" ]] && CMD+=(-logdir "$LOGS_DIR")
    CMD+=("$SERVICE_TYPE")
    [[ ${#ARGS[@]} -gt 0 ]] && CMD+=("${ARGS[@]}")

    echo "Executing: ${CMD[*]}"

    # Run weed with notify support
    run_weed
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
