GO ?= go
GOBIN ?= $$($(GO) env GOPATH)/bin
GOLANGCI_LINT ?= $(GOBIN)/golangci-lint
GOLANGCI_LINT_VERSION ?= v1.60.3

# Code tidy
.PHONY: tidy
tidy:
	go mod tidy
	go fmt ./...

.PHONY: get-golangcilint
get-golangcilint:
	test -f $(GOLANGCI_LINT) || curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $$($(GO) env GOPATH)/bin $(GOLANGCI_LINT_VERSION)

# Runs lint on entire repo
.PHONY: lint
lint: get-golangcilint
	$(GOLANGCI_LINT) run ./...

# Runs tests on entire repo
.PHONY: test
test:
	go test -timeout=3s -race -count=10 -failfast -shuffle=on -short ./... -coverprofile=./cover.short.profile -covermode=atomic -coverpkg=./...
	go test -timeout=10s -race -count=1 -failfast  -shuffle=on ./... -coverprofile=./cover.long.profile -covermode=atomic -coverpkg=./...

# Runs test coverage check
.PHONY: check-coverage
check-coverage: test
	go run ./main.go --config=./.github/.testcoverage.yml

# View coverage profile
.PHONY: view-coverage
view-coverage:
	go test ./... -coverprofile=./cover.all.profile -covermode=atomic -coverpkg=./...
	go tool cover -html=cover.all.profile -o=cover.html
	xdg-open cover.html

# Create a new release
release:
	@echo "Creating release $(NEXT_VERSION)"
	@git tag -a $(NEXT_VERSION) -m "Release $(NEXT_VERSION)"
	@git push origin $(NEXT_VERSION)

# Test release locally
test-release:
	goreleaser release --snapshot --clean --skip-publish

# Show current version
version:
	@echo "Current version: $(VERSION)"
	@echo "Next version: $(NEXT_VERSION)"