# Tests and CI for seaweedfs-systemd

## Overview

Add BATS tests, shellcheck linting, XSD validation, and GitHub Actions CI to the project.
Fix security and correctness bugs in `dist/seaweedfs-service.sh` discovered during review.

## 1. Bug Fixes in dist/seaweedfs-service.sh

### 1.1 Add `set -euo pipefail`

Add after shebang, matching `deps.sh` convention.

### 1.2 Sanitize SERVICE_ID

Current code injects `$SERVICE_ID` directly into XPath expressions (line 59):
```bash
SERVICE_TYPE=$(xmlstarlet sel ... -v "//x:service[x:id='$SERVICE_ID']/x:type" ...)
```

Fix: validate at entry point with regex:
```bash
if [[ ! "$SERVICE_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Invalid service ID '$SERVICE_ID'"
    exit 1
fi
```

### 1.3 Replace case block with computed mapping

Lines 162-230: 70-line case block maps SERVICE_TYPE to args element name.
All 21 entries follow the same rule: replace `.` with `-`, append `-args`.
The case block also misses the `iam` type present in XSD.

Replace with:
```bash
ARGS_ELEMENT="${SERVICE_TYPE//./-}-args"
ARGS=$(build_args "$ARGS_ELEMENT")
```

XSD already validates that SERVICE_TYPE is from the enum, so "unknown type" is caught at xmllint stage.

Additionally, validate SERVICE_TYPE with regex as defense-in-depth (protects against XPath injection
via `$args_path` if xmllint is ever stubbed or bypassed):
```bash
if [[ ! "$SERVICE_TYPE" =~ ^[a-zA-Z][a-zA-Z0-9.]*$ ]]; then
    echo "Error: Invalid service type '$SERVICE_TYPE'"
    exit 1
fi
```

### 1.4 Remove eval, switch to arrays

Current `run_weed()` takes a string command and uses `eval` (line 134).
This is a command injection risk since XML values flow into the command string.

#### build_args refactor

Return results via global array instead of echo:
```bash
build_args() {
    local args_path=$1
    ARGS=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ARGS+=("$line")
    done < <(xmlstarlet sel -N x="$NS" \
        -t -m "//x:service[x:id='$SERVICE_ID']/x:$args_path/*" \
        -v "concat('-', local-name(), '=', .)" -n "$CONFIG_PATH")
}
```

Note: `local-name()` instead of `name()` to avoid namespace prefix issues.

#### Command assembly as array

```bash
CMD=()
if [[ -n "$RUN_USER" && -n "$RUN_GROUP" ]]; then
    CMD+=(sudo -u "$RUN_USER" -g "$RUN_GROUP" --)
fi
CMD+=("$WEED_BINARY")
[[ -n "$CONFIG_DIR" ]] && CMD+=(-config_dir "$CONFIG_DIR")
[[ -n "$LOGS_DIR" ]] && CMD+=(-logdir "$LOGS_DIR")
CMD+=("$SERVICE_TYPE")
[[ ${#ARGS[@]} -gt 0 ]] && CMD+=("${ARGS[@]}")
```

Note: guard `${#ARGS[@]} -gt 0` prevents "unbound variable" error with `set -u` on bash < 4.4
when args element is empty (e.g. `<worker-args/>`).

#### Launch without eval

```bash
if [[ -n "$RUN_DIR" ]]; then
    (cd "$RUN_DIR" && exec "${CMD[@]}") &
else
    "${CMD[@]}" &
fi
WEED_PID=$!
```

`run_weed()` no longer takes a string argument; it uses `CMD` array directly.

### 1.5 Fix xmllint + set -e incompatibility

Lines 52-56: `xmllint` runs as a standalone statement, then `$?` is checked.
With `set -e`, the script exits on line 52 if xmllint fails, never reaching the if.

Fix:
```bash
if ! xmllint --noout --schema "$SCHEMA_PATH" "$CONFIG_PATH"; then
    echo "Error: XML configuration file does not conform to the schema."
    exit 1
fi
```

### 1.6 Validate RUN_USER/RUN_GROUP

Line 233 silently ignores if only one of RUN_USER/RUN_GROUP is set, causing the service
to run as root instead of the intended user. Also, values flow into `sudo` without sanitization.

Fix: validate with regex and error on partial config:
```bash
# Validate RUN_USER/RUN_GROUP format
validate_unix_name() {
    local name=$1 field=$2
    if [[ -n "$name" && ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Invalid $field '$name'"
        exit 1
    fi
}
validate_unix_name "$RUN_USER" "run-user"
validate_unix_name "$RUN_GROUP" "run-group"

# Error on partial config (not warning — silent root execution is dangerous)
if [[ -n "$RUN_USER" && -z "$RUN_GROUP" ]] || [[ -z "$RUN_USER" && -n "$RUN_GROUP" ]]; then
    echo "Error: Both run-user and run-group must be set together"
    exit 1
fi
```

### 1.7 Fix wait_for_ready false READY

`wait_for_ready` checks PID once at 0.5s, then sleeps 3s and sends READY without rechecking.
If the process dies during sleep, systemd receives a false READY notification.

Fix: recheck PID before every `systemd-notify --ready` and in mountpoint loop:
```bash
# For non-mount: recheck before notify
sleep 3
if ! kill -0 "$pid" 2>/dev/null; then
    echo "Error: weed process died before ready"
    exit 1
fi
systemd-notify --ready

# For mount: check PID each iteration
for i in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Error: weed process died while waiting for mount"
        exit 1
    fi
    if mountpoint -q "$mount_dir"; then
        echo "Mount point ready after ${i}s"
        systemd-notify --ready
        return 0
    fi
    sleep 1
done
```

### 1.8 Extract NS constant

### 1.8 Extract NS constant

Replace 6 inline occurrences of `http://zinin.ru/xml/ns/seaweedfs-systemd` with:
```bash
NS="http://zinin.ru/xml/ns/seaweedfs-systemd"
```

Matches the pattern already used in `deps.sh`.

## 2. Bug Fixes in dist/seaweedfs-deps.sh

### 2.1 Validate unit names (path traversal prevention)

Unit names from XML flow directly into file paths (`/etc/systemd/system/${unit}.service.d/`).
A malicious unit name with `/` or `..` could write files outside the target directory.

Fix: validate all unit names and service IDs used in path construction:
```bash
validate_unit_name() {
    local name=$1
    if [[ ! "$name" =~ ^[a-zA-Z0-9@._:-]+$ ]]; then
        echo "Error: Invalid unit name '$name'"
        return 1
    fi
}
```

### 2.2 Support all systemd unit suffixes

Current code only handles `.service` and `.target`, auto-appending `.service` to everything else.
This breaks `.socket`, `.mount`, `.timer`, `.path` units.

Fix: recognize all common systemd suffixes:
```bash
# Check if unit name already has a known suffix
has_unit_suffix() {
    local name=$1
    [[ "$name" =~ \.(service|target|socket|mount|timer|path|slice|scope)$ ]]
}

# Add .service only if no suffix present
if ! has_unit_suffix "$unit"; then
    unit="${unit}.service"
fi
```

Also update `clean_dropins` to search for all `*.d/seaweedfs.conf` patterns, not just `*.service.d`.

### 2.3 Fix grep regex injection

Line 55: `grep -qx "$ref"` treats `$ref` as regex. A service ID containing `.` (e.g., hypothetical `service.a`) would match `serviceXa`.

Fix: use `grep -qxF` for fixed-string matching.

### 2.4 Fix return value overflow

Line 61: `return $errors` wraps at 256 (shell return values 0-255). >255 errors would return 0 = false success.

Fix:
```bash
return $((errors > 0 ? 1 : 0))
```

## 3. Test Infrastructure

### 3.1 File structure

```
tests/
  seaweedfs-service.bats      # unit + integration tests for service.sh
  seaweedfs-deps.bats          # unit + integration tests for deps.sh
  xsd-validation.bats          # XSD validation of fixtures
  helpers/
    setup.bash                 # shared setup/teardown, constants
    stub-weed.bash             # stub weed binary
  fixtures/
    # Existing
    services-with-dependencies.xml
    services-with-dependents.xml
    services-with-cycle.xml
    services-invalid-ref.xml
    # New - valid
    services-minimal.xml           # one server, no optional fields, no deps
    services-all-types.xml         # all 22 service types
    services-dotted-args.xml       # args with dots: ip.bind, filer.localSocket, volume.dir.idx
    services-filer-sync.xml        # filer.sync type with dotted args (a.filerProxy)
    services-global-args.xml       # service with config-dir and logs-dir
    services-mixed-deps.xml        # both <service> and <unit> deps + dependency-type
    services-shared-dependent.xml  # two services with dependents pointing to same unit
    services-no-deps.xml           # services without any dependencies
    # New - invalid
    services-invalid-type.xml      # unknown service type, fails XSD
```

### 3.2 helpers/setup.bash

- `PROJECT_ROOT`, `FIXTURES_DIR`, `DIST_DIR` path constants
- `NS` namespace constant
- `source_service_functions()` — sources service.sh functions without running main (BASH_SOURCE guard)
- `create_stub_weed()` — creates executable stub in `$BATS_TEST_TMPDIR` that logs args to file
- `setup_stub_path()` — creates stub scripts for `xmllint`, `systemd-notify`, `systemctl` in
  `$BATS_TEST_TMPDIR/bin` and prepends to PATH. This approach is required because `command -v`
  does not find bash exported functions — only real executables in PATH.

### 3.3 helpers/stub-weed.bash

```bash
#!/bin/bash
echo "$@" > "${STUB_WEED_LOG:-/tmp/stub-weed.log}"
sleep "${STUB_WEED_SLEEP:-0.1}"
```

### 3.4 seaweedfs-service.bats

#### Unit tests (tag: unit)

- `build_args` parses arguments from XML into array
- `build_args` handles dotted arg names (ip.bind, volume.dir.idx)
- `build_args` handles values with spaces
- Type mapping: `filer.backup` -> `filer-backup-args`, `mq.broker` -> `mq-broker-args`
- Type mapping works for all 22 types from XSD
- SERVICE_ID sanitization: valid IDs pass, injection attempts rejected
- RUN_USER/RUN_GROUP: warning when only one is set
- NS constant used consistently

#### Integration tests (tag: integration)

- Full run with stub weed: stub receives correct arguments
- Server with global args (config-dir, logs-dir) passed correctly
- Filer.sync with dotted args: correct command line generated
- Error: missing config file -> exit 1
- Error: service not found -> exit 1
- Error: invalid XML -> exit 1 (requires xmllint)

### 3.5 seaweedfs-deps.bats

#### Unit tests (tag: unit)

- `validate_service_refs` catches invalid references (services-invalid-ref.xml)
- `validate_service_refs` with `grep -qxF` doesn't match regex-like IDs
- `detect_cycles` finds cycle A->B->A (services-with-cycle.xml)
- `generate_dependents_dropin` produces correct systemd [Unit] section
- `generate_dependencies_dropin` produces correct systemd [Unit] section
- `generate_dependents_dropin` handles multiple services pointing to same unit

#### Integration tests (tag: integration)

- `check` (dry-run): shows planned actions, creates no files
- `apply`: creates drop-in files in tmpdir (override DROPIN_DIR_BASE)
- `apply` with shared dependent: nginx gets combined drop-in from both services
- `clean`: removes drop-in files from tmpdir
- Config with no deps: "No dependencies found" message, no files created
- Fixture with cycle -> exit 1
- Fixture with invalid ref -> exit 1

### 3.6 xsd-validation.bats

- All valid fixtures pass XSD validation
- `services-invalid-ref.xml` fails XSD keyref validation
- `services-invalid-type.xml` fails XSD enum validation
- `services-all-types.xml` passes — confirms XSD knows all 22 types

Convention: files matching `services-invalid-*.xml` are skipped by `make validate` and tested in BATS as expected failures.

## 4. Makefile

```makefile
SHELL := /bin/bash

SCRIPTS := dist/seaweedfs-service.sh dist/seaweedfs-deps.sh
XSD := xsd/seaweedfs-systemd.xsd
VALID_FIXTURES := $(filter-out %invalid-%.xml, $(wildcard tests/fixtures/*.xml))

.PHONY: test test-unit test-integration lint validate all

all: lint validate test

lint:
	shellcheck $(SCRIPTS)

validate:
	@for f in $(VALID_FIXTURES); do \
	    echo "Validating $$f..."; \
	    xmllint --noout --schema $(XSD) "$$f" || exit 1; \
	done

test:
	bats tests/

test-unit:
	bats --filter-tags unit tests/

test-integration:
	bats --filter-tags integration tests/
```

Naming convention: invalid fixtures contain `invalid` in the filename (e.g. `services-invalid-ref.xml`).
They are excluded from `make validate` via `$(filter-out %invalid-%.xml, ...)` and tested
as expected failures in `xsd-validation.bats`.

## 5. GitHub Actions

File: `.github/workflows/test.yml`

```yaml
name: Test
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y xmlstarlet libxml2-utils shellcheck
      - name: Install bats
        run: |
          git clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core.git /tmp/bats
          sudo /tmp/bats/install.sh /usr/local
      - run: make lint
      - run: make validate
      - run: make test
```

Bats installed from git with pinned version (not apt) to ensure tag filtering support (`--filter-tags`)
and reproducible CI builds.

## Summary of all changes

| Area | Files | What |
|------|-------|------|
| Bug fixes | `dist/seaweedfs-service.sh` | 8 fixes: set -euo, sanitize ID, validate SERVICE_TYPE, computed mapping, remove eval/arrays, xmllint+set-e, validate+error user/group, fix wait_for_ready PID recheck, NS constant |
| Bug fixes | `dist/seaweedfs-deps.sh` | 4 fixes: validate unit names (path traversal), support all systemd suffixes, grep -qxF, return overflow |
| Tests | `tests/*.bats`, `tests/helpers/` | 3 BATS test files, 2 helpers |
| Fixtures | `tests/fixtures/` | 9 new XML fixtures |
| Build | `Makefile` | lint, validate, test targets |
| CI | `.github/workflows/test.yml` | GitHub Actions on push/PR |
