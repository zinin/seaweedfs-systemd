# Systemd Dependencies for SeaweedFS Mount

## Problem

Services like nginx, dovecot, exim4 need SeaweedFS mount to be ready before they start. Without explicit dependencies, they may:
- Fail to start (configuration error if mount point is empty)
- Start but malfunction (missing files)
- Require manual restart after mount becomes available

Editing `/usr/lib/systemd/system/nginx.service` directly is not viable — apt upgrades overwrite it.

## Solution

Use systemd drop-in files in `/etc/systemd/system/<service>.service.d/` which survive package upgrades.

Dependencies are declared in XML configuration and applied via dedicated script.

## XML Format

```xml
<service>
    <id>zinin-mount</id>
    <type>mount</type>
    <run-user>root</run-user>
    <run-group>root</run-group>
    <run-dir>/var/lib/seaweedfs/zinin</run-dir>
    <config-dir>/var/lib/seaweedfs/zinin</config-dir>
    <logs-dir>/var/lib/seaweedfs/zinin/logs</logs-dir>
    <mount-args>
        <filer>localhost:10201</filer>
        <dir>/mnt/seaweedfs/zinin</dir>
    </mount-args>
    <dependents>
        <unit>nginx</unit>
        <unit>dovecot</unit>
        <unit>exim4</unit>
    </dependents>
</service>
```

## Drop-in File Structure

For each unit in `<dependents>`, create:

```
/etc/systemd/system/nginx.service.d/seaweedfs.conf
```

Contents:

```ini
# Managed by seaweedfs-deps.sh - DO NOT EDIT
# Source: seaweedfs@zinin-mount.service

[Unit]
Requires=seaweedfs@zinin-mount.service
After=seaweedfs@zinin-mount.service
```

- `Requires` — nginx won't start without mount; stops if mount stops
- `After` — nginx waits for mount to fully start

## Script: seaweedfs-deps.sh

Location: `dist/seaweedfs-deps.sh`

### Usage

```bash
# Apply dependencies from XML
./seaweedfs-deps.sh apply /etc/seaweedfs/services.xml

# Show what would be done (dry-run)
./seaweedfs-deps.sh check /etc/seaweedfs/services.xml

# Remove all seaweedfs drop-in files
./seaweedfs-deps.sh clean
```

### Algorithm (apply)

1. Find all `/etc/systemd/system/*.service.d/seaweedfs.conf` files — delete them
2. Remove empty `.service.d/` directories
3. Parse XML, find all `<service>` with `<dependents>`
4. For each `<unit>` create drop-in file
5. Run `systemctl daemon-reload`

### Dependencies

- `xmlstarlet` (already used in project)

## XSD Schema Changes

Add to `xsd/seaweedfs-systemd.xsd`:

```xml
<xs:complexType name="DependentsType">
    <xs:sequence>
        <xs:element name="unit" type="xs:string" maxOccurs="unbounded"/>
    </xs:sequence>
</xs:complexType>
```

Add to ServiceType (after logs-dir, before *-args):

```xml
<xs:element name="dependents" type="DependentsType" minOccurs="0"/>
```

## Ansible Integration

Optional task in `ansible/tasks/main.yml`:

```yaml
- name: Apply systemd dependencies
  command: /opt/seaweedfs/seaweedfs-deps.sh apply /etc/seaweedfs/services.xml
  notify: reload systemd
```

## Workflow

1. Edit XML — add `<dependents>` to mount service
2. Run `./seaweedfs-deps.sh apply /etc/seaweedfs/services.xml`
3. Verify: `systemctl cat nginx.service` — shows drop-in
4. Restart dependent services if needed

## Files to Create/Modify

- `dist/seaweedfs-deps.sh` — new script
- `xsd/seaweedfs-systemd.xsd` — add DependentsType
- `ansible/tasks/main.yml` — optional integration
