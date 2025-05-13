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
GOBIN ?= $$($(GO) env GOPATH)/bin
GOLANGCI_LINT ?= $(GOBIN)/golangci-lint
GOLANGCI_LINT_VERSION ?= v2.0.2

# Rust configuration
CARGO ?= cargo
RUSTFMT ?= rustfmt

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

.PHONY: help
help: ## Show this help message
	@echo "$(COLOR_BOLD)Available targets:$(COLOR_RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(COLOR_CYAN)%-20s$(COLOR_RESET) %s\n", $$1, $$2}'

.PHONY: tidy
tidy: ## Tidy and format Go code
	@echo "$(COLOR_BOLD)Tidying Go modules and formatting code$(COLOR_RESET)"
	@$(GO) mod tidy
	@$(GO) fmt ./...
	@echo "$(COLOR_BOLD)Formatting Rust code$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && $(RUSTFMT) src/*.rs
	@cd cmd/checkers/sysmon && $(RUSTFMT) src/*.rs

.PHONY: get-golangcilint
get-golangcilint: ## Install golangci-lint
	@echo "$(COLOR_BOLD)Installing golangci-lint $(GOLANGCI_LINT_VERSION)$(COLOR_RESET)"
	@test -f $(GOLANGCI_LINT) || curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $$($(GO) env GOPATH)/bin $(GOLANGCI_LINT_VERSION)

.PHONY: lint
lint: get-golangcilint ## Run linting checks
	@echo "$(COLOR_BOLD)Running Go linter$(COLOR_RESET)"
	@$(GOLANGCI_LINT) run ./...
	@echo "$(COLOR_BOLD)Running Rust linter$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && $(CARGO) clippy -- -D warnings
	@cd cmd/checkers/sysmon && $(CARGO) clippy -- -D warnings

.PHONY: test
test: ## Run all tests with coverage
	@echo "$(COLOR_BOLD)Running Go short tests$(COLOR_RESET)"
	@$(GO) test -timeout=3s -race -count=10 -failfast -shuffle=on -short ./... -coverprofile=./cover.short.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Go long tests$(COLOR_RESET)"
	@$(GO) test -timeout=10s -race -count=1 -failfast -shuffle=on ./... -coverprofile=./cover.long.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Rust tests$(COLOR_RESET)"
	@cd cmd/checkers/rperf-client && $(CARGO) test
	@cd cmd/checkers/sysmon && $(CARGO) test

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

.PHONY: test-release
test-release: ## Test release locally using goreleaser
	@echo "$(COLOR_BOLD)Testing release locally$(COLOR_RESET)"
	@goreleaser release --snapshot --clean --skip-publish

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

.PHONY: generate-proto
generate-proto: ## Generate Go and Rust code from protobuf definitions
	@echo "$(COLOR_BOLD)Generating Go code from protobuf definitions$(COLOR_RESET)"
	@protoc -I=proto \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/kv.proto
	@protoc -I=proto \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/monitoring.proto
	@protoc -I=proto \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/rperf/rperf.proto
	@protoc -I=proto \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/flow/flow.proto
	@protoc -I=cmd/checkers/sysmon/src/proto \
		--go_out=cmd/checkers/sysmon/src/proto --go_opt=paths=source_relative \
		--go-grpc_out=cmd/checkers/sysmon/src/proto --go-grpc_opt=paths=source_relative \
		cmd/checkers/sysmon/src/proto/monitoring.proto
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
	@mkdir -p bin
	@cp $(RPERF_CLIENT_BUILD_DIR)/$(RPERF_CLIENT_BIN) bin/serviceradar-rperf-checker
	@cp $(RPERF_SERVER_BUILD_DIR)/$(RPERF_SERVER_BIN) bin/serviceradar-rperf
	@cp $(SYSMON_BUILD_DIR)/$(SYSMON_BIN) bin/serviceradar-sysmon

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
	@cd web && npm install && npm run build
	@mkdir -p pkg/core/api/web
	@cp -r web/dist pkg/core/api/web/

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

# Default target
.DEFAULT_GOAL := help