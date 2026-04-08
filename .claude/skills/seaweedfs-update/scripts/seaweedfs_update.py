#!/usr/bin/env python3
"""
SeaweedFS Update Script

Downloads the latest SeaweedFS release from GitHub, updates the version
in ansible/vars/main.yml, and generates help.txt documentation.

Usage:
    python3 seaweedfs_update.py           # Full update
    python3 seaweedfs_update.py --check   # Only check versions
"""

import json
import os
import re
import subprocess
import sys
import tarfile
from urllib.request import urlopen, urlretrieve

REPO = "seaweedfs/seaweedfs"
ARCHIVE_NAME = "linux_amd64_full.tar.gz"
EXECUTABLE = "weed"
HELP_FILE = "help.txt"
ANSIBLE_VARS = "ansible/vars/main.yml"


def get_latest_release() -> str:
    """Get the latest release tag from GitHub API."""
    api_url = f"https://api.github.com/repos/{REPO}/releases/latest"
    with urlopen(api_url) as response:
        data = json.loads(response.read().decode())
        return data["tag_name"]


def get_current_version() -> str | None:
    """Read current version from ansible/vars/main.yml."""
    if not os.path.exists(ANSIBLE_VARS):
        return None
    with open(ANSIBLE_VARS) as f:
        for line in f:
            match = re.match(r'^seaweedfs_version:\s*(.+)$', line)
            if match:
                return match.group(1).strip()
    return None


def update_ansible_version(version: str):
    """Update seaweedfs_version in ansible/vars/main.yml."""
    with open(ANSIBLE_VARS) as f:
        content = f.read()
    content = re.sub(
        r'^(seaweedfs_version:\s*).*$',
        rf'\g<1>{version}',
        content,
        flags=re.MULTILINE
    )
    with open(ANSIBLE_VARS, 'w') as f:
        f.write(content)
    print(f"Updated {ANSIBLE_VARS}: seaweedfs_version: {version}")


def download_release(tag: str) -> str:
    """Download release archive from GitHub."""
    url = f"https://github.com/{REPO}/releases/download/{tag}/{ARCHIVE_NAME}"
    print(f"Downloading {url}...")
    local_path, _ = urlretrieve(url, ARCHIVE_NAME)
    print(f"Downloaded to {local_path}")
    return local_path


def extract_executable(archive_path: str) -> str:
    """Extract weed executable from tar.gz archive."""
    print(f"Extracting {EXECUTABLE} from {archive_path}...")
    with tarfile.open(archive_path, "r:gz") as tar:
        tar.extract(EXECUTABLE, filter="data")
    os.chmod(EXECUTABLE, 0o755)
    print(f"Extracted and made executable: {EXECUTABLE}")
    return f"./{EXECUTABLE}"


def parse_commands(weed_path: str) -> tuple[list[str], str]:
    """Parse available commands from weed executable output."""
    result = subprocess.run([weed_path], capture_output=True, text=True)
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

    print(f"Found {len(commands)} commands: {', '.join(commands)}")
    return commands, output


def generate_help(weed_path: str, commands: list[str], overview: str):
    """Generate help.txt with documentation for all commands."""
    print(f"Generating {HELP_FILE}...")

    with open(HELP_FILE, "w") as f:
        f.write(f"{'=' * 60}\n")
        f.write("SeaweedFS Overview\n")
        f.write(f"{'=' * 60}\n\n")
        f.write(overview)
        f.write("\n\n")

        for cmd in commands:
            print(f"  Running: {weed_path} help {cmd}")
            result = subprocess.run(
                [weed_path, "help", cmd],
                capture_output=True,
                text=True
            )
            output = result.stdout + result.stderr
            f.write(f"{'=' * 60}\n")
            f.write(f"Command: weed help {cmd}\n")
            f.write(f"{'=' * 60}\n\n")
            f.write(output)
            f.write("\n\n")

    print(f"Generated {HELP_FILE} with help for {len(commands)} commands")


def main():
    check_only = "--check" in sys.argv

    # Step 1: Get versions
    current = get_current_version()
    print(f"Current version: {current or 'not set'}")

    latest_tag = get_latest_release()
    print(f"Latest release:  {latest_tag}")

    if current and current == latest_tag:
        print("Already up to date.")
        if check_only:
            return
        print("Use --force to re-download anyway.")
        if "--force" not in sys.argv:
            sys.exit(0)

    if current != latest_tag:
        print("Update available!")

    if check_only:
        return

    # Step 2: Download and extract
    archive_path = download_release(latest_tag)
    weed_path = extract_executable(archive_path)

    # Step 3: Update ansible vars
    update_ansible_version(latest_tag)

    # Step 4: Generate help.txt
    commands, overview = parse_commands(weed_path)
    if not commands:
        print("ERROR: No commands found!", file=sys.stderr)
        sys.exit(1)

    generate_help(weed_path, commands, overview)

    # Cleanup archive
    os.remove(archive_path)
    print(f"\nDone! Cleaned up {archive_path}")
    print(f"Binary: ./{EXECUTABLE}")
    print(f"Documentation: {HELP_FILE}")
    print(f"Version updated in: {ANSIBLE_VARS}")


if __name__ == "__main__":
    main()
