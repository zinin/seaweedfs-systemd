#!/usr/bin/env python3
"""
Compare parameters from ./weed help with current XSD schema.
Outputs a JSON report of additions, removals, and type changes.
"""

import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

XSD_FILE = "xsd/seaweedfs-systemd.xsd"
NS = "http://www.w3.org/2001/XMLSchema"

# Commands to include (long-running systemd services)
INCLUDE_COMMANDS = {
    "admin", "backup", "filer", "filer.backup", "filer.meta.backup",
    "filer.remote.gateway", "filer.remote.sync", "filer.replicate",
    "filer.sync", "fuse", "iam", "master", "master.follower", "mini",
    "mount", "mq.broker", "mq.kafka.gateway", "s3", "server", "sftp",
    "volume", "webdav", "worker",
}

# Commands to exclude (utilities, interactive, informational)
EXCLUDE_COMMANDS = {
    "help", "version",                          # informational
    "shell", "autocomplete", "autocomplete.uninstall",  # interactive
    "benchmark", "fix", "export", "upload", "download", "compact", "update",  # one-shot utilities
    "scaffold", "mq.agent",                     # development/client tools
    "filer.cat", "filer.copy", "filer.meta.tail",  # file utilities
}

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


def parse_weed_help(cmd: str) -> list[dict]:
    """Parse parameters from ./weed help <cmd>."""
    result = subprocess.run(
        ["./weed", "help", cmd], capture_output=True, text=True
    )
    output = result.stdout + result.stderr
    params = []

    for match in re.finditer(
        r"^\s+-(\S+?)(?:\s+(int64|int|uint|float64|float|string|duration|value))?\s*$",
        output,
        re.MULTILINE,
    ):
        name = match.group(1)
        go_type = match.group(2)

        if go_type:
            xsd_type = TYPE_MAP.get(go_type, "xs:string")
        else:
            xsd_type = "xs:boolean"

        params.append({"name": name, "type": xsd_type})

    return sorted(params, key=lambda p: p["name"])


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


def get_available_commands() -> list[str]:
    """Get all commands from ./weed and warn about unknown ones."""
    result = subprocess.run(["./weed"], capture_output=True, text=True)
    output = result.stdout + result.stderr
    commands = []
    in_commands_section = False

    for line in output.splitlines():
        if "The commands are:" in line:
            in_commands_section = True
            continue
        if in_commands_section:
            match = re.match(r'^\s+(\S+)\s+', line)
            if match:
                commands.append(match.group(1))
            elif line.strip().startswith("Use ") or (line.strip() == "" and commands):
                if line.strip().startswith("Use "):
                    break

    unknown = set(commands) - INCLUDE_COMMANDS - EXCLUDE_COMMANDS
    if unknown:
        print(f"WARNING: Unknown commands (not in include/exclude): {', '.join(sorted(unknown))}", file=sys.stderr)

    return commands


def main():
    get_available_commands()  # warn about unknown commands

    xsd_types = parse_xsd()
    report = {"commands": [], "summary": {"added": 0, "removed": 0, "changed": 0, "new_types": 0}}

    for cmd in sorted(INCLUDE_COMMANDS):
        args_type = command_to_args_type(cmd)
        element_name = command_to_element(cmd)
        weed_params = parse_weed_help(cmd)

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

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
