#!/usr/bin/env python3
"""
Compare parameters from ./weed help with current XSD schema.
Outputs a JSON report of additions, removals, and type changes.

The report also surfaces everything that would otherwise drift silently:
  removed_commands   — INCLUDE command that no longer exists in this weed build
  orphan_types       — Args type in the XSD backed by no INCLUDE command
  unknown_types      — flag whose Go type is missing from TYPE_MAP
  skipped_no_flags   — INCLUDE command that exists but declares no flags
"""

import json
import re
import subprocess
import xml.etree.ElementTree as ET

XSD_FILE = "xsd/seaweedfs-systemd.xsd"
NS = "http://www.w3.org/2001/XMLSchema"

# Commands to include (long-running systemd services)
INCLUDE_COMMANDS = {
    "admin", "backup", "filer", "filer.backup", "filer.meta.backup",
    "filer.remote.gateway", "filer.remote.sync", "filer.replicate",
    "filer.sync", "fuse", "iam", "master", "master.follower", "mini",
    "mount", "mq.broker", "mq.kafka.gateway", "nfs", "s3", "server",
    "sftp", "volume", "webdav", "worker",
}

# Commands to exclude (utilities, interactive, informational)
EXCLUDE_COMMANDS = {
    "help", "version",                          # informational
    "shell", "autocomplete", "autocomplete.uninstall",  # interactive
    "benchmark", "fix", "export", "upload", "download", "compact", "update",  # one-shot utilities
    "scaffold", "mq.agent",                     # development/client tools
    "filer.cat", "filer.copy", "filer.meta.tail",  # file utilities
    "filer.sync.verify",                        # one-shot verification utility
}

# Args types kept in the XSD on purpose even though no weed command backs them.
# Every entry is a permanent exception to the orphan check — add with care, and
# only after confirming the type is hand-maintained rather than upstream drift.
MANUAL_ARGS_TYPES: set[str] = set()

# Go type -> XSD type
TYPE_MAP = {
    "int": "xs:int",
    "int64": "xs:long",
    "uint": "xs:unsignedInt",
    "float": "xs:float",
    "float64": "xs:double",
    "string": "xs:string",
    "duration": "xs:duration",
    "value": "xs:string",
}


def command_to_args_type(cmd: str) -> str:
    """filer.backup -> FilerBackupArgs"""
    return "".join(p.capitalize() for p in cmd.split(".")) + "Args"


def command_to_element(cmd: str) -> str:
    """filer.backup -> filer-backup-args"""
    return cmd.replace(".", "-") + "-args"


def get_command_help(cmd: str) -> str:
    """Return raw ./weed help output for one command."""
    result = subprocess.run(["./weed", "help", cmd], capture_output=True, text=True)
    return result.stdout + result.stderr


# A flag declaration is a lone "-name" or "-name <gotype>" on its own line.
# The name pattern is deliberately strict: it must not swallow example lines
# such as `-rdma.enabled=true -rdma.sidecar=localhost:8081` found in help text.
FLAG_RE = re.compile(r"^\s+-([A-Za-z][A-Za-z0-9_.-]*)(?:\s+(\S+))?\s*$", re.MULTILINE)


def parse_weed_help(cmd: str) -> tuple[list[dict], str, list[dict]]:
    """Parse parameters from ./weed help <cmd>.

    Returns (parameters, raw help text, unrecognised Go types). A flag whose Go
    type is absent from TYPE_MAP still yields a parameter — typed xs:string as a
    guess — but is reported so the type mapping can be extended deliberately
    instead of the flag vanishing from the diff.
    """
    output = get_command_help(cmd)
    params = []
    unknown_types = []

    for match in FLAG_RE.finditer(output):
        name = match.group(1)
        go_type = match.group(2)
        if go_type is None:
            xsd_type = "xs:boolean"
        elif go_type in TYPE_MAP:
            xsd_type = TYPE_MAP[go_type]
        else:
            xsd_type = "xs:string"
            unknown_types.append({
                "command": cmd,
                "parameter": name,
                "go_type": go_type,
                "guessed_type": xsd_type,
            })
        params.append({"name": name, "type": xsd_type})

    return sorted(params, key=lambda p: p["name"]), output, unknown_types


def parse_xsd() -> dict[str, list[dict]]:
    """Parse current XSD to extract Args types and their parameters."""
    tree = ET.parse(XSD_FILE)
    root = tree.getroot()
    types = {}

    for ct in root.findall(f"{{{NS}}}complexType"):
        type_name = ct.get("name", "")
        if not type_name.endswith("Args"):
            continue

        params = []
        # Look in xs:all or xs:sequence
        for container_tag in ["all", "sequence"]:
            container = ct.find(f"{{{NS}}}{container_tag}")
            if container is not None:
                for elem in container.findall(f"{{{NS}}}element"):
                    params.append({
                        "name": elem.get("name"),
                        "type": elem.get("type"),
                    })

        types[type_name] = sorted(params, key=lambda p: p["name"])

    return types


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


def main():
    commands, overview_lines = get_available_commands()
    available = set(commands)

    unknown_types = []

    unknown_commands = []
    for cmd in sorted(available - INCLUDE_COMMANDS - EXCLUDE_COMMANDS):
        params, help_text, cmd_unknown_types = parse_weed_help(cmd)
        unknown_types.extend(cmd_unknown_types)
        unknown_commands.append({
            "command": cmd,
            "overview_line": overview_lines.get(cmd, cmd),
            "help_text": help_text,
            "parameters": params,
            "has_parameters": bool(params),
            "args_type": command_to_args_type(cmd),
            "element_name": command_to_element(cmd),
        })

    xsd_types = parse_xsd()

    # An INCLUDE command missing from this build was dropped upstream: its Args
    # type, service-type enum value and choice element are now dead schema.
    removed_commands = [
        {
            "command": cmd,
            "args_type": command_to_args_type(cmd),
            "element_name": command_to_element(cmd),
            "in_xsd": command_to_args_type(cmd) in xsd_types,
        }
        for cmd in sorted(INCLUDE_COMMANDS - available)
    ]

    # An Args type nobody claims: either upstream drift nobody noticed, or a
    # hand-maintained type that belongs in MANUAL_ARGS_TYPES.
    expected_types = {command_to_args_type(c) for c in INCLUDE_COMMANDS} | MANUAL_ARGS_TYPES
    orphan_types = sorted(set(xsd_types) - expected_types)

    report = {
        "commands": [],
        "summary": {"added": 0, "removed": 0, "changed": 0, "new_types": 0},
        "unknown_commands": unknown_commands,
        "removed_commands": removed_commands,
        "orphan_types": orphan_types,
        "unknown_types": unknown_types,
        "skipped_no_flags": [],
    }

    for cmd in sorted(INCLUDE_COMMANDS & available):
        args_type = command_to_args_type(cmd)
        element_name = command_to_element(cmd)
        weed_params, _, cmd_unknown_types = parse_weed_help(cmd)
        unknown_types.extend(cmd_unknown_types)

        if not weed_params:
            report["skipped_no_flags"].append(cmd)
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

        if args_type in xsd_types:
            xsd_params = {p["name"]: p["type"] for p in xsd_types[args_type]}
            weed_params_map = {p["name"]: p["type"] for p in weed_params}

            for name, xsd_t in sorted(xsd_params.items()):
                if name not in weed_params_map:
                    entry["removed"].append({"name": name, "type": xsd_t})
                    report["summary"]["removed"] += 1
                elif weed_params_map[name] != xsd_t:
                    entry["changed"].append({
                        "name": name,
                        "old_type": xsd_t,
                        "new_type": weed_params_map[name],
                    })
                    report["summary"]["changed"] += 1
                else:
                    entry["unchanged"].append(name)

            for name, weed_t in sorted(weed_params_map.items()):
                if name not in xsd_params:
                    entry["added"].append({"name": name, "type": weed_t})
                    report["summary"]["added"] += 1
        else:
            entry["added"] = [{"name": p["name"], "type": p["type"]} for p in weed_params]
            report["summary"]["added"] += len(weed_params)
            report["summary"]["new_types"] += 1

        if entry["added"] or entry["removed"] or entry["changed"] or entry["is_new"]:
            report["commands"].append(entry)

    report["summary"]["removed_commands"] = len(removed_commands)
    report["summary"]["orphan_types"] = len(orphan_types)
    report["summary"]["unknown_types"] = len(unknown_types)
    report["summary"]["unknown_commands"] = len(unknown_commands)
    report["summary"]["skipped_no_flags"] = len(report["skipped_no_flags"])

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
