#!/bin/bash

# This script launches SeaweedFS services based on XML configuration
# It parses the XML config file and extracts service-specific arguments for the weed binary
# Usage: ./seeweedfs-service.sh <service_id> [config_path]
#   service_id: ID of the service from XML config
#   config_path: Optional path to XML config (default: /etc/seaweedfs/services.xml)

# Default configuration path
CONFIG_PATH=${2:-"/etc/seaweedfs/services.xml"}
SCHEMA_PATH="/opt/seaweedfs/seaweedfs-systemd.xsd"
SERVICE_ID=$1
WEED_BINARY="/opt/seaweedfs/weed"

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
if [ -z "$SERVICE_ID" ]; then
    echo "Usage: $0 <service_id> [config_path]"
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Config file not found at $CONFIG_PATH"
    exit 1
fi

# Check if schema file exists
if [ ! -f "$SCHEMA_PATH" ]; then
    echo "Error: Schema file not found at $SCHEMA_PATH"
    exit 1
fi

# Validate XML against schema
xmllint --noout --schema "$SCHEMA_PATH" "$CONFIG_PATH"
if [ $? -ne 0 ]; then
    echo "Error: XML configuration file does not conform to the schema."
    exit 1
fi

# Get service type
SERVICE_TYPE=$(xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" -t -v "//x:service[x:id='$SERVICE_ID']/x:type" "$CONFIG_PATH")

if [ -z "$SERVICE_TYPE" ]; then
    echo "Error: Service with ID '$SERVICE_ID' not found in config"
    exit 1
fi

# Get run-user and run-group
RUN_USER=$(xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-user" "$CONFIG_PATH")
RUN_GROUP=$(xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-group" "$CONFIG_PATH")

# Function to build command arguments
build_args() {
    local service_type=$1
    local args_path=$2
    local args=""

    # Extract arguments based on the service type
    args=$(xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" -t -m "//x:service[x:id='$SERVICE_ID']/x:$args_path/*" -v "concat('-', name(), '=', .)" -o " " "$CONFIG_PATH")

    echo "$args"
}

# Get run-dir, config-dir, and logs-dir if specified
RUN_DIR=$(xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-dir" "$CONFIG_PATH")
CONFIG_DIR=$(xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" -t -v "//x:service[x:id='$SERVICE_ID']/x:config-dir" "$CONFIG_PATH")
LOGS_DIR=$(xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" -t -v "//x:service[x:id='$SERVICE_ID']/x:logs-dir" "$CONFIG_PATH")

# Build global arguments (config-dir and logs-dir)
GLOBAL_ARGS=""
if [ -n "$CONFIG_DIR" ]; then
    GLOBAL_ARGS="-config_dir $CONFIG_DIR"
fi
if [ -n "$LOGS_DIR" ]; then
    GLOBAL_ARGS="$GLOBAL_ARGS -logdir $LOGS_DIR"
fi

# Build service-specific arguments based on service type
case $SERVICE_TYPE in
    "server")
        ARGS=$(build_args "$SERVICE_TYPE" "server-args")
        ;;
    "master")
        ARGS=$(build_args "$SERVICE_TYPE" "master-args")
        ;;
    "volume")
        ARGS=$(build_args "$SERVICE_TYPE" "volume-args")
        ;;
    "filer.sync")
        ARGS=$(build_args "$SERVICE_TYPE" "filer-sync-args")
        ;;
    "mount")
        ARGS=$(build_args "$SERVICE_TYPE" "mount-args")
        ;;
    "backup")
        ARGS=$(build_args "$SERVICE_TYPE" "backup-args")
        ;;
    "filer")
        ARGS=$(build_args "$SERVICE_TYPE" "filer-args")
        ;;
    "filer.backup")
        ARGS=$(build_args "$SERVICE_TYPE" "filer-backup-args")
        ;;
    "filer.meta.backup")
        ARGS=$(build_args "$SERVICE_TYPE" "filer-meta-backup-args")
        ;;
    "filer.remote.gateway")
        ARGS=$(build_args "$SERVICE_TYPE" "filer-remote-gateway-args")
        ;;
    "filer.remote.sync")
        ARGS=$(build_args "$SERVICE_TYPE" "filer-remote-sync-args")
        ;;
    "iam")
        ARGS=$(build_args "$SERVICE_TYPE" "iam-args")
        ;;
    "mq.broker")
        ARGS=$(build_args "$SERVICE_TYPE" "mq-broker-args")
        ;;
    "s3")
        ARGS=$(build_args "$SERVICE_TYPE" "s3-args")
        ;;
    "webdav")
        ARGS=$(build_args "$SERVICE_TYPE" "webdav-args")
        ;;
    *)
        echo "Error: Unknown service type '$SERVICE_TYPE'"
        exit 1
        ;;
esac

# Show the command that will be executed
if [ -n "$RUN_DIR" ]; then
    echo "Executing: cd '$RUN_DIR' && $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS"
else
    echo "Executing: $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS"
fi

# Execute the command with run-dir if specified
if [ -n "$RUN_USER" ] && [ -n "$RUN_GROUP" ]; then
    if [ -n "$RUN_DIR" ]; then
        exec sudo -u "$RUN_USER" -g "$RUN_GROUP" bash -c "cd '$RUN_DIR' && $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS"
    else
        exec sudo -u "$RUN_USER" -g "$RUN_GROUP" $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS
    fi
else
    if [ -n "$RUN_DIR" ]; then
        exec bash -c "cd '$RUN_DIR' && $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS"
    else
        exec $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS
    fi
fi