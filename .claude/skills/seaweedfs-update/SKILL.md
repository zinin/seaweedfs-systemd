---
name: seaweedfs-update
description: Check latest SeaweedFS version on GitHub, download if newer, update XSD schema and ansible vars. Use when updating SeaweedFS, checking for new versions, or synchronizing schema with a new release. Triggers on "update seaweedfs", "new seaweedfs version", "update schema", "update weed", or any request related to SeaweedFS version management.
---

# SeaweedFS Update

## Overview

All-in-one skill for updating SeaweedFS: checks the latest release on GitHub, compares with the current version in `ansible/vars/main.yml`, downloads the binary if needed, generates help documentation, discovers new commands, classifies them automatically when possible, reruns command classification as needed, updates the XSD schema, and opens the PR.

Drift runs in both directions: parameters and commands are also *removed* upstream, and a schema that only ever grows keeps validating configs that can no longer start. Every signal the comparison produces — new commands, removed commands, orphan types, unmapped Go types — must be resolved before the run is considered done.

## When to Use

- Checking if a new SeaweedFS version is available
- Updating SeaweedFS to the latest version
- Regenerating help.txt and updating XSD schema after a new release

## Quick Reference

| File | Purpose |
|------|---------|
| `ansible/vars/main.yml` | Current version (`seaweedfs_version`) — commit this |
| `./weed` | SeaweedFS binary (downloaded, gitignored — never commit) |
| `help.txt` | Generated help documentation (gitignored — never commit) |
| `xsd/seaweedfs-systemd.xsd` | XSD schema to update — commit this |
| `scripts/seaweedfs_update.py` | Download and version management |
| `scripts/compare_xsd.py` | Compare weed help with current XSD, output JSON diff |

## Algorithm

### Step 1: Check Versions and Existing PRs

```bash
python3 .claude/skills/seaweedfs-update/scripts/seaweedfs_update.py --check
```

Exit codes:
- `0` — already up to date, OR update available and no duplicate PR
- `2` — update available but an open PR for the same target version already exists

This combined check also lists any open PR titled `chore: update SeaweedFS to <new_version>` (matched exactly) via `gh pr list`. It prevents the scheduled routine from accumulating duplicate PRs when an earlier run already opened one.

**Interactive mode**:
- Exit 0, "already up to date" — show result, ask user to proceed anyway only if explicitly requested.
- Exit 0, "update available" — proceed.
- Exit 2, existing PR found — surface PR number/URL to the user, ask whether to (a) stop, (b) close the stale PR and rerun, or (c) override with `--force`.

**Non-interactive mode** (cloud routine):
- Exit 0, "already up to date" — stop, no action.
- Exit 0, "update available" — proceed automatically.
- Exit 2, existing PR found — stop. Do NOT create a duplicate PR. Log the existing PR number/URL and exit cleanly. A human will review/merge/close the open PR; the next routine run will reassess.

`--force` overrides the duplicate-PR guard for emergency manual reruns.

### Step 2: Download and Generate Help

```bash
python3 .claude/skills/seaweedfs-update/scripts/seaweedfs_update.py
```

Downloads `weed`, updates `seaweedfs_version` in `ansible/vars/main.yml`, generates `help.txt`.

### Step 3: Compare Parameters

```bash
python3 .claude/skills/seaweedfs-update/scripts/compare_xsd.py
```

Outputs a JSON report with the exact list of added, removed, and changed parameters per Args type. This report is the source of truth for XSD changes — no manual parsing of `./weed help` needed.

Besides `commands[]` and `summary`, the report carries four drift signals. **None of them may be ignored** — each exists because that class of drift used to pass unnoticed:

| Field | Meaning | Handled in |
|-------|---------|------------|
| `unknown_commands` | command in `weed` that is in neither filter list | Step 3.5 |
| `removed_commands` | `INCLUDE_COMMANDS` entry that no longer exists in this `weed` build | Step 3.6 |
| `orphan_types` | Args type in the XSD backed by no `INCLUDE_COMMANDS` entry | Step 3.6 |
| `unknown_types` | flag whose Go type is missing from `TYPE_MAP` (parsed as `xs:string` guess) | Step 3.6 |

`skipped_no_flags` is informational: commands that exist but declare no flags (e.g. `fuse`, `filer.replicate`), so no Args type is generated for them.

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

### Step 3.6: Handle Drift Signals

**`removed_commands`** — the command was dropped upstream (e.g. `nfs` was removed in SeaweedFS by [#9724](https://github.com/seaweedfs/seaweedfs/pull/9724)). Its Args type, `ServiceTypeEnum` value and `xs:choice` element are now dead schema that still validates configs which can never start. For each entry with `in_xsd: true`:

1. Confirm the removal upstream before deleting anything:
   ```bash
   gh api "repos/seaweedfs/seaweedfs/commits?path=weed/command/<cmd>.go&per_page=3" \
     --jq '.[] | "\(.commit.author.date[0:10]) \(.commit.message | split("\n")[0])"'
   ```
   A deletion commit at the top confirms it. If the command merely moved or was renamed, treat it as a rename instead: update `INCLUDE_COMMANDS` and rename the Args type.
2. Remove from the XSD: `<xs:enumeration value="cmd"/>`, `<xs:element name="cmd-args" .../>` in `ServiceType`, and the `CmdArgs` complexType.
3. Remove the command from `INCLUDE_COMMANDS`.
4. Update anything referencing the removed type: `tests/fixtures/services-all-types.xml` and the expected-element list in `tests/seaweedfs-service.bats`.
5. Note it in the report — this is a **breaking schema change** for anyone whose `services.xml` still uses that service type.

Interactive mode: confirm the deletion with the user before step 2. Non-interactive mode: do not delete — report the finding in the PR body and leave the schema untouched, since a breaking change must not land unattended.

**`orphan_types`** — an Args type nobody claims. Same upstream check as above. Either it is drift from a command removed long ago (delete it, same procedure), or it is a hand-maintained type that never came from `weed` — in which case add it to `MANUAL_ARGS_TYPES` in `compare_xsd.py` with a comment explaining why, so it stops being reported.

**`unknown_types`** — SeaweedFS introduced a Go flag type not in `TYPE_MAP`. The parameter is not lost: it is included with an `xs:string` guess. Add the correct mapping to `TYPE_MAP` in `compare_xsd.py` **and** to the Type Mapping tables in this file and `CLAUDE.md`, then rerun `compare_xsd.py`. Never leave the guess in place silently.

### Step 4: Apply Changes to XSD

Base every edit on the JSON report from Step 3 — no re-parsing of `./weed help` needed.

**Small diff** (roughly under 15 parameters and no new Args types, which is the common case): apply the edits directly. Dispatching subagents costs more than the edits themselves.

**Large diff** (many parameters, or one or more new Args types): apply in batches via subagents, 3-4 commands per subagent, run sequentially to avoid file conflicts. Each subagent gets the exact parameter list.

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

1. Validate XSD syntax:
   ```bash
   xmllint --noout xsd/seaweedfs-systemd.xsd
   ```

2. Rerun `compare_xsd.py` — it must report an empty diff and no unhandled drift signals. This is the proof the schema now matches the release.

3. Run the same checks CI runs (`lint`, `validate`, `test` — a few seconds total), so a red CI is not discovered after the PR is opened:
   ```bash
   make all
   ```
   `make test` needs `xmlstarlet` and `bats`. If `xmlstarlet` is missing locally the deps tests fail with unrelated errors — install it (`sudo apt-get install -y xmlstarlet`) or fall back to `make lint validate` and say in the report that `make test` was skipped and why.

4. Output summary:
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
   Removed commands: cmd (schema entries deleted / left for review)
   Orphan types: TypeName (deleted / whitelisted)
   Unknown Go types: gotype -> xs:type (TYPE_MAP extended)

   Schema updated: xsd/seaweedfs-systemd.xsd
   ```

### Step 6: Branch, Commit and PR

Never commit on `master` — the version bump always lands through a PR.

**The PR title must be exactly `chore: update SeaweedFS to <version>`.** Step 1's duplicate guard (`find_existing_open_pr` in `seaweedfs_update.py`) matches this string exactly; any other wording makes the guard blind and the scheduled routine opens a fresh PR every single day.

```bash
git switch -c update-seaweedfs-<version>
git add ansible/vars/main.yml xsd/seaweedfs-systemd.xsd   # never help.txt or weed — both gitignored
git commit    # message format below
git push -u origin update-seaweedfs-<version>
gh pr create --base master --title "chore: update SeaweedFS to <version>" --body "..."
```

Commit message format (matches the existing history):
```
chore: update SeaweedFS to 4.41

- Bump seaweedfs_version 4.38 -> 4.41 in ansible/vars/main.yml
- S3Args: add ip
- MountArgs: add df.logical, windows.gid, windows.uid
```

Stage only the files this skill changed — the working tree may hold unrelated untracked files.

Interactive mode: confirm with the user before pushing. Non-interactive mode: branch, commit, push and open the PR without asking; include the Step 5 report in the PR body.

## Command Filter Lists

`INCLUDE_COMMANDS`, `EXCLUDE_COMMANDS` and `MANUAL_ARGS_TYPES` in `scripts/compare_xsd.py` are the persistent registry — **the code is the source of truth**, read it rather than trusting a copy of the lists here.

Classification criteria:

- **Include** — long-running services that make sense under systemd: `server`, `master`, `volume`, `filer`, `s3`, `mount`, `mq.broker`, `filer.sync`, `worker`, …
- **Exclude** — informational (`version`), interactive (`shell`, `autocomplete`), one-shot utilities (`benchmark`, `fix`, `compact`, `filer.sync.verify`), development/client tools (`scaffold`, `mq.agent`), file utilities (`filer.cat`, `filer.copy`)
- **`MANUAL_ARGS_TYPES`** — Args types deliberately kept in the XSD with no backing `weed` command; each entry needs a comment saying why, otherwise it is drift, not a decision

Registry hygiene:

- Commands that exist but declare no flags are skipped automatically (no empty Args types) and listed under `skipped_no_flags`
- A command removed upstream must be dropped from `INCLUDE_COMMANDS`, not left behind — otherwise its dead Args type lingers in the schema (see Step 3.6)
- Keep every list alphabetically ordered

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

A Go type outside this table is **not** silently dropped: the parameter is kept with an `xs:string` guess and reported in `unknown_types`. Extend `TYPE_MAP` (and this table, and `CLAUDE.md`) rather than shipping the guess.

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

**Command removed upstream** — never treat a vanished command as "no parameters". It shows up in `removed_commands`, and its schema entries must be deleted (Step 3.6). Deleting a service type is a breaking change: interactive mode confirms with the user, non-interactive mode reports instead of deleting.

**Flags with dashes** (`default-partitions`, `schema-registry-url`) — valid flag names, parsed like any other.

## Errors

| Error | Action |
|-------|--------|
| GitHub API failure / rate limit | Retry later or provide version manually |
| `./weed` not found after download | Check network, retry |
| `./weed help` fails for a command | Log error, skip command, continue |
| Invalid XSD after edits | Check XML syntax, fix manually |
| Existing open PR for target version (exit 2) | Stop — merge/close the PR first, or pass `--force` if intentional |
| `removed_commands` / `orphan_types` non-empty | Step 3.6 — confirm upstream, then delete schema entries or whitelist |
| `unknown_types` non-empty | Extend `TYPE_MAP`, rerun `compare_xsd.py` — never ship the `xs:string` guess |
| `make test` fails on missing `xmlstarlet` | Environment, not schema — install it or run `make lint validate` and say so |

## Usage

```
/seaweedfs-update
```

## Workflow

1. `/seaweedfs-update` — checks version and open PRs, downloads, updates the schema, handles drift signals
2. Review changes: `git diff ansible/vars/main.yml xsd/seaweedfs-systemd.xsd`
3. Branch, commit and open the PR (Step 6) — title exactly `chore: update SeaweedFS to <version>`

## Cloud Routine Idempotency

The scheduled routine MUST be idempotent across days: if version 4.X is announced upstream and the routine opens PR #N, the next day's run sees PR #N still open and exits cleanly without opening PR #N+1. Step 1's `--check` returns exit code 2 in this case; the skill must treat that as a normal "skip" outcome, not a failure. Only when PR #N is merged (master catches up) or closed (someone decided not to bump) does the next run resume work.

Idempotency rests entirely on the PR title being exactly `chore: update SeaweedFS to <version>` (Step 6). Reword it and the guard stops seeing yesterday's PR.
