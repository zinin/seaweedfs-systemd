#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
}

setup_compare_xsd_workspace() {
    local workdir="${BATS_TEST_TMPDIR}/compare-xsd"
    mkdir -p "$workdir"
    ln -s "${PROJECT_ROOT}/xsd" "$workdir/xsd"
    cp "$(create_compare_xsd_stub_weed)" "$workdir/weed"
    chmod +x "$workdir/weed"
    echo "$workdir"
}

# bats test_tags=unit
@test "compare_xsd.py: reports unknown command with structured evidence" {
    local workdir
    workdir=$(setup_compare_xsd_workspace)

    cd "$workdir"
    STUB_COMPARE_XSD_MODE="unknown-nfs" run python3 "${PROJECT_ROOT}/.claude/skills/seaweedfs-update/scripts/compare_xsd.py"

    [[ "$status" -eq 0 ]]

    local json_file="${BATS_TEST_TMPDIR}/compare-xsd.json"
    printf '%s\n' "$output" > "$json_file"

    run python3 - <<'PY' "$json_file"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

assert "unknown_commands" in data, data
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
    local workdir
    workdir=$(setup_compare_xsd_workspace)

    cd "$workdir"
    STUB_COMPARE_XSD_MODE="known-excluded-only" run python3 "${PROJECT_ROOT}/.claude/skills/seaweedfs-update/scripts/compare_xsd.py"

    [[ "$status" -eq 0 ]]

    local json_file="${BATS_TEST_TMPDIR}/compare-xsd-excluded.json"
    printf '%s\n' "$output" > "$json_file"

    run python3 - <<'PY' "$json_file"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

assert data.get("unknown_commands") == [], data
PY

    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "compare_xsd.py: reports derived names for dotted unknown commands" {
    local workdir
    workdir=$(setup_compare_xsd_workspace)

    cd "$workdir"
    STUB_COMPARE_XSD_MODE="unknown-dotted" run python3 "${PROJECT_ROOT}/.claude/skills/seaweedfs-update/scripts/compare_xsd.py"

    [[ "$status" -eq 0 ]]

    local json_file="${BATS_TEST_TMPDIR}/compare-xsd-dotted.json"
    printf '%s\n' "$output" > "$json_file"

    run python3 - <<'PY' "$json_file"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

unknown = data["unknown_commands"]
assert len(unknown) == 1, unknown
item = unknown[0]
assert item["command"] == "filer.rebalance"
assert item["args_type"] == "FilerRebalanceArgs"
assert item["element_name"] == "filer-rebalance-args"
PY

    [[ "$status" -eq 0 ]]
}
