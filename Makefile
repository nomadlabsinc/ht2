.PHONY: test test-docker test-parallel test-ci test-unit test-integration test-security test-h2c build clean format lint

# Default Crystal version
CRYSTAL_VERSION ?= 1.16
CRYSTAL_WORKERS ?= 4
PARALLEL_TESTS ?= true

# Build the Docker test image
build-test-image:
	docker build -f Dockerfile.test --build-arg CRYSTAL_VERSION=$(CRYSTAL_VERSION) -t ht2-test:$(CRYSTAL_VERSION) .

# Run all tests in Docker (default)
test: build-test-image
	docker run --rm \
		-e CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) \
		-e PARALLEL_TESTS=$(PARALLEL_TESTS) \
		-e TEST_CERT_PATH=/certs \
		-v $(PWD):/app \
		ht2-test:$(CRYSTAL_VERSION) \
		/app/scripts/run-tests.sh all

# Run tests in parallel using docker compose
test-parallel:
	CRYSTAL_VERSION=$(CRYSTAL_VERSION) docker compose -f docker compose.test.yml up --abort-on-container-exit

# Run specific test suites
test-unit: build-test-image
	docker run --rm \
		-e CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) \
		-e TEST_CERT_PATH=/certs \
		-v $(PWD):/app \
		ht2-test:$(CRYSTAL_VERSION) \
		/app/scripts/run-tests.sh unit

test-integration: build-test-image
	docker run --rm \
		-e CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) \
		-e TEST_CERT_PATH=/certs \
		-v $(PWD):/app \
		ht2-test:$(CRYSTAL_VERSION) \
		/app/scripts/run-tests.sh integration

test-security: build-test-image
	docker run --rm \
		-e CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) \
		-e TEST_CERT_PATH=/certs \
		-v $(PWD):/app \
		ht2-test:$(CRYSTAL_VERSION) \
		/app/scripts/run-tests.sh security

test-h2c: build-test-image
	docker run --rm \
		-e CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) \
		-e TEST_CERT_PATH=/certs \
		-v $(PWD):/app \
		ht2-test:$(CRYSTAL_VERSION) \
		/app/scripts/run-tests.sh h2c

# Run tests locally (not in Docker)
test-local:
	crystal spec --no-color

# CI test runner - optimized for Ubicloud Standard-4
test-ci: build-test-image
	@echo "Running CI tests on $(shell nproc) cores"
	docker run --rm \
		-e CRYSTAL_WORKERS=$(shell nproc) \
		-e PARALLEL_TESTS=true \
		-e TEST_CERT_PATH=/certs \
		-e LOG_LEVEL=ERROR \
		--cpus=$(shell nproc) \
		-v $(PWD):/app \
		ht2-test:$(CRYSTAL_VERSION) \
		/app/scripts/run-tests.sh all

# Build the project
build:
	crystal build --release src/ht2.cr

# Format code
format:
	crystal tool format

# Check formatting
format-check:
	crystal tool format --check

# Run linter
lint:
	docker run --rm -v $(PWD):/app -w /app crystallang/crystal:$(CRYSTAL_VERSION)-alpine \
		sh -c "shards install && crystal tool format --check && ameba src spec --except Metrics/CyclomaticComplexity"

# H2spec compliance testing
h2spec-build:
	docker build -f Dockerfile.h2spec -t ht2-h2spec .

# Run H2spec tests split into parts (like CI)
h2spec: h2spec-build
	@echo "Running H2spec compliance tests (split mode)..."
	@mkdir -p h2spec-results
	docker compose -f docker-compose.h2spec.yml up --abort-on-container-exit h2spec-server h2spec-part1 h2spec-part2
	@echo ""
	@echo "=== H2spec Results Summary ==="
	@if [ -f h2spec-results/part1_results.txt ] && [ -f h2spec-results/part2_results.txt ]; then \
		PART1_SUMMARY=$$(tail -1 h2spec-results/part1_results.txt); \
		PART2_SUMMARY=$$(tail -1 h2spec-results/part2_results.txt); \
		echo "Part 1: $$PART1_SUMMARY"; \
		echo "Part 2: $$PART2_SUMMARY"; \
	else \
		echo "Error: Result files not found"; \
		exit 1; \
	fi

# Run H2spec Part 1 only (sections 3-5)
h2spec-part1: h2spec-build
	@echo "Running H2spec Part 1 tests..."
	@mkdir -p h2spec-results
	docker compose -f docker-compose.h2spec.yml up --abort-on-container-exit h2spec-server h2spec-part1

# Run H2spec Part 2 only
h2spec-part2: h2spec-build
	@echo "Running H2spec Part 2 tests..."
	@mkdir -p h2spec-results
	docker compose -f docker-compose.h2spec.yml up --abort-on-container-exit h2spec-server h2spec-part2

# Clean up H2spec containers and results
h2spec-clean:
	docker compose -f docker-compose.h2spec.yml down -v
	rm -rf h2spec-results

# Clean up
clean: h2spec-clean
	rm -rf bin lib .crystal .shards
	docker compose -f docker-compose.test.yml down -v
