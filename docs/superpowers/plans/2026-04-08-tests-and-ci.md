# Tests and CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add BATS tests, shellcheck linting, XSD validation, and GitHub Actions CI; fix security and correctness bugs in shell scripts.

**Architecture:** Fix scripts first (make them testable via source guard + array-based args), then create test infrastructure (helpers, fixtures, stub weed), then BATS tests, then Makefile and CI. Each task produces a commit.

**Tech Stack:** BATS (bash testing), shellcheck, xmllint, xmlstarlet, GNU Make, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-04-08-tests-and-ci-design.md`

---

### Task 1: Fix dist/seaweedfs-deps.sh

Two small bug fixes + testability changes + source guard.

**Files:**
- Modify: `dist/seaweedfs-deps.sh:11` (DROPIN_DIR_BASE overridable)
- Modify: `dist/seaweedfs-deps.sh:55` (grep fix)
- Modify: `dist/seaweedfs-deps.sh:61` (return overflow)
- Modify: `dist/seaweedfs-deps.sh:185-466` (source guard)

- [ ] **Step 1: Make DROPIN_DIR_BASE overridable for testing (line 11)**

```bash
# OLD:
DROPIN_DIR_BASE="/etc/systemd/system"
# NEW:
DROPIN_DIR_BASE="${DROPIN_DIR_BASE:-/etc/systemd/system}"
```

- [ ] **Step 2: Fix grep regex injection (line 55)**

Change `grep -qx` to `grep -qxF` for fixed-string matching:

```bash
# In validate_service_refs(), line 55
# OLD:
        if ! echo "$valid_ids" | grep -qx "$ref"; then
# NEW:
        if ! echo "$valid_ids" | grep -qxF "$ref"; then
```

- [ ] **Step 3: Fix return value overflow (line 61)**

```bash
# In validate_service_refs(), line 61
# OLD:
    return $errors
# NEW:
    return $((errors > 0 ? 1 : 0))
```

- [ ] **Step 4: Add source guard**

Wrap the main execution block (lines 185-466) so functions can be sourced without side effects:

```bash
# Replace line 185 onward. Before:
if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
...
# All the way to the end of the case block

# After: wrap in guard
main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    COMMAND="$1"
    CONFIG_PATH="${2:-$DEFAULT_CONFIG}"

    check_deps

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

            if ! run_validations "$CONFIG_PATH"; then
                exit 1
            fi

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

            if ! run_validations "$CONFIG_PATH"; then
                echo ""
                echo "Fix validation errors before applying"
                exit 1
            fi

            echo ""
            echo "=== Files to remove ==="
            clean_dropins true
            process_config "$CONFIG_PATH" true
            ;;
        *)
            echo "Error: Unknown command '$COMMAND'"
            usage
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

- [ ] **Step 5: Commit**

```bash
git add dist/seaweedfs-deps.sh
git commit -m "fix: grep regex injection and return overflow in deps.sh

- Make DROPIN_DIR_BASE overridable from environment for testability
- Use grep -qxF instead of grep -qx to prevent regex interpretation of service IDs
- Fix return value overflow (>255 errors would falsely return 0)
- Add source guard for BATS testability"
```

---

### Task 2: Refactor dist/seaweedfs-service.sh

Seven bug fixes + restructure for testability. This is the largest task.

**Files:**
- Modify: `dist/seaweedfs-service.sh` (full refactor)

- [ ] **Step 1: Write the complete refactored script**

Replace the entire file with:

```bash
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

    # Get service type
    SERVICE_TYPE=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:type" "$CONFIG_PATH")

    if [[ -z "$SERVICE_TYPE" ]]; then
        echo "Error: Service with ID '$SERVICE_ID' not found in config"
        exit 1
    fi

    # Get run-user and run-group
    RUN_USER=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-user" "$CONFIG_PATH")
    RUN_GROUP=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-group" "$CONFIG_PATH")

    # Get run-dir, config-dir, and logs-dir if specified
    RUN_DIR=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:run-dir" "$CONFIG_PATH")
    CONFIG_DIR=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:config-dir" "$CONFIG_PATH")
    LOGS_DIR=$(xmlstarlet sel -N x="$NS" -t -v "//x:service[x:id='$SERVICE_ID']/x:logs-dir" "$CONFIG_PATH")

    # Build service-specific arguments: type "filer.backup" -> element "filer-backup-args"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    build_args "$ARGS_ELEMENT"

    # Warn on incomplete sudo config
    if [[ -n "$RUN_USER" && -z "$RUN_GROUP" ]] || [[ -z "$RUN_USER" && -n "$RUN_GROUP" ]]; then
        echo "Warning: Both run-user and run-group should be set. Ignoring partial sudo config."
    fi

    # Build command array
    CMD=()
    if [[ -n "$RUN_USER" && -n "$RUN_GROUP" ]]; then
        CMD+=(sudo -u "$RUN_USER" -g "$RUN_GROUP" --)
    fi
    CMD+=("$WEED_BINARY")
    [[ -n "$CONFIG_DIR" ]] && CMD+=(-config_dir "$CONFIG_DIR")
    [[ -n "$LOGS_DIR" ]] && CMD+=(-logdir "$LOGS_DIR")
    CMD+=("$SERVICE_TYPE")
    CMD+=("${ARGS[@]}")

    echo "Executing: ${CMD[*]}"

    # Run weed with notify support
    run_weed
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

- [ ] **Step 2: Verify script syntax**

Run: `bash -n dist/seaweedfs-service.sh`
Expected: no output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add dist/seaweedfs-service.sh
git commit -m "fix: remove eval, sanitize inputs, switch to arrays in service.sh

- Add set -euo pipefail
- Sanitize SERVICE_ID with regex before XPath substitution
- Replace 70-line case block with computed mapping (SERVICE_TYPE dots to dashes + -args)
- Remove eval in run_weed, use bash arrays for command construction
- Use local-name() instead of name() in XPath to avoid namespace prefix issues
- Fix xmllint + set -e incompatibility
- Warn when only one of run-user/run-group is set
- Extract NS constant (was duplicated 6 times)
- Add source guard (BASH_SOURCE) for BATS testability"
```

---

### Task 3: Create test fixtures

Nine new XML fixture files for BATS tests.

**Files:**
- Create: `tests/fixtures/services-minimal.xml`
- Create: `tests/fixtures/services-all-types.xml`
- Create: `tests/fixtures/services-dotted-args.xml`
- Create: `tests/fixtures/services-filer-sync.xml`
- Create: `tests/fixtures/services-global-args.xml`
- Create: `tests/fixtures/services-mixed-deps.xml`
- Create: `tests/fixtures/services-shared-dependent.xml`
- Create: `tests/fixtures/services-no-deps.xml`
- Create: `tests/fixtures/services-invalid-type.xml`

- [ ] **Step 1: services-minimal.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>test-server</id>
        <type>server</type>
        <run-user>seaweedfs</run-user>
        <run-group>seaweedfs</run-group>
        <run-dir>/var/lib/seaweedfs/test</run-dir>
        <server-args>
            <dir>/data</dir>
        </server-args>
    </service>
</services>
```

- [ ] **Step 2: services-all-types.xml**

One service per type (all 22). Each uses minimal args (one field).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>t-admin</id>
        <type>admin</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <admin-args><port>9001</port></admin-args>
    </service>
    <service>
        <id>t-backup</id>
        <type>backup</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <backup-args><dir>/backup</dir></backup-args>
    </service>
    <service>
        <id>t-db</id>
        <type>db</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <db-args><port>9002</port></db-args>
    </service>
    <service>
        <id>t-filer</id>
        <type>filer</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <filer-args><port>8888</port></filer-args>
    </service>
    <service>
        <id>t-filer-backup</id>
        <type>filer.backup</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <filer-backup-args><filer>localhost:8888</filer></filer-backup-args>
    </service>
    <service>
        <id>t-filer-meta-backup</id>
        <type>filer.meta.backup</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <filer-meta-backup-args><filer>localhost:8888</filer></filer-meta-backup-args>
    </service>
    <service>
        <id>t-filer-remote-gateway</id>
        <type>filer.remote.gateway</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <filer-remote-gateway-args><filer>localhost:8888</filer></filer-remote-gateway-args>
    </service>
    <service>
        <id>t-filer-remote-sync</id>
        <type>filer.remote.sync</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <filer-remote-sync-args><filer>localhost:8888</filer></filer-remote-sync-args>
    </service>
    <service>
        <id>t-filer-sync</id>
        <type>filer.sync</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <filer-sync-args><a>localhost:8888</a></filer-sync-args>
    </service>
    <service>
        <id>t-iam</id>
        <type>iam</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <iam-args><masters>localhost:9333</masters></iam-args>
    </service>
    <service>
        <id>t-master</id>
        <type>master</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <master-args><port>9333</port></master-args>
    </service>
    <service>
        <id>t-master-follower</id>
        <type>master.follower</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <master-follower-args><masters>localhost:9333</masters></master-follower-args>
    </service>
    <service>
        <id>t-mini</id>
        <type>mini</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <mini-args><dir>/data</dir></mini-args>
    </service>
    <service>
        <id>t-mount</id>
        <type>mount</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <mount-args><filer>localhost:8888</filer><dir>/mnt/sw</dir></mount-args>
    </service>
    <service>
        <id>t-mq-broker</id>
        <type>mq.broker</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <mq-broker-args><port>17777</port></mq-broker-args>
    </service>
    <service>
        <id>t-mq-kafka-gateway</id>
        <type>mq.kafka.gateway</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <mq-kafka-gateway-args><port>19092</port></mq-kafka-gateway-args>
    </service>
    <service>
        <id>t-s3</id>
        <type>s3</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <s3-args><port>8333</port></s3-args>
    </service>
    <service>
        <id>t-server</id>
        <type>server</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <server-args><dir>/data</dir></server-args>
    </service>
    <service>
        <id>t-sftp</id>
        <type>sftp</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <sftp-args><port>2022</port></sftp-args>
    </service>
    <service>
        <id>t-volume</id>
        <type>volume</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <volume-args><dir>/data</dir></volume-args>
    </service>
    <service>
        <id>t-webdav</id>
        <type>webdav</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <webdav-args><port>7333</port></webdav-args>
    </service>
    <service>
        <id>t-worker</id>
        <type>worker</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <worker-args/>
    </service>
</services>
```

- [ ] **Step 3: services-dotted-args.xml**

Tests args with dots in element names (from real production configs).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>dotted-server</id>
        <type>server</type>
        <run-user>seaweedfs</run-user>
        <run-group>seaweedfs</run-group>
        <run-dir>/var/lib/seaweedfs</run-dir>
        <server-args>
            <dir>/data</dir>
            <ip>myhost</ip>
            <ip.bind>0.0.0.0</ip.bind>
            <filer>true</filer>
            <filer.localSocket>/var/lib/seaweedfs/filer.sock</filer.localSocket>
            <filer.port>10201</filer.port>
            <master.port>10001</master.port>
            <master.volumeSizeLimitMB>1000</master.volumeSizeLimitMB>
            <volume.dir.idx>/data/idx</volume.dir.idx>
            <volume.max>10000</volume.max>
            <volume.port>10101</volume.port>
            <volume.publicUrl>myhost:10101</volume.publicUrl>
        </server-args>
    </service>
</services>
```

- [ ] **Step 4: services-filer-sync.xml**

Dotted service type + dotted arg names.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>test-filer-sync</id>
        <type>filer.sync</type>
        <run-user>root</run-user>
        <run-group>root</run-group>
        <run-dir>/var/lib/seaweedfs</run-dir>
        <filer-sync-args>
            <a>host-a:10201</a>
            <b>host-b:10201</b>
            <a.filerProxy>true</a.filerProxy>
            <b.filerProxy>true</b.filerProxy>
        </filer-sync-args>
    </service>
</services>
```

- [ ] **Step 5: services-global-args.xml**

Tests config-dir and logs-dir (global args passed to weed before subcommand).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>global-server</id>
        <type>server</type>
        <run-user>seaweedfs</run-user>
        <run-group>seaweedfs</run-group>
        <run-dir>/var/lib/seaweedfs</run-dir>
        <config-dir>/var/lib/seaweedfs/config</config-dir>
        <logs-dir>/var/lib/seaweedfs/logs</logs-dir>
        <server-args>
            <dir>/data</dir>
        </server-args>
    </service>
</services>
```

- [ ] **Step 6: services-mixed-deps.xml**

Both `<service>` and `<unit>` dependencies + `dependency-type` attributes.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>main-server</id>
        <type>server</type>
        <run-user>seaweedfs</run-user>
        <run-group>seaweedfs</run-group>
        <run-dir>/var/lib/seaweedfs</run-dir>
        <server-args>
            <dir>/data</dir>
        </server-args>
    </service>
    <service>
        <id>main-mount</id>
        <type>mount</type>
        <run-user>root</run-user>
        <run-group>root</run-group>
        <run-dir>/var/lib/seaweedfs/mount</run-dir>
        <dependencies>
            <service dependency-type="binds-to">main-server</service>
            <unit>network-online.target</unit>
            <unit dependency-type="wants">local-fs.target</unit>
        </dependencies>
        <mount-args>
            <filer>localhost:8888</filer>
            <dir>/mnt/sw</dir>
        </mount-args>
    </service>
</services>
```

- [ ] **Step 7: services-shared-dependent.xml**

Two services whose dependents both point to the same external unit (nginx).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>mount-a</id>
        <type>mount</type>
        <run-user>root</run-user>
        <run-group>root</run-group>
        <run-dir>/var/lib/seaweedfs/a</run-dir>
        <dependents>
            <unit dependency-type="binds-to">nginx</unit>
        </dependents>
        <mount-args>
            <filer>localhost:8888</filer>
            <dir>/mnt/a</dir>
        </mount-args>
    </service>
    <service>
        <id>mount-b</id>
        <type>mount</type>
        <run-user>root</run-user>
        <run-group>root</run-group>
        <run-dir>/var/lib/seaweedfs/b</run-dir>
        <dependents>
            <unit dependency-type="binds-to">nginx</unit>
        </dependents>
        <mount-args>
            <filer>localhost:8889</filer>
            <dir>/mnt/b</dir>
        </mount-args>
    </service>
</services>
```

- [ ] **Step 8: services-no-deps.xml**

Services with no dependencies or dependents. deps.sh should output "nothing to do".

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>standalone-filer</id>
        <type>filer</type>
        <run-user>seaweedfs</run-user>
        <run-group>seaweedfs</run-group>
        <run-dir>/var/lib/seaweedfs</run-dir>
        <filer-args>
            <port>8888</port>
        </filer-args>
    </service>
</services>
```

- [ ] **Step 9: services-invalid-type.xml**

Invalid service type — fails XSD enum validation.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>bad-type</id>
        <type>nonexistent</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <server-args>
            <dir>/data</dir>
        </server-args>
    </service>
</services>
```

- [ ] **Step 10: Validate all valid fixtures against XSD**

Run:
```bash
for f in tests/fixtures/services-{minimal,all-types,dotted-args,filer-sync,global-args,mixed-deps,shared-dependent,no-deps,with-dependencies,with-dependents,with-cycle}.xml; do
    echo "Validating $f..."
    xmllint --noout --schema xsd/seaweedfs-systemd.xsd "$f"
done
```
Expected: all pass.

- [ ] **Step 11: Verify invalid fixtures fail XSD**

Run:
```bash
xmllint --noout --schema xsd/seaweedfs-systemd.xsd tests/fixtures/services-invalid-type.xml
xmllint --noout --schema xsd/seaweedfs-systemd.xsd tests/fixtures/services-invalid-ref.xml
```
Expected: both fail with validation errors.

- [ ] **Step 12: Commit**

```bash
git add tests/fixtures/
git commit -m "test: add XML fixtures for BATS tests

9 new fixtures: minimal, all-types, dotted-args, filer-sync, global-args,
mixed-deps, shared-dependent, no-deps, invalid-type"
```

---

### Task 4: Create test helpers

**Files:**
- Create: `tests/helpers/setup.bash`
- Create: `tests/helpers/stub-weed.bash`

- [ ] **Step 1: Create tests/helpers/setup.bash**

```bash
# Shared setup for BATS tests

PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist"
FIXTURES_DIR="${PROJECT_ROOT}/tests/fixtures"
XSD_PATH="${PROJECT_ROOT}/xsd/seaweedfs-systemd.xsd"
NS="http://zinin.ru/xml/ns/seaweedfs-systemd"

# Source service.sh functions without running main
source_service_functions() {
    # Source the script — the BASH_SOURCE guard prevents main() from running
    source "${DIST_DIR}/seaweedfs-service.sh"
}

# Source deps.sh functions without running main
source_deps_functions() {
    source "${DIST_DIR}/seaweedfs-deps.sh"
}

# Create a stub weed binary in BATS_TEST_TMPDIR
create_stub_weed() {
    local stub="${BATS_TEST_TMPDIR}/weed"
    cp "${PROJECT_ROOT}/tests/helpers/stub-weed.bash" "$stub"
    chmod +x "$stub"
    echo "$stub"
}
```

- [ ] **Step 2: Create tests/helpers/stub-weed.bash**

```bash
#!/bin/bash
# Stub weed binary for testing
# Logs all arguments to STUB_WEED_LOG for test assertions
echo "$@" > "${STUB_WEED_LOG:-${BATS_TEST_TMPDIR:-/tmp}/stub-weed.log}"
# Keep process alive briefly for tests that check PID
sleep "${STUB_WEED_SLEEP:-0.1}"
```

- [ ] **Step 3: Commit**

```bash
git add tests/helpers/
git commit -m "test: add BATS test helpers and stub weed binary"
```

---

### Task 5: Write seaweedfs-service.bats

**Files:**
- Create: `tests/seaweedfs-service.bats`

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
    source_service_functions
}

# --- Unit tests: validate_service_id ---

# bats test_tags=unit
@test "validate_service_id: accepts valid alphanumeric ID" {
    run validate_service_id "my-server-01"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_service_id: accepts ID with dots" {
    run validate_service_id "filer.sync-1"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_service_id: rejects single quote (XPath injection)" {
    run validate_service_id "test']; --bad"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid service ID"* ]]
}

# bats test_tags=unit
@test "validate_service_id: rejects empty string" {
    run validate_service_id ""
    [[ "$status" -ne 0 ]]
}

# bats test_tags=unit
@test "validate_service_id: rejects spaces" {
    run validate_service_id "my server"
    [[ "$status" -ne 0 ]]
}

# --- Unit tests: build_args ---

# bats test_tags=unit
@test "build_args: parses simple args from XML" {
    SERVICE_ID="test-server"
    CONFIG_PATH="${FIXTURES_DIR}/services-minimal.xml"
    build_args "server-args"
    [[ "${#ARGS[@]}" -ge 1 ]]
    [[ "${ARGS[0]}" == "-dir=/data" ]]
}

# bats test_tags=unit
@test "build_args: handles dotted arg names" {
    SERVICE_ID="dotted-server"
    CONFIG_PATH="${FIXTURES_DIR}/services-dotted-args.xml"
    build_args "server-args"

    # Check that dotted names are preserved
    local found_ip_bind=false
    local found_volume_dir_idx=false
    for arg in "${ARGS[@]}"; do
        [[ "$arg" == "-ip.bind=0.0.0.0" ]] && found_ip_bind=true
        [[ "$arg" == "-volume.dir.idx=/data/idx" ]] && found_volume_dir_idx=true
    done
    [[ "$found_ip_bind" == "true" ]]
    [[ "$found_volume_dir_idx" == "true" ]]
}

# bats test_tags=unit
@test "build_args: handles filer.sync dotted args" {
    SERVICE_ID="test-filer-sync"
    CONFIG_PATH="${FIXTURES_DIR}/services-filer-sync.xml"
    build_args "filer-sync-args"

    [[ "${#ARGS[@]}" -eq 4 ]]
    local found_a_proxy=false
    for arg in "${ARGS[@]}"; do
        [[ "$arg" == "-a.filerProxy=true" ]] && found_a_proxy=true
    done
    [[ "$found_a_proxy" == "true" ]]
}

# bats test_tags=unit
@test "build_args: empty args element returns empty array" {
    SERVICE_ID="t-worker"
    CONFIG_PATH="${FIXTURES_DIR}/services-all-types.xml"
    build_args "worker-args"
    [[ "${#ARGS[@]}" -eq 0 ]]
}

# --- Unit tests: type mapping ---

# bats test_tags=unit
@test "type mapping: simple type server -> server-args" {
    local SERVICE_TYPE="server"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "server-args" ]]
}

# bats test_tags=unit
@test "type mapping: dotted type filer.backup -> filer-backup-args" {
    local SERVICE_TYPE="filer.backup"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "filer-backup-args" ]]
}

# bats test_tags=unit
@test "type mapping: triple dot filer.meta.backup -> filer-meta-backup-args" {
    local SERVICE_TYPE="filer.meta.backup"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "filer-meta-backup-args" ]]
}

# bats test_tags=unit
@test "type mapping: mq.kafka.gateway -> mq-kafka-gateway-args" {
    local SERVICE_TYPE="mq.kafka.gateway"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "mq-kafka-gateway-args" ]]
}

# bats test_tags=unit
@test "type mapping: all 22 types produce valid element names" {
    local types=(admin backup db filer filer.backup filer.meta.backup
        filer.remote.gateway filer.remote.sync filer.sync iam master
        master.follower mini mount mq.broker mq.kafka.gateway s3 server
        sftp volume webdav worker)
    local expected=(admin-args backup-args db-args filer-args filer-backup-args
        filer-meta-backup-args filer-remote-gateway-args filer-remote-sync-args
        filer-sync-args iam-args master-args master-follower-args mini-args
        mount-args mq-broker-args mq-kafka-gateway-args s3-args server-args
        sftp-args volume-args webdav-args worker-args)

    for i in "${!types[@]}"; do
        local result="${types[$i]//./-}-args"
        [[ "$result" == "${expected[$i]}" ]]
    done
}

# --- Integration tests ---

# bats test_tags=integration
@test "service.sh: full run with stub weed produces correct args" {
    local stub_weed
    stub_weed=$(create_stub_weed)
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"

    # Stub out xmllint (skip schema validation), systemd-notify
    xmllint() { return 0; }
    systemd-notify() { return 0; }
    export -f xmllint systemd-notify

    run bash -c "
        export SEAWEEDFS_WEED_BINARY='${stub_weed}'
        export SEAWEEDFS_SCHEMA_PATH='${XSD_PATH}'
        export STUB_WEED_LOG='${STUB_WEED_LOG}'
        export STUB_WEED_SLEEP=0
        # Stub xmllint and systemd-notify
        xmllint() { return 0; }
        systemd-notify() { return 0; }
        export -f xmllint systemd-notify
        '${DIST_DIR}/seaweedfs-service.sh' test-server '${FIXTURES_DIR}/services-minimal.xml'
    "

    # Check stub weed received the args
    [[ -f "$STUB_WEED_LOG" ]]
    local logged
    logged=$(cat "$STUB_WEED_LOG")
    [[ "$logged" == *"server"* ]]
    [[ "$logged" == *"-dir=/data"* ]]
}

# bats test_tags=integration
@test "service.sh: global args (config-dir, logs-dir) passed before subcommand" {
    local stub_weed
    stub_weed=$(create_stub_weed)
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"

    run bash -c "
        export SEAWEEDFS_WEED_BINARY='${stub_weed}'
        export SEAWEEDFS_SCHEMA_PATH='${XSD_PATH}'
        export STUB_WEED_LOG='${STUB_WEED_LOG}'
        export STUB_WEED_SLEEP=0
        xmllint() { return 0; }
        systemd-notify() { return 0; }
        export -f xmllint systemd-notify
        '${DIST_DIR}/seaweedfs-service.sh' global-server '${FIXTURES_DIR}/services-global-args.xml'
    "

    local logged
    logged=$(cat "$STUB_WEED_LOG")
    [[ "$logged" == *"-config_dir /var/lib/seaweedfs/config"* ]]
    [[ "$logged" == *"-logdir /var/lib/seaweedfs/logs"* ]]
}

# bats test_tags=integration
@test "service.sh: missing config file returns exit 1" {
    run bash -c "
        xmllint() { return 0; }
        systemd-notify() { return 0; }
        export -f xmllint systemd-notify
        export SEAWEEDFS_SCHEMA_PATH='${XSD_PATH}'
        export SEAWEEDFS_WEED_BINARY='/bin/true'
        '${DIST_DIR}/seaweedfs-service.sh' test-server /nonexistent/config.xml
    "
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Config file not found"* ]]
}

# bats test_tags=integration
@test "service.sh: service not found returns exit 1" {
    local stub_weed
    stub_weed=$(create_stub_weed)

    run bash -c "
        export SEAWEEDFS_WEED_BINARY='${stub_weed}'
        export SEAWEEDFS_SCHEMA_PATH='${XSD_PATH}'
        xmllint() { return 0; }
        systemd-notify() { return 0; }
        export -f xmllint systemd-notify
        '${DIST_DIR}/seaweedfs-service.sh' nonexistent-id '${FIXTURES_DIR}/services-minimal.xml'
    "
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found in config"* ]]
}

# bats test_tags=integration
@test "service.sh: invalid SERVICE_ID rejected" {
    run bash -c "
        export SEAWEEDFS_SCHEMA_PATH='${XSD_PATH}'
        export SEAWEEDFS_WEED_BINARY='/bin/true'
        '${DIST_DIR}/seaweedfs-service.sh' \"test'; drop\" '${FIXTURES_DIR}/services-minimal.xml'
    "
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid service ID"* ]]
}
```

- [ ] **Step 2: Run unit tests**

Run: `bats --filter-tags unit tests/seaweedfs-service.bats`
Expected: all pass

- [ ] **Step 3: Run integration tests**

Run: `bats --filter-tags integration tests/seaweedfs-service.bats`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add tests/seaweedfs-service.bats
git commit -m "test: add BATS tests for seaweedfs-service.sh

Unit tests: validate_service_id, build_args, type mapping (all 22 types)
Integration tests: full run with stub weed, error handling"
```

---

### Task 6: Write seaweedfs-deps.bats

**Files:**
- Create: `tests/seaweedfs-deps.bats`

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
    source_deps_functions
}

# --- Unit tests: validate_service_refs ---

# bats test_tags=unit
@test "validate_service_refs: accepts valid references" {
    run validate_service_refs "${FIXTURES_DIR}/services-with-dependencies.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_service_refs: catches invalid reference" {
    run validate_service_refs "${FIXTURES_DIR}/services-invalid-ref.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown service reference: nonexistent-service"* ]]
}

# bats test_tags=unit
@test "validate_service_refs: grep -qxF does not match regex-like IDs" {
    # Create fixture with service ID containing dots
    local tmp_config="${BATS_TEST_TMPDIR}/regex-test.xml"
    cat > "$tmp_config" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd">
    <service>
        <id>serviceXa</id>
        <type>filer</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <dependencies>
            <service>service.a</service>
        </dependencies>
        <filer-args><port>8888</port></filer-args>
    </service>
</services>
XMLEOF

    # "service.a" should NOT match "serviceXa" with fixed-string grep
    run validate_service_refs "$tmp_config"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown service reference: service.a"* ]]
}

# --- Unit tests: detect_cycles ---

# bats test_tags=unit
@test "detect_cycles: finds A->B->A cycle" {
    run detect_cycles "${FIXTURES_DIR}/services-with-cycle.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cycle detected"* ]]
}

# bats test_tags=unit
@test "detect_cycles: no cycle in valid config" {
    run detect_cycles "${FIXTURES_DIR}/services-with-dependencies.xml"
    [[ "$status" -eq 0 ]]
}

# --- Unit tests: generate_dependents_dropin ---

# bats test_tags=unit
@test "generate_dependents_dropin: produces correct systemd unit" {
    local output
    output=$(generate_dependents_dropin "/etc/seaweedfs/services.xml" "mount-a:requires")

    [[ "$output" == *"[Unit]"* ]]
    [[ "$output" == *"Requires=seaweedfs@mount-a.service"* ]]
    [[ "$output" == *"After=seaweedfs@mount-a.service"* ]]
}

# bats test_tags=unit
@test "generate_dependents_dropin: handles binds-to type" {
    local output
    output=$(generate_dependents_dropin "/etc/seaweedfs/services.xml" "mount-a:binds-to")

    [[ "$output" == *"BindsTo=seaweedfs@mount-a.service"* ]]
    [[ "$output" == *"After=seaweedfs@mount-a.service"* ]]
    # Should NOT contain Requires
    [[ "$output" != *"Requires="* ]]
}

# bats test_tags=unit
@test "generate_dependents_dropin: combines multiple services" {
    local output
    output=$(generate_dependents_dropin "/etc/seaweedfs/services.xml" \
        "mount-a:binds-to" "mount-b:requires")

    [[ "$output" == *"BindsTo=seaweedfs@mount-a.service"* ]]
    [[ "$output" == *"Requires=seaweedfs@mount-b.service"* ]]
    [[ "$output" == *"After=seaweedfs@mount-a.service seaweedfs@mount-b.service"* ]]
}

# --- Unit tests: generate_dependencies_dropin ---

# bats test_tags=unit
@test "generate_dependencies_dropin: adds .service suffix to units" {
    local output
    output=$(generate_dependencies_dropin "/etc/seaweedfs/services.xml" "postgresql:requires")

    [[ "$output" == *"Requires=postgresql.service"* ]]
    [[ "$output" == *"After=postgresql.service"* ]]
}

# bats test_tags=unit
@test "generate_dependencies_dropin: preserves .target suffix" {
    local output
    output=$(generate_dependencies_dropin "/etc/seaweedfs/services.xml" "network-online.target:requires")

    [[ "$output" == *"Requires=network-online.target"* ]]
    [[ "$output" == *"After=network-online.target"* ]]
}

# bats test_tags=unit
@test "generate_dependencies_dropin: handles wants type" {
    local output
    output=$(generate_dependencies_dropin "/etc/seaweedfs/services.xml" "local-fs.target:wants")

    [[ "$output" == *"Wants=local-fs.target"* ]]
    [[ "$output" != *"Requires="* ]]
}

# --- Integration tests ---

# bats test_tags=integration
@test "deps.sh check: dry-run creates no files" {
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "$DROPIN_DIR_BASE"

    # Stub systemctl
    systemctl() { return 0; }
    export -f systemctl

    run bash -c "
        export DROPIN_DIR_BASE='${DROPIN_DIR_BASE}'
        systemctl() { return 0; }
        export -f systemctl
        '${DIST_DIR}/seaweedfs-deps.sh' check '${FIXTURES_DIR}/services-with-dependents.xml'
    "
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Would create"* ]]
    # No actual files should be created
    local count
    count=$(find "$DROPIN_DIR_BASE" -name "seaweedfs.conf" 2>/dev/null | wc -l)
    [[ "$count" -eq 0 ]]
}

# bats test_tags=integration
@test "deps.sh apply: creates drop-in files" {
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "$DROPIN_DIR_BASE"

    run bash -c "
        export DROPIN_DIR_BASE='${DROPIN_DIR_BASE}'
        systemctl() { return 0; }
        export -f systemctl
        '${DIST_DIR}/seaweedfs-deps.sh' apply '${FIXTURES_DIR}/services-with-dependents.xml'
    "
    [[ "$status" -eq 0 ]]

    # nginx drop-in should exist
    [[ -f "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf" ]]
    # dovecot drop-in should exist
    [[ -f "${DROPIN_DIR_BASE}/dovecot.service.d/seaweedfs.conf" ]]

    # Check content
    local nginx_conf
    nginx_conf=$(cat "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf")
    [[ "$nginx_conf" == *"seaweedfs@test-mount.service"* ]]
}

# bats test_tags=integration
@test "deps.sh apply: shared dependent combines services" {
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "$DROPIN_DIR_BASE"

    run bash -c "
        export DROPIN_DIR_BASE='${DROPIN_DIR_BASE}'
        systemctl() { return 0; }
        export -f systemctl
        '${DIST_DIR}/seaweedfs-deps.sh' apply '${FIXTURES_DIR}/services-shared-dependent.xml'
    "
    [[ "$status" -eq 0 ]]

    local nginx_conf
    nginx_conf=$(cat "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf")
    # Both mount-a and mount-b should appear
    [[ "$nginx_conf" == *"mount-a"* ]]
    [[ "$nginx_conf" == *"mount-b"* ]]
}

# bats test_tags=integration
@test "deps.sh check: no deps config outputs no-op messages" {
    run bash -c "
        systemctl() { return 0; }
        export -f systemctl
        '${DIST_DIR}/seaweedfs-deps.sh' check '${FIXTURES_DIR}/services-no-deps.xml'
    "
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No dependents found"* ]]
    [[ "$output" == *"No dependencies found"* ]]
}

# bats test_tags=integration
@test "deps.sh check: cycle detected returns exit 1" {
    run bash -c "
        systemctl() { return 0; }
        export -f systemctl
        '${DIST_DIR}/seaweedfs-deps.sh' check '${FIXTURES_DIR}/services-with-cycle.xml'
    "
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cycle detected"* ]]
}

# bats test_tags=integration
@test "deps.sh check: invalid ref returns exit 1" {
    run bash -c "
        systemctl() { return 0; }
        export -f systemctl
        '${DIST_DIR}/seaweedfs-deps.sh' check '${FIXTURES_DIR}/services-invalid-ref.xml'
    "
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown service reference"* ]]
}

# bats test_tags=integration
@test "deps.sh clean: removes drop-in files" {
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "${DROPIN_DIR_BASE}/nginx.service.d"
    echo "[Unit]" > "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf"

    run bash -c "
        export DROPIN_DIR_BASE='${DROPIN_DIR_BASE}'
        systemctl() { return 0; }
        export -f systemctl
        '${DIST_DIR}/seaweedfs-deps.sh' clean
    "
    [[ "$status" -eq 0 ]]
    [[ ! -f "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf" ]]
}
```

- [ ] **Step 2: Run unit tests**

Run: `bats --filter-tags unit tests/seaweedfs-deps.bats`
Expected: all pass

- [ ] **Step 3: Run integration tests**

Run: `bats --filter-tags integration tests/seaweedfs-deps.bats`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add tests/seaweedfs-deps.bats
git commit -m "test: add BATS tests for seaweedfs-deps.sh

Unit tests: validate_service_refs, detect_cycles, generate_dependents_dropin,
generate_dependencies_dropin
Integration tests: check/apply/clean commands, shared dependents, error handling"
```

---

### Task 7: Write xsd-validation.bats

**Files:**
- Create: `tests/xsd-validation.bats`

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
}

# bats test_tags=unit
@test "XSD: services-minimal.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-minimal.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-all-types.xml validates (all 22 types)" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-all-types.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-dotted-args.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-dotted-args.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-filer-sync.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-filer-sync.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-global-args.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-global-args.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-with-dependencies.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-with-dependencies.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-with-dependents.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-with-dependents.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-with-cycle.xml validates (cycles are not XSD-detectable)" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-with-cycle.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-mixed-deps.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-mixed-deps.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-shared-dependent.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-shared-dependent.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-no-deps.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-no-deps.xml"
    [[ "$status" -eq 0 ]]
}

# --- Invalid fixtures ---

# bats test_tags=unit
@test "XSD: services-invalid-ref.xml fails keyref validation" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-invalid-ref.xml"
    [[ "$status" -ne 0 ]]
}

# bats test_tags=unit
@test "XSD: services-invalid-type.xml fails enum validation" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-invalid-type.xml"
    [[ "$status" -ne 0 ]]
}
```

- [ ] **Step 2: Run tests**

Run: `bats tests/xsd-validation.bats`
Expected: all pass

- [ ] **Step 3: Commit**

```bash
git add tests/xsd-validation.bats
git commit -m "test: add XSD validation tests for all fixtures"
```

---

### Task 8: Create Makefile

**Files:**
- Create: `Makefile`

- [ ] **Step 1: Write the Makefile**

```makefile
SHELL := /bin/bash

SCRIPTS := dist/seaweedfs-service.sh dist/seaweedfs-deps.sh
XSD := xsd/seaweedfs-systemd.xsd
VALID_FIXTURES := $(filter-out %invalid-%.xml, $(wildcard tests/fixtures/*.xml))

.PHONY: test test-unit test-integration lint validate all

all: lint validate test

lint:
	shellcheck $(SCRIPTS)

validate:
	@for f in $(VALID_FIXTURES); do \
	    echo "Validating $$f..."; \
	    xmllint --noout --schema $(XSD) "$$f" || exit 1; \
	done

test:
	bats tests/

test-unit:
	bats --filter-tags unit tests/

test-integration:
	bats --filter-tags integration tests/
```

- [ ] **Step 2: Run make lint**

Run: `make lint`
Expected: shellcheck passes for both scripts (may reveal warnings to fix)

- [ ] **Step 3: Fix any shellcheck warnings**

If shellcheck reports issues in the refactored scripts, fix them. Common ones:
- SC2086 (unquoted variables) — should be minimal after array refactor
- SC2155 (declare and assign separately) — fix `local var=$(...)` to two lines

- [ ] **Step 4: Run make validate**

Run: `make validate`
Expected: all valid fixtures pass XSD validation

- [ ] **Step 5: Run make test**

Run: `make test`
Expected: all BATS tests pass

- [ ] **Step 6: Run make all**

Run: `make all`
Expected: lint + validate + test all pass

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "build: add Makefile with lint, validate, and test targets"
```

If shellcheck fixes were needed:
```bash
git add Makefile dist/
git commit -m "build: add Makefile with lint, validate, and test targets

Also fix shellcheck warnings in scripts"
```

---

### Task 9: Create GitHub Actions workflow

**Files:**
- Create: `.github/workflows/test.yml`

- [ ] **Step 1: Write the workflow file**

```yaml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y xmlstarlet libxml2-utils shellcheck

      - name: Install bats
        run: |
          git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats
          sudo /tmp/bats/install.sh /usr/local

      - name: Lint
        run: make lint

      - name: Validate XSD
        run: make validate

      - name: Test
        run: make test
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: add GitHub Actions workflow for lint, validate, and test"
```

---

### Task 10: Final validation and cleanup

- [ ] **Step 1: Run full make all**

Run: `make all`
Expected: all green — lint, validate, test pass.

- [ ] **Step 2: Review git log**

Run: `git log --oneline feature/tests-and-ci ^master`
Expected: clean commit history with one commit per task.

- [ ] **Step 3: Remove plan documents from branch**

Per CLAUDE.md: plan documents must not appear in the PR diff.

```bash
git rm -r docs/superpowers/
git commit -m "chore: remove plan documents before PR"
```

- [ ] **Step 4: Push and create PR**

```bash
git push -u origin feature/tests-and-ci
gh pr create --title "Add tests, CI, and fix script bugs" --body "$(cat <<'EOF'
## Summary
- Fix security bugs in seaweedfs-service.sh: remove eval (command injection), sanitize SERVICE_ID (XPath injection), add set -euo pipefail
- Fix correctness bugs: grep regex injection in deps.sh, return overflow, xmllint+set-e incompatibility
- Simplify service.sh: replace 70-line case block with 2-line computed mapping
- Add BATS test suite (unit + integration) for both scripts and XSD validation
- Add Makefile with lint/validate/test targets
- Add GitHub Actions CI

## Test plan
- [ ] `make all` passes locally
- [ ] GitHub Actions workflow passes
- [ ] Verify service.sh works on a real system: `./seaweedfs-service.sh <id> /etc/seaweedfs/services.xml`
- [ ] Verify deps.sh works on a real system: `./seaweedfs-deps.sh check /etc/seaweedfs/services.xml`
EOF
)"
```
