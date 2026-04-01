# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Go configuration
GO ?= go
GOCACHE ?= $(CURDIR)/.gocache
GOMODCACHE ?= $(CURDIR)/.gomodcache
export GOCACHE
export GOMODCACHE
GOBIN ?= $$($(GO) env GOPATH)/bin
GOLANGCI_LINT ?= golangci-lint
GOLANGCI_LINT_VERSION ?= v2.11.3
GOLANGCI_LINT_TIMEOUT ?= 10m
SWIFTLINT ?= swiftlint

# Rust configuration
CARGO ?= cargo
RUSTFMT ?= rustfmt

# Set up Rust environment - use original user's paths when running with sudo
ifdef SUDO_USER
	# Use dscl on macOS, getent on Linux
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Darwin)
		ORIGINAL_HOME := $(shell dscl . -read /Users/$(SUDO_USER) NFSHomeDirectory | awk '{print $$2}')
	else
		ORIGINAL_HOME := $(shell getent passwd $(SUDO_USER) | cut -d: -f6)
	endif
	RUSTUP_HOME ?= $(ORIGINAL_HOME)/.rustup
	CARGO_HOME ?= $(ORIGINAL_HOME)/.cargo
else
	RUSTUP_HOME ?= $(HOME)/.rustup
	CARGO_HOME ?= $(HOME)/.cargo
endif

RPERF_CLIENT_BUILD_DIR ?= rust/rperf-client/target/release
RPERF_CLIENT_BIN ?= serviceradar-rperf-checker
RPERF_SERVER_BUILD_DIR ?= rust/rperf-server/target/release
RPERF_SERVER_BIN ?= rperf

# Version configuration
VERSION ?= $(shell git describe --tags --always)
NEXT_VERSION ?= $(shell git describe --tags --abbrev=0 | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g')
RELEASE ?= 1

# Container configuration
REGISTRY ?= registry.carverauto.dev/serviceradar
KO_DOCKER_REPO ?= $(REGISTRY)
PLATFORMS ?= linux/amd64,linux/arm64

# Colors for pretty printing
COLOR_RESET = \033[0m
COLOR_BOLD = \033[1m
COLOR_GREEN = \033[32m
COLOR_YELLOW = \033[33m
COLOR_CYAN = \033[36m

HOST_OS := $(shell uname -s)

ifeq ($(HOST_OS),Darwin)
HOSTFREQ_OBJ := go/pkg/cpufreq/hostfreq_darwin_embed.o
HOSTFREQ_SRC := go/pkg/cpufreq/hostfreq_darwin.mm
HOSTFREQ_HDR := go/pkg/cpufreq/hostfreq_bridge.h

$(HOSTFREQ_OBJ): $(HOSTFREQ_SRC) $(HOSTFREQ_HDR)
	@echo "$(COLOR_BOLD)Compiling hostfreq Objective-C++ bridge$(COLOR_RESET)"
	@xcrun clang++ -arch arm64 -std=c++20 -fobjc-arc -x objective-c++ -I go/pkg/cpufreq -c $(HOSTFREQ_SRC) -o $@

.PHONY: hostfreq-embed-object
hostfreq-embed-object: $(HOSTFREQ_OBJ)

TEST_PREREQS := hostfreq-embed-object
GO_TEST_TAGS := -tags=hostfreq_embed
else
.PHONY: hostfreq-embed-object
hostfreq-embed-object:
	@true

TEST_PREREQS :=
GO_TEST_TAGS :=
endif

.PHONY: help
help: ## Show this help message
	@echo "$(COLOR_BOLD)Available targets:$(COLOR_RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(COLOR_CYAN)%-20s$(COLOR_RESET) %s\n", $$1, $$2}'

.PHONY: compose-up
compose-up: ## Start Docker Compose stack
	@docker compose up -d

.PHONY: compose-upgrade
compose-upgrade: ## Pull images and recreate containers without destroying volumes
	@docker compose pull
	@docker compose up -d --force-recreate

.PHONY: build
build: ## Build all OCI images with Bazel (remote)
	@bazel build --config=remote //:images

.PHONY: build-workspace
build-workspace: ## Build the full workspace with Bazel (remote)
	@bazel build --config=remote //...

.PHONY: build-web-ng
build-web-ng: ## Build just the web-ng OCI image with Bazel (remote)
	@bazel build --config=remote //docker/images:web_ng_image_amd64

.PHONY: push-web-ng
push-web-ng: ## Build and push just the web-ng OCI image to GHCR (remote)
	@bazel run --config=remote_push --stamp //docker/images:web_ng_image_amd64_push

.PHONY: push_all
push_all: ## Build and push all OCI images to GHCR (CI only, see issue #2517)
	@set -eu; \
	if [ -n "$(PUSH_TAG)" ]; then \
		bazel run --config=remote_push --stamp //:push -- --tag "$(PUSH_TAG)"; \
		$(MAKE) verify_publish VERIFY_TAG="$(PUSH_TAG)"; \
	else \
		bazel run --config=remote_push --stamp //:push; \
		$(MAKE) verify_publish; \
	fi

.PHONY: verify_publish
verify_publish: ## Verify published GHCR image shape and runtime metadata (set VERIFY_TAG=<tag> to include an extra tag)
	@set -eu; \
	./scripts/verify-ghcr-publish.sh latest "sha-$$(git rev-parse HEAD)"; \
	if [ -n "$(VERIFY_TAG)" ]; then \
		./scripts/verify-ghcr-publish.sh "$(VERIFY_TAG)"; \
	fi

.PHONY: check-dev-image-tags
check-dev-image-tags: ## Verify dev image tag defaults (latest + APP_TAG fallbacks)
	@scripts/check-dev-image-tags.sh

.PHONY: demo-staging-canary
demo-staging-canary: ## Configure demo-staging ArgoCD app for canary tags (web=latest, others pinned)
	@./scripts/demo-staging-canary.py --app serviceradar-demo-staging --base-tag v1.0.75 --web-tag latest

.PHONY: demo-staging-web
demo-staging-web: ## Push web-ng image (latest) and restart serviceradar-web-ng in demo-staging
	@./scripts/demo-staging-web.sh demo-staging

.PHONY: demo-staging-core
demo-staging-core: ## Push core image (latest) and restart serviceradar-core in demo-staging
	@./scripts/demo-staging-core.sh demo-staging

.PHONY: cnpg-smoke
cnpg-smoke: ## Run CNPG API smoke tests (set NAMESPACE=<ns>, default demo-staging)
	@NS=$(if $(NAMESPACE),$(NAMESPACE),demo-staging); \
	echo "$(COLOR_BOLD)Running CNPG smoke tests in namespace $${NS}$(COLOR_RESET)"; \
	./scripts/cnpg-smoke.sh $${NS}

.PHONY: agent-build-darwin
agent-build-darwin: hostfreq-embed-object ## Build the agent for macOS (arm64) into dist/agent/bin
	@OUTDIR=$(abspath $(if $(WORKSPACE),$(WORKSPACE),dist/agent)/bin); \
	mkdir -p "$$OUTDIR"; \
	if ! GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -tags hostfreq_embed -trimpath -ldflags "-s -w" -o "$$OUTDIR/serviceradar-agent" ./go/cmd/agent; then exit 1; fi

.PHONY: agent-package-macos
agent-package-macos: ## Build macOS agent installer package (.pkg) with signing/notarization support
	@scripts/agent/package-macos.sh

.PHONY: tidy
tidy: ## Tidy and format Go code
	@echo "$(COLOR_BOLD)Tidying Go modules and formatting code$(COLOR_RESET)"
	@$(GO) mod tidy
	@$(GO) fmt ./...
	@echo "$(COLOR_BOLD)Formatting Rust code$(COLOR_RESET)"
	@cd rust/rperf-client && $(RUSTFMT) src/*.rs
	@cd rust/trapd && $(RUSTFMT) src/*.rs
	@cd rust/consumers/zen && $(RUSTFMT) src/*.rs
	@cd rust/otel && $(RUSTFMT) src/*.rs
	@cd rust/flowgger && $(RUSTFMT) src/*.rs src/flowgger/*.rs

.PHONY: update-rust-deps
update-rust-deps: ## Repin Bazel-managed Rust dependencies (use REPIN=<mode>, VERIFY_TARGET=<label>)
	@./scripts/update-rust-bazel-deps.sh "$(if $(REPIN),$(REPIN),workspace)" "$(if $(VERIFY_TARGET),$(VERIFY_TARGET),//rust/srql:srql_lib)"

.PHONY: get-golangcilint
get-golangcilint: ## Install golangci-lint
	@echo "$(COLOR_BOLD)Checking golangci-lint $(GOLANGCI_LINT_VERSION)$(COLOR_RESET)"
	@which $(GOLANGCI_LINT) > /dev/null || (echo "golangci-lint not found, please install it" && exit 1)
	@expected_version="$(patsubst v%,%,$(GOLANGCI_LINT_VERSION))"; \
	if ! $(GOLANGCI_LINT) version | grep -F "version $${expected_version}" > /dev/null; then \
		found_version="$$( $(GOLANGCI_LINT) version | sed -n 's/.*version \([0-9][^ ]*\).*/v\1/p' | head -n1 )"; \
		echo "golangci-lint $${found_version:-unknown} found, expected $(GOLANGCI_LINT_VERSION)"; \
		exit 1; \
	fi

.PHONY: get-swiftlint
get-swiftlint: ## Check SwiftLint is installed
	@echo "$(COLOR_BOLD)Checking SwiftLint$(COLOR_RESET)"
	@which $(SWIFTLINT) > /dev/null || (echo "swiftlint not found, please install it from https://github.com/realm/SwiftLint" && exit 1)

.PHONY: get-bun
get-bun: ## Check Bun is installed
	@echo "$(COLOR_BOLD)Checking Bun$(COLOR_RESET)"
	@which bun > /dev/null || (echo "bun not found, please install it from https://bun.sh" && exit 1)

.PHONY: lint
lint: lint-go get-bun ## Run linting checks
ifeq ($(HOST_OS),Darwin)
	@echo "$(COLOR_BOLD)Running SwiftLint$(COLOR_RESET)"
	@which $(SWIFTLINT) > /dev/null || (echo "swiftlint not found, please install it from https://github.com/realm/SwiftLint" && exit 1)
	@$(SWIFTLINT) lint --config .swiftlint.yml
else
	@echo "$(COLOR_BOLD)Skipping SwiftLint (HOST_OS=$(HOST_OS); Darwin only)$(COLOR_RESET)"
endif
	@echo "$(COLOR_BOLD)Running Rust linter$(COLOR_RESET)"
	@cd rust/rperf-client && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd rust/trapd && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd rust/consumers/zen && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd rust/otel && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd rust/flowgger && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd rust/srql && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy --all-targets -- -D warnings
	@$(MAKE) lint-elixir
	@echo "$(COLOR_BOLD)Running web-ng assets ESLint$(COLOR_RESET)"
	@cd elixir/web-ng/assets && bun run lint

.PHONY: lint-elixir
lint-elixir: ## Run the repository-standard Elixir analyzer contract across elixir/*
	@set -eu; \
		projects="connection::--skip-dialyzer datasvc::--skip-dialyzer elixir_uuid::--skip-dialyzer serviceradar_agent_gateway::--skip-dialyzer serviceradar_core::--skip-dialyzer serviceradar_core_elx::--skip-dialyzer serviceradar_srql::--skip-dialyzer web-ng::--phoenix --skip-dialyzer"; \
	for entry in $$projects; do \
		project="$${entry%%::*}"; \
		args="$${entry#*::}"; \
		echo "$(COLOR_BOLD)Running Elixir quality ($${project})$(COLOR_RESET)"; \
		./scripts/elixir_quality.sh --project "elixir/$${project}" $$args; \
	done

.PHONY: lint-elixir-dialyzer
lint-elixir-dialyzer: ## Run Dialyzer across elixir/* on demand
	@set -eu; \
		projects="connection datasvc elixir_uuid serviceradar_agent_gateway serviceradar_core serviceradar_core_elx serviceradar_srql web-ng"; \
	for project in $$projects; do \
		echo "$(COLOR_BOLD)Running Elixir Dialyzer ($${project})$(COLOR_RESET)"; \
		(cd "elixir/$${project}" && mix deps.get && mix deps.compile && mix compile && mix dialyzer); \
	done

.PHONY: format-elixir
format-elixir: ## Run mix format across the Elixir projects under elixir/*
	@set -eu; \
		projects="connection datasvc elixir_uuid serviceradar_agent_gateway serviceradar_core serviceradar_core_elx serviceradar_srql web-ng"; \
	for project in $$projects; do \
		echo "$(COLOR_BOLD)Formatting Elixir project ($${project})$(COLOR_RESET)"; \
		(cd "elixir/$${project}" && mix format); \
	done

.PHONY: lint-go
lint-go: get-golangcilint ## Run Go linting checks
	@echo "$(COLOR_BOLD)Running Go linter$(COLOR_RESET)"
	@$(GOLANGCI_LINT) run --timeout $(GOLANGCI_LINT_TIMEOUT) ./...

.PHONY: test
test: $(TEST_PREREQS) get-bun ## Run all tests with coverage
	@echo "$(COLOR_BOLD)Running Go short tests$(COLOR_RESET)"
	@$(GO) test $(GO_TEST_TAGS) -timeout=15s -race -count=10 -failfast -shuffle=on -short ./... -coverprofile=./cover.short.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Go long tests$(COLOR_RESET)"
	@$(GO) test $(GO_TEST_TAGS) -timeout=120s -race -count=1 -failfast -shuffle=on ./... -coverprofile=./cover.long.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Rust tests$(COLOR_RESET)"
	@cd rust/rperf-client && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd rust/trapd && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd rust/consumers/zen && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd rust/otel && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd rust/flowgger && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd rust/srql && SRQL_ALLOW_AGE_SKIP=1 RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@echo "$(COLOR_BOLD)Running web-ng assets Vitest$(COLOR_RESET)"
	@cd elixir/web-ng/assets && bun run test
	@echo "$(COLOR_BOLD)Running web-ng precommit$(COLOR_RESET)"
	@ENV_FILE="$${ENV_FILE:-$(CURDIR)/.env}"; \
	case "$${ENV_FILE}" in \
	  /*|./*|../*) ;; \
	  *) ENV_FILE="$(CURDIR)/$${ENV_FILE}" ;; \
	esac; \
	if [ -f "$${ENV_FILE}" ]; then set -a; . "$${ENV_FILE}"; set +a; fi; \
	cd elixir/web-ng && mix precommit

.PHONY: test-integration
test-integration: ## Run serviceradar_core integration tests (requires SRQL/CNPG fixture)
	@./scripts/test-integration.sh

.PHONY: check-coverage
check-coverage: test ## Check test coverage against thresholds
	@echo "$(COLOR_BOLD)Checking test coverage$(COLOR_RESET)"
	@$(GO) run ./main.go --config=./.github/.testcoverage.yml

.PHONY: view-coverage
view-coverage: ## Generate and view coverage report
	@echo "$(COLOR_BOLD)Generating coverage report$(COLOR_RESET)"
	@$(GO) test ./... -coverprofile=./cover.all.profile -covermode=atomic -coverpkg=./...
	@$(GO) tool cover -html=cover.all.profile -o=cover.html
	@xdg-open cover.html

.PHONY: release
release: ## Create and push a new release
	@echo "$(COLOR_BOLD)Creating release $(NEXT_VERSION)$(COLOR_RESET)"
	@git tag -a $(NEXT_VERSION) -m "Release $(NEXT_VERSION)"
	@git push origin $(NEXT_VERSION)

.PHONY: web-ng-release-check
web-ng-release-check: ## Build web-ng Bazel release tarball preflight (same path used by MixRelease CI)
	@echo "$(COLOR_BOLD)Running web-ng release preflight$(COLOR_RESET)"
	@bazel build --config=remote //elixir/web-ng:release_tar


.PHONY: version
version: ## Show current and next version
	@echo "$(COLOR_BOLD)Current version: $(VERSION)$(COLOR_RESET)"
	@echo "$(COLOR_BOLD)Next version: $(NEXT_VERSION)$(COLOR_RESET)"

.PHONY: clean
clean: ## Clean up build artifacts
	@echo "$(COLOR_BOLD)Cleaning up build artifacts$(COLOR_RESET)"
	@rm -f cover.*.profile cover.html
	@rm -rf bin/
	@rm -rf serviceradar-*_* release-artifacts/
	@cd rust/rperf-client && $(CARGO) clean
	@cd rust/trapd && $(CARGO) clean
	@cd rust/consumers/zen && $(CARGO) clean
	@cd rust/otel && $(CARGO) clean
	@cd rust/flowgger && $(CARGO) clean

.PHONY: generate-proto
generate-proto: ## Generate Go and Rust code from protobuf definitions
	@echo "$(COLOR_BOLD)Generating Go code from protobuf definitions$(COLOR_RESET)"
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/discovery/discovery.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/kv.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/data_service.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/identitymap/v1/identity_map.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/core_service.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/monitoring.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/camera_media.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/rperf/rperf.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/flow/flow.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/nats_account.proto
	@echo "$(COLOR_BOLD)Generated Go protobuf code$(COLOR_RESET)"

.PHONY: build-binaries
build-binaries: generate-proto ## Build all binaries locally (Go + Rust)
	@echo "$(COLOR_BOLD)Building all binaries$(COLOR_RESET)"
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-agent go/cmd/agent/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-core cmd/core/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-datasvc go/cmd/data-services/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-cli go/cmd/cli/main.go
	@echo "$(COLOR_BOLD)Building Rust binaries$(COLOR_RESET)"
	@cd rust/rperf-client && $(CARGO) build --release
	@cd rust/rperf-server && $(CARGO) build --release
	@cd rust/trapd && $(CARGO) build --release
	@cd rust/consumers/zen && $(CARGO) build --release
	@cd rust/otel && $(CARGO) build --release
	@cd rust/flowgger && $(CARGO) build --release
	@mkdir -p bin
	@cp $(RPERF_CLIENT_BUILD_DIR)/$(RPERF_CLIENT_BIN) bin/serviceradar-rperf-checker
	@cp $(RPERF_SERVER_BUILD_DIR)/$(RPERF_SERVER_BIN) bin/serviceradar-rperf
	@cp rust/trapd/target/release/serviceradar-trapd bin/serviceradar-trapd
	@cp rust/consumers/zen/target/release/zen-consumer bin/serviceradar-zen-consumer
	@cp rust/otel/target/release/serviceradar-otel bin/serviceradar-otel
	@cp rust/flowgger/target/release/flowgger bin/serviceradar-flowgger

# Build Debian packages
.PHONY: deb-agent
deb-agent: ## Build the agent Debian package
	@echo "$(COLOR_BOLD)Building agent Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb agent

.PHONY: deb-kv
deb-kv: ## Build the KV Debian package
	@echo "$(COLOR_BOLD)Building KV Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb kv

.PHONY: deb-sync
deb-sync: ## Build the KV Sync Debian package
	@echo "$(COLOR_BOLD)Building KV Sync Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb sync

.PHONY: deb-rperf-checker
deb-rperf-checker: ## Build the RPerf checker Debian package
	@echo "$(COLOR_BOLD)Building RPerf checker Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb rperf-client

.PHONY: deb-rperf
deb-rperf: ## Build the RPerf server Debian package
	@echo "$(COLOR_BOLD)Building RPerf server Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb rperf-server

.PHONY: deb-cli
deb-cli: ## Build the CLI Debian package
	@echo "$(COLOR_BOLD)Building CLI Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb cli

.PHONY: deb-sysmon
deb-sysmon: ## Build the Sysmon checker Debian package
	@echo "$(COLOR_BOLD)Building Sysmon checker Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb sysmon

.PHONY: deb-all
deb-all: ## Build all Debian packages
	@echo "$(COLOR_BOLD)Building all Debian packages$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb --all

.PHONY: deb-all-container
deb-all-container: ## Build all Debian packages
	@echo "$(COLOR_BOLD)Building all Debian packages$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb agent
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb nats
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb kv
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb sync
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb rperf-server
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb rperf-client
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb cli
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb sysmon-checker

# Build RPM packages
.PHONY: rpm-agent
rpm-agent: ## Build the agent RPM package
	@echo "$(COLOR_BOLD)Building agent RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm agent

.PHONY: rpm-nats
rpm-nats: ## Build the NATS RPM package
	@echo "$(COLOR_BOLD)Building NATS JetStream RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm nats

.PHONY: rpm-kv
rpm-kv: ## Build the KV RPM package
	@echo "$(COLOR_BOLD)Building KV RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm kv

.PHONY: rpm-sync
rpm-sync: ## Build the KV Sync RPM package
	@echo "$(COLOR_BOLD)Building KV Sync RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm sync

.PHONY: rpm-rperf
rpm-rperf: ## Build the RPerf server RPM package
	@echo "$(COLOR_BOLD)Building RPerf server RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm rperf-server

.PHONY: rpm-rperf-checker
rpm-rperf-checker: ## Build the RPerf checker RPM package
	@echo "$(COLOR_BOLD)Building RPerf checker RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm rperf-client

.PHONY: rpm-cli
rpm-cli: ## Build the CLI RPM package
	@echo "$(COLOR_BOLD)Building CLI RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm cli

.PHONY: rpm-sysmon
rpm-sysmon: ## Build the Sysmon checker RPM package
	@echo "$(COLOR_BOLD)Building Sysmon checker RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm sysmon

.PHONY: rpm-all
rpm-all: ## Build all RPM packages
	@echo "$(COLOR_BOLD)Building all RPM packages$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm --all

# Docusaurus commands
.PHONY: docs-start
docs-start: ## Start Docusaurus development server
	@echo "$(COLOR_BOLD)Starting Docusaurus development server$(COLOR_RESET)"
	@cd docs && pnpm start

.PHONY: docs-build
docs-build: ## Build Docusaurus static files for production
	@echo "$(COLOR_BOLD)Building Docusaurus static files$(COLOR_RESET)"
	@cd docs && pnpm run build

.PHONY: docs-serve
docs-serve: ## Serve the built Docusaurus website locally
	@echo "$(COLOR_BOLD)Serving built Docusaurus website$(COLOR_RESET)"
	@cd docs && pnpm run serve

.PHONY: docs-deploy
docs-deploy: ## Deploy Docusaurus website to GitHub pages
	@echo "$(COLOR_BOLD)Deploying Docusaurus to GitHub pages$(COLOR_RESET)"
	@cd docs && pnpm run deploy

.PHONY: docs-setup
docs-setup: ## Initial setup for Docusaurus development
	@echo "$(COLOR_BOLD)Setting up Docusaurus development environment$(COLOR_RESET)"
	@cd docs && pnpm install

# RPerf plugin specific targets
.PHONY: build-rperf-checker
build-rperf-checker: generate-proto ## Build only the rperf plugin
	@echo "$(COLOR_BOLD)Building Rust rperf checker$(COLOR_RESET)"
	@cd rust/rperf-client && $(CARGO) build --release
	@mkdir -p bin
	@cp -v $(shell pwd)/rust/rperf-client/target/release/$(RPERF_CLIENT_BIN) bin/serviceradar-rperf-checker

.PHONY: run-rperf-checker
run-rperf-checker: build-rperf-checker ## Run the rperf plugin
	@echo "$(COLOR_BOLD)Running rperf checker$(COLOR_RESET)"
	@./bin/serviceradar-rperf-checker $(ARGS)

# RPerf server specific targets
.PHONY: build-rperf
build-rperf: generate-proto ## Build only the rperf server
	@echo "$(COLOR_BOLD)Building Rust rperf server$(COLOR_RESET)"
	@cd rust/rperf-server && $(CARGO) build --release
	@mkdir -p bin
	@cp -v $(shell pwd)/rust/rperf-server/target/release/$(RPERF_SERVER_BIN) bin/serviceradar-rperf

.PHONY: run-rperf
run-rperf: build-rperf ## Run the rperf server
	@echo "$(COLOR_BOLD)Running rperf server$(COLOR_RESET)"
	@./bin/serviceradar-rperf $(ARGS)

# Default target
.DEFAULT_GOAL := help
