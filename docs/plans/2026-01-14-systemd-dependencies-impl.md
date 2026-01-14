# Systemd Dependencies Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `<dependents>` element to XML config and `seaweedfs-deps.sh` script for managing systemd drop-in files.

**Architecture:** XML config declares which systemd units depend on SeaweedFS mount. Dedicated script creates/removes drop-in files in `/etc/systemd/system/*.service.d/seaweedfs.conf`.

**Tech Stack:** Bash, xmlstarlet, systemd drop-in files

---

## Task 1: Add DependentsType to XSD Schema

**Files:**
- Modify: `xsd/seaweedfs-systemd.xsd:17-50`

**Step 1: Add DependentsType complex type**

Add after line 76 (after ServiceTypeEnum closing tag):

```xml
    <xs:complexType name="DependentsType">
        <xs:sequence>
            <xs:element name="unit" type="xs:string" maxOccurs="unbounded"/>
        </xs:sequence>
    </xs:complexType>
```

**Step 2: Add dependents element to ServiceType**

Change ServiceType from `xs:sequence` to allow `dependents` after `logs-dir` and before `xs:choice`. Replace lines 17-50:

```xml
    <xs:complexType name="ServiceType">
        <xs:sequence>
            <xs:element name="id" type="xs:string"/>
            <xs:element name="type" type="tns:ServiceTypeEnum"/>
            <xs:element name="run-user" type="xs:string"/>
            <xs:element name="run-group" type="xs:string"/>
            <xs:element name="run-dir" type="xs:string"/>
            <xs:element name="config-dir" type="xs:string" minOccurs="0"/>
            <xs:element name="logs-dir" type="xs:string" minOccurs="0"/>
            <xs:element name="dependents" type="tns:DependentsType" minOccurs="0"/>
            <xs:choice>
                <xs:element name="admin-args" type="tns:AdminArgs"/>
                <xs:element name="backup-args" type="tns:BackupArgs"/>
                <xs:element name="db-args" type="tns:DbArgs"/>
                <xs:element name="filer-args" type="tns:FilerArgs"/>
                <xs:element name="filer-backup-args" type="tns:FilerBackupArgs"/>
                <xs:element name="filer-meta-backup-args" type="tns:FilerMetaBackupArgs"/>
                <xs:element name="filer-remote-gateway-args" type="tns:FilerRemoteGatewayArgs"/>
                <xs:element name="filer-remote-sync-args" type="tns:FilerRemoteSyncArgs"/>
                <xs:element name="filer-sync-args" type="tns:FilerSyncArgs"/>
                <xs:element name="master-args" type="tns:MasterArgs"/>
                <xs:element name="master-follower-args" type="tns:MasterFollowerArgs"/>
                <xs:element name="mini-args" type="tns:MiniArgs"/>
                <xs:element name="mount-args" type="tns:MountArgs"/>
                <xs:element name="mq-broker-args" type="tns:MqBrokerArgs"/>
                <xs:element name="mq-kafka-gateway-args" type="tns:MqKafkaGatewayArgs"/>
                <xs:element name="s3-args" type="tns:S3Args"/>
                <xs:element name="server-args" type="tns:ServerArgs"/>
                <xs:element name="sftp-args" type="tns:SftpArgs"/>
                <xs:element name="volume-args" type="tns:VolumeArgs"/>
                <xs:element name="webdav-args" type="tns:WebdavArgs"/>
                <xs:element name="worker-args" type="tns:WorkerArgs"/>
            </xs:choice>
        </xs:sequence>
    </xs:complexType>
```

**Step 3: Validate XSD syntax**

Run: `xmllint --noout xsd/seaweedfs-systemd.xsd`
Expected: No output (valid)

**Step 4: Commit**

```bash
git add xsd/seaweedfs-systemd.xsd
git commit -m "$(cat <<'EOF'
feat(xsd): add dependents element for systemd dependencies

Allows declaring which systemd units (nginx, dovecot, etc.)
depend on a SeaweedFS service via <dependents><unit> elements.
EOF
)"
```

---

## Task 2: Create Test XML with Dependents

**Files:**
- Create: `tests/fixtures/services-with-dependents.xml`

**Step 1: Create test fixtures directory**

Run: `mkdir -p tests/fixtures`

**Step 2: Create test XML file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd ../xsd/seaweedfs-systemd.xsd">
    <service>
        <id>test-mount</id>
        <type>mount</type>
        <run-user>root</run-user>
        <run-group>root</run-group>
        <run-dir>/var/lib/seaweedfs/test</run-dir>
        <dependents>
            <unit>nginx</unit>
            <unit>dovecot</unit>
        </dependents>
        <mount-args>
            <filer>localhost:8888</filer>
            <dir>/mnt/test</dir>
        </mount-args>
    </service>
    <service>
        <id>test-filer</id>
        <type>filer</type>
        <run-user>seaweedfs</run-user>
        <run-group>seaweedfs</run-group>
        <run-dir>/var/lib/seaweedfs/filer</run-dir>
        <filer-args>
            <port>8888</port>
        </filer-args>
    </service>
</services>
```

**Step 3: Validate test XML against schema**

Run: `xmllint --noout --schema xsd/seaweedfs-systemd.xsd tests/fixtures/services-with-dependents.xml`
Expected: `tests/fixtures/services-with-dependents.xml validates`

**Step 4: Commit**

```bash
git add tests/fixtures/services-with-dependents.xml
git commit -m "$(cat <<'EOF'
test: add fixture XML with dependents element
EOF
)"
```

---

## Task 3: Create seaweedfs-deps.sh Script - Core Structure

**Files:**
- Create: `dist/seaweedfs-deps.sh`

**Step 1: Create script with header and usage**

```bash
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
```

**Step 2: Make script executable**

Run: `chmod +x dist/seaweedfs-deps.sh`

**Step 3: Test script runs without error**

Run: `./dist/seaweedfs-deps.sh`
Expected: Usage message displayed

Run: `./dist/seaweedfs-deps.sh apply`
Expected: "Command: apply" (will fail later for missing config, but structure works)

**Step 4: Commit**

```bash
git add dist/seaweedfs-deps.sh
git commit -m "$(cat <<'EOF'
feat: add seaweedfs-deps.sh script skeleton
EOF
)"
```

---

## Task 4: Implement clean Command

**Files:**
- Modify: `dist/seaweedfs-deps.sh`

**Step 1: Add clean_dropins function**

Add before the case statement:

```bash
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
```

**Step 2: Update case statement for clean**

```bash
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
```

**Step 3: Test clean command (dry-run mentally)**

Run: `./dist/seaweedfs-deps.sh clean`
Expected: "Searching for seaweedfs drop-in files..." then "No seaweedfs drop-in files found" (assuming none exist)

**Step 4: Commit**

```bash
git add dist/seaweedfs-deps.sh
git commit -m "$(cat <<'EOF'
feat(deps): implement clean command
EOF
)"
```

---

## Task 5: Implement XML Parsing and Drop-in Generation

**Files:**
- Modify: `dist/seaweedfs-deps.sh`

**Step 1: Add function to generate drop-in content**

Add after clean_dropins function:

```bash
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
```

**Step 2: Update case statement for apply and check**

Replace the apply|check block:

```bash
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
```

**Step 3: Test check command with test fixture**

Run: `./dist/seaweedfs-deps.sh check tests/fixtures/services-with-dependents.xml`
Expected output showing:
- Would remove any existing drop-ins
- Would create nginx.service.d/seaweedfs.conf
- Would create dovecot.service.d/seaweedfs.conf

**Step 4: Commit**

```bash
git add dist/seaweedfs-deps.sh
git commit -m "$(cat <<'EOF'
feat(deps): implement apply and check commands

- Parses XML config for <dependents> elements
- Creates drop-in files in /etc/systemd/system/*.service.d/
- check command shows dry-run output
- apply cleans existing files before creating new ones
EOF
)"
```

---

## Task 6: Add Script to Ansible Deployment

**Files:**
- Modify: `ansible/tasks/main.yml:67-75`

**Step 1: Add seaweedfs-deps.sh to copy loop**

Update the copy task to include the new script:

```yaml
- name: Copy systemd services and scripts
  ansible.builtin.copy:
    src: "{{ item.src }}"
    dest: "{{ item.dest }}"
    mode: "{{ item.mode }}"
  loop:
    - { src: "../../dist/seaweedfs@.service", dest: "/etc/systemd/system/", mode: "0644" }
    - { src: "../../dist/seaweedfs-service.sh", dest: "/opt/seaweedfs/", mode: "0755" }
    - { src: "../../dist/seaweedfs-deps.sh", dest: "/opt/seaweedfs/", mode: "0755" }
    - { src: "../../xsd/seaweedfs-systemd.xsd", dest: "/opt/seaweedfs/", mode: "0644" }
```

**Step 2: Commit**

```bash
git add ansible/tasks/main.yml
git commit -m "$(cat <<'EOF'
feat(ansible): deploy seaweedfs-deps.sh script
EOF
)"
```

---

## Task 7: Integration Test (Manual)

**Step 1: Run check on test fixture**

Run: `./dist/seaweedfs-deps.sh check tests/fixtures/services-with-dependents.xml`

Verify output shows:
- Service test-mount with dependents nginx, dovecot
- Service test-filer without dependents (no output for it)

**Step 2: Test apply (requires root, optional)**

Run (as root): `sudo ./dist/seaweedfs-deps.sh apply tests/fixtures/services-with-dependents.xml`

Verify files created:
```bash
cat /etc/systemd/system/nginx.service.d/seaweedfs.conf
cat /etc/systemd/system/dovecot.service.d/seaweedfs.conf
```

**Step 3: Test clean**

Run (as root): `sudo ./dist/seaweedfs-deps.sh clean`

Verify files removed.

**Step 4: Final commit with docs update**

Update design doc to mark as implemented, or create a follow-up if needed.

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add DependentsType to XSD | `xsd/seaweedfs-systemd.xsd` |
| 2 | Create test XML fixture | `tests/fixtures/services-with-dependents.xml` |
| 3 | Script skeleton | `dist/seaweedfs-deps.sh` |
| 4 | Implement clean | `dist/seaweedfs-deps.sh` |
| 5 | Implement apply/check | `dist/seaweedfs-deps.sh` |
| 6 | Ansible integration | `ansible/tasks/main.yml` |
| 7 | Manual integration test | - |

Total: 7 tasks, ~6 commits
