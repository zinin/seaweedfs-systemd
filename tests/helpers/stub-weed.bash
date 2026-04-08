#!/bin/bash
# Stub weed binary for testing
# Logs all arguments to STUB_WEED_LOG for test assertions
echo "$@" > "${STUB_WEED_LOG:-${BATS_TEST_TMPDIR:-/tmp}/stub-weed.log}"
# Keep process alive briefly for tests that check PID
sleep "${STUB_WEED_SLEEP:-0.1}"
