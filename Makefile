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
BUF_VERSION ?= v1.70.0
BUF ?= go run github.com/bufbuild/buf/cmd/buf@$(BUF_VERSION)
# Must match the pin in .github/workflows/golangci-lint.yml -- that workflow is the gate a PR
# has to satisfy, and the two golangci-lint releases do not agree on what is a finding. v2.11.4
# bundles goconst v1.8.2, v2.12.2 bundles v1.10.0, and the newer one reports ~1700 findings in
# this tree that the pinned one reports zero of.
GOLANGCI_LINT_VERSION ?= v2.11.4
GOLANGCI_LINT_DIR ?= $(shell $(GO) env GOPATH)/bin/golangci-lint-$(GOLANGCI_LINT_VERSION)
GOLANGCI_LINT ?= $(GOLANGCI_LINT_DIR)/golangci-lint
GOLANGCI_LINT_TIMEOUT ?= 30m
GO_LINT_PACKAGES ?= ./go/... ./proto/...
SWIFTLINT ?= swiftlint

# Canonical full-workspace Bazel arguments. The cache-proxy targets below reuse the existing
# build/test recipes with target-specific flag overrides so they cannot drift from the
# commands developers and CI already run.
BAZEL ?= bazel
BAZEL_CI_FLAGS ?= -c opt --config=remote
# EMPTY ON PURPOSE, AND IT MUST NOT NAME A PROFILE THAT NO LONGER EXISTS.
#
# The cache proxy used to be opt-in via `--config=cache_proxy`. It is now the default for
# every remote build: //.bazelrc sends `build:cache_only --remote_cache` to the shared Envoy
# edge, and remote_base/--config=ci inherit cache_only. There is nothing left to
# opt into, so the `-cache` targets below are aliases that differ only in using the CI flags.
#
# Left as a variable rather than deleted so those target names keep working. Do NOT put a
# `--config=` value here speculatively: Bazel treats an undefined config as a hard error
# ("Config value 'cache_proxy' is not defined in any .rc file", exit 2), so a stale name takes
# the whole target out rather than degrading it. This used to be enforced by
# //buildbuddy_cache_proxy_config_test.py, which asserted that every --config named here is
# defined in //.bazelrc; that test has been deleted and NOTHING enforces it now, so a stale
# --config value here fails at invocation rather than at test time.
BAZEL_CACHE_PROXY_CONFIG ?=
BAZEL_WORKSPACE_BUILD_FLAGS ?= $(BAZEL_CI_FLAGS)
BAZEL_WORKSPACE_TARGETS ?= //...
BAZEL_UNIT_TEST_FLAGS ?= $(BAZEL_CI_FLAGS)
BAZEL_UNIT_TEST_FILTERS ?= --test_tag_filters=-integration_test,-acceptance_test

# Every Mix project under elixir/, in the order CI walks them. Keep this in step with
# scripts/elixir_quality.sh workspace_projects and .github/workflows/elixir-quality.yml.
# PRs gate format + Credo (--lint-only); the rest of the Mix contract runs daily from
# //buildbuddy.yaml.
#
# This list used to be copied into lint-elixir, lint-elixir-dialyzer and format-elixir
# separately, and all three drifted: they still named `connection` and `elixir_uuid`, deleted
# in 80c1c0fa45 when vendored deps moved under //third_party, and none of them named
# `palisade`, which CI does lint. Because the loop runs under `set -eu` and
# elixir_quality.sh exits non-zero on a missing directory, `make lint-elixir` -- and therefore
# `make lint` -- died on the FIRST entry and never analyzed a single project.
ELIXIR_PROJECTS ?= datasvc palisade serviceradar_agent_gateway serviceradar_core serviceradar_core_elx serviceradar_srql web-ng

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

.PHONY: hooks-setup
hooks-setup: ## Configure repo-local git hooks and install pre-commit environments
	@which pre-commit > /dev/null || (echo "pre-commit not found, please install it first" && exit 1)
	@git config core.hooksPath .githooks
	@pre-commit install-hooks

.PHONY: compose-up
compose-up: ## Start Docker Compose stack
	@docker compose up -d

.PHONY: compose-upgrade
compose-upgrade: ## Pull images and recreate containers without destroying volumes
	@docker compose pull
	@docker compose up -d --force-recreate

.PHONY: build
build: ## Build all OCI images with Bazel (remote)
	@$(BAZEL) build $(BAZEL_CI_FLAGS) //:images

.PHONY: build-workspace
build-workspace: ## Build the full workspace with Bazel (remote)
	@$(BAZEL) build $(BAZEL_WORKSPACE_BUILD_FLAGS) $(BAZEL_WORKSPACE_TARGETS)

.PHONY: build-workspace-cache
build-workspace-cache: BAZEL_WORKSPACE_BUILD_FLAGS = $(BAZEL_CI_FLAGS) $(BAZEL_CACHE_PROXY_CONFIG)
build-workspace-cache: build-workspace ## Build the full workspace through the BuildBuddy cache proxy

.PHONY: build-web-ng
build-web-ng: ## Build just the web-ng OCI image with Bazel (remote)
	@$(BAZEL) build $(BAZEL_CI_FLAGS) //docker/images:web_ng_image_amd64

.PHONY: generate-agent-ebpf
generate-agent-ebpf: ## Regenerate checked-in agent eBPF probe artifacts
	@./scripts/generate-agent-ebpf.sh

.PHONY: verify-agent-ebpf
verify-agent-ebpf: ## Verify checked-in agent eBPF probe artifacts are current
	@./scripts/generate-agent-ebpf.sh --check

.PHONY: push-web-ng
push-web-ng: ## Build and push just web-ng on Linux/CI (macOS must use make push_all)
	@if [ "$(HOST_OS)" = "Darwin" ]; then \
		echo "error: the single-image launcher is Linux-only; use 'make push_all' on macOS" >&2; \
		exit 2; \
	fi
	@$(BAZEL) run $(BAZEL_CI_FLAGS) --stamp //docker/images:web_ng_image_amd64_push

.PHONY: push_all
push_all: ## Build and push all OCI container images (set LOCAL_COSIGN_SIGN=1 to also sign+verify locally)
	@set -eu; \
	effective_tag="$(PUSH_TAG)"; \
	if [ -z "$${effective_tag}" ]; then \
		effective_tag="sha-$$(git rev-parse HEAD)"; \
	fi; \
	if [ "$${LOCAL_COSIGN_SIGN:-0}" = "1" ]; then \
		if [ -z "$${COSIGN_KEY_REF:-}" ]; then \
			COSIGN_KEY_FILE="$${COSIGN_KEY_FILE:-$$HOME/.cosign/cosign.key}"; export COSIGN_KEY_FILE; \
			if [ -z "$${COSIGN_PASSWORD:-}" ] && [ -f "$${COSIGN_KEY_FILE}" ] && [ -t 0 ]; then \
				printf 'Cosign password: ' >&2; \
				stty -echo; \
				IFS= read -r COSIGN_PASSWORD; \
				stty echo; \
				printf '\n' >&2; \
				export COSIGN_PASSWORD; \
			fi; \
			if [ -f "$${COSIGN_KEY_FILE}" ]; then \
				cosign public-key --key "$${COSIGN_KEY_FILE}" >/dev/null || { \
					echo "error: unable to decrypt COSIGN_KEY_FILE with the provided password" >&2; \
					exit 1; \
				}; \
			fi; \
		fi; \
	fi; \
	if [ "$(HOST_OS)" = "Darwin" ]; then \
		./scripts/push_all_images.sh --tag "$${effective_tag}"; \
	else \
		$(BAZEL) run $(BAZEL_CI_FLAGS) --stamp //:push -- --tag "$${effective_tag}"; \
	fi; \
	if [ "$${LOCAL_COSIGN_SIGN:-0}" = "1" ]; then \
		./scripts/sign-oci-publish.sh; \
		$(MAKE) verify_publish VERIFY_TAG="$${effective_tag}"; \
	else \
		echo "skipping local cosign sign+verify; in-cluster signer (openbao) will sign after push"; \
	fi

.PHONY: push_all_release
push_all_release: ## Build, sign, and verify all OCI container images and first-party Wasm plugin OCI artifacts
	@set -eu; \
	effective_tag="$(PUSH_TAG)"; \
	if [ -z "$${effective_tag}" ]; then \
		effective_tag="sha-$$(git rev-parse HEAD)"; \
	fi; \
	$(MAKE) push_all LOCAL_COSIGN_SIGN=1 PUSH_TAG="$${effective_tag}"; \
	$(MAKE) push_wasm_plugins LOCAL_COSIGN_SIGN=1 PUSH_TAG="$${effective_tag}"

.PHONY: verify_publish
verify_publish: ## Verify published OCI image shape and runtime metadata (set VERIFY_TAG=<tag> to include an extra tag)
	@set -eu; \
	primary_tag="$(VERIFY_TAG)"; \
	if [ -z "$${primary_tag}" ]; then \
		primary_tag="sha-$$(git rev-parse HEAD)"; \
	fi; \
	./scripts/verify-oci-publish.sh latest "$${primary_tag}"

.PHONY: build_wasm_plugins
build_wasm_plugins: ## Build first-party Wasm plugin bundle artifacts locally with Bazel
	@bazel build //build/wasm_plugins:all_bundles

.PHONY: push_wasm_plugins
push_wasm_plugins: ## Build and publish first-party Wasm plugin OCI artifacts (set LOCAL_COSIGN_SIGN=1 to also sign+verify locally)
	@set -eu; \
	effective_tag="$(PUSH_TAG)"; \
	if [ -z "$${effective_tag}" ]; then \
		effective_tag="sha-$$(git rev-parse HEAD)"; \
	fi; \
	if [ "$${LOCAL_COSIGN_SIGN:-0}" = "1" ] && [ -z "$${COSIGN_KEY_REF:-}" ]; then \
		COSIGN_KEY_FILE="$${COSIGN_KEY_FILE:-$$HOME/.cosign/cosign.key}"; export COSIGN_KEY_FILE; \
		if [ -z "$${COSIGN_PASSWORD:-}" ] && [ -f "$${COSIGN_KEY_FILE}" ] && [ -t 0 ]; then \
			printf 'Cosign password: ' >&2; \
			stty -echo; \
			IFS= read -r COSIGN_PASSWORD; \
			stty echo; \
			printf '\n' >&2; \
			export COSIGN_PASSWORD; \
		fi; \
	fi; \
	./scripts/push_all_wasm_plugins.sh --tag "$${effective_tag}"; \
	if [ "$${LOCAL_COSIGN_SIGN:-0}" = "1" ]; then \
		./scripts/sign-wasm-plugin-publish.sh "$${effective_tag}"; \
		$(MAKE) verify_wasm_plugins VERIFY_TAG="$${effective_tag}"; \
	else \
		echo "skipping local cosign sign+verify for wasm plugins; in-cluster signer will sign after push"; \
	fi

.PHONY: verify_wasm_plugins
verify_wasm_plugins: ## Verify published Wasm plugin OCI artifacts and signatures (set VERIFY_TAG=<tag> to include an extra tag)
	@set -eu; \
	primary_tag="$(VERIFY_TAG)"; \
	if [ -z "$${primary_tag}" ]; then \
		primary_tag="sha-$$(git rev-parse HEAD)"; \
	fi; \
	./scripts/verify-wasm-plugin-publish.sh "$${primary_tag}"

# validate_addon_manifests and check_addon_dependency_isolation are GONE. Both were
# second implementations of gates Bazel already owns, and CI ran each twice:
#   //build/native_addons:validate_addon_manifests_test  runs the same Bazel-built
#     //go/tools/addon-manifest-validator over the addon.yaml files, which it takes as
#     declared data rather than globbing the worktree.
#   //build/native_addons:dependency_isolation_test  asserts the identical contract --
#     deps(//go/cmd/agent:agent) must not reach //go/pkg/addon/sdk or
#     //go/cmd/serviceradar-*-addon -- via a genquery over the real build graph instead
#     of shelling out to `go list -deps`, so it needs no Go toolchain on the runner.
# Both are members of :build_gates_test. Use `make check_addon_hermetic_build_gates`.

.PHONY: check_addon_no_stdlib_plugin
check_addon_no_stdlib_plugin: ## Forbid the Go stdlib `plugin` package in the agent + add-on builds
	@./scripts/check-addon-no-stdlib-plugin.sh

.PHONY: check_addon_deadcode_elimination
check_addon_deadcode_elimination: ## Ensure Go native add-ons do not force broad linker method retention
	@./scripts/check-addon-deadcode-elimination.sh

.PHONY: check_addon_binary_size
check_addon_binary_size: ## Per-artifact binary-size regression gate (requires go-size-analyzer / gsa; pass ARTIFACTS=...)
	@./scripts/check-addon-binary-size.sh $(ARTIFACTS)

.PHONY: check_addon_binary_size_bazel
check_addon_binary_size_bazel: ## Build all native add-on binaries and run the binary-size regression gate
	@set -eu; \
	bazel build //build/native_addons:all_binaries --remote_download_outputs=all; \
	artifacts="$$(bazel cquery --output=files //build/native_addons:all_binaries)"; \
	if [ -z "$${artifacts}" ]; then \
		echo "no native add-on binary artifacts resolved" >&2; \
		exit 1; \
	fi; \
	./scripts/check-addon-binary-size.sh $${artifacts}

.PHONY: check_addon_hermetic_build_gates
check_addon_hermetic_build_gates: ## Run Bazel-owned native add-on gate fixtures
	@bazel test //build/native_addons:build_gates_test

.PHONY: addon_build_gates
# binary-size is covered by the Bazel //build/native_addons:binary_size_test (run via
# build_gates_test), which is RBE-correct because it gets the binaries as test runfiles.
# The make check_addon_binary_size_bazel path (bazel build + a separate cquery + stat of
# the cross-config output paths) is NOT RBE-safe — those outputs aren't reliably
# materialized locally under remote execution — so it is intentionally not a prerequisite.
addon_build_gates: check_addon_no_stdlib_plugin check_addon_deadcode_elimination ## Run all add-on build/CI hygiene gates that need no secrets
	@echo "add-on build gates passed"

.PHONY: build_native_addons
build_native_addons: addon_build_gates ## Build first-party native add-on bundle artifacts locally with Bazel (gated on manifest + isolation checks)
	@bazel build -c opt //build/native_addons:all_bundles

.PHONY: check-dev-image-tags
check-dev-image-tags: ## Verify dev image tag defaults (latest + APP_TAG fallbacks)
	@scripts/check-dev-image-tags.sh

.PHONY: demo-staging-canary
demo-staging-canary: ## Configure demo-staging ArgoCD app for canary tags (web=latest, others pinned)
	@./scripts/demo-staging-canary.py --app serviceradar-demo-staging --base-tag v1.0.75 --web-tag latest

.PHONY: demo-staging-web
demo-staging-web: ## Push web-ng image (latest) and restart serviceradar-web-ng in demo-staging
	@if [ "$(HOST_OS)" = "Darwin" ]; then \
		$(MAKE) push_all; \
	else \
		$(BAZEL) run $(BAZEL_CI_FLAGS) --stamp //docker/images:web_ng_image_amd64_push; \
	fi
	@kubectl -n demo-staging rollout restart deployment/serviceradar-web-ng
	@kubectl -n demo-staging rollout status deployment/serviceradar-web-ng --timeout=300s
	@kubectl -n demo-staging get deploy serviceradar-web-ng -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

.PHONY: demo-staging-core
demo-staging-core: ## Push core image (latest) and restart serviceradar-core in demo-staging
	@if [ "$(HOST_OS)" = "Darwin" ]; then \
		$(MAKE) push_all; \
	else \
		$(BAZEL) run $(BAZEL_CI_FLAGS) --stamp //docker/images:core_image_amd64_push; \
	fi
	@kubectl -n demo-staging rollout restart deployment/serviceradar-core
	@kubectl -n demo-staging rollout status deployment/serviceradar-core --timeout=300s
	@kubectl -n demo-staging get deploy serviceradar-core -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

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
	@cd rust/otel && $(RUSTFMT) src/*.rs
	@cd rust/flowgger && $(RUSTFMT) src/*.rs src/flowgger/*.rs

.PHONY: update-rust-deps
update-rust-deps: ## Update root Cargo.lock, refresh //third_party/crate_mirror, verify with Bazel (REPIN=<mode>, VERIFY_TARGET=<label>)
	@./scripts/update-rust-bazel-deps.sh "$(if $(REPIN),$(REPIN),workspace)" "$(if $(VERIFY_TARGET),$(VERIFY_TARGET),//rust/...)"

.PHONY: lint-p0f-additions
lint-p0f-additions: ## Validate ServiceRadar p0f additions corpus grammar
	@./scripts/lint-p0f-additions.sh

.PHONY: lint-recog-additions
lint-recog-additions: ## Validate ServiceRadar Recog additions XML and license header
	@./scripts/lint-recog-additions.sh

# Installs the pinned version into its own version-scoped directory rather than asserting that
# whatever is on PATH happens to match. An earlier revision only asserted, which blocked
# `make lint` on any machine whose golangci-lint had drifted (a Homebrew upgrade was enough)
# and offered no way to fix it. Version-scoped so it never clobbers a golangci-lint the
# developer installed for other work; set GOLANGCI_LINT to override.
.PHONY: get-golangcilint
get-golangcilint: ## Install the pinned golangci-lint
	@echo "$(COLOR_BOLD)Checking golangci-lint $(GOLANGCI_LINT_VERSION)$(COLOR_RESET)"
	@test -x "$(GOLANGCI_LINT)" || \
		GOBIN="$(GOLANGCI_LINT_DIR)" $(GO) install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)

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
	@cd rust/otel && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd rust/flowgger && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy -- -D warnings
	@cd rust/srql && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) clippy --all-targets -- -D warnings
	@$(MAKE) lint-elixir
	@echo "$(COLOR_BOLD)Running web-ng assets ESLint$(COLOR_RESET)"
	@cd elixir/web-ng/assets && bun run lint

.PHONY: lint-elixir
lint-elixir: ## Run the repository-standard Elixir analyzer contract across elixir/*
	@set -eu; \
	for project in $(ELIXIR_PROJECTS); do \
		extra=""; \
		if [ "$${project}" = "web-ng" ]; then extra="--phoenix"; fi; \
		echo "$(COLOR_BOLD)Running Elixir quality ($${project})$(COLOR_RESET)"; \
		./scripts/elixir_quality.sh --project "elixir/$${project}" --skip-dialyzer $${extra}; \
	done

.PHONY: lint-elixir-dialyzer
lint-elixir-dialyzer: ## Run Dialyzer across elixir/* on demand
	@set -eu; \
	for project in $(ELIXIR_PROJECTS); do \
		echo "$(COLOR_BOLD)Running Elixir Dialyzer ($${project})$(COLOR_RESET)"; \
		(cd "elixir/$${project}" && mix deps.get && mix deps.compile && mix compile && mix dialyzer); \
	done

.PHONY: format
format: ## Run the CI clippy gate over the Rust workspace
	@./scripts/lint-rust.sh

.PHONY: format-elixir
format-elixir: ## Run mix format across the Elixir projects under elixir/*
	@set -eu; \
	for project in $(ELIXIR_PROJECTS); do \
		echo "$(COLOR_BOLD)Formatting Elixir project ($${project})$(COLOR_RESET)"; \
		(cd "elixir/$${project}" && mix format); \
	done

.PHONY: lint-go
lint-go: get-golangcilint ## Run Go linting checks
	@echo "$(COLOR_BOLD)Running Go linter$(COLOR_RESET)"
	@$(GOLANGCI_LINT) run --timeout $(GOLANGCI_LINT_TIMEOUT) $$(go list -f '{{.Dir}}' $(GO_LINT_PACKAGES))

.PHONY: test
test: ## Run every unit test the way CI does (bazel, remote, opt)
	@echo "$(COLOR_BOLD)Running all unit tests via bazel$(COLOR_RESET)"
	@$(BAZEL) test $(BAZEL_UNIT_TEST_FLAGS) $(BAZEL_WORKSPACE_TARGETS) $(BAZEL_UNIT_TEST_FILTERS)

.PHONY: test-cache
test-cache: BAZEL_UNIT_TEST_FLAGS = $(BAZEL_CI_FLAGS) $(BAZEL_CACHE_PROXY_CONFIG)
test-cache: test ## Run the canonical unit-test sweep through the BuildBuddy cache proxy

# Everything CI runs before it will accept a release, in one command. `test-toolchains`
# below is the per-language path (go test / cargo test / vitest / mix precommit); it is
# NOT a substitute, because it does not build or run the bazel test targets. Elixir unit
# shards live only in bazel, so two broken Elixir suites reached a release tag while the
# per-language target stayed green. Run this before cutting anything.
.PHONY: test-unit
test-unit: test ## Alias for `test` (bazel unit tests)

.PHONY: test-toolchains
test-toolchains: $(TEST_PREREQS) get-bun ## Per-language tests + Go coverage profiles (not a CI substitute)
	@echo "$(COLOR_BOLD)Running Go short tests$(COLOR_RESET)"
	@$(GO) test $(GO_TEST_TAGS) -timeout=45s -race -count=10 -failfast -shuffle=on -short ./... -coverprofile=./cover.short.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Go long tests$(COLOR_RESET)"
	@$(GO) test $(GO_TEST_TAGS) -timeout=120s -race -count=1 -failfast -shuffle=on ./... -coverprofile=./cover.long.profile -covermode=atomic -coverpkg=./...
	@echo "$(COLOR_BOLD)Running Rust tests$(COLOR_RESET)"
	@cd rust/rperf-client && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
	@cd rust/trapd && RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO) test
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

.PHONY: test-all
test-all: test test-toolchains ## Bazel unit tests + per-language tests (database integration is explicit)

.PHONY: check
check: ## Pre-push gate: build + test + race-test everything on the remote cache
	@./scripts/check.sh

.PHONY: check-coverage
# Depends on test-toolchains, not test: the thresholds are checked against the
# cover.*.profile files that only the Go leg of test-toolchains writes.
check-coverage: test-toolchains ## Check test coverage against thresholds
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
	@$(BAZEL) build $(BAZEL_CI_FLAGS) //elixir/web-ng:release_tar


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
		proto/automation_launch_envelope.proto
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
		proto/desktop_media.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/remote_capture.proto
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
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		proto/agent/netprobe/v1/netprobe.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		--go-grpc_out=proto --go-grpc_opt=paths=source_relative \
		proto/agent/addon/v1/addon.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		proto/agent/discovery/v1/discovery.proto
	@protoc -I=proto -I=. \
		--go_out=proto --go_opt=paths=source_relative \
		proto/metric/v1/metric.proto
	@echo "$(COLOR_BOLD)Generated Go protobuf code$(COLOR_RESET)"

# Elixir protobuf regeneration
# -----------------------------------------------------------------------------
# Run `make generate-proto-elixir` after editing any proto/*.proto file that
# already has a checked-in Elixir binding under
# elixir/serviceradar_core/lib/serviceradar/proto/ (e.g. flow/flow.proto). The
# target keeps the .pb.ex stubs in lockstep with the proto contract so manual
# edits (such as the B-6 `cmdline` -> `redacted_cmdline` rename) cannot drift.
#
# The escript is pinned to the same protobuf hex version declared in
# elixir/serviceradar_core/mix.exs ({:protobuf, "~> 0.16.0"}) and is invoked
# via the protoc plugin discovery path so contributors do not need to mutate
# their shell rc files.
ELIXIR_PROTOBUF_VERSION ?= 0.16.0
ELIXIR_PROTO_OUT ?= elixir/serviceradar_core/lib/serviceradar/proto
PROTOC_GEN_ELIXIR ?= $(HOME)/.mix/escripts/protoc-gen-elixir

.PHONY: install-protoc-gen-elixir
install-protoc-gen-elixir: ## Install the protoc-gen-elixir escript pinned to the protobuf hex dep
	@if [ ! -x "$(PROTOC_GEN_ELIXIR)" ] || \
		[ "$$($(PROTOC_GEN_ELIXIR) --version 2>/dev/null)" != "$(ELIXIR_PROTOBUF_VERSION)" ]; then \
		echo "$(COLOR_BOLD)Installing protoc-gen-elixir $(ELIXIR_PROTOBUF_VERSION)$(COLOR_RESET)"; \
		mix escript.install --force hex protobuf $(ELIXIR_PROTOBUF_VERSION); \
	fi

.PHONY: generate-proto-elixir
generate-proto-elixir: install-protoc-gen-elixir ## Generate Elixir code from protobuf definitions (run after proto contract changes)
	@echo "$(COLOR_BOLD)Generating Elixir code from protobuf definitions$(COLOR_RESET)"
	@mkdir -p $(ELIXIR_PROTO_OUT)
	@PATH="$(dir $(PROTOC_GEN_ELIXIR)):$$PATH" protoc -I=proto -I=. \
		--elixir_out=plugins=grpc:$(ELIXIR_PROTO_OUT) \
		proto/flow/flow.proto \
		proto/automation_launch_envelope.proto \
		proto/core_service.proto \
		proto/kv.proto \
		proto/monitoring.proto \
		proto/nats_account.proto \
		proto/data_service.proto \
		proto/camera_media.proto \
		proto/desktop_media.proto \
		proto/remote_capture.proto \
		proto/identitymap/v1/identity_map.proto \
		proto/agent/netprobe/v1/netprobe.proto \
		proto/agent/addon/v1/addon.proto \
		proto/agent/discovery/v1/discovery.proto \
		proto/metric/v1/metric.proto
	@cd elixir/serviceradar_core && \
		mix format --force "$(abspath $(ELIXIR_PROTO_OUT))/**/*.pb.ex"
	@echo "$(COLOR_BOLD)Generated Elixir protobuf code under $(ELIXIR_PROTO_OUT)$(COLOR_RESET)"

.PHONY: verify-proto-elixir
verify-proto-elixir: generate-proto-elixir ## Fail if regenerated Elixir bindings differ from the checked-in tree (CI drift guard)
	@git diff --exit-code -- $(ELIXIR_PROTO_OUT) || ( \
		echo "$(COLOR_BOLD)Elixir protobuf bindings are out of sync with proto/. Run 'make generate-proto-elixir' and commit the result.$(COLOR_RESET)"; \
		exit 1; \
	)

.PHONY: proto-lint
proto-lint: ## Lint protobuf definitions with Buf
	@$(BUF) lint proto --path proto/agent/netprobe/v1

# Wire-compatibility gate (GitHub #4026). Compares the working tree against the
# merge base so a PR is judged on what it changes, not on how far behind it is.
# PROTO_BREAKING_AGAINST is overridable for local runs against another ref.
PROTO_BREAKING_BASE ?= origin/staging
PROTO_BREAKING_AGAINST ?= .git#ref=$(PROTO_BREAKING_BASE)

.PHONY: proto-breaking
proto-breaking: ## Fail on wire-incompatible protobuf changes vs the merge base
	@$(BUF) breaking --against '$(PROTO_BREAKING_AGAINST)'

.PHONY: build-binaries
build-binaries: generate-proto ## Build all binaries locally (Go + Rust)
	@echo "$(COLOR_BOLD)Building all binaries$(COLOR_RESET)"
	@$(GO) build -ldflags "-X github.com/carverauto/serviceradar/go/cmd/agent.Version=$(VERSION)" -o bin/serviceradar-agent go/cmd/agent/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-core cmd/core/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/serviceradar-datasvc go/cmd/data-services/main.go
	@$(GO) build -ldflags "-X main.version=$(VERSION)" -o bin/srctl go/cmd/cli/main.go
	@ln -sf srctl bin/serviceradar-cli
	@echo "$(COLOR_BOLD)Building Rust binaries$(COLOR_RESET)"
	@cd rust/rperf-client && $(CARGO) build --release
	@cd rust/rperf-server && $(CARGO) build --release
	@cd rust/trapd && $(CARGO) build --release
	@cd rust/otel && $(CARGO) build --release
	@cd rust/flowgger && $(CARGO) build --release
	@mkdir -p bin
	@cp $(RPERF_CLIENT_BUILD_DIR)/$(RPERF_CLIENT_BIN) bin/serviceradar-rperf-checker
	@cp $(RPERF_SERVER_BUILD_DIR)/$(RPERF_SERVER_BIN) bin/serviceradar-rperf
	@cp rust/trapd/target/release/serviceradar-trapd bin/serviceradar-trapd
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
