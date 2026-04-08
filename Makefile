SHELL := /bin/bash

SCRIPTS := dist/seaweedfs-service.sh dist/seaweedfs-deps.sh
XSD := xsd/seaweedfs-systemd.xsd
VALID_FIXTURES := $(filter-out tests/fixtures/services-invalid-%.xml, $(wildcard tests/fixtures/*.xml))

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
