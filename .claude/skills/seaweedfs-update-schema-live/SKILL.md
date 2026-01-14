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
