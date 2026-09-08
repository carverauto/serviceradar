# Tasks: Remove Deprecated Golang Core Service

## 1. Source Code Cleanup

### 1.1 pkg/models Cleanup (Remove Webhook Dependency)
- [ ] 1.1.1 Remove `Webhooks` field from `CoreServiceConfig` in `pkg/models/config.go`
- [ ] 1.1.2 Remove import of `pkg/core/alerts` from `pkg/models/config.go`
- [ ] 1.1.3 Remove any webhook-related JSON marshaling logic in `pkg/models/config.go`
- [ ] 1.1.4 Verify `go build ./pkg/models/...` passes

### 1.2 Remove pkg/mcp (Deprecated MCP Implementation)
- [ ] 1.2.1 Remove `pkg/mcp/` directory entirely
- [ ] 1.2.2 Remove mcp alias from `alias/BUILD.bazel`

### 1.3 Remove pkg/core (All Subpackages)
- [ ] 1.3.1 Remove `pkg/core/` directory entirely (includes alerts, api, auth, bootstrap, templateregistry)
- [ ] 1.3.2 Remove core package aliases from `alias/BUILD.bazel`

### 1.4 Remove cmd/core (Service Entrypoint)
- [ ] 1.4.1 Remove `cmd/core/` directory entirely
- [ ] 1.4.2 Verify `go build ./...` passes after all source removals

## 2. Build System Cleanup

- [ ] 2.1 Remove core aliases from `alias/BUILD.bazel`:
  - `//pkg/core:core`
  - `//pkg/core/alerts:alerts`
  - `//pkg/core/api:api`
  - `//pkg/core/auth:auth`
  - `//pkg/core/bootstrap:bootstrap`
  - `//pkg/core/templateregistry:templateregistry`
  - `//pkg/mcp:mcp`
- [ ] 2.2 Remove core binary mapping from `docker/images/BUILD.bazel`
- [ ] 2.3 Remove core target from `build/packaging/packages.bzl`
- [ ] 2.4 Verify `bazel build //...` succeeds
- [ ] 2.5 Verify `bazel test //...` succeeds

## 3. Packaging Artifacts Removal

- [ ] 3.1 Remove `build/packaging/core/` directory:
  - `build/packaging/core/config/core.json`
  - `build/packaging/core/config/core.docker.json`
  - `build/packaging/core/scripts/postinstall.sh`
  - `build/packaging/core/scripts/preremove.sh`
  - `build/packaging/core/systemd/serviceradar-core.service`
- [ ] 3.2 Remove core entry from `build/packaging/components.json`
- [ ] 3.3 Remove `build/packaging/specs/serviceradar-core.spec`
- [ ] 3.4 Remove `docker/rpm/Dockerfile.rpm.core`

## 4. Docker Cleanup

- [ ] 4.1 Remove `docker/compose/Dockerfile.core`
- [ ] 4.2 Remove `docker/compose/entrypoint-core.sh`
- [ ] 4.3 Audit `docker-compose.yml` for any remaining golang core references
- [ ] 4.4 Test docker compose stack starts correctly

## 5. Kubernetes/Helm Cleanup

- [ ] 5.1 Remove `k8s/demo/base/serviceradar-core.yaml`
- [ ] 5.2 Remove `k8s/demo/prod/serviceradar-core-grpc-external.yaml`
- [ ] 5.3 Remove `k8s/demo/staging/serviceradar-core-grpc-external.yaml`
- [ ] 5.4 Evaluate `k8s/demo/base/spire/spire-clusterspiffeid-core.yaml` - remove if not needed for core-elx
- [ ] 5.5 Remove or replace `helm/serviceradar/templates/core.yaml` with core-elx template
- [ ] 5.6 Verify `helm template` renders correctly
- [ ] 5.7 Verify `helm lint` passes

## 6. Documentation Updates

- [ ] 6.1 Update `docs/docs/architecture.md`:
  - Update architecture diagram to show core-elx
  - Remove references to golang core service
  - Update component descriptions
- [ ] 6.2 Update `docs/docs/installation.md`:
  - Remove serviceradar-core package references
  - Update to reference core-elx
- [ ] 6.3 Update `INSTALL.md`:
  - Remove serviceradar-core package downloads
  - Update installation commands
- [ ] 6.4 Update main `README.md`:
  - Update architecture description
  - Update component list
- [ ] 6.5 Search and update any mermaid diagrams referencing golang core
- [ ] 6.6 Update `openspec/project.md` if it references golang core patterns

## 7. CI/CD Cleanup

- [ ] 7.1 Audit `.github/workflows/` for golang core build/test jobs
- [ ] 7.2 Remove or update workflow steps for core service
- [ ] 7.3 Update any release scripts that build golang core

## 8. Final Verification

- [ ] 8.1 Full Go build verification: `go build ./...`
- [ ] 8.2 Full Bazel build verification: `bazel build //...`
- [ ] 8.3 Full Bazel test verification: `bazel test //...`
- [ ] 8.4 Docker compose stack verification
- [ ] 8.5 Helm chart linting and template verification
- [ ] 8.6 Documentation build verification
- [ ] 8.7 Final grep for remaining "serviceradar-core" references (excluding core-elx, archived changes)
