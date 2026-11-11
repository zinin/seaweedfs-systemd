# Shared setup for BATS tests

PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist"
FIXTURES_DIR="${PROJECT_ROOT}/tests/fixtures"
XSD_PATH="${PROJECT_ROOT}/xsd/seaweedfs-systemd.xsd"
NS="http://zinin.ru/xml/ns/seaweedfs-systemd"

# Source service.sh functions without running main
source_service_functions() {
    # Source the script — the BASH_SOURCE guard prevents main() from running
    source "${DIST_DIR}/seaweedfs-service.sh"
}

# Source deps.sh functions without running main
source_deps_functions() {
    source "${DIST_DIR}/seaweedfs-deps.sh"
}

# Create a stub weed binary in BATS_TEST_TMPDIR
create_stub_weed() {
    local stub="${BATS_TEST_TMPDIR}/weed"
    cp "${PROJECT_ROOT}/tests/helpers/stub-weed.bash" "$stub"
    chmod +x "$stub"
    echo "$stub"
}

# Create stub scripts in PATH for integration tests.
# command -v does NOT find bash exported functions — only real executables.
# So we create stub scripts instead of using export -f.
setup_stub_path() {
    local stub_bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub_bin"

    # xmllint stub — validates nothing, returns success
    cat > "$stub_bin/xmllint" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$stub_bin/xmllint"

    # systemd-notify stub. With STUB_NOTIFY_LOG set, logs its args, the ports the
    # ss stub reports as listening at that moment and the content of
    # STUB_STATE_FILE (if set), so tests can check what was ready at notify time.
    cat > "$stub_bin/systemd-notify" <<'STUB'
#!/bin/bash
if [[ -n "${STUB_NOTIFY_LOG:-}" ]]; then
    state=""
    [[ -n "${STUB_STATE_FILE:-}" ]] && state=$(cat "$STUB_STATE_FILE" 2>/dev/null || true)
    echo "$* listening=[$(ss -Hltn | awk '{print $4}' | tr '\n' ' ')] state=[$state]" >> "$STUB_NOTIFY_LOG"
fi
exit 0
STUB
    chmod +x "$stub_bin/systemd-notify"

    # curl stub: answers http://HOST:PORT/PATH with the file STUB_CURL_DIR/PORT/PATH and
    # HTTP code 200, or the code in PATH.code next to it; exits 7 (connection refused)
    # if there is no such file. Honours -w with %{http_code} and \n. STUB_CURL_CALLS
    # names a file that gets the URL of every call, STUB_CURL_ARGS one that gets all args.
    cat > "$stub_bin/curl" <<'STUB'
#!/bin/bash
url="" format="" prev=""
for a in "$@"; do
    case "$a" in http://*) url=$a ;; esac
    [[ "$prev" == "-w" ]] && format=$a
    prev=$a
done
[[ -n "${STUB_CURL_CALLS:-}" ]] && echo "$url" >> "$STUB_CURL_CALLS"
[[ -n "${STUB_CURL_ARGS:-}" ]] && echo "$*" >> "$STUB_CURL_ARGS"
rest=${url#http://}
hostport=${rest%%/*}
path=/${rest#*/}
port=${hostport##*:}
file="${STUB_CURL_DIR:-/nonexistent}/${port}${path}"
[[ -f "$file" ]] || exit 7
code=200
[[ -f "$file.code" ]] && code=$(cat "$file.code")
cat "$file"
[[ -n "$format" ]] && printf '%b' "${format//%\{http_code\}/$code}"
exit 0
STUB
    chmod +x "$stub_bin/curl"

    # ss stub: lists local addresses as listening TCP sockets, like `ss -Hltn`.
    # Addresses come from STUB_SS_LISTEN_FILE if set, else from STUB_SS_LISTEN,
    # e.g. "0.0.0.0:9333 [::]:19333 *:8080". STUB_SS_DELAY makes each call slow,
    # STUB_SS_CALLS names a file that gets a line per call.
    cat > "$stub_bin/ss" <<'STUB'
#!/bin/bash
[[ -n "${STUB_SS_CALLS:-}" ]] && echo call >> "$STUB_SS_CALLS"
[[ -n "${STUB_SS_DELAY:-}" ]] && sleep "$STUB_SS_DELAY"
listen=${STUB_SS_LISTEN:-}
if [[ -n "${STUB_SS_LISTEN_FILE:-}" ]]; then
    listen=$(cat "$STUB_SS_LISTEN_FILE" 2>/dev/null || true)
fi
for addr in $listen; do
    echo "LISTEN 0      4096      ${addr}      0.0.0.0:*"
done
STUB
    chmod +x "$stub_bin/ss"

    # systemctl stub
    cat > "$stub_bin/systemctl" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$stub_bin/systemctl"

    # Prepend to PATH so stubs are found before real binaries
    export PATH="${stub_bin}:${PATH}"
}

# Create a stub weed binary for compare_xsd tests.
create_compare_xsd_stub_weed() {
    local stub="${BATS_TEST_TMPDIR}/weed"
    cp "${PROJECT_ROOT}/tests/helpers/stub-weed-compare-xsd.bash" "$stub"
    chmod +x "$stub"
    echo "$stub"
}

# Write curl stub answers (STUB_CURL_DIR layout) for a server whose master listens on
# MPORT and volume server on VPORT:
#   stub_master_state DIR MPORT VPORT LEADER MASTER_VOLUMES LOCAL_VOLUMES
# LEADER — leader address, empty if there is none; MASTER_VOLUMES — volumes the master
# knows for the volume server, "none" if it is not registered; LOCAL_VOLUMES — volumes
# the volume server has.
stub_master_state() {
    local dir=$1 mport=$2 vport=$3 leader=$4 mvols=$5 lvols=$6
    mkdir -p "$dir/$mport/cluster" "$dir/$mport/dir" "$dir/$vport"
    local is_leader=false nodes="" vols="" i
    [[ -n "$leader" ]] && is_leader=true
    printf '{"IsLeader":%s,"Leader":"%s","MaxVolumeId":%s}' \
        "$is_leader" "$leader" "$lvols" > "$dir/$mport/cluster/status"
    if [[ "$mvols" != "none" ]]; then
        nodes=$(printf '{"Url":"srv:%s","PublicUrl":"srv.example:%s","Volumes":%s,"EcShards":0,"Max":10000,"VolumeIds":" 1-%s"}' \
            "$vport" "$vport" "$mvols" "$mvols")
    fi
    printf '{"Topology":{"Max":10000,"Free":9998,"DataCenters":[{"Id":"DefaultDataCenter","Racks":[{"Id":"DefaultRack","DataNodes":[%s]}]}],"Layouts":[]},"Version":"test"}' \
        "$nodes" > "$dir/$mport/dir/status"
    for ((i = 1; i <= lvols; i++)); do
        vols+="${vols:+,}{\"Id\":$i,\"Size\":100,\"Collection\":\"\"}"
    done
    printf '{"DiskStatuses":[{"dir":"/data","all":100,"used":1}],"Version":"test","Volumes":[%s]}' \
        "$vols" > "$dir/$vport/status"
}
