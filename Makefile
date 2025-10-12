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
GOLANGCI_LINT_VERSION ?= v2.4.0

# Rust configuration
CARGO ?= cargo
RUSTFMT ?= rustfmt

# OCaml configuration
OPAM ?= opam
DUNE ?= dune
DUNE_ROOT ?= --root ocaml

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

RPERF_CLIENT_BUILD_DIR ?= cmd/checkers/rperf-client/target/release
RPERF_CLIENT_BIN ?= serviceradar-rperf-checker
RPERF_SERVER_BUILD_DIR ?= cmd/checkers/rperf-server/target/release
RPERF_SERVER_BIN ?= rperf
SYSMON_BUILD_DIR ?= cmd/checkers/sysmon/target/release
SYSMON_BIN ?= serviceradar-sysmon

# Version configuration
VERSION ?= $(shell git describe --tags --always)
NEXT_VERSION ?= $(shell git describe --tags --abbrev=0 | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g')
RELEASE ?= 1

# Container configuration
REGISTRY ?= ghcr.io/carverauto/serviceradar
KO_DOCKER_REPO ?= $(REGISTRY)
PLATFORMS ?= linux/amd64,linux/arm64

# Colors for pretty printing
COLOR_RESET = \033[0m
COLOR_BOLD = \033[1m
COLOR_GREEN = \033[32m
COLOR_YELLOW = \033[33m
COLOR_CYAN = \033[36m

HOST_OS := $(shell uname -s)

.PHONY: help
help: ## Show this help message
	@echo "$(COLOR_BOLD)Available targets:$(COLOR_RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(COLOR_CYAN)%-20s$(COLOR_RESET) %s\n", $$1, $$2}'

.PHONY: sysmonvm-host-setup
sysmonvm-host-setup: ## Prepare host tooling and workspace for the sysmon-vm AlmaLinux VM
	@$(if $(WORKSPACE),scripts/sysmonvm/host-setup.sh --workspace "$(WORKSPACE)",scripts/sysmonvm/host-setup.sh)

.PHONY: sysmonvm-fetch-image
sysmonvm-fetch-image: ## Download the AlmaLinux cloud image referenced in dist/sysmonvm/config.yaml
	@$(if $(WORKSPACE),scripts/sysmonvm/fetch-image.sh --workspace "$(WORKSPACE)",scripts/sysmonvm/fetch-image.sh)

.PHONY: sysmonvm-vm-create
sysmonvm-vm-create: ## Create writable VM disk and cloud-init seed ISO for sysmon-vm
	@$(if $(WORKSPACE),scripts/sysmonvm/vm-create.sh --workspace "$(WORKSPACE)",scripts/sysmonvm/vm-create.sh)

.PHONY: sysmonvm-vm-start
sysmonvm-vm-start: ## Boot the AlmaLinux VM headless for sysmon-vm testing
	@$(if $(WORKSPACE),scripts/sysmonvm/vm-start.sh --workspace "$(WORKSPACE)",scripts/sysmonvm/vm-start.sh)

.PHONY: sysmonvm-vm-start-daemon
sysmonvm-vm-start-daemon: ## Boot the AlmaLinux VM in the background (daemonized, serial logs under dist/sysmonvm/logs)
	@$(if $(WORKSPACE),scripts/sysmonvm/vm-start.sh --workspace "$(WORKSPACE)" --daemonize,scripts/sysmonvm/vm-start.sh --daemonize)

.PHONY: sysmonvm-vm-destroy
sysmonvm-vm-destroy: ## Remove VM overlay disk and cloud-init artifacts
	@$(if $(WORKSPACE),scripts/sysmonvm/vm-destroy.sh --workspace "$(WORKSPACE)",scripts/sysmonvm/vm-destroy.sh)

.PHONY: sysmonvm-vm-ssh
sysmonvm-vm-ssh: ## SSH into the AlmaLinux VM (pass ARGS="command" for non-interactive usage)
	@$(if $(WORKSPACE),scripts/sysmonvm/vm-ssh.sh --workspace "$(WORKSPACE)" $(if $(ARGS),-- $(ARGS),),scripts/sysmonvm/vm-ssh.sh $(if $(ARGS),-- $(ARGS),))

.PHONY: sysmonvm-vm-bootstrap
sysmonvm-vm-bootstrap: ## Install baseline packages inside the VM (dnf upgrade, kernel-tools, etc.)
	@$(if $(WORKSPACE),scripts/sysmonvm/vm-bootstrap.sh --workspace "$(WORKSPACE)" $(if $(filter 0,$(UPGRADE)),--no-upgrade,),scripts/sysmonvm/vm-bootstrap.sh $(if $(filter 0,$(UPGRADE)),--no-upgrade,))

.PHONY: sysmonvm-build-checker
sysmonvm-build-checker: ## Cross-compile the sysmon-vm checker for Linux/arm64 into dist/sysmonvm/bin
	@$(if $(WORKSPACE),scripts/sysmonvm/build-checker.sh --workspace "$(WORKSPACE)",scripts/sysmonvm/build-checker.sh)

.PHONY: sysmonvm-build-checker-darwin
sysmonvm-build-checker-darwin: ## Build the sysmon-vm checker for macOS (arm64) into dist/sysmonvm/mac-host/bin
	@OUTDIR=$(abspath $(if $(WORKSPACE),$(WORKSPACE),dist/sysmonvm)/mac-host/bin); \
	mkdir -p "$$OUTDIR"; \
	GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$$OUTDIR/serviceradar-sysmon-vm" ./cmd/checkers/sysmon-vm

.PHONY: sysmonvm-host-build
sysmonvm-host-build: ## Build the macOS host frequency helper into dist/sysmonvm/mac-host/bin
	@OUTDIR=$(abspath $(if $(WORKSPACE),$(WORKSPACE),dist/sysmonvm)/mac-host/bin); \
	mkdir -p "$$OUTDIR"; \
	$(MAKE) -C cmd/checkers/sysmon-vm/hostmac OUTDIR="$$OUTDIR"

.PHONY: sysmonvm-host-install
sysmonvm-host-install: ## Install the macOS host frequency helper launchd service (run with sudo)
	@scripts/sysmonvm/host-install-macos.sh

.PHONY: sysmonvm-host-package
sysmonvm-host-package: ## Build macOS sysmon-vm host helper tarball and installer package
	@scripts/sysmonvm/package-host-macos.sh

.PHONY: sysmonvm-vm-install
sysmonvm-vm-install: ## Copy the checker binary/config into the VM and install (set SERVICE=0 to skip systemd unit)
	@$(if $(WORKSPACE),scripts/sysmonvm/vm-install-checker.sh --workspace "$(WORKSPACE)" $(if $(filter 0,$(SERVICE)),--skip-service,),scripts/sysmonvm/vm-install-checker.sh $(if $(filter 0,$(SERVICE)),--skip-service,))

.PHONY: tidy
tidy: ## Tidy and format Go code
	@echo "$(COLOR_BOLD)Tidying Go modules and formatting code$(COLOR_RESET)"
	@$(GO) mod tidy
	@$(GO) fmt ./...
	@echo "$(COLOR_BOLD)Formatting Rust code$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && $(RUSTFMT) src/*.rs
	@cd cmd/checkers/sysmon && $(RUSTFMT) src/*.rs
	@cd cmd/trapd && $(RUSTFMT) src/*.rs
	@cd cmd/consumers/zen && $(RUSTFMT) src/*.rs
	@cd cmd/otel && $(RUSTFMT) src/*.rs
	@cd cmd/flowgger && $(RUSTFMT) src/*.rs src/flowgger/*.rs

.PHONY: get-golangcilint
get-golangcilint: ## Install golangci-lint
	@echo "$(COLOR_BOLD)Checking golangci-lint $(GOLANGCI_LINT_VERSION)$(COLOR_RESET)"
	@which $(GOLANGCI_LINT) > /dev/null || (echo "golangci-lint not found, please install it" && exit 1)

.PHONY: lint-clang-tidy
lint-clang-tidy: ## Run clang-tidy diagnostics for macOS host helper
	@if [ "$(HOST_OS)" != "Darwin" ]; then \
		echo "$(COLOR_YELLOW)Skipping clang-tidy for hostfreq (requires macOS toolchain)$(COLOR_RESET)"; \
	else \
		echo "$(COLOR_BOLD)Running clang-tidy for hostfreq via Bazel$(COLOR_RESET)"; \
		bazel build --config=clang-tidy //cmd/checkers/sysmon-vm/hostmac:hostfreq; \
	fi

.PHONY: lint
lint: get-golangcilint ## Run linting checks
	@$(MAKE) lint-clang-tidy
	@echo "$(COLOR_BOLD)Running Go linter$(COLOR_RESET)"
	@$(GOLANGCI_LINT) run ./...
	@echo "$(COLOR_BOLD)Running Rust linter$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd cmd/checkers/sysmon && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd cmd/trapd && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd cmd/consumers/zen && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd cmd/otel && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd cmd/flowgger && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@echo "$(COLOR_BOLD)Running OCaml linters$(COLOR_RESET)"
	@$(MAKE) lint-ocaml

# OCaml lint targets
.PHONY: lint-ocaml
lint-ocaml: lint-ocaml-fmt lint-ocaml-opam lint-ocaml-doc ## Run all OCaml linting checks
	@echo "✅ All OCaml lint checks passed!"

.PHONY: lint-ocaml-fmt
lint-ocaml-fmt: ## Check OCaml code formatting
	@echo "🔍 Checking OCaml code formatting..."
	@$(OPAM) list ocamlformat > /dev/null 2>&1 || (echo "Installing ocamlformat..." && $(OPAM) install ocamlformat -y)
	@$(OPAM) exec -- $(DUNE) build $(DUNE_ROOT) @fmt

.PHONY: lint-ocaml-opam
lint-ocaml-opam: ## Check opam files
	@echo "🔍 Checking opam files..."
	@if [ -f ./proton.opam ]; then $(OPAM) exec -- $(OPAM) lint ./proton.opam; fi

.PHONY: lint-ocaml-doc
lint-ocaml-doc: ## Check OCaml documentation
	@echo "🔍 Checking OCaml documentation..."
	@$(OPAM) exec -- $(DUNE) build $(DUNE_ROOT) @doc

.PHONY: lint-ocaml-fix
lint-ocaml-fix: ## Auto-fix OCaml formatting issues
	@echo "🔧 Auto-fixing OCaml formatting issues..."
	@$(OPAM) list ocamlformat > /dev/null 2>&1 || (echo "Installing ocamlformat..." && $(OPAM) install ocamlformat -y)
	@$(OPAM) exec -- $(DUNE) build $(DUNE_ROOT) @fmt --auto-promote
	@echo "✅ OCaml formatting issues fixed!"

.PHONY: test
test: ## Run all tests with coverage
	@echo "$(COLOR_BOLD)Running Go short tests$(COLOR_RESET)"
	@$(GO) test -timeout=3s -race -count=10 -failfast -shuffle=on -short ./... -coverprofile=./cover.short.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Go long tests$(COLOR_RESET)"
	@$(GO) test -timeout=10s -race -count=1 -failfast -shuffle=on ./... -coverprofile=./cover.long.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Rust tests$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd cmd/checkers/sysmon && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd cmd/trapd && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd cmd/consumers/zen && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd cmd/otel && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd cmd/flowgger && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@$(MAKE) --no-print-directory test-ocaml

# OCaml test targets
.PHONY: test-ocaml
test-ocaml: ## Run OCaml tests
	@echo "$(COLOR_BOLD)Running OCaml tests$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) test $(DUNE_ROOT)

.PHONY: test-ocaml-silent
test-ocaml-silent: ## Run OCaml tests silently (only shows failures)
	@$(OPAM) exec -- $(DUNE) test $(DUNE_ROOT)

.PHONY: test-ocaml-verbose
test-ocaml-verbose: ## Run OCaml tests with verbose output
	@$(OPAM) exec -- $(DUNE) test --verbose $(DUNE_ROOT)

.PHONY: bench-ocaml-readers
bench-ocaml-readers: ## Run OCaml reader micro-benchmarks
	@echo "$(COLOR_BOLD)Running OCaml reader micro-benchmarks (ONLY_READER_MICRO=1)$(COLOR_RESET)"
	@ONLY_READER_MICRO=1 $(OPAM) exec -- $(DUNE) exec benchmark/benchmark_main.exe

.PHONY: livetest-ocaml
livetest-ocaml: ## Run OCaml live tests against real Proton database
	@echo "$(COLOR_BOLD)Running OCaml live tests against Proton database$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) build @livetest

.PHONY: e2e-ocaml
e2e-ocaml: livetest-ocaml ## Run OCaml end-to-end tests (alias for livetest-ocaml)

.PHONY: test-live-ocaml
test-live-ocaml: ## Run OCaml live test executable directly
	@$(OPAM) exec -- $(DUNE) exec test_live/test_live.exe

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
	@cd cmd/checkers/rperf-client && $(CARGO) clean
	@cd cmd/checkers/sysmon && $(CARGO) clean
	@cd cmd/trapd && $(CARGO) clean
	@cd cmd/consumers/zen && $(CARGO) clean
	@cd cmd/otel && $(CARGO) clean
	@cd cmd/flowgger && $(CARGO) clean
	@echo "$(COLOR_BOLD)Cleaning OCaml build artifacts$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) clean

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
		proto/rperf/rperf.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/flow/flow.proto
	@echo "$(COLOR_BOLD)Generated Go protobuf code$(COLOR_RESET)"

.PHONY: build
build: generate-proto ## Build all binaries
	@echo "$(COLOR_BOLD)Building all binaries$(COLOR_RESET)"
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-agent cmd/agent/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-poller cmd/poller/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-dusk-checker cmd/checkers/dusk/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-core cmd/core/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-kv cmd/kv/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-sync cmd/sync/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-snmp-checker cmd/checkers/snmp/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-cli cmd/cli/main.go
	@echo "$(COLOR_BOLD)Building Rust binaries$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && $(CARGO) build --release
	@cd cmd/checkers/rperf-server && $(CARGO) build --release
	@cd cmd/checkers/sysmon && $(CARGO) build --release
	@cd cmd/trapd && $(CARGO) build --release
	@cd cmd/consumers/zen && $(CARGO) build --release
	@cd cmd/otel && $(CARGO) build --release
	@cd cmd/flowgger && $(CARGO) build --release
	@mkdir -p bin
	@cp $(RPERF_CLIENT_BUILD_DIR)/$(RPERF_CLIENT_BIN) bin/serviceradar-rperf-checker
	@cp $(RPERF_SERVER_BUILD_DIR)/$(RPERF_SERVER_BIN) bin/serviceradar-rperf
	@cp $(SYSMON_BUILD_DIR)/$(SYSMON_BIN) bin/serviceradar-sysmon
	@cp cmd/trapd/target/release/serviceradar-trapd bin/serviceradar-trapd
	@cp cmd/consumers/zen/target/release/zen-consumer bin/serviceradar-zen-consumer
	@cp cmd/otel/target/release/serviceradar-otel bin/serviceradar-otel
	@cp cmd/flowgger/target/release/flowgger bin/serviceradar-flowgger

# OCaml build targets
.PHONY: build-ocaml
build-ocaml: ## Build OCaml libraries
	@echo "$(COLOR_BOLD)Building OCaml libraries$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) build @all

.PHONY: kodata-prep
kodata-prep: build-web ## Prepare kodata directories
	@echo "$(COLOR_BOLD)Preparing kodata directories$(COLOR_RESET)"
	@mkdir -p cmd/core/.kodata
	@cp -r pkg/core/api/web/dist cmd/core/.kodata/web

# Build Debian packages
.PHONY: deb-agent
deb-agent: build-web ## Build the agent Debian package
	@echo "$(COLOR_BOLD)Building agent Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb agent

.PHONY: deb-poller
deb-poller: build-web ## Build the poller Debian package
	@echo "$(COLOR_BOLD)Building poller Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb poller

.PHONY: deb-core
deb-core: build-web ## Build the core Debian package (standard)
	@echo "$(COLOR_BOLD)Building core Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb core

.PHONY: deb-web
deb-web: build-web ## Build the web Debian package
	@echo "$(COLOR_BOLD)Building web Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb web

.PHONY: deb-kv
deb-kv: ## Build the KV Debian package
	@echo "$(COLOR_BOLD)Building KV Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb kv

.PHONY: deb-sync
deb-sync: ## Build the KV Sync Debian package
	@echo "$(COLOR_BOLD)Building KV Sync Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb sync

.PHONY: deb-core-container
deb-core-container: build-web ## Build the core Debian package with container support
	@echo "$(COLOR_BOLD)Building core Debian package with container support$(COLOR_RESET)"
	@VERSION=$(VERSION) BUILD_TAGS=containers ./scripts/setup-package.sh --type=deb core

.PHONY: deb-dusk
deb-dusk: ## Build the Dusk checker Debian package
	@echo "$(COLOR_BOLD)Building Dusk checker Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb dusk-checker

.PHONY: deb-snmp
deb-snmp: ## Build the SNMP checker Debian package
	@echo "$(COLOR_BOLD)Building SNMP checker Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb snmp-checker

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
deb-all-container: ## Build all Debian packages with container support for core
	@echo "$(COLOR_BOLD)Building all Debian packages with container support for core$(COLOR_RESET)"
	@VERSION=$(VERSION) BUILD_TAGS=containers ./scripts/setup-package.sh --type=deb core
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb agent
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb poller
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb web
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb nats
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb kv
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb sync
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb dusk-checker
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb snmp-checker
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb rperf-server
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb rperf-client
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb cli
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=deb sysmon-checker

# Build RPM packages
.PHONY: rpm-core
rpm-core: ## Build the core RPM package
	@echo "$(COLOR_BOLD)Building core RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm core

.PHONY: rpm-agent
rpm-agent: ## Build the agent RPM package
	@echo "$(COLOR_BOLD)Building agent RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm agent

.PHONY: rpm-poller
rpm-poller: ## Build the poller RPM package
	@echo "$(COLOR_BOLD)Building poller RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm poller

.PHONY: rpm-web
rpm-web: ## Build the web RPM package
	@echo "$(COLOR_BOLD)Building web RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm web

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

.PHONY: rpm-dusk
rpm-dusk: ## Build the Dusk checker RPM package
	@echo "$(COLOR_BOLD)Building Dusk checker RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm dusk-checker

.PHONY: rpm-snmp
rpm-snmp: ## Build the SNMP checker RPM package
	@echo "$(COLOR_BOLD)Building SNMP checker RPM package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-package.sh --type=rpm snmp-checker

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

# Web UI build
.PHONY: build-web
build-web: ## Build the Next.js web interface
	@echo "$(COLOR_BOLD)Building Next.js web interface$(COLOR_RESET)"
	@NEXT_PUBLIC_VERSION=$(VERSION) ./tools/bazel/bazel build //pkg/core/api/web:files
	@BAZEL_BIN=$$(./tools/bazel/bazel info bazel-bin) && \
		rm -rf pkg/core/api/web/.next && \
		mkdir -p pkg/core/api/web/.next && \
		cp -R $$BAZEL_BIN/pkg/core/api/web/.next/. pkg/core/api/web/.next/

# RPerf plugin specific targets
.PHONY: build-rperf-checker
build-rperf-checker: generate-proto ## Build only the rperf plugin
	@echo "$(COLOR_BOLD)Building Rust rperf checker$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && $(CARGO) build --release
	@mkdir -p bin
	@cp -v $(shell pwd)/cmd/checkers/rperf-client/target/release/$(RPERF_CLIENT_BIN) bin/serviceradar-rperf-checker

.PHONY: run-rperf-checker
run-rperf-checker: build-rperf-checker ## Run the rperf plugin
	@echo "$(COLOR_BOLD)Running rperf checker$(COLOR_RESET)"
	@./bin/serviceradar-rperf-checker $(ARGS)

# RPerf server specific targets
.PHONY: build-rperf
build-rperf: generate-proto ## Build only the rperf server
	@echo "$(COLOR_BOLD)Building Rust rperf server$(COLOR_RESET)"
	@cd cmd/checkers/rperf-server && $(CARGO) build --release
	@mkdir -p bin
	@cp -v $(shell pwd)/cmd/checkers/rperf-server/target/release/$(RPERF_SERVER_BIN) bin/serviceradar-rperf

.PHONY: run-rperf
run-rperf: build-rperf ## Run the rperf server
	@echo "$(COLOR_BOLD)Running rperf server$(COLOR_RESET)"
	@./bin/serviceradar-rperf $(ARGS)

# Sysmon specific targets
.PHONY: build-sysmon
build-sysmon: generate-proto ## Build only the sysmon checker
	@echo "$(COLOR_BOLD)Building Rust sysmon checker$(COLOR_RESET)"
	@cd cmd/checkers/sysmon && $(CARGO) build --release
	@mkdir -p bin
	@cp -v $(shell pwd)/cmd/checkers/sysmon/target/release/$(SYSMON_BIN) bin/serviceradar-sysmon

.PHONY: run-sysmon
run-sysmon: build-sysmon ## Run the sysmon checker
	@echo "$(COLOR_BOLD)Running sysmon checker$(COLOR_RESET)"
	@./bin/serviceradar-sysmon $(ARGS)

# OCaml development targets
.PHONY: format-ocaml
format-ocaml: ## Format OCaml code
	@echo "$(COLOR_BOLD)Formatting OCaml code$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) build @fmt --auto-promote

.PHONY: check-format-ocaml
check-format-ocaml: ## Check OCaml code formatting
	@echo "$(COLOR_BOLD)Checking OCaml code formatting$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) build @fmt

.PHONY: watch-ocaml
watch-ocaml: ## OCaml development watch mode - rebuilds on file changes
	@echo "$(COLOR_BOLD)Starting OCaml watch mode$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) build @all --watch

.PHONY: test-watch-ocaml
test-watch-ocaml: ## Run OCaml tests in watch mode
	@echo "$(COLOR_BOLD)Starting OCaml test watch mode$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) test --watch

.PHONY: doc-ocaml
doc-ocaml: ## Build OCaml documentation
	@echo "$(COLOR_BOLD)Building OCaml documentation$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) build @doc

.PHONY: install-ocaml
install-ocaml: ## Install OCaml library locally
	@echo "$(COLOR_BOLD)Installing OCaml library locally$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) install

.PHONY: example-ocaml
example-ocaml: ## Run OCaml example query
	@echo "$(COLOR_BOLD)Running OCaml example query$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) exec examples/query

.PHONY: compression-example-ocaml
compression-example-ocaml: ## Run OCaml compression example
	@echo "$(COLOR_BOLD)Running OCaml compression example$(COLOR_RESET)"
	@$(OPAM) exec -- $(DUNE) exec examples/compression_example

# Default target
.DEFAULT_GOAL := help
