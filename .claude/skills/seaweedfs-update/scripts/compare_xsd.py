#!/usr/bin/env python3
"""
Compare parameters from ./weed help with current XSD schema.
Outputs a JSON report of additions, removals, and type changes.
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

    unknown_commands = []
    for cmd in sorted(set(commands) - INCLUDE_COMMANDS - EXCLUDE_COMMANDS):
        params, help_text = parse_weed_help(cmd)
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
    report = {"commands": [], "summary": {"added": 0, "removed": 0, "changed": 0, "new_types": 0}, "unknown_commands": unknown_commands}

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
