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
    local types=(admin backup filer filer.backup filer.meta.backup
        filer.remote.gateway filer.remote.sync filer.sync iam image master
        master.follower mini mount mq.broker mq.kafka.gateway s3 server
        sftp volume webdav worker)
    local expected=(admin-args backup-args filer-args filer-backup-args
        filer-meta-backup-args filer-remote-gateway-args filer-remote-sync-args
        filer-sync-args iam-args image-args master-args master-follower-args mini-args
        mount-args mq-broker-args mq-kafka-gateway-args s3-args server-args
        sftp-args volume-args webdav-args worker-args)

    for i in "${!types[@]}"; do
        local result="${types[$i]//./-}-args"
        [[ "$result" == "${expected[$i]}" ]]
    done
}

# --- Unit tests: server_ready_ports ---

# bats test_tags=unit
@test "server_ready_ports: weed defaults when no ports are set" {
    ARGS=(-dir=/data)
    run server_ready_ports
    [[ "$status" -eq 0 ]]
    [[ "$output" == "9333 19333 8080 18080" ]]
}

# bats test_tags=unit
@test "server_ready_ports: ports from args, filer enabled, gRPC = port + 10000" {
    ARGS=(-dir=/data -master.port=10001 -volume.port=10101 -filer=true -filer.port=10201 -metricsPort=10301)
    run server_ready_ports
    [[ "$status" -eq 0 ]]
    [[ "$output" == "10001 20001 10101 20101 10201 20201" ]]
}

# bats test_tags=unit
@test "server_ready_ports: explicit gRPC ports win over port + 10000" {
    ARGS=(-master.port=10001 -master.port.grpc=30001 -volume.port=10101 -volume.port.grpc=30101
        -filer=1 -filer.port=10201 -filer.port.grpc=30201)
    run server_ready_ports
    [[ "$output" == "10001 30001 10101 30101 10201 30201" ]]
}

# bats test_tags=unit
@test "server_ready_ports: disabled master and filer add no ports" {
    ARGS=(-master=false -volume.port=10101 -filer=false -filer.port=10201)
    run server_ready_ports
    [[ "$output" == "10101 20101" ]]
}

# bats test_tags=unit
@test "server_ready_ports: filer enabled without port uses weed default 8888" {
    ARGS=(-master=0 -volume=0 -filer=true)
    run server_ready_ports
    [[ "$output" == "8888 18888" ]]
}

# bats test_tags=unit
@test "server_ready_ports: s3, sftp, iam, webdav and mq turn the filer on, as weed does" {
    local flag
    for flag in -s3=true -sftp=true -iam=1 -webdav=true -mq.broker=true -mq.agent=true; do
        ARGS=(-master.port=10001 -volume.port=10101 -filer=false "$flag")
        run server_ready_ports
        [[ "$output" == "10001 20001 10101 20101 8888 18888" ]] || { echo "$flag: $output"; false; }
    done
    ARGS=(-master.port=10001 -volume.port=10101 -s3=false -s3.port=8333)
    run server_ready_ports
    [[ "$output" == "10001 20001 10101 20101" ]]
}

# --- Unit tests: wait_for_ports ---

# bats test_tags=unit
@test "wait_for_ports: returns at once when all ports listen on any address" {
    setup_stub_path
    export STUB_SS_LISTEN="0.0.0.0:10001 [::]:20001 *:10101"
    run wait_for_ports $$ 10001 20001 10101
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Ports listening after 0s: 10001 20001 10101"* ]]
    [[ "$output" != *"Warning"* ]]
}

# bats test_tags=unit
@test "wait_for_ports: a port on another address does not count as a suffix match" {
    setup_stub_path
    export STUB_SS_LISTEN="0.0.0.0:110001 0.0.0.0:20001"
    export SEAWEEDFS_READY_TIMEOUT=0
    run wait_for_ports $$ 10001 20001
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: ports not listening after 0s: 10001;"* ]]
}

# bats test_tags=unit
@test "wait_for_ports: waits for a port that starts listening later" {
    setup_stub_path
    export STUB_SS_LISTEN_FILE="${BATS_TEST_TMPDIR}/listen"
    echo "0.0.0.0:10001" > "$STUB_SS_LISTEN_FILE"
    ( sleep 2; echo "0.0.0.0:10001 [::]:20201" > "$STUB_SS_LISTEN_FILE" ) &
    export SEAWEEDFS_READY_TIMEOUT=10
    run wait_for_ports $$ 10001 20201
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ Ports\ listening\ after\ [1-9][0-9]*s ]]
    [[ "$output" != *"Warning"* ]]
}

# bats test_tags=unit
@test "wait_for_ports: after the timeout warns with missing ports and succeeds" {
    setup_stub_path
    export STUB_SS_LISTEN="0.0.0.0:10001"
    export SEAWEEDFS_READY_TIMEOUT=1
    run wait_for_ports $$ 10001 20201
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: ports not listening after 1s: 20201;"* ]]
}

# bats test_tags=unit
@test "wait_for_ports: the timeout is wall-clock seconds, not loop passes" {
    setup_stub_path
    export STUB_SS_LISTEN=""
    export STUB_SS_DELAY=1.5
    export STUB_SS_CALLS="${BATS_TEST_TMPDIR}/ss-calls"
    export SEAWEEDFS_READY_TIMEOUT=2
    run wait_for_ports $$ 10001
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: ports not listening after 2s: 10001;"* ]]
    # 1.5 s per check + 1 s pause: past 2 s after the second check; counting passes would take three
    [[ "$(wc -l < "$STUB_SS_CALLS")" -eq 2 ]]
}

# bats test_tags=unit
@test "ready_timeout: 45 by default, decimal seconds, anything else falls back to 45" {
    unset SEAWEEDFS_READY_TIMEOUT
    run ready_timeout
    [[ "$output" == "45" ]]

    SEAWEEDFS_READY_TIMEOUT=20 run ready_timeout
    [[ "$output" == "20" ]]

    # a leading zero is still decimal, not octal
    SEAWEEDFS_READY_TIMEOUT=08 run ready_timeout
    [[ "$output" == "8" ]]

    local value
    for value in 45s abc -1 ""; do
        SEAWEEDFS_READY_TIMEOUT=$value run ready_timeout
        [[ "$status" -eq 0 ]]
        [[ "$output" == *"Warning: SEAWEEDFS_READY_TIMEOUT='$value' is not a number of seconds, using 45"* ]] \
            || [[ -z "$value" && "$output" == "45" ]]
        [[ "${lines[-1]}" == "45" ]]
    done
}

# bats test_tags=unit
@test "wait_for_ports: an invalid SEAWEEDFS_READY_TIMEOUT warns and still waits" {
    setup_stub_path
    export STUB_SS_LISTEN="0.0.0.0:10001"
    SEAWEEDFS_READY_TIMEOUT=45s run wait_for_ports $$ 10001
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: SEAWEEDFS_READY_TIMEOUT='45s' is not a number of seconds, using 45"* ]]
    [[ "$output" == *"Ports listening after 0s: 10001"* ]]
}

# bats test_tags=unit
@test "wait_for_ports: exits 1 when weed dies while waiting" {
    setup_stub_path
    export STUB_SS_LISTEN=""
    export SEAWEEDFS_READY_TIMEOUT=10
    sleep 0 &
    local dead=$!
    wait "$dead"
    run wait_for_ports "$dead" 10001
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"weed process died while waiting for ports"* ]]
}

# bats test_tags=unit
@test "wait_for_ports: without ss warns and does not wait" {
    run bash -c 'source "$1"; PATH=/nonexistent; wait_for_ports $$ 10001' _ "${DIST_DIR}/seaweedfs-service.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: ss not found"* ]]
}

# --- Unit tests: server data readiness ---

# bats test_tags=unit
@test "server_http_host: 127.0.0.1 when binding all addresses, else -ip.bind, else -ip" {
    ARGS=(-dir=/data)
    run server_http_host; [[ "$output" == "127.0.0.1" ]]
    ARGS=(-ip.bind=0.0.0.0 -ip=yop)
    run server_http_host; [[ "$output" == "127.0.0.1" ]]
    ARGS=(-ip.bind=::)
    run server_http_host; [[ "$output" == "127.0.0.1" ]]
    ARGS=(-ip=yop -ip.bind=10.0.0.5)
    run server_http_host; [[ "$output" == "10.0.0.5" ]]
    ARGS=(-ip.bind=fd00::5)
    run server_http_host; [[ "$output" == "[fd00::5]" ]]
    # weed: an empty -ip.bind means the -ip address
    ARGS=(-ip=yop)
    run server_http_host; [[ "$output" == "yop" ]]
}

# bats test_tags=unit
@test "server_arg: last value of -NAME= in ARGS, else the default" {
    ARGS=(-master.port=10001 -master=false -master.port.grpc=30001)
    run server_arg master.port 9333; [[ "$output" == "10001" ]]
    run server_arg master true; [[ "$output" == "false" ]]
    run server_arg volume.port 8080; [[ "$output" == "8080" ]]
}

# bats test_tags=unit
@test "master_has_leader: true only when /cluster/status names a leader" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 1 1
    run master_has_leader 127.0.0.1 10001
    [[ "$status" -eq 0 ]]

    stub_master_state "$STUB_CURL_DIR" 10001 10101 "" none 1
    run master_has_leader 127.0.0.1 10001
    [[ "$status" -ne 0 ]]

    # master not answering
    run master_has_leader 127.0.0.1 10002
    [[ "$status" -ne 0 ]]
}

# bats test_tags=unit
@test "volume_registered: the master must know at least the volumes the server has" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 2 2
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -eq 0 ]]

    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 1 2
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -ne 0 ]]

    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" none 2
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -ne 0 ]]

    # an empty volume server counts once it is registered
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 0 0
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -eq 0 ]]

    # the node of another volume server does not count: Url srv:10101 is not ...:1010
    mkdir -p "$STUB_CURL_DIR/1010"
    printf '{"Volumes":[]}' > "$STUB_CURL_DIR/1010/status"
    run volume_registered 127.0.0.1 10001 1010
    [[ "$status" -ne 0 ]]

    # volume server not answering
    rm "$STUB_CURL_DIR/10101/status"
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -ne 0 ]]
}

# bats test_tags=unit
@test "wait_for_server_data: returns at once when the master has a leader and knows the volumes" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 3 3
    ARGS=(-master.port=10001 -volume.port=10101 -filer=true)
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ Master\ has\ a\ leader\ and\ knows\ the\ volumes\ after\ [01]s ]]
    [[ "$output" != *"Warning"* ]]
}

# bats test_tags=unit
@test "wait_for_server_data: waits for the leader and the volume registration" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export SEAWEEDFS_READY_TIMEOUT=15
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "" none 3
    ( sleep 1.5; stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" none 3
      sleep 1.5; stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 3 3 ) &
    ARGS=(-master.port=10001 -volume.port=10101)
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ Master\ has\ a\ leader\ and\ knows\ the\ volumes\ after\ [3-9]s ]]
    [[ "$output" != *"Warning"* ]]
}

# bats test_tags=unit
@test "wait_for_server_data: after the timeout warns which part is missing and succeeds" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export SEAWEEDFS_READY_TIMEOUT=1
    ARGS=(-master.port=10001 -volume.port=10101)
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "" none 3
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: master has no leader after 1s; reporting ready anyway"* ]]

    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 2 3
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: master does not know all volumes of the volume server :10101 after 1s; reporting ready anyway"* ]]
}

# bats test_tags=unit
@test "wait_for_server_data: the timeout counts from the start passed in" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export SEAWEEDFS_READY_TIMEOUT=3
    ARGS=(-master.port=10001 -volume.port=10101)
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "" none 3
    export STUB_CURL_CALLS="${BATS_TEST_TMPDIR}/curl-calls"
    # the ports already took 5 s of the 3 s budget: give up without probing
    local start=$(( ${EPOCHREALTIME/[.,]/} - 5000000 ))
    SECONDS=0
    run wait_for_server_data $$ "$start"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: no time left after the ports to wait for the master leader and volumes; reporting ready anyway"* ]]
    (( SECONDS <= 1 ))
    [[ ! -s "$STUB_CURL_CALLS" ]]
}

# bats test_tags=unit
@test "wait_for_server_data: exits 1 when weed dies while waiting" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export SEAWEEDFS_READY_TIMEOUT=10
    ARGS=(-master.port=10001 -volume.port=10101)
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "" none 3
    sleep 0 &
    local dead=$!
    wait "$dead"
    run wait_for_server_data "$dead" "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"weed process died while waiting for the master"* ]]
}

# bats test_tags=unit
@test "wait_for_server_data: nothing to wait for without a master; the leader only without a volume server" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export STUB_CURL_CALLS="${BATS_TEST_TMPDIR}/curl-calls"
    ARGS=(-master=false -volume.port=10101 -filer=true)
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ ! -s "$STUB_CURL_CALLS" ]]

    # no volume server: a leader is enough, its volumes are not asked for
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" none 0
    ARGS=(-master.port=10001 -volume=false)
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Master has a leader"* ]]
    run grep -q ':10101/' "$STUB_CURL_CALLS"
    [[ "$status" -ne 0 ]]
}

# bats test_tags=unit
@test "wait_for_server_data: without curl or python3 warns and does not wait" {
    run bash -c 'source "$1"; ARGS=(-master.port=10001); PATH=/nonexistent; wait_for_server_data $$ 0' _ "${DIST_DIR}/seaweedfs-service.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: curl not found, not waiting for the master leader and volumes"* ]]
}

# bats test_tags=unit
@test "readiness probes skip ~/.curlrc and proxies: they go to this host" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export STUB_CURL_ARGS="${BATS_TEST_TMPDIR}/curl-args"
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 1 1
    run master_has_leader 127.0.0.1 10001
    [[ "$status" -eq 0 ]]
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$STUB_CURL_ARGS")" -eq 3 ]]
    local line
    while IFS= read -r line; do
        [[ "$line" == "-q "* ]] || { echo "not -q first: $line"; false; }
        [[ "$line" == *" --noproxy * "* ]] || { echo "no --noproxy: $line"; false; }
    done < "$STUB_CURL_ARGS"
}

# bats test_tags=unit
@test "master_has_leader and volume_registered: 401 or 403 means the probe is refused (2)" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 1 1
    echo 401 > "$STUB_CURL_DIR/10001/dir/status.code"
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -eq 2 ]]
    echo 403 > "$STUB_CURL_DIR/10001/cluster/status.code"
    run master_has_leader 127.0.0.1 10001
    [[ "$status" -eq 2 ]]
    # other errors are just "not yet"
    echo 500 > "$STUB_CURL_DIR/10001/cluster/status.code"
    run master_has_leader 127.0.0.1 10001
    [[ "$status" -eq 1 ]]
}

# bats test_tags=unit
@test "volume_registered: with an id the volume server is found by its full Url, not by the port" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" none 3
    local topo='{"Topology":{"DataCenters":[{"Racks":[{"DataNodes":[%s]}]}]}}'
    # another host's volume server on the same port has the volumes, ours is not registered
    printf "$topo" '{"Url":"other:10101","Volumes":5}' > "$STUB_CURL_DIR/10001/dir/status"
    run volume_registered 127.0.0.1 10001 10101 srv:10101
    [[ "$status" -eq 1 ]]
    # without an id any node on the port counts
    run volume_registered 127.0.0.1 10001 10101
    [[ "$status" -eq 0 ]]
    # ours registered after the other one, with fewer volumes than the other
    printf "$topo" '{"Url":"other:10101","Volumes":1},{"Url":"srv:10101","Volumes":3}' > "$STUB_CURL_DIR/10001/dir/status"
    run volume_registered 127.0.0.1 10001 10101 srv:10101
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "wait_for_server_data: looks for its volume server as -ip:port" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export SEAWEEDFS_READY_TIMEOUT=1
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" none 3
    printf '{"Topology":{"DataCenters":[{"Racks":[{"DataNodes":[{"Url":"other:10101","Volumes":3}]}]}]}}' \
        > "$STUB_CURL_DIR/10001/dir/status"
    ARGS=(-ip=srv -ip.bind=0.0.0.0 -master.port=10001 -volume.port=10101)
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: master does not know all volumes of the volume server srv:10101 after 1s"* ]]
}

# bats test_tags=unit
@test "wait_for_server_data: a master that refuses the probes (-whiteList) is not waited for" {
    setup_stub_path
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export SEAWEEDFS_READY_TIMEOUT=10
    stub_master_state "$STUB_CURL_DIR" 10001 10101 "srv:10001.20001" 3 3
    echo 401 > "$STUB_CURL_DIR/10001/dir/status.code"
    ARGS=(-master.port=10001 -volume.port=10101)
    SECONDS=0
    run wait_for_server_data $$ "${EPOCHREALTIME/[.,]/}"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: master or volume server at 127.0.0.1 refuses the readiness probes (HTTP 401/403, -whiteList?); not waiting for the master leader and volumes"* ]]
    (( SECONDS <= 2 ))
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

    # Stub weed listens on nothing: a server gives up waiting for its ports
    # quickly unless a test sets a longer timeout
    export SEAWEEDFS_READY_TIMEOUT=1
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

# bats test_tags=integration
@test "service.sh: server notifies ready only after its ports listen" {
    setup_integration
    create_stub_weed
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"
    export STUB_WEED_SLEEP=8
    export STUB_NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log"
    export STUB_SS_LISTEN_FILE="${BATS_TEST_TMPDIR}/listen"
    export SEAWEEDFS_READY_TIMEOUT=15
    : > "$STUB_SS_LISTEN_FILE"
    # the master already has a leader and knows the volume: only the ports are waited for
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    stub_master_state "$STUB_CURL_DIR" 9333 8080 "localhost:9333.19333" 1 1
    # weed defaults for a server without filer: master 9333/19333, volume 8080/18080
    ( sleep 5; echo "0.0.0.0:9333 [::]:19333 0.0.0.0:8080 [::]:18080" > "$STUB_SS_LISTEN_FILE" ) &

    local fixture
    fixture=$(make_tmp_fixture "${FIXTURES_DIR}/services-minimal.xml")

    run timeout 30 "${DIST_DIR}/seaweedfs-service.sh" test-server "$fixture"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Ports listening after"* ]]
    [[ "$output" != *"Warning"* ]]
    # at the moment of --ready all four ports were listening
    [[ "$(grep -c -- '--ready' "$STUB_NOTIFY_LOG")" -eq 1 ]]
    grep -- '--ready' "$STUB_NOTIFY_LOG" | grep -q -- '\[::\]:18080'
}

# bats test_tags=integration
@test "service.sh: server notifies ready only after the master has a leader and knows its volumes" {
    setup_integration
    create_stub_weed
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"
    export STUB_WEED_SLEEP=20
    export STUB_NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log"
    export STUB_SS_LISTEN="0.0.0.0:9333 [::]:19333 0.0.0.0:8080 [::]:18080"
    export STUB_CURL_DIR="${BATS_TEST_TMPDIR}/curl"
    export STUB_STATE_FILE="${BATS_TEST_TMPDIR}/state"
    export SEAWEEDFS_READY_TIMEOUT=20
    echo "no leader" > "$STUB_STATE_FILE"
    stub_master_state "$STUB_CURL_DIR" 9333 8080 "" none 2
    # the state file changes first, so at notify time it never lags behind the master
    ( sleep 5; echo "leader" > "$STUB_STATE_FILE"
      stub_master_state "$STUB_CURL_DIR" 9333 8080 "localhost:9333.19333" none 2
      sleep 2; echo "volumes" > "$STUB_STATE_FILE"
      stub_master_state "$STUB_CURL_DIR" 9333 8080 "localhost:9333.19333" 2 2 ) &

    local fixture
    fixture=$(make_tmp_fixture "${FIXTURES_DIR}/services-minimal.xml")

    run timeout 40 "${DIST_DIR}/seaweedfs-service.sh" test-server "$fixture"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Ports listening after 0s"* ]]
    [[ "$output" == *"Master has a leader and knows the volumes after"* ]]
    [[ "$output" != *"Warning"* ]]
    [[ "$(grep -c -- '--ready' "$STUB_NOTIFY_LOG")" -eq 1 ]]
    grep -- '--ready' "$STUB_NOTIFY_LOG" | grep -q 'state=\[volumes\]'
}

# bats test_tags=integration
@test "service.sh: server notifies ready anyway when its ports never listen" {
    setup_integration
    create_stub_weed
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"
    export STUB_WEED_SLEEP=8
    export STUB_NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log"
    export STUB_SS_LISTEN=""

    local fixture
    fixture=$(make_tmp_fixture "${FIXTURES_DIR}/services-minimal.xml")

    run timeout 30 "${DIST_DIR}/seaweedfs-service.sh" test-server "$fixture"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Warning: ports not listening after 1s: 9333 19333 8080 18080;"* ]]
    grep -q -- '--ready' "$STUB_NOTIFY_LOG"
}

# bats test_tags=integration
@test "service.sh: filer.sync does not wait for ports" {
    setup_integration
    create_stub_weed
    export STUB_WEED_LOG="${BATS_TEST_TMPDIR}/weed.log"
    export STUB_WEED_SLEEP=5
    export STUB_NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log"
    export STUB_SS_LISTEN=""
    export SEAWEEDFS_READY_TIMEOUT=30

    local fixture
    fixture=$(make_tmp_fixture "${FIXTURES_DIR}/services-filer-sync.xml")

    run timeout 20 "${DIST_DIR}/seaweedfs-service.sh" test-filer-sync "$fixture"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"Ports listening"* ]]
    [[ "$output" != *"Warning"* ]]
    grep -q -- '--ready' "$STUB_NOTIFY_LOG"
}
