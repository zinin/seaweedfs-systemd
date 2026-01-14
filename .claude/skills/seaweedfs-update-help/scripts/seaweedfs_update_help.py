#!/usr/bin/env python3
"""
SeaweedFS Help Documentation Generator

Downloads the latest SeaweedFS release from GitHub,
extracts the weed executable, and generates help.txt
with documentation for all available commands.

Commands are parsed dynamically from ./weed output.
"""

import os
import re
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen, urlretrieve
import json


def get_latest_release(repo: str) -> str:
    """Get the latest release tag from GitHub API."""
    api_url = f"https://api.github.com/repos/{repo}/releases/latest"
    print(f"Fetching latest release from {api_url}...")

    with urlopen(api_url) as response:
        data = json.loads(response.read().decode())
        tag = data["tag_name"]
        print(f"Latest release: {tag}")
        return tag


def download_release(repo: str, tag: str, filename: str) -> str:
    """Download release archive from GitHub."""
    url = f"https://github.com/{repo}/releases/download/{tag}/{filename}"
    print(f"Downloading {url}...")

    local_path, _ = urlretrieve(url, filename)
    print(f"Downloaded to {local_path}")
    return local_path


def extract_executable(archive_path: str, executable_name: str) -> str:
    """Extract specific executable from tar.gz archive."""
    print(f"Extracting {executable_name} from {archive_path}...")

    with tarfile.open(archive_path, "r:gz") as tar:
        tar.extract(executable_name, filter="data")

    # Make executable
    os.chmod(executable_name, 0o755)
    print(f"Extracted and made executable: {executable_name}")
    return f"./{executable_name}"


def parse_commands(weed_path: str) -> tuple[list[str], str]:
    """
    Parse available commands from weed executable output.

    Runs ./weed without arguments and parses the command list
    from the "The commands are:" section.

    Returns:
        Tuple of (commands list, full overview output)
    """
    print(f"Parsing commands from {weed_path}...")

    result = subprocess.run(
        [weed_path],
        capture_output=True,
        text=True
    )

    # Combine stdout and stderr (weed may output to either)
    output = result.stdout + result.stderr

    # Find the commands section
    # Format:
    # The commands are:
    #
    #     backup      description...
    #     filer       description...
    commands = []
    in_commands_section = False

    for line in output.splitlines():
        if "The commands are:" in line:
            in_commands_section = True
            continue

        if in_commands_section:
            # Commands are indented with spaces, then command name, then spaces, then description
            match = re.match(r'^\s+(\S+)\s+', line)
            if match:
                commands.append(match.group(1))
            # Empty line or "Use" line ends the section
            elif line.strip().startswith("Use ") or (line.strip() == "" and commands):
                if line.strip().startswith("Use "):
                    break

    print(f"Found {len(commands)} commands: {', '.join(commands)}")
    return commands, output


def generate_help(weed_path: str, commands: list[str], overview: str, output_file: str):
    """Generate help.txt with overview and documentation for all commands."""
    print(f"Generating {output_file}...")

    with open(output_file, "w") as f:
        # Write overview section first
        f.write(f"{'=' * 60}\n")
        f.write("SeaweedFS Overview\n")
        f.write(f"{'=' * 60}\n\n")
        f.write(overview)
        f.write("\n\n")

        # Write help for each command
        for cmd in commands:
            print(f"  Running: {weed_path} help {cmd}")

            result = subprocess.run(
                [weed_path, "help", cmd],
                capture_output=True,
                text=True
            )

            # Combine stdout and stderr
            output = result.stdout + result.stderr

            f.write(f"{'=' * 60}\n")
            f.write(f"Command: weed help {cmd}\n")
            f.write(f"{'=' * 60}\n\n")
            f.write(output)
            f.write("\n\n")

    print(f"Generated {output_file} with help for {len(commands)} commands")


def main():
    repo = "seaweedfs/seaweedfs"
    archive_name = "linux_amd64_full.tar.gz"
    executable = "weed"
    output_file = "help.txt"

    # Step 1: Get latest release
    tag = get_latest_release(repo)

    # Step 2: Download release
    archive_path = download_release(repo, tag, archive_name)

    # Step 3: Extract executable
    weed_path = extract_executable(archive_path, executable)

    # Step 4: Parse commands dynamically
    commands, overview = parse_commands(weed_path)

    if not commands:
        print("ERROR: No commands found!", file=sys.stderr)
        sys.exit(1)

    # Step 5: Generate help documentation
    generate_help(weed_path, commands, overview, output_file)

    # Cleanup archive
    os.remove(archive_path)
    print(f"\nDone! Cleaned up {archive_path}")
    print(f"Output: {output_file}")


if __name__ == "__main__":
    main()
