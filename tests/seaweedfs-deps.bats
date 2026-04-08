#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
    source_deps_functions
}

# --- Unit tests: validate_service_refs ---

# bats test_tags=unit
@test "validate_service_refs: accepts valid references" {
    run validate_service_refs "${FIXTURES_DIR}/services-with-dependencies.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_service_refs: catches invalid reference" {
    run validate_service_refs "${FIXTURES_DIR}/services-invalid-ref.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown service reference: nonexistent-service"* ]]
}

# bats test_tags=unit
@test "validate_service_refs: grep -qxF does not match regex-like IDs" {
    # Create fixture with service ID containing dots
    local tmp_config="${BATS_TEST_TMPDIR}/regex-test.xml"
    cat > "$tmp_config" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd">
    <service>
        <id>serviceXa</id>
        <type>filer</type>
        <run-user>sw</run-user>
        <run-group>sw</run-group>
        <run-dir>/tmp</run-dir>
        <dependencies>
            <service>service.a</service>
        </dependencies>
        <filer-args><port>8888</port></filer-args>
    </service>
</services>
XMLEOF

    # "service.a" should NOT match "serviceXa" with fixed-string grep
    run validate_service_refs "$tmp_config"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown service reference: service.a"* ]]
}

# --- Unit tests: detect_cycles ---

# bats test_tags=unit
@test "detect_cycles: finds A->B->A cycle" {
    run detect_cycles "${FIXTURES_DIR}/services-with-cycle.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cycle detected"* ]]
}

# bats test_tags=unit
@test "detect_cycles: no cycle in valid config" {
    run detect_cycles "${FIXTURES_DIR}/services-with-dependencies.xml"
    [[ "$status" -eq 0 ]]
}

# --- Unit tests: generate_dependents_dropin ---

# bats test_tags=unit
@test "generate_dependents_dropin: produces correct systemd unit" {
    local output
    output=$(generate_dependents_dropin "/etc/seaweedfs/services.xml" "mount-a:requires")

    [[ "$output" == *"[Unit]"* ]]
    [[ "$output" == *"Requires=seaweedfs@mount-a.service"* ]]
    [[ "$output" == *"After=seaweedfs@mount-a.service"* ]]
}

# bats test_tags=unit
@test "generate_dependents_dropin: handles binds-to type" {
    local output
    output=$(generate_dependents_dropin "/etc/seaweedfs/services.xml" "mount-a:binds-to")

    [[ "$output" == *"BindsTo=seaweedfs@mount-a.service"* ]]
    [[ "$output" == *"After=seaweedfs@mount-a.service"* ]]
    # Should NOT contain Requires
    [[ "$output" != *"Requires="* ]]
}

# bats test_tags=unit
@test "generate_dependents_dropin: combines multiple services" {
    local output
    output=$(generate_dependents_dropin "/etc/seaweedfs/services.xml" \
        "mount-a:binds-to" "mount-b:requires")

    [[ "$output" == *"BindsTo=seaweedfs@mount-a.service"* ]]
    [[ "$output" == *"Requires=seaweedfs@mount-b.service"* ]]
    [[ "$output" == *"After=seaweedfs@mount-a.service seaweedfs@mount-b.service"* ]]
}

# --- Unit tests: generate_dependencies_dropin ---

# bats test_tags=unit
@test "generate_dependencies_dropin: adds .service suffix to units" {
    local output
    output=$(generate_dependencies_dropin "/etc/seaweedfs/services.xml" "postgresql:requires")

    [[ "$output" == *"Requires=postgresql.service"* ]]
    [[ "$output" == *"After=postgresql.service"* ]]
}

# bats test_tags=unit
@test "generate_dependencies_dropin: preserves .target suffix" {
    local output
    output=$(generate_dependencies_dropin "/etc/seaweedfs/services.xml" "network-online.target:requires")

    [[ "$output" == *"Requires=network-online.target"* ]]
    [[ "$output" == *"After=network-online.target"* ]]
}

# bats test_tags=unit
@test "generate_dependencies_dropin: handles wants type" {
    local output
    output=$(generate_dependencies_dropin "/etc/seaweedfs/services.xml" "local-fs.target:wants")

    [[ "$output" == *"Wants=local-fs.target"* ]]
    [[ "$output" != *"Requires="* ]]
}

# --- Integration tests ---

# bats test_tags=integration
@test "deps.sh check: dry-run creates no files" {
    setup_stub_path
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "$DROPIN_DIR_BASE"

    run "${DIST_DIR}/seaweedfs-deps.sh" check "${FIXTURES_DIR}/services-with-dependents.xml"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Would create"* ]]
    # No actual files should be created
    local count
    count=$(find "$DROPIN_DIR_BASE" -name "seaweedfs.conf" 2>/dev/null | wc -l)
    [[ "$count" -eq 0 ]]
}

# bats test_tags=integration
@test "deps.sh apply: creates drop-in files" {
    setup_stub_path
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "$DROPIN_DIR_BASE"

    run "${DIST_DIR}/seaweedfs-deps.sh" apply "${FIXTURES_DIR}/services-with-dependents.xml"
    [[ "$status" -eq 0 ]]

    # nginx drop-in should exist
    [[ -f "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf" ]]
    # dovecot drop-in should exist
    [[ -f "${DROPIN_DIR_BASE}/dovecot.service.d/seaweedfs.conf" ]]

    # Check content
    local nginx_conf
    nginx_conf=$(cat "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf")
    [[ "$nginx_conf" == *"seaweedfs@test-mount.service"* ]]
}

# bats test_tags=integration
@test "deps.sh apply: shared dependent combines services" {
    setup_stub_path
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "$DROPIN_DIR_BASE"

    run "${DIST_DIR}/seaweedfs-deps.sh" apply "${FIXTURES_DIR}/services-shared-dependent.xml"
    [[ "$status" -eq 0 ]]

    local nginx_conf
    nginx_conf=$(cat "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf")
    # Both mount-a and mount-b should appear
    [[ "$nginx_conf" == *"mount-a"* ]]
    [[ "$nginx_conf" == *"mount-b"* ]]
}

# bats test_tags=integration
@test "deps.sh check: no deps config outputs no-op messages" {
    setup_stub_path

    run "${DIST_DIR}/seaweedfs-deps.sh" check "${FIXTURES_DIR}/services-no-deps.xml"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No dependents found"* ]]
    [[ "$output" == *"No dependencies found"* ]]
}

# bats test_tags=integration
@test "deps.sh check: cycle detected returns exit 1" {
    setup_stub_path

    run "${DIST_DIR}/seaweedfs-deps.sh" check "${FIXTURES_DIR}/services-with-cycle.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Cycle detected"* ]]
}

# bats test_tags=integration
@test "deps.sh check: invalid ref returns exit 1" {
    setup_stub_path

    run "${DIST_DIR}/seaweedfs-deps.sh" check "${FIXTURES_DIR}/services-invalid-ref.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown service reference"* ]]
}

# bats test_tags=integration
@test "deps.sh clean: removes drop-in files" {
    setup_stub_path
    export DROPIN_DIR_BASE="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "${DROPIN_DIR_BASE}/nginx.service.d"
    echo "[Unit]" > "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf"

    run "${DIST_DIR}/seaweedfs-deps.sh" clean
    [[ "$status" -eq 0 ]]
    [[ ! -f "${DROPIN_DIR_BASE}/nginx.service.d/seaweedfs.conf" ]]
}
