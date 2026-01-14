---
name: seaweedfs-update-schema-live
description: Update XSD schema by calling ./weed directly, processing each command in isolated subagent
---

# SeaweedFS Update Schema Live

## Overview

Updates XSD schema directly by calling `./weed` binary. Each command is processed in a separate subagent with clean context, reducing errors when handling large number of parameters.

## When to Use

- After downloading new `./weed` via `/seaweedfs-update-help`
- As alternative to `/seaweedfs-update-schema` for more reliable processing
- When updating schema for many commands at once

## Prerequisites

- Executable `./weed` in project root (run `/seaweedfs-update-help` first)
- XSD schema at `xsd/seaweedfs-systemd.xsd`

## Quick Reference

| File | Purpose |
|------|---------|
| `./weed` | SeaweedFS binary |
| `xsd/seaweedfs-systemd.xsd` | Target schema to update |

## Algorithm

### Step 1: Get Command List

Run `./weed` and parse the "The commands are:" section to get all available commands.

```bash
./weed 2>&1
```

Extract command names from lines matching pattern: `^\s+(\S+)\s+` after "The commands are:".

### Step 2: Filter Commands

**Include** commands that make sense as systemd services:
- `server`, `master`, `volume`, `filer`, `s3`, `mount`, `webdav`, `sftp`
- `filer.backup`, `filer.meta.backup`, `filer.sync`, `filer.remote.sync`, `filer.remote.gateway`
- `mq.broker`, `backup`, `admin`, `mini`, `worker`

**Exclude** non-service commands:
- `help`, `version` — informational
- `shell`, `autocomplete` — interactive
- `benchmark`, `fix`, `export`, `upload`, `download` — utilities
- `scaffold`, `mq.agent` — development/client tools

### Step 3: Process Each Command

For each command, spawn a subagent using Task tool:

```
Task(
    subagent_type="general-purpose",
    description="Update XSD for {command}",
    prompt=SUBAGENT_PROMPT.format(command=command, args_type=args_type)
)
```

**Run sequentially** — each subagent must complete before the next starts to avoid file conflicts.

### Step 4: Generate Report

After all commands processed, output summary:

```
=== SeaweedFS Schema Live Update Report ===

Commands processed: N
New Args types created: X
Parameters added: Y
Parameters removed: Z
Parameters changed: W

Schema updated: xsd/seaweedfs-systemd.xsd
```

## Command to Args Type Conversion

### Command Name → Args Type

1. Split command by `.`
2. Capitalize each part
3. Append `Args`

| Command | Args Type |
|---------|-----------|
| `server` | `ServerArgs` |
| `master` | `MasterArgs` |
| `filer` | `FilerArgs` |
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
| `mq.broker` | `mq-broker-args` |

## Type Mapping

### Go Type → XSD Type

| Go type | XSD type | Example |
|---------|----------|---------|
| `int` | `xs:int` | `-port int` |
| `int64` | `xs:long` | `-size int64` |
| `uint` | `xs:unsignedInt` | `-volumeSizeLimitMB uint` |
| `float` | `xs:float` | `-garbageThreshold float` |
| `float64` | `xs:double` | `-ratio float64` |
| `string` | `xs:string` | `-dir string` |
| `duration` | `xs:duration` | `-timeAgo duration` |
| `value` | `xs:string` | `-config value` |
| (no type) | `xs:boolean` | `-debug` |

### Heuristics When Type Missing

- `(default true)` or `(default false)` → `xs:boolean`
- `(default 123)` integer → `xs:int`
- `(default 0.5)` decimal → `xs:float`
- `(default "text")` → `xs:string`

## Subagent Prompt Template

Use this prompt when spawning subagent for each command:

```
Update XSD schema for SeaweedFS command: {command}

## Your Task

1. Run: `./weed help {command}`

2. Parse parameters from output. Format:
   ```
   -paramName type
       description (default value)
   ```
   - Parameter without type = boolean

3. Target Args type: `{ArgsType}`

4. Read `xsd/seaweedfs-systemd.xsd`

5. Find `<xs:complexType name="{ArgsType}">`

6. **If type exists:** Compare parameters:
   - New parameter → add `<xs:element name="paramName" type="xs:type" minOccurs="0"/>` in alphabetical order
   - Missing parameter → remove from schema
   - Different type → update `type` attribute

7. **If type does NOT exist:** Create new:

   a) Add to `ServiceTypeEnum`:
   ```xml
   <xs:enumeration value="{command}"/>
   ```

   b) Add to `xs:choice` in `ServiceType`:
   ```xml
   <xs:element name="{element-name}" type="tns:{ArgsType}"/>
   ```

   c) Create new `xs:complexType` before `</xs:schema>`:
   ```xml
   <xs:complexType name="{ArgsType}">
       <xs:sequence>
           <xs:element name="param1" type="xs:string" minOccurs="0"/>
           <!-- ... all parameters alphabetically -->
       </xs:sequence>
   </xs:complexType>
   ```

8. Type mapping:
   - int → xs:int
   - int64 → xs:long
   - uint → xs:unsignedInt
   - float → xs:float
   - string → xs:string
   - duration → xs:duration
   - no type → xs:boolean

9. Return brief report:
   ```
   Command: {command}
   Added: param1, param2
   Removed: oldParam
   Changed: param3 (xs:string → xs:int)
   New type created: yes/no
   ```
```

## Edge Cases

### Commands Without Parameters

Some commands have empty `Default Parameters:` section. Skip these — no point in empty Args type for systemd services.

### Parameters with Dots in Name

Parameters like `s3.port`, `master.volumeSizeLimitMB` — these are parameter names, NOT command separators.

Keep as-is in XSD:
```xml
<xs:element name="s3.port" type="xs:int" minOccurs="0"/>
```

### Deprecated Parameters

If parameter description contains "deprecated":
- Remove from schema (along with other missing parameters)
- Note in report

### XSD Formatting

- Indentation: 4 spaces
- Elements within sequence: alphabetical order
- New Args types: add at end of file, before `</xs:schema>`
- New enum values: add at end of `ServiceTypeEnum`
- New choice elements: add at end of `xs:choice`

## Errors

### ./weed not found

```
Error: ./weed not found in project root.
Run /seaweedfs-update-help first to download SeaweedFS binary.
```

### ./weed help fails

If `./weed help <command>` returns error:
- Log the error
- Skip this command
- Continue with next command

### Invalid XSD

If XSD cannot be parsed:
```
Error: Failed to parse xsd/seaweedfs-systemd.xsd.
Check XML syntax manually before running this skill.
```

### Validation

After all updates, recommend running:
```bash
xmllint --noout xsd/seaweedfs-systemd.xsd
```
