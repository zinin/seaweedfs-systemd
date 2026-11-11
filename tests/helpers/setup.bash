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

    # systemd-notify stub. With STUB_NOTIFY_LOG set, logs its args and the
    # ports the ss stub reports as listening at that moment.
    cat > "$stub_bin/systemd-notify" <<'STUB'
#!/bin/bash
if [[ -n "${STUB_NOTIFY_LOG:-}" ]]; then
    echo "$* listening=[$(ss -Hltn | awk '{print $4}' | tr '\n' ' ')]" >> "$STUB_NOTIFY_LOG"
fi
exit 0
STUB
    chmod +x "$stub_bin/systemd-notify"

    # ss stub: lists local addresses as listening TCP sockets, like `ss -Hltn`.
    # Addresses come from STUB_SS_LISTEN_FILE if set, else from STUB_SS_LISTEN,
    # e.g. "0.0.0.0:9333 [::]:19333 *:8080".
    cat > "$stub_bin/ss" <<'STUB'
#!/bin/bash
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
