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
GOLANGCI_LINT_VERSION ?= v1.64.5

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

.PHONY: get-golangcilint
get-golangcilint: ## Install golangci-lint
	@echo "$(COLOR_BOLD)Installing golangci-lint $(GOLANGCI_LINT_VERSION)$(COLOR_RESET)"
	@test -f $(GOLANGCI_LINT) || curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $$($(GO) env GOPATH)/bin $(GOLANGCI_LINT_VERSION)

.PHONY: lint
lint: get-golangcilint ## Run linting checks
	@echo "$(COLOR_BOLD)Running linter$(COLOR_RESET)"
	@$(GOLANGCI_LINT) run ./...

.PHONY: test
test: ## Run all tests with coverage
	@echo "$(COLOR_BOLD)Running short tests$(COLOR_RESET)"
	@$(GO) test -timeout=3s -race -count=10 -failfast -shuffle=on -short ./... -coverprofile=./cover.short.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running long tests$(COLOR_RESET)"
	@$(GO) test -timeout=10s -race -count=1 -failfast -shuffle=on ./... -coverprofile=./cover.long.profile -covermode=atomic -coverpkg=./...

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

.PHONY: build
build: ## Build all binaries
	@echo "$(COLOR_BOLD)Building all binaries$(COLOR_RESET)"
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-agent cmd/agent/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-poller cmd/poller/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-dusk-checker cmd/checkers/dusk/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-core cmd/core/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-snmp-checker cmd/checkers/snmp/main.go

.PHONY: kodata-prep
kodata-prep: build-web ## Prepare kodata directories
	@echo "$(COLOR_BOLD)Preparing kodata directories$(COLOR_RESET)"
	@mkdir -p cmd/core/.kodata
	@cp -r pkg/core/api/web/dist cmd/core/.kodata/web

.PHONY: container-build
container-build: kodata-prep ## Build container images with ko
	@echo "$(COLOR_BOLD)Building container images with ko$(COLOR_RESET)"
	@cd cmd/agent && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-agent GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION) --bare .
	@cd cmd/poller && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-poller GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION) --bare .
	@echo "$(COLOR_BOLD)Building core container with CGO using Docker (amd64 only)$(COLOR_RESET)"
	@docker buildx build --platform=linux/amd64 -f Dockerfile.build \
		-t $(KO_DOCKER_REPO)/serviceradar-core:$(VERSION) \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_TAGS=containers \
		--push .
	@cd cmd/checkers/dusk && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-dusk-checker GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION) --bare .
	@cd cmd/checkers/snmp && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-snmp-checker GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION) --bare .

.PHONY: container-push
container-push: kodata-prep ## Build and push container images with ko
	@echo "$(COLOR_BOLD)Building and pushing container images with ko$(COLOR_RESET)"
	@cd cmd/agent && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-agent GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION),latest --bare .
	@cd cmd/poller && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-poller GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION),latest --bare .
	@echo "$(COLOR_BOLD)Building and pushing core container with CGO using Docker (amd64 only)$(COLOR_RESET)"
	@docker buildx build --platform=linux/amd64 -f Dockerfile.build \
		-t $(KO_DOCKER_REPO)/serviceradar-core:$(VERSION) \
		-t $(KO_DOCKER_REPO)/serviceradar-core:latest \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_TAGS=containers \
		--push .
	@cd cmd/checkers/dusk && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-dusk-checker GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION),latest --bare .
	@cd cmd/checkers/snmp && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/serviceradar-snmp-checker GOFLAGS="-tags=containers" ko build --platform=$(PLATFORMS) --tags=$(VERSION),latest --bare .

# Build Debian packages
.PHONY: deb-agent
deb-agent: build-web ## Build the agent Debian package
	@echo "$(COLOR_BOLD)Building agent Debian package$(COLOR_RESET)"
	@./scripts/setup-deb-agent.sh

.PHONY: deb-poller
deb-poller: build-web ## Build the poller Debian package
	@echo "$(COLOR_BOLD)Building poller Debian package$(COLOR_RESET)"
	@./scripts/setup-deb-poller.sh

.PHONY: deb-core
deb-core: build-web ## Build the core Debian package (standard)
	@echo "$(COLOR_BOLD)Building core Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-deb-core.sh

.PHONY: deb-web
deb-web: build-web ## Build the web Debian package
	@echo "$(COLOR_BOLD)Building web Debian package$(COLOR_RESET)"
	@VERSION=$(VERSION) ./scripts/setup-deb-web.sh

.PHONY: deb-core-container
deb-core-container: build-web ## Build the core Debian package with container support
	@echo "$(COLOR_BOLD)Building core Debian package with container support$(COLOR_RESET)"
	@VERSION=$(VERSION) BUILD_TAGS=containers ./scripts/setup-deb-core.sh

.PHONY: deb-dusk
deb-dusk: ## Build the Dusk checker Debian package
	@echo "$(COLOR_BOLD)Building Dusk checker Debian package$(COLOR_RESET)"
	@./scripts/setup-deb-dusk-checker.sh

.PHONY: deb-snmp
deb-snmp: ## Build the SNMP checker Debian package
	@echo "$(COLOR_BOLD)Building SNMP checker Debian package$(COLOR_RESET)"
	@./scripts/setup-deb-snmp-checker.sh

.PHONY: deb-all
deb-all: deb-agent deb-poller deb-core deb-web deb-dusk deb-snmp ## Build all Debian packages
	@echo "$(COLOR_BOLD)All Debian packages built$(COLOR_RESET)"

.PHONY: deb-all-container
deb-all-container: deb-agent deb-poller deb-core-container deb-web deb-dusk deb-snmp ## Build all Debian packages with container support for core
	@echo "$(COLOR_BOLD)All Debian packages built (with container support for core)$(COLOR_RESET)"

# Build RPM packages
.PHONY: rpm-prep
rpm-prep: ## Prepare directory structure for RPM building
	@echo "$(COLOR_BOLD)Preparing RPM build environment$(COLOR_RESET)"
	@mkdir -p release-artifacts/rpm

.PHONY: rpm-core
rpm-core: rpm-prep ## Build the core RPM package
	@echo "$(COLOR_BOLD)Building core RPM package$(COLOR_RESET)"
	@docker build \
		--platform linux/amd64 \
		--build-arg VERSION="$(VERSION)" \
		--build-arg RELEASE="$(RELEASE)" \
		-f Dockerfile-rpm.core \
		-t serviceradar-rpm-core \
		.
	@docker create --name temp-core-container serviceradar-rpm-core
	@docker cp temp-core-container:/rpms/. ./release-artifacts/rpm/
	@docker rm temp-core-container

.PHONY: rpm-web
rpm-web: rpm-prep ## Build the web RPM package
	@echo "$(COLOR_BOLD)Building web RPM package$(COLOR_RESET)"
	@docker build \
		--platform linux/amd64 \
		--build-arg VERSION="$(VERSION)" \
		--build-arg RELEASE="$(RELEASE)" \
		-f Dockerfile.rpm.web \
		-t serviceradar-rpm-web \
		.
	@docker create --name temp-web-container serviceradar-rpm-web
	@docker cp temp-web-container:/rpms/. ./release-artifacts/rpm/
	@docker rm temp-web-container

.PHONY: rpm-agent
rpm-agent: rpm-prep ## Build the agent RPM package
	@echo "$(COLOR_BOLD)Building agent RPM package$(COLOR_RESET)"
	@docker build \
		--platform linux/amd64 \
		--build-arg VERSION="$(VERSION)" \
		--build-arg RELEASE="$(RELEASE)" \
		--build-arg COMPONENT="agent" \
		--build-arg BINARY_PATH="./cmd/agent" \
		-f Dockerfile.rpm.simple \
		-t serviceradar-rpm-agent \
		.
	@docker create --name temp-agent-container serviceradar-rpm-agent
	@docker cp temp-agent-container:/rpms/. ./release-artifacts/rpm/
	@docker rm temp-agent-container

.PHONY: rpm-poller
rpm-poller: rpm-prep ## Build the poller RPM package
	@echo "$(COLOR_BOLD)Building poller RPM package$(COLOR_RESET)"
	@docker build \
		--platform linux/amd64 \
		--build-arg VERSION="$(VERSION)" \
		--build-arg RELEASE="$(RELEASE)" \
		--build-arg COMPONENT="poller" \
		--build-arg BINARY_PATH="./cmd/poller" \
		-f Dockerfile.rpm.simple \
		-t serviceradar-rpm-poller \
		.
	@docker create --name temp-poller-container serviceradar-rpm-poller
	@docker cp temp-poller-container:/rpms/. ./release-artifacts/rpm/
	@docker rm temp-poller-container

.PHONY: rpm-dusk
rpm-dusk: rpm-prep ## Build the dusk checker RPM package
	@echo "$(COLOR_BOLD)Building dusk checker RPM package$(COLOR_RESET)"
	@docker build \
		--platform linux/amd64 \
		--build-arg VERSION="$(VERSION)" \
		--build-arg RELEASE="$(RELEASE)" \
		--build-arg COMPONENT="dusk-checker" \
		--build-arg BINARY_PATH="./cmd/checkers/dusk" \
		-f Dockerfile.rpm.simple \
		-t serviceradar-rpm-dusk-checker \
		.
	@docker create --name temp-dusk-container serviceradar-rpm-dusk-checker
	@docker cp temp-dusk-container:/rpms/. ./release-artifacts/rpm/
	@docker rm temp-dusk-container

.PHONY: rpm-snmp
rpm-snmp: rpm-prep ## Build the SNMP checker RPM package
	@echo "$(COLOR_BOLD)Building SNMP checker RPM package$(COLOR_RESET)"
	@docker build \
		--platform linux/amd64 \
		--build-arg VERSION="$(VERSION)" \
		--build-arg RELEASE="$(RELEASE)" \
		--build-arg COMPONENT="snmp-checker" \
		--build-arg BINARY_PATH="./cmd/checkers/snmp" \
		-f Dockerfile.rpm.simple \
		-t serviceradar-rpm-snmp-checker \
		.
	@docker create --name temp-snmp-container serviceradar-rpm-snmp-checker
	@docker cp temp-snmp-container:/rpms/. ./release-artifacts/rpm/
	@docker rm temp-snmp-container

.PHONY: rpm-all
rpm-all: rpm-core rpm-web rpm-agent rpm-poller rpm-dusk rpm-snmp ## Build all RPM packages
	@echo "$(COLOR_BOLD)All RPM packages built$(COLOR_RESET)"

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

# Build web UI
.PHONY: build-web
build-web: ## Build the Next.js web interface
	@echo "$(COLOR_BOLD)Building Next.js web interface$(COLOR_RESET)"
	@cd web && npm install && npm run build
	@mkdir -p pkg/core/api/web
	@cp -r web/dist pkg/core/api/web/

# Default target
.DEFAULT_GOAL := help