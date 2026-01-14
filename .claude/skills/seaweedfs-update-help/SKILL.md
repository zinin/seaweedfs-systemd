---
name: seaweedfs-update-help
description: Use when updating SeaweedFS binary or regenerating help documentation for weed commands
---

# SeaweedFS Update Help

## Overview

Automates downloading the latest SeaweedFS release and generating comprehensive help documentation with dynamic command discovery.

## When to Use

- Updating SeaweedFS to latest version
- Regenerating help.txt after new release
- Need fresh documentation for all weed commands

## Quick Reference

| File | Purpose |
|------|---------|
| `scripts/seaweedfs_update_help.py` | Main script |
| `help.txt` | Generated documentation (in project root) |
| `weed` | Downloaded executable (in project root) |

## Usage

Run from project root:

```bash
python3 .claude/skills/seaweedfs-update-help/scripts/seaweedfs_update_help.py
```

## Key Features

**Overview section** - includes full `./weed` output at the beginning: version, command list with descriptions, and logging options.

**Dynamic command parsing** - parses available commands from `./weed` output instead of hardcoded list. This ensures new commands are automatically included.

**GitHub API** - uses API to get latest release tag reliably.

**Combined output** - captures both stdout and stderr for complete documentation.

## Script Structure

```python
get_latest_release(repo)     # GitHub API -> tag
download_release(repo, tag)  # Download tar.gz
extract_executable(archive)  # Extract weed binary
parse_commands(weed_path)    # Dynamic command discovery
generate_help(commands)      # Run help for each command
```

## Common Modifications

**Different architecture:**
```python
archive_name = "linux_arm64_full.tar.gz"  # ARM64
archive_name = "darwin_amd64_full.tar.gz"  # macOS
```

**Custom output format:**
```python
# In generate_help(), modify the f.write() calls
f.write(f"## {cmd}\n\n```\n{output}\n```\n\n")  # Markdown format
```
