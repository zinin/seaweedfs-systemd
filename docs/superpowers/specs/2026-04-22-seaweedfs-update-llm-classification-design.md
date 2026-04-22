# SeaweedFS Update Unknown Command Classification Design

## Summary

`/seaweedfs-update` currently relies on `compare_xsd.py` filter lists to decide which `weed` commands participate in XSD updates. When SeaweedFS introduces a new command that is not present in either `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS`, the current workflow logs a warning and skips it. This can produce an incomplete schema update and an auto-generated PR that looks successful while silently omitting support for a new long-running service command.

This design changes the workflow so that Python remains a deterministic data collector, while Claude makes the semantic classification decision. `compare_xsd.py` will report unknown commands with structured evidence. The `/seaweedfs-update` skill will then classify each unknown command into `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS`, persist that decision into `compare_xsd.py`, rerun the comparison, and only then continue with XSD updates.

## Problem

The current behavior has two failure modes:

1. A new long-running service command can be skipped, so `xsd/seaweedfs-systemd.xsd` does not learn about a new service type or args block.
2. The skip is only visible as a warning, which is too weak for an automation path that can create a PR.

The `nfs` command added in SeaweedFS 4.21 is the concrete example that exposed this gap: it was reported as `Unknown commands skipped: nfs`, the schema was not updated for it, and the generated PR still looked like a normal version bump.

## Goals

- Prevent new commands from being silently skipped during `/seaweedfs-update`.
- Keep `compare_xsd.py` simple, deterministic, and free of any LLM calls.
- Let Claude make the semantic decision about whether a new command belongs in `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS`.
- Persist every accepted decision into `compare_xsd.py` so future runs are deterministic.
- Make interactive and non-interactive behavior explicit and safe.

## Non-Goals

- Do not embed Anthropic or any other LLM API client into project Python scripts.
- Do not attempt to auto-classify commands inside Python via regex-only or heuristic-only rules.
- Do not change how known commands are diffed against the schema.
- Do not redesign the XSD update batching flow beyond the unknown-command classification loop.

## Design Principles

1. **Python collects facts; Claude makes judgments.**
2. **Every new command must receive an explicit fate:** include, exclude, or fail the run pending human input.
3. **Persistent lists remain the source of truth.** Claude can update them, but the committed Python file remains the durable classification registry.
4. **Automation must be strict.** A non-interactive run must not create a PR if a new command cannot be confidently classified.

## Proposed Workflow

### Current high-level flow

1. Check latest SeaweedFS version.
2. Download `weed` and regenerate `help.txt`.
3. Run `compare_xsd.py`.
4. Apply XSD changes.
5. Validate and report.

### New high-level flow

1. Check latest SeaweedFS version.
2. Download `weed` and regenerate `help.txt`.
3. Run `compare_xsd.py`.
4. If `unknown_commands` is empty, continue normally.
5. If `unknown_commands` is non-empty, Claude classifies each command using structured evidence from the script output.
6. Claude updates `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS` in `compare_xsd.py`.
7. Claude reruns `compare_xsd.py`.
8. Repeat until there are no unknown commands left, or the run blocks on an unresolved low-confidence decision.
9. Apply XSD changes.
10. Validate and report.

## `compare_xsd.py` Responsibilities

`compare_xsd.py` remains a deterministic comparison script. It is responsible for:

- reading the current XSD,
- listing available `weed` commands,
- parsing `weed help <command>` output,
- comparing known included commands against the schema,
- emitting a JSON report.

It is no longer responsible for making a classification decision about unknown commands.

### Required new output

The JSON report must include a top-level `unknown_commands` array. Each item must contain enough evidence for Claude to make a semantic classification decision without rerunning custom parsing logic.

Proposed shape:

```json
{
  "commands": [...],
  "summary": {
    "added": 0,
    "removed": 0,
    "changed": 0,
    "new_types": 0
  },
  "unknown_commands": [
    {
      "command": "nfs",
      "overview_line": "nfs start NFS server backed by SeaweedFS filer",
      "help_text": "full output of ./weed help nfs",
      "parameters": [
        {"name": "port", "type": "xs:int"},
        {"name": "filer", "type": "xs:string"}
      ],
      "has_parameters": true,
      "args_type": "NfsArgs",
      "element_name": "nfs-args"
    }
  ]
}
```

### Notes on the output contract

- `overview_line` gives Claude the short semantic description from the root `weed` help listing.
- `help_text` gives the full description and usage context.
- `parameters` and `has_parameters` provide structural context.
- `args_type` and `element_name` save the workflow from recomputing naming conversions later.

The script may still print warnings to stderr for visibility, but the workflow must no longer rely on stderr text parsing for unknown-command handling.

## Claude Classification Loop

The semantic decision lives in the `/seaweedfs-update` skill workflow.

For each item in `unknown_commands`, Claude examines:

- command name,
- root help summary line,
- full `weed help <command>` output,
- parameter list.

Claude then decides whether the command is:

- a long-running service suitable for XML/systemd support, so it belongs in `INCLUDE_COMMANDS`, or
- a utility, interactive command, informational command, or one-shot operation, so it belongs in `EXCLUDE_COMMANDS`.

### When Claude is confident

If Claude is confident in the classification:

1. update `compare_xsd.py`,
2. add the command to the correct set,
3. preserve alphabetical ordering,
4. rerun `compare_xsd.py`,
5. continue the update flow.

This makes the decision persistent and ensures the next run is deterministic.

### When Claude is not confident

If Claude is not confident:

- **Interactive mode:** ask the user whether the command belongs in include or exclude, then persist the answer.
- **Non-interactive mode:** stop the run with a clear failure message and do not proceed to PR creation.

This is the critical safety gate that replaces the current weak `warning + skip` behavior.

## Persistence Rules

The durable classification registry remains inside `compare_xsd.py` as `INCLUDE_COMMANDS` and `EXCLUDE_COMMANDS`.

Whenever Claude classifies a command successfully, the result must be written back into one of these sets. The workflow must not rely on transient in-memory decisions only for the current run.

Benefits:

- later runs remain deterministic,
- the command list becomes part of versioned project history,
- reviewers can see and discuss classification decisions as ordinary code changes,
- unknown commands shrink over time instead of repeatedly reappearing.

## Interactive vs Non-Interactive Behavior

### Interactive

Interactive runs may ask the user only when Claude cannot classify a command with sufficient confidence.

Expected flow:

1. show the command name,
2. show the short description and relevant help context,
3. explain why the decision is ambiguous,
4. ask whether to place it in `INCLUDE_COMMANDS` or `EXCLUDE_COMMANDS`,
5. persist the answer,
6. rerun `compare_xsd.py`.

### Non-Interactive

Non-interactive runs must never silently skip a command and must never continue with an unresolved ambiguity.

Expected flow:

1. emit a clear failure reason,
2. identify the unknown command,
3. explain that the command requires classification into include or exclude,
4. stop before XSD update completion and before PR creation.

This ensures automation cannot create a misleading "successful" PR after omitting support for a newly introduced service command.

## Reporting

The final update report should mention command classification activity explicitly.

Suggested additions:

- newly discovered commands,
- commands auto-classified by Claude,
- commands classified by explicit user choice,
- whether any rerun of `compare_xsd.py` was required.

Example summary lines:

```text
New commands discovered: 1
Classified automatically: nfs -> include
Classification reruns: 1
```

If a run fails because of an unresolved low-confidence command, the failure output should name that command directly.

## File-Level Impact

### `.claude/skills/seaweedfs-update/scripts/compare_xsd.py`

Changes:

- extend the JSON output with `unknown_commands`,
- collect root help summary lines for unknown commands,
- capture full help output and parsed parameters for unknown commands,
- remove the current design assumption that unknown commands are merely warned about and skipped.

What stays the same:

- no LLM calls,
- no semantic decision logic,
- no hidden persistence behavior.

### `.claude/skills/seaweedfs-update/SKILL.md`

Changes:

- document the unknown-command classification loop explicitly,
- state that Claude, not Python, classifies new commands,
- document the rerun behavior after persisting a decision,
- document interactive ask vs non-interactive fail.

## Testing Strategy

Testing should cover both the Python report contract and the higher-level workflow behavior.

### Python script tests

Validate that `compare_xsd.py`:

- returns `unknown_commands` in JSON when it sees commands outside both lists,
- includes `overview_line`, `help_text`, `parameters`, `has_parameters`, `args_type`, and `element_name`,
- continues to emit normal schema diff data for known included commands.

### Workflow tests

Validate that `/seaweedfs-update` behavior is documented and reproducible for:

1. unknown command with a confident Claude classification to include,
2. unknown command with a confident Claude classification to exclude,
3. low-confidence unknown command in interactive mode,
4. low-confidence unknown command in non-interactive mode,
5. rerun after persistence, showing that the command is no longer unknown.

## Acceptance Criteria

This design is successful when all of the following are true:

- a new SeaweedFS command cannot be silently skipped anymore,
- project Python scripts remain deterministic and contain no LLM integration,
- Claude receives enough structured evidence to classify a new command without brittle stderr parsing,
- every accepted classification is persisted into `compare_xsd.py`,
- non-interactive automation fails safely on unresolved ambiguity,
- schema update PRs can no longer appear complete while omitting a newly introduced service command.

## Trade-Offs

### Benefits

- clean separation of responsibilities,
- stronger automation safety,
- durable classification history,
- better reviewer visibility.

### Costs

- the workflow now has an extra rerun step when new commands appear,
- the skill orchestration becomes slightly more complex,
- classification quality depends on Claude's judgment and the quality of help text.

These costs are acceptable because the alternative is silently incorrect automation.

## Recommendation

Implement this design by keeping `compare_xsd.py` as a structured evidence producer and moving all semantic classification decisions into the `/seaweedfs-update` skill workflow. This is the simplest design that preserves deterministic project scripts while still allowing correct handling of newly introduced SeaweedFS commands.
