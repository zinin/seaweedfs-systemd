#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
    source_service_functions
    # Set env vars needed by sourced functions
    export SEAWEEDFS_WEED_BINARY="${BATS_TEST_TMPDIR}/weed"
    export SEAWEEDFS_SCHEMA_PATH="${XSD_PATH}"
}

# --- Unit tests: validate_service_id ---

# bats test_tags=unit
@test "validate_service_id: accepts valid alphanumeric ID" {
    run validate_service_id "my-server-01"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_service_id: accepts ID with dots" {
    run validate_service_id "filer.sync-1"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_service_id: rejects single quote (XPath injection)" {
    run validate_service_id "test']; --bad"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid service ID"* ]]
}

# bats test_tags=unit
@test "validate_service_id: rejects empty string" {
    run validate_service_id ""
    [[ "$status" -ne 0 ]]
}

# bats test_tags=unit
@test "validate_service_id: rejects spaces" {
    run validate_service_id "my server"
    [[ "$status" -ne 0 ]]
}

# --- Unit tests: validate_unix_name ---

# bats test_tags=unit
@test "validate_unix_name: accepts valid username" {
    run validate_unix_name "seaweedfs" "run-user"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_unix_name: accepts empty (optional)" {
    run validate_unix_name "" "run-user"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "validate_unix_name: rejects special chars" {
    run validate_unix_name 'root;rm' "run-user"
    [[ "$status" -ne 0 ]]
}

# --- Unit tests: build_args ---

# bats test_tags=unit
@test "build_args: parses simple args from XML" {
    SERVICE_ID="test-server"
    CONFIG_PATH="${FIXTURES_DIR}/services-minimal.xml"
    build_args "server-args"
    [[ "${#ARGS[@]}" -ge 1 ]]
    [[ "${ARGS[0]}" == "-dir=/data" ]]
}

# bats test_tags=unit
@test "build_args: handles dotted arg names" {
    SERVICE_ID="dotted-server"
    CONFIG_PATH="${FIXTURES_DIR}/services-dotted-args.xml"
    build_args "server-args"

    # Check that dotted names are preserved
    local found_ip_bind=false
    local found_volume_dir_idx=false
    for arg in "${ARGS[@]}"; do
        [[ "$arg" == "-ip.bind=0.0.0.0" ]] && found_ip_bind=true
        [[ "$arg" == "-volume.dir.idx=/data/idx" ]] && found_volume_dir_idx=true
    done
    [[ "$found_ip_bind" == "true" ]]
    [[ "$found_volume_dir_idx" == "true" ]]
}

# bats test_tags=unit
@test "build_args: handles filer.sync dotted args" {
    SERVICE_ID="test-filer-sync"
    CONFIG_PATH="${FIXTURES_DIR}/services-filer-sync.xml"
    build_args "filer-sync-args"

    [[ "${#ARGS[@]}" -eq 4 ]]
    local found_a_proxy=false
    for arg in "${ARGS[@]}"; do
        [[ "$arg" == "-a.filerProxy=true" ]] && found_a_proxy=true
    done
    [[ "$found_a_proxy" == "true" ]]
}

# bats test_tags=unit
@test "build_args: empty args element returns empty array" {
    SERVICE_ID="t-worker"
    CONFIG_PATH="${FIXTURES_DIR}/services-all-types.xml"
    build_args "worker-args"
    [[ "${#ARGS[@]}" -eq 0 ]]
}

# --- Unit tests: type mapping ---

# bats test_tags=unit
@test "type mapping: simple type server -> server-args" {
    local SERVICE_TYPE="server"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "server-args" ]]
}

# bats test_tags=unit
@test "type mapping: dotted type filer.backup -> filer-backup-args" {
    local SERVICE_TYPE="filer.backup"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "filer-backup-args" ]]
}

# bats test_tags=unit
@test "type mapping: triple dot filer.meta.backup -> filer-meta-backup-args" {
    local SERVICE_TYPE="filer.meta.backup"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "filer-meta-backup-args" ]]
}

# bats test_tags=unit
@test "type mapping: mq.kafka.gateway -> mq-kafka-gateway-args" {
    local SERVICE_TYPE="mq.kafka.gateway"
    local ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
    [[ "$ARGS_ELEMENT" == "mq-kafka-gateway-args" ]]
}

# bats test_tags=unit
@test "type mapping: all 22 types produce valid element names" {
    local types=(admin backup db filer filer.backup filer.meta.backup
        filer.remote.gateway filer.remote.sync filer.sync iam master
        master.follower mini mount mq.broker mq.kafka.gateway s3 server
        sftp volume webdav worker)
    local expected=(admin-args backup-args db-args filer-args filer-backup-args
        filer-meta-backup-args filer-remote-gateway-args filer-remote-sync-args
        filer-sync-args iam-args master-args master-follower-args mini-args
        mount-args mq-broker-args mq-kafka-gateway-args s3-args server-args
        sftp-args volume-args webdav-args worker-args)

    for i in "${!types[@]}"; do
        local result="${types[$i]//./-}-args"
        [[ "$result" == "${expected[$i]}" ]]
    done
}

# --- Integration tests ---

# Helper: set up stubs for integration tests
# Adds sudo stub that passes through to the actual command,
# and creates the run-dir expected by fixtures.
setup_integration() {
    setup_stub_path
    local stub_bin="${BATS_TEST_TMPDIR}/bin"

    # sudo stub: skip options, execute command after '--'
    cat > "$stub_bin/sudo" <<'STUB'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --) shift; break ;;
        -*) shift; shift ;;  # skip -u USER, -g GROUP
        *) break ;;
    esac
done
exec "$@"
STUB
    chmod +x "$stub_bin/sudo"

    # Create run-dir in tmpdir
    mkdir -p "${BATS_TEST_TMPDIR}/run-dir"
}

# Generate a fixture with run-dir/config-dir/logs-dir replaced to use tmpdir
make_tmp_fixture() {
    local src=$1
    local tmp_fixture="${BATS_TEST_TMPDIR}/$(basename "$src")"
    sed -e "s|/var/lib/seaweedfs[^<]*|${BATS_TEST_TMPDIR}/run-dir|g" "$src" > "$tmp_fixture"
    echo "$tmp_fixture"
}

# bats test_tags=integration
@test "service.sh: full run with stub weed produces correct args" {
    setup_integration
    create_stub_weed
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"
    # Keep stub alive long enough for wait_for_ready (sleep 0.5 + sleep 3)
    export STUB_WEED_SLEEP=5

    local fixture
    fixture=$(make_tmp_fixture "${FIXTURES_DIR}/services-minimal.xml")

    run timeout 10 "${DIST_DIR}/seaweedfs-service.sh" test-server "$fixture"

    # Check stub weed received the args
    [[ -f "$STUB_WEED_LOG" ]]
    local logged
    logged=$(cat "$STUB_WEED_LOG")
    [[ "$logged" == *"server"* ]]
    [[ "$logged" == *"-dir=/data"* ]]
}

# bats test_tags=integration
@test "service.sh: global args (config-dir, logs-dir) passed before subcommand" {
    setup_integration
    create_stub_weed
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"
    export STUB_WEED_SLEEP=5

    local fixture
    fixture=$(make_tmp_fixture "${FIXTURES_DIR}/services-global-args.xml")

    run timeout 10 "${DIST_DIR}/seaweedfs-service.sh" global-server "$fixture"

    local logged
    logged=$(cat "$STUB_WEED_LOG")
    # Check that global args are present (paths are tmpdir-rewritten by make_tmp_fixture)
    [[ "$logged" == *"-config_dir"* ]]
    [[ "$logged" == *"-logdir"* ]]
    [[ "$logged" == *"server"* ]]
}

# bats test_tags=integration
@test "service.sh: missing config file returns exit 1" {
    setup_integration
    export SEAWEEDFS_WEED_BINARY='/bin/true'

    run "${DIST_DIR}/seaweedfs-service.sh" test-server /nonexistent/config.xml
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Config file not found"* ]]
}

# bats test_tags=integration
@test "service.sh: service not found returns exit 1" {
    setup_integration
    create_stub_weed

    run "${DIST_DIR}/seaweedfs-service.sh" nonexistent-id "${FIXTURES_DIR}/services-minimal.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found in config"* ]]
}

# bats test_tags=integration
@test "service.sh: invalid SERVICE_ID rejected" {
    setup_integration
    export SEAWEEDFS_WEED_BINARY='/bin/true'

    run "${DIST_DIR}/seaweedfs-service.sh" "test'; drop" "${FIXTURES_DIR}/services-minimal.xml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid service ID"* ]]
}
