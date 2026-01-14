# SeaweedFS Systemd Integration

Systemd integration for managing SeaweedFS via XML configuration with XSD validation.

## Commands

```bash
# Start service
./seaweedfs-service.sh <service_id> [config_path]

# Manage dependencies (systemd drop-in files)
./seaweedfs-deps.sh apply [config.xml]  # Create drop-ins
./seaweedfs-deps.sh check [config.xml]  # Dry-run
./seaweedfs-deps.sh clean               # Remove drop-ins

# Ansible deployment
ansible-playbook -i inventory ansible/tasks/main.yml

# XML validation
xmllint --noout --schema xsd/seaweedfs-systemd.xsd /etc/seaweedfs/services.xml
```

## Architecture

| Path | Purpose |
|------|---------|
| `dist/seaweedfs-service.sh` | Service startup script via XML |
| `dist/seaweedfs-deps.sh` | Manage systemd drop-in dependencies |
| `dist/seaweedfs@.service` | Systemd unit template |
| `xsd/seaweedfs-systemd.xsd` | Configuration XSD schema |
| `ansible/` | Deployment playbook |
| `tests/fixtures/` | XML test fixtures for validation |
| `help.txt` | Weed commands documentation |
| `weed` | SeaweedFS binary (not in git) |

## Key Patterns

**XML namespace**: `http://zinin.ru/xml/ns/seaweedfs-systemd`

**Service types**: server, master, volume, filer, s3, mount, webdav, sftp, mq.broker, etc.

**Args naming**: command `filer.backup` → type `FilerBackupArgs` → element `filer-backup-args`

**Service dependencies**: `<dependencies>` (what this service needs), `<dependents>` (what needs this service)

**Dependency types**: `requires` (default), `binds-to`, `wants` — maps to systemd dependency directives

## Dependencies

- `xmlstarlet` — XML parsing
- `xmllint` (libxml2-utils) — XSD validation

## Skills

| Skill | Purpose |
|-------|---------|
| `/seaweedfs-update-help` | Download weed, generate help.txt |
| `/seaweedfs-update-schema` | Update XSD from help.txt |
| `/seaweedfs-update-schema-live` | Update XSD directly via ./weed |

## Workflow: Update Schema

1. `/seaweedfs-update-help` — download new version
2. `/seaweedfs-update-schema-live` — update XSD
3. `git diff xsd/seaweedfs-systemd.xsd` — review changes
4. Commit

## Type Mapping (Go → XSD)

| Go | XSD |
|----|-----|
| `int` | `xs:int` |
| `int64` | `xs:long` |
| `uint` | `xs:unsignedInt` |
| `float` | `xs:float` |
| `string` | `xs:string` |
| `duration` | `xs:duration` |
| (no type) | `xs:boolean` |
