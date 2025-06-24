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

# Run tests in parallel using docker-compose
test-parallel:
	CRYSTAL_VERSION=$(CRYSTAL_VERSION) docker-compose -f docker-compose.test.yml up --abort-on-container-exit

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

# Clean up
clean:
	rm -rf bin lib .crystal .shards
	docker-compose -f docker-compose.test.yml down -v