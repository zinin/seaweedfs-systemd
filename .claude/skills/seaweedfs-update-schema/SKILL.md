---
name: seaweedfs-update-schema
description: Update XSD schema from SeaweedFS help documentation - adds new parameters, removes deprecated ones, creates new Args types for new commands
---

# SeaweedFS Update Schema

## Overview

Automatically updates the XSD schema `xsd/seaweedfs-systemd.xsd` based on current documentation from `help.txt`.

## When to Use

- After updating SeaweedFS and regenerating help.txt
- To synchronize the schema with a new SeaweedFS version
- After running `/seaweedfs-update-help`

## Quick Reference

| File | Purpose |
|------|---------|
| `help.txt` | Source of current parameters |
| `xsd/seaweedfs-systemd.xsd` | Target schema to update |

## Algorithm

### Step 1: Parse help.txt

1. Read the `help.txt` file from the project root

2. Find all command blocks by pattern:
   ```
   ============================================================
   Command: weed help <command_name>
   ============================================================
   ```

3. For each block:
   - Extract the command name from `weed help <command_name>`
   - Find the `Default Parameters:` section
   - Parse parameters until the next `====` delimiter

4. Parameter format in help.txt:
   ```
     -paramName type
       	description text (default value)
   ```

   Examples:
   ```
     -port int
       	server http listen port (default 9333)
     -debug
       	enable debug mode
     -garbageThreshold float
       	threshold to vacuum (default 0.3)
     -timeAgo duration
       	start time before now
   ```

5. Extract for each parameter:
   - Name (without dash): `port`, `debug`, `garbageThreshold`
   - Go type (if present): `int`, `string`, `float`, `duration`, `uint`
   - Default value (if present): from `(default ...)` in description

### Step 2: Type Mapping

**Go type → XSD type:**

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

**Heuristics when type is missing:**
- `(default true)` or `(default false)` → `xs:boolean`
- `(default 123)` (integer) → `xs:int`
- `(default 0.5)` (decimal) → `xs:float`
- `(default "text")` or any text → `xs:string`
- Unclear → ask the user

### Step 3: Command Name → Args Type

**Conversion rules:**
1. Remove `weed help ` from the command name
2. Split by `.`
3. Capitalize each part
4. Append `Args`

**Examples:**

| Command | Args Type |
|---------|-----------|
| `weed help server` | `ServerArgs` |
| `weed help master` | `MasterArgs` |
| `weed help filer` | `FilerArgs` |
| `weed help filer.backup` | `FilerBackupArgs` |
| `weed help filer.meta.backup` | `FilerMetaBackupArgs` |
| `weed help mq.broker` | `MqBrokerArgs` |
| `weed help s3` | `S3Args` |

**Reverse conversion (Args Type → command):**
- `ServerArgs` → `server`
- `FilerBackupArgs` → `filer.backup`
- `MqBrokerArgs` → `mq.broker`

### Step 4: Compare with Current XSD

1. Read the file `xsd/seaweedfs-systemd.xsd`

2. For each `xs:complexType name="*Args"`:
   - Extract the type name (e.g., `ServerArgs`)
   - Find all `xs:element` within `xs:sequence`
   - For each element extract: `name`, `type`, `minOccurs`

3. Match against data from help.txt:
   - Convert type name to command: `ServerArgs` → `server`
   - Find the corresponding command in parsed data

4. Categorize changes:

   **New parameters** (in help.txt, not in XSD):
   - Add to schema

   **Removed parameters** (in XSD, not in help.txt):
   - Check for rename (see Step 5)
   - If not a rename → ask for confirmation before removing

   **Changed type** (parameter exists in both, type differs):
   - Update type automatically

   **New commands** (in help.txt, no Args type in XSD):
   - Create new Args type

### Step 5: Detect Renames (Levenshtein)

For each "removed" parameter:

1. Calculate similarity with each "new" parameter
2. Use Levenshtein distance or string similarity
3. If similarity ≥ 70%:
   ```
   Parameter 'server' was removed.
   Similar to new parameter 'master' (75% similarity).
   Is this a rename? (yes/no/delete both/keep both)
   ```

4. If similarity < 70%:
   ```
   Parameter 'oldParam' is missing in the new version.
   Remove from schema? (yes/no)
   ```

### Step 6: Apply Changes to XSD

**Adding a new parameter:**

Insert into `xs:sequence` of the corresponding Args type in alphabetical order:

```xml
<xs:element name="newParam" type="xs:int" minOccurs="0"/>
```

- Default is `minOccurs="0"` (optional)
- If parameter is explicitly required (no default, critical) → omit `minOccurs`

**Removing a parameter:**

Delete the line `<xs:element name="paramName" .../>` from `xs:sequence`

**Changing type:**

Replace the `type` attribute value:
```xml
<!-- Before: -->
<xs:element name="param" type="xs:string" minOccurs="0"/>
<!-- After: -->
<xs:element name="param" type="xs:int" minOccurs="0"/>
```

**Creating a new Args type:**

1. Add new value to `ServiceTypeEnum`:
```xml
<xs:enumeration value="new.command"/>
```

2. Add to `xs:choice` inside `ServiceType`:
```xml
<xs:element name="new-command-args" type="tns:NewCommandArgs"/>
```

3. Create new `xs:complexType`:
```xml
<xs:complexType name="NewCommandArgs">
    <xs:sequence>
        <xs:element name="param1" type="xs:string" minOccurs="0"/>
        <xs:element name="param2" type="xs:int" minOccurs="0"/>
    </xs:sequence>
</xs:complexType>
```

**Formatting:**
- Indentation: 4 spaces
- Element order within sequence: alphabetical
- Args type order: preserve existing, add new ones at the end

## Edge Cases

### Nested parameters (with dots in name)

Parameters like `s3.port`, `master.volumeSizeLimitMB`:
- This is NOT a command separator
- Keep as-is in XSD: `<xs:element name="s3.port" .../>`
- Dot in command name (`filer.backup`) — command separator
- Dot in parameter name (`s3.port`) — part of the parameter name

### Deprecated parameters

If description contains "deprecated":
```
-masters string
    comma-separated master servers (deprecated, use -master instead)
```

Action:
```
Parameter 'masters' is marked as deprecated.
Recommendation: remove from schema, use 'master' instead.
Remove? (yes/no)
```

### Commands without parameters

Some commands (e.g., `weed autocomplete`) have an empty `Default Parameters:` section.

Action on first occurrence:
```
Command 'autocomplete' has no parameters.
Create empty AutocompleteArgs type? (yes/skip)
```

### Determining if required

A parameter is required if:
- No `(default ...)` in description
- Description contains words "required", "must", "necessary"
- Command doesn't work without this parameter (contextual)

Otherwise — optional (`minOccurs="0"`)

When in doubt — ask the user.

### Errors

**help.txt not found:**
```
Error: help.txt not found in project root.
Run /seaweedfs-update-help first to generate documentation.
```

**Invalid XSD:**
```
Error: failed to parse xsd/seaweedfs-systemd.xsd.
Check XML syntax manually.
```

## Usage

```
/seaweedfs-update-schema
```

## Output

After execution, display a report:

```
=== SeaweedFS Schema Update Report ===

Commands analyzed: 25
Args types in schema: 14

ADDED parameters: 12
  ServerArgs:
    + adminPassword (xs:string)
    + adminUser (xs:string)
  FilerArgs:
    + sftp (xs:boolean)
    + sftp.port (xs:int)
  ...

REMOVED parameters: 3
  ServerArgs:
    - oldParam (confirmed by user)
  ...

CHANGED types: 2
  MasterArgs.volumeSizeLimitMB: xs:int → xs:unsignedInt

NEW Args types: 2
  + AdminArgs (15 parameters)
  + MiniArgs (47 parameters)

Schema updated: xsd/seaweedfs-systemd.xsd
```

## Workflow Integration

Typical usage order:

1. `/seaweedfs-update-help` — download new version, generate help.txt
2. `/seaweedfs-update-schema` — update XSD based on help.txt
3. Review changes: `git diff xsd/seaweedfs-systemd.xsd`
4. Commit changes
