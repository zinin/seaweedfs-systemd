#!/usr/bin/env bats

setup() {
    load helpers/setup.bash
}

# bats test_tags=unit
@test "XSD: services-minimal.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-minimal.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-all-types.xml validates (all 22 types)" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-all-types.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-dotted-args.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-dotted-args.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-filer-sync.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-filer-sync.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-global-args.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-global-args.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-with-dependencies.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-with-dependencies.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-with-dependents.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-with-dependents.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-with-cycle.xml validates (cycles are not XSD-detectable)" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-with-cycle.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-mixed-deps.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-mixed-deps.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-shared-dependent.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-shared-dependent.xml"
    [[ "$status" -eq 0 ]]
}

# bats test_tags=unit
@test "XSD: services-no-deps.xml validates" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-no-deps.xml"
    [[ "$status" -eq 0 ]]
}

# --- Invalid fixtures ---

# bats test_tags=unit
@test "XSD: services-invalid-ref.xml fails keyref validation" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-invalid-ref.xml"
    [[ "$status" -ne 0 ]]
}

# bats test_tags=unit
@test "XSD: services-invalid-type.xml fails enum validation" {
    run xmllint --noout --schema "$XSD_PATH" "${FIXTURES_DIR}/services-invalid-type.xml"
    [[ "$status" -ne 0 ]]
}
