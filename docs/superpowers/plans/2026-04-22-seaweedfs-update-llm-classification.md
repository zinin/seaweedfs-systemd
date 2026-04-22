# SeaweedFS Unknown Command Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/seaweedfs-update` stop silently skipping newly introduced `weed` commands by having `compare_xsd.py` emit structured evidence for unknown commands and the skill workflow persist an explicit include/exclude decision before continuing.

**Architecture:** Keep `.claude/skills/seaweedfs-update/scripts/compare_xsd.py` deterministic and limited to collecting facts about unknown commands. Move semantic classification into the `/seaweedfs-update` skill workflow so Claude reads the script output, updates the command lists in `compare_xsd.py`, reruns the script, and only then continues the XSD update flow.

**Tech Stack:** Python 3, project skill markdown, JSON output from `compare_xsd.py`, Bash validation commands, existing BATS harness for shell workflows.

---

## File Structure

- Modify: `.claude/skills/seaweedfs-update/scripts/compare_xsd.py`
  - Add structured `unknown_commands` collection to the JSON report.
  - Keep include/exclude sets as the persistent source of truth.
  - Keep classification decisions out of Python.
- Modify: `.claude/skills/seaweedfs-update/SKILL.md`
  - Document the new unknown-command classification loop.
  - Document rerun behavior and interactive/non-interactive branching.
- Create: `tests/compare_xsd.bats`
  - Add tests for the JSON contract around unknown commands.
- Create: `tests/helpers/stub-weed-compare-xsd.bash`
  - Stub `weed` specifically for `compare_xsd.py` tests, including root help and per-command help text.
- Possibly modify: `Makefile`
  - Only if needed to keep `bats tests/` automatically picking up the new test file without extra configuration. If the new BATS file is discovered automatically, do not change `Makefile`.

---

### Task 1: Add failing tests for unknown command reporting

**Files:**
- Create: `tests/compare_xsd.bats`
- Create: `tests/helpers/stub-weed-compare-xsd.bash`
- Modify: `tests/helpers/setup.bash`

- [ ] **Step 1: Write the failing test file for unknown command JSON reporting**

```bash
#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
}

# bats test_tags=unit
@test "compare_xsd.py: reports unknown command with structured evidence" {
    local stub
    stub=$(create_compare_xsd_stub_weed)

    PATH="${BATS_TEST_TMPDIR}:$PATH" \
    STUB_COMPARE_XSD_MODE="unknown-nfs" \
    run python3 ./.claude/skills/seaweedfs-update/scripts/compare_xsd.py

    [[ "$status" -eq 0 ]]

    local json_file="${BATS_TEST_TMPDIR}/compare-xsd.json"
    printf '%s\n' "$output" > "$json_file"

    run python3 - <<'PY' "$json_file"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

unknown = data["unknown_commands"]
assert len(unknown) == 1, unknown
item = unknown[0]
assert item["command"] == "nfs"
assert item["overview_line"].startswith("nfs ")
assert "NFS" in item["help_text"]
assert item["has_parameters"] is True
assert item["args_type"] == "NfsArgs"
assert item["element_name"] == "nfs-args"
assert any(p["name"] == "filer" for p in item["parameters"])
PY

    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "compare_xsd.py: omits known excluded commands from unknown_commands" {
    local stub
    stub=$(create_compare_xsd_stub_weed)

    PATH="${BATS_TEST_TMPDIR}:$PATH" \
    STUB_COMPARE_XSD_MODE="known-excluded-only" \
    run python3 ./.claude/skills/seaweedfs-update/scripts/compare_xsd.py

    [[ "$status" -eq 0 ]]

    local json_file="${BATS_TEST_TMPDIR}/compare-xsd.json"
    printf '%s\n' "$output" > "$json_file"

    run python3 - <<'PY' "$json_file"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

assert data["unknown_commands"] == [], data["unknown_commands"]
PY

    [[ "$status" -eq 0 ]]
}
```

- [ ] **Step 2: Add a compare_xsd-specific stub weed helper that can emit root help and per-command help**

```bash
#!/bin/bash
set -euo pipefail

mode="${STUB_COMPARE_XSD_MODE:-unknown-nfs}"

if [[ "$#" -eq 0 ]]; then
    case "$mode" in
        unknown-nfs)
            cat <<'EOF'
SeaweedFS: store billions of files and serve them fast!

The commands are:
    server      start a master server, a volume server, and optionally a filer and a S3 gateway
    nfs         start NFS server backed by SeaweedFS filer
    shell       run interactive administrative commands

Use "weed help [command]" for more information about a command.
EOF
            ;;
        known-excluded-only)
            cat <<'EOF'
SeaweedFS: store billions of files and serve them fast!

The commands are:
    server      start a master server, a volume server, and optionally a filer and a S3 gateway
    shell       run interactive administrative commands

Use "weed help [command]" for more information about a command.
EOF
            ;;
    esac
    exit 0
fi

if [[ "$1" == "help" && "$2" == "server" ]]; then
    cat <<'EOF'
Usage: weed server -dir=/data

Default Parameters:
  -dir string
        data directory
EOF
    exit 0
fi

if [[ "$1" == "help" && "$2" == "nfs" ]]; then
    cat <<'EOF'
Usage: weed nfs -filer=localhost:8888 -port=2049

  Start NFS server backed by SeaweedFS filer.

Default Parameters:
  -filer string
        filer address
  -port int
        nfs port
EOF
    exit 0
fi

if [[ "$1" == "help" && "$2" == "shell" ]]; then
    cat <<'EOF'
Usage: weed shell

  Run interactive administrative commands.
EOF
    exit 0
fi

exit 1
```

- [ ] **Step 3: Extend the shared test helper with a factory for the compare_xsd stub**

```bash
create_compare_xsd_stub_weed() {
    local stub="${BATS_TEST_TMPDIR}/weed"
    cp "${PROJECT_ROOT}/tests/helpers/stub-weed-compare-xsd.bash" "$stub"
    chmod +x "$stub"
    echo "$stub"
}
```

- [ ] **Step 4: Run the new BATS test to verify it fails before implementation**

Run: `bats tests/compare_xsd.bats`
Expected: FAIL because `compare_xsd.py` does not yet emit `unknown_commands` with the required fields.

- [ ] **Step 5: Commit the failing tests**

```bash
git add tests/compare_xsd.bats tests/helpers/stub-weed-compare-xsd.bash tests/helpers/setup.bash
git commit -m "test: cover unknown seaweedfs command reporting"
```

### Task 2: Implement structured unknown command reporting in `compare_xsd.py`

**Files:**
- Modify: `.claude/skills/seaweedfs-update/scripts/compare_xsd.py`
- Test: `tests/compare_xsd.bats`

- [ ] **Step 1: Add a helper to capture root help command summary lines**

```python
def get_available_commands() -> tuple[list[str], dict[str, str]]:
    """Get all commands from ./weed and their overview lines."""
    result = subprocess.run(["./weed"], capture_output=True, text=True)
    output = result.stdout + result.stderr
    commands = []
    overview_lines = {}
    in_commands_section = False

    for line in output.splitlines():
        if "The commands are:" in line:
            in_commands_section = True
            continue
        if in_commands_section:
            match = re.match(r'^\s+(\S+)\s+(.*)$', line)
            if match:
                command = match.group(1)
                description = match.group(2).strip()
                commands.append(command)
                overview_lines[command] = f"{command} {description}".strip()
            elif line.strip().startswith("Use ") or (line.strip() == "" and commands):
                if line.strip().startswith("Use "):
                    break

    return commands, overview_lines
```

- [ ] **Step 2: Add a helper that returns both parsed parameters and raw help text for one command**

```python
def get_command_help(cmd: str) -> str:
    """Return raw ./weed help output for one command."""
    result = subprocess.run(["./weed", "help", cmd], capture_output=True, text=True)
    return result.stdout + result.stderr


def parse_weed_help(cmd: str) -> tuple[list[dict], str]:
    """Parse parameters from ./weed help <cmd> and return raw help text."""
    output = get_command_help(cmd)
    params = []

    for match in re.finditer(
        r"^\s+-(\S+?)(?:\s+(int64|int|uint|float64|float|string|duration|value))?\s*$",
        output,
        re.MULTILINE,
    ):
        name = match.group(1)
        go_type = match.group(2)
        xsd_type = TYPE_MAP.get(go_type, "xs:string") if go_type else "xs:boolean"
        params.append({"name": name, "type": xsd_type})

    return sorted(params, key=lambda p: p["name"]), output
```

- [ ] **Step 3: Replace the warning-only unknown handling with structured `unknown_commands` output**

```python
def main():
    commands, overview_lines = get_available_commands()

    unknown_commands = []
    for cmd in sorted(set(commands) - INCLUDE_COMMANDS - EXCLUDE_COMMANDS):
        params, help_text = parse_weed_help(cmd)
        unknown_commands.append(
            {
                "command": cmd,
                "overview_line": overview_lines.get(cmd, cmd),
                "help_text": help_text,
                "parameters": params,
                "has_parameters": bool(params),
                "args_type": command_to_args_type(cmd),
                "element_name": command_to_element(cmd),
            }
        )

    xsd_types = parse_xsd()
    report = {
        "commands": [],
        "summary": {"added": 0, "removed": 0, "changed": 0, "new_types": 0},
        "unknown_commands": unknown_commands,
    }

    for cmd in sorted(INCLUDE_COMMANDS):
        args_type = command_to_args_type(cmd)
        element_name = command_to_element(cmd)
        weed_params, _ = parse_weed_help(cmd)
        if not weed_params:
            continue
        entry = {
            "command": cmd,
            "args_type": args_type,
            "element_name": element_name,
            "is_new": args_type not in xsd_types,
            "added": [],
            "removed": [],
            "changed": [],
            "unchanged": [],
        }
        ...

    print(json.dumps(report, indent=2))
```

- [ ] **Step 4: Run the focused BATS test again to verify it now passes**

Run: `bats tests/compare_xsd.bats`
Expected: PASS with both tests green.

- [ ] **Step 5: Commit the implementation for structured unknown command reporting**

```bash
git add .claude/skills/seaweedfs-update/scripts/compare_xsd.py tests/compare_xsd.bats tests/helpers/stub-weed-compare-xsd.bash tests/helpers/setup.bash
git commit -m "feat: report unknown seaweedfs commands for review"
```

### Task 3: Update the skill workflow to classify, persist, and rerun

**Files:**
- Modify: `.claude/skills/seaweedfs-update/SKILL.md`
- Modify: `.claude/skills/seaweedfs-update/scripts/compare_xsd.py`

- [ ] **Step 1: Update the Step 3 section in `SKILL.md` to describe `unknown_commands` as JSON evidence**

```markdown
### Step 3: Compare Parameters

```bash
python3 .claude/skills/seaweedfs-update/scripts/compare_xsd.py
```

Outputs a JSON report with:
- exact list of added, removed, and changed parameters per Args type
- `unknown_commands`, containing structured evidence for any new command not present in `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS`

This JSON report is the source of truth for both XSD changes and unknown-command review.
```

- [ ] **Step 2: Add a new workflow section describing the Claude classification loop**

```markdown
### Step 3.5: Classify Unknown Commands

If `unknown_commands` is non-empty, Claude reviews each command using:
- `overview_line`
- `help_text`
- parsed `parameters`
- `has_parameters`

For confident decisions:
1. Add the command to `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS` in `compare_xsd.py`
2. Keep the set alphabetically ordered
3. Rerun `compare_xsd.py`

For low-confidence decisions:
- Interactive mode: ask the user whether the command belongs in include or exclude
- Non-interactive mode: fail the run and do not create a PR
```

- [ ] **Step 3: Update the existing unknown-command wording so “warning + skip” is no longer the documented end state**

```markdown
Commands without a classification are never silently skipped.
They must be either:
- persisted to `INCLUDE_COMMANDS`,
- persisted to `EXCLUDE_COMMANDS`, or
- treated as a blocking ambiguity in non-interactive mode.
```

- [ ] **Step 4: Add a helper note near the filter lists clarifying that these sets are the persistent decision registry**

```markdown
`INCLUDE_COMMANDS` and `EXCLUDE_COMMANDS` are the persistent classification registry.
When Claude classifies a previously unknown command with confidence, it must write that decision back into one of these sets before rerunning `compare_xsd.py`.
```

- [ ] **Step 5: Run a targeted read-through check on the modified skill text**

Run: `python3 - <<'PY'
from pathlib import Path
text = Path('.claude/skills/seaweedfs-update/SKILL.md').read_text()
assert 'Step 3.5: Classify Unknown Commands' in text
assert 'unknown_commands' in text
assert 'never silently skipped' in text
PY`
Expected: PASS with no output.

- [ ] **Step 6: Commit the skill workflow update**

```bash
git add .claude/skills/seaweedfs-update/SKILL.md .claude/skills/seaweedfs-update/scripts/compare_xsd.py
git commit -m "docs: define unknown command classification loop"
```

### Task 4: Add regression coverage for persistence-ready command naming data

**Files:**
- Modify: `tests/compare_xsd.bats`
- Test: `tests/compare_xsd.bats`

- [ ] **Step 1: Add a test that proves unknown dotted commands are converted into `args_type` and `element_name` correctly**

```bash
# bats test_tags=unit
@test "compare_xsd.py: reports derived names for dotted unknown commands" {
    local stub
    stub=$(create_compare_xsd_stub_weed)

    PATH="${BATS_TEST_TMPDIR}:$PATH" \
    STUB_COMPARE_XSD_MODE="unknown-dotted" \
    run python3 ./.claude/skills/seaweedfs-update/scripts/compare_xsd.py

    [[ "$status" -eq 0 ]]

    local json_file="${BATS_TEST_TMPDIR}/compare-xsd-dotted.json"
    printf '%s\n' "$output" > "$json_file"

    run python3 - <<'PY' "$json_file"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

item = data["unknown_commands"][0]
assert item["command"] == "filer.rebalance"
assert item["args_type"] == "FilerRebalanceArgs"
assert item["element_name"] == "filer-rebalance-args"
PY

    [[ "$status" -eq 0 ]]
}
```

- [ ] **Step 2: Extend the stub helper with the dotted-command fixture mode**

```bash
        unknown-dotted)
            cat <<'EOF'
SeaweedFS: store billions of files and serve them fast!

The commands are:
    filer.rebalance start filer rebalance worker

Use "weed help [command]" for more information about a command.
EOF
            ;;
```

```bash
if [[ "$1" == "help" && "$2" == "filer.rebalance" ]]; then
    cat <<'EOF'
Usage: weed filer.rebalance -filer=localhost:8888

  Start filer rebalance worker.

Default Parameters:
  -filer string
        filer address
EOF
    exit 0
fi
```

- [ ] **Step 3: Run the compare_xsd BATS file again to verify the new regression passes**

Run: `bats tests/compare_xsd.bats`
Expected: PASS with all compare_xsd tests green.

- [ ] **Step 4: Commit the naming regression test**

```bash
git add tests/compare_xsd.bats tests/helpers/stub-weed-compare-xsd.bash
git commit -m "test: cover unknown command naming metadata"
```

### Task 5: Run full verification and document expected behavior

**Files:**
- Modify: `.claude/skills/seaweedfs-update/SKILL.md`
- Test: `tests/compare_xsd.bats`
- Test: `tests/xsd-validation.bats`

- [ ] **Step 1: Add explicit report wording in `SKILL.md` for classified commands and reruns**

```markdown
3. Output summary:
   ```
   === SeaweedFS Update Report ===

   Version: 4.20 → 4.21
   Commands processed: N
   New commands discovered: X
   Classified automatically: cmd1 -> include, cmd2 -> exclude
   Classification reruns: R
   New Args types created: Y
   Parameters added: Z
   Parameters removed: W
   Parameters changed: V

   Schema updated: xsd/seaweedfs-systemd.xsd
   ```
```

- [ ] **Step 2: Run the focused compare_xsd test file**

Run: `bats tests/compare_xsd.bats`
Expected: PASS.

- [ ] **Step 3: Run the existing XSD validation tests to confirm no schema regression from helper changes**

Run: `bats tests/xsd-validation.bats`
Expected: PASS.

- [ ] **Step 4: Run the full project test suite for final confidence**

Run: `make test`
Expected: PASS with the existing BATS suite plus `tests/compare_xsd.bats` all green.

- [ ] **Step 5: Commit the verification-aligned documentation changes**

```bash
git add .claude/skills/seaweedfs-update/SKILL.md tests/compare_xsd.bats tests/helpers/stub-weed-compare-xsd.bash .claude/skills/seaweedfs-update/scripts/compare_xsd.py
git commit -m "test: verify seaweedfs command classification flow"
```

---

## Self-Review

### Spec coverage

- Structured unknown command evidence in Python: covered by Task 2.
- Claude-side classification loop and rerun behavior: covered by Task 3.
- Interactive ask vs non-interactive fail documentation: covered by Task 3.
- Persistence in include/exclude lists: covered by Task 3.
- Verification and reporting updates: covered by Task 5.

### Placeholder scan

- No `TODO`, `TBD`, or deferred implementation markers remain.
- Every task names exact files and exact commands.
- Test tasks include concrete test code or exact expected assertions.

### Type consistency

- Unknown command JSON fields are consistently named: `command`, `overview_line`, `help_text`, `parameters`, `has_parameters`, `args_type`, `element_name`.
- Command naming helpers consistently use `command_to_args_type()` and `command_to_element()`.

