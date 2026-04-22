---
name: seaweedfs-update
description: Check latest SeaweedFS version on GitHub, download if newer, update XSD schema and ansible vars. Use when updating SeaweedFS, checking for new versions, or synchronizing schema with a new release. Triggers on "update seaweedfs", "new seaweedfs version", "update schema", "update weed", or any request related to SeaweedFS version management.
---

# SeaweedFS Update

## Overview

All-in-one skill for updating SeaweedFS: checks the latest release on GitHub, compares with the current version in `ansible/vars/main.yml`, downloads the binary if needed, generates help documentation, discovers new commands, classifies them automatically when possible, reruns command classification as needed, and updates the XSD schema.

## When to Use

- Checking if a new SeaweedFS version is available
- Updating SeaweedFS to the latest version
- Regenerating help.txt and updating XSD schema after a new release

## Quick Reference

| File | Purpose |
|------|---------|
| `ansible/vars/main.yml` | Current version (`seaweedfs_version`) |
| `./weed` | SeaweedFS binary (downloaded, not in git) |
| `help.txt` | Generated help documentation |
| `xsd/seaweedfs-systemd.xsd` | XSD schema to update |
| `scripts/seaweedfs_update.py` | Download and version management |
| `scripts/compare_xsd.py` | Compare weed help with current XSD, output JSON diff |

## Algorithm

### Step 1: Check Versions

```bash
python3 .claude/skills/seaweedfs-update/scripts/seaweedfs_update.py --check
```

**Interactive mode**: show result, ask user to proceed if versions match.
**Non-interactive mode**: if versions match — stop. If update available — proceed automatically.

### Step 2: Download and Generate Help

```bash
python3 .claude/skills/seaweedfs-update/scripts/seaweedfs_update.py
```

Downloads `weed`, updates `seaweedfs_version` in `ansible/vars/main.yml`, generates `help.txt`.

### Step 3: Compare Parameters

```bash
python3 .claude/skills/seaweedfs-update/scripts/compare_xsd.py
```

Outputs a JSON report with the exact list of added, removed, and changed parameters per Args type, plus an `unknown_commands` array with structured evidence for any command that is not already in `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS`.

This JSON report is the source of truth for XSD changes and for unknown-command review — no manual parsing needed.

The script still handles command filtering internally (see Command Filter Lists below), but unknown commands are no longer treated as a silent warning-and-skip case.

### Step 3.5: Classify Unknown Commands

If `unknown_commands` is non-empty, Claude reviews each command using:

- `overview_line`
- `help_text`
- parsed `parameters`
- `has_parameters`
- `args_type`
- `element_name`

For each confident decision, Claude updates `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS` in `compare_xsd.py`, keeps the registry alphabetically ordered, reruns `compare_xsd.py`, and continues the update flow.

For low-confidence decisions:

- Interactive mode: ask the user whether the command belongs in include or exclude, then persist the answer.
- Non-interactive mode: fail the run and do not create a PR.

Commands without a classification are never silently skipped.

### Step 4: Apply Changes to XSD

Based on the JSON report from Step 3, apply changes in batches via subagents. Group 3-4 commands per subagent, run sequentially to avoid file conflicts.

Each subagent gets the exact list of parameters to add/remove/change — no re-parsing of `./weed help` needed. This is faster and more reliable than per-command subagents.

Subagent prompt pattern:
```
Update XSD schema file xsd/seaweedfs-systemd.xsd.
Use 4-space indentation. Element format:
<xs:element name="NAME" type="TYPE" minOccurs="0"/>

## TypeName — add N parameters:
- paramName (xs:type)
...

## TypeName — remove M parameters:
- paramName
...

Insert new elements alphabetically within existing xs:all block.
Read the file first, then make targeted edits.
```

For **new Args types**, the subagent must also:
1. Add `<xs:enumeration value="command"/>` to `ServiceTypeEnum` (alphabetical)
2. Add `<xs:element name="command-args" type="tns:CommandArgs"/>` to `xs:choice` in `ServiceType` (alphabetical)
3. Create new `<xs:complexType name="CommandArgs">` with `<xs:all>` before `</xs:schema>`

### Step 5: Validate and Report

1. Validate XSD:
   ```bash
   xmllint --noout xsd/seaweedfs-systemd.xsd
   ```

2. Validate test fixtures:
   ```bash
   for f in tests/fixtures/*.xml; do xmllint --noout --schema xsd/seaweedfs-systemd.xsd "$f"; done
   ```

3. Output summary:
   ```
   === SeaweedFS Update Report ===

   Version: 4.06 → 4.19
   Commands processed: N
   New commands discovered: X
   Classified automatically: cmd1 -> include, cmd2 -> exclude
   Classification reruns: R
   New Args types created: X
   Parameters added: Y
   Parameters removed: Z
   Parameters changed: W

   Schema updated: xsd/seaweedfs-systemd.xsd
   ```

## Command Filter Lists

`INCLUDE_COMMANDS` and `EXCLUDE_COMMANDS` in `scripts/compare_xsd.py` are the persistent classification registry.

**Include** — long-running services suitable for systemd:
- `server`, `master`, `master.follower`, `volume`, `filer`, `s3`, `mount`, `webdav`, `sftp`
- `filer.backup`, `filer.meta.backup`, `filer.sync`, `filer.remote.sync`, `filer.remote.gateway`, `filer.replicate`
- `mq.broker`, `mq.kafka.gateway`, `backup`, `admin`, `mini`, `worker`, `iam`, `fuse`

**Exclude** — utilities, interactive, informational:
- `help`, `version` — informational
- `shell`, `autocomplete`, `autocomplete.uninstall` — interactive
- `benchmark`, `fix`, `export`, `upload`, `download`, `compact`, `update` — one-shot utilities
- `scaffold`, `mq.agent` — development/client tools
- `filer.cat`, `filer.copy`, `filer.meta.tail` — file utilities

Commands without parameters are skipped automatically (no empty Args types).

## Command to Args Type Conversion

### Command Name → Args Type

1. Split command by `.`
2. Capitalize each part
3. Append `Args`

| Command | Args Type |
|---------|-----------|
| `server` | `ServerArgs` |
| `filer.backup` | `FilerBackupArgs` |
| `filer.meta.backup` | `FilerMetaBackupArgs` |
| `mq.broker` | `MqBrokerArgs` |

### Command Name → XML Element Name

1. Replace `.` with `-`
2. Append `-args`

| Command | Element Name |
|---------|--------------|
| `server` | `server-args` |
| `filer.backup` | `filer-backup-args` |

## Type Mapping (Go → XSD)

| Go type | XSD type |
|---------|----------|
| `int` | `xs:int` |
| `int64` | `xs:long` |
| `uint` | `xs:unsignedInt` |
| `float` | `xs:float` |
| `float64` | `xs:double` |
| `string` | `xs:string` |
| `duration` | `xs:duration` |
| `value` | `xs:string` |
| (no type) | `xs:boolean` |

## XSD Formatting Rules

- Indentation: 4 spaces
- Args types use `<xs:all>` (not `<xs:sequence>`) — order doesn't matter in XML instance
- Elements within `xs:all`: alphabetical order for readability
- New Args types: before `</xs:schema>`
- Enum values in `ServiceTypeEnum`: alphabetical order
- Choice elements in `ServiceType`: alphabetical order

## Edge Cases

**Parameters with dots in name** (`s3.port`, `master.volumeSizeLimitMB`) — these are parameter names, NOT command separators. Keep as-is in XSD.

**Deprecated parameters** — if description contains "deprecated", remove from schema.

**Commands without parameters** — skip, no empty Args type needed.

## Errors

| Error | Action |
|-------|--------|
| GitHub API failure / rate limit | Retry later or provide version manually |
| `./weed` not found after download | Check network, retry |
| `./weed help` fails for a command | Log error, skip command, continue |
| Invalid XSD after edits | Check XML syntax, fix manually |

## Usage

```
/seaweedfs-update
```

## Workflow

1. `/seaweedfs-update` — checks version, downloads, updates everything
2. Review changes: `git diff ansible/vars/main.yml xsd/seaweedfs-systemd.xsd`
3. Commit changes
