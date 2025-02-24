# Go configuration
GO ?= go
GOBIN ?= $$($(GO) env GOPATH)/bin
GOLANGCI_LINT ?= $(GOBIN)/golangci-lint
GOLANGCI_LINT_VERSION ?= v1.64.5

# Version configuration
VERSION ?= $(shell git describe --tags --always)
NEXT_VERSION ?= $(shell git describe --tags --abbrev=0 | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g')

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

.PHONY: build
build: ## Build all binaries
	@echo "$(COLOR_BOLD)Building all binaries$(COLOR_RESET)"
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-agent cmd/agent/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-poller cmd/poller/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-dusk-checker cmd/checkers/dusk/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-cloud cmd/cloud/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-snmp-checker cmd/checkers/snmp/main.go

.PHONY: build-web
build-web: ## Build web UI
	@echo "$(COLOR_BOLD)Building web UI$(COLOR_RESET)"
	@./scripts/build-web.sh
	@mkdir -p pkg/cloud/api/web/
	@cp -r web/dist pkg/cloud/api/web/

.PHONY: kodata-prep
kodata-prep: build-web ## Prepare kodata directories
	@echo "$(COLOR_BOLD)Preparing kodata directories$(COLOR_RESET)"
	@mkdir -p cmd/cloud/.kodata
	@cp -r pkg/cloud/api/web/dist cmd/cloud/.kodata/web

.PHONY: container-build
container-build: kodata-prep ## Build container images with ko
	@echo "$(COLOR_BOLD)Building container images with ko$(COLOR_RESET)"
	@GOFLAGS="-tags=containers" KO_DOCKER_REPO=$(KO_DOCKER_REPO) ko build \
		--platform=$(PLATFORMS) \
		--base-import-paths \
		--tags=$(VERSION) \
		--bare \
		--image-refs=image-refs.txt \
		./cmd/agent \
		./cmd/poller \
		./cmd/cloud \
		./cmd/checkers/dusk \
		./cmd/checkers/snmp

.PHONY: container-push
container-push: kodata-prep ## Build and push container images with ko
	@echo "$(COLOR_BOLD)Building and pushing container images with ko$(COLOR_RESET)"
	@GOFLAGS="-tags=containers" KO_DOCKER_REPO=$(KO_DOCKER_REPO) ko build \
		--platform=$(PLATFORMS) \
		--base-import-paths \
		--tags=$(VERSION),latest \
		--bare \
		--image-refs=image-refs.txt \
		./cmd/agent \
		./cmd/poller \
		./cmd/cloud \
		./cmd/checkers/dusk \
		./cmd/checkers/snmp

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

# Default target
.DEFAULT_GOAL := help