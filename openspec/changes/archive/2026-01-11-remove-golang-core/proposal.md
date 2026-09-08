# Change: Remove Deprecated Golang Core Service

## Why

The golang-based `serviceradar-core` service has been fully replaced by the Elixir-based `core-elx` (serviceradar-core-elx) service. The golang artifacts remain scattered throughout the codebase, creating maintenance burden, confusion for new contributors, and potential for accidental usage of deprecated code. A clean removal will reduce technical debt and align the codebase with the current architecture.

## What Changes

### **BREAKING** - Removal of Golang Core Artifacts

1. **Source Code Removal**
   - Remove `cmd/core/` - Main golang core service entrypoint
   - Remove `pkg/core/` - Core golang package (alerts, api, auth, bootstrap, templateregistry)
   - Remove `pkg/mcp/` - Deprecated MCP implementation (orphan code, no consumers)
   - Update `pkg/models/config.go` - Remove deprecated `Webhooks` field and `pkg/core/alerts` import

2. **Build System Cleanup**
   - Remove core targets from `alias/BUILD.bazel`
   - Remove core binary from `docker/images/BUILD.bazel`
   - Remove core package from `build/packaging/packages.bzl`

3. **Packaging Artifacts**
   - Remove `build/packaging/core/` directory (config, scripts, systemd)
   - Remove core entry from `build/packaging/components.json`
   - Remove `build/packaging/specs/serviceradar-core.spec` (RPM spec)
   - Remove `docker/rpm/Dockerfile.rpm.core`

4. **Container Artifacts**
   - Remove `docker/compose/Dockerfile.core`
   - Remove `docker/compose/entrypoint-core.sh`
   - Update docker-compose files to remove golang core references

5. **Kubernetes/Helm Cleanup**
   - Remove or update `k8s/demo/base/serviceradar-core.yaml`
   - Remove external gRPC service manifests for golang core
   - Update `helm/serviceradar/templates/core.yaml` (may need to be replaced with core-elx template)
   - Remove SPIRE identity config for golang core if no longer needed

6. **Documentation Updates**
   - Update `docs/docs/architecture.md` to reflect Elixir-only architecture
   - Update `docs/docs/installation.md` and `INSTALL.md`
   - Update main `README.md`
   - Update any mermaid diagrams showing golang core

### Dependency Analysis Complete

Dependency analysis confirmed no active services depend on pkg/core:

- **`pkg/mcp/`** - Orphan code, not imported by any active service
- **`pkg/models/config.go`** - Only uses `alerts.WebhookConfig` for deprecated webhook feature
- **`pkg/core/auth`** - Only used by deprecated pkg/mcp

All packages can be safely removed. The `Webhooks` field in `CoreServiceConfig` will be removed as webhook alerting is deprecated.

### Also Deprecated (Not Removed in This Change)

- `serviceradar-web` (replaced by web-ng) - separate cleanup proposal recommended
- `serviceradar-poller` - already fully removed

## Impact

- **Affected specs**: `edge-architecture`
- **Affected code**:
  - `cmd/core/` (removed)
  - `pkg/core/` (removed)
  - `pkg/mcp/` (removed)
  - `pkg/models/config.go` (Webhooks field removed)
  - `build/packaging/core/` (removed)
  - `docker/compose/Dockerfile.core` (removed)
  - `docker/rpm/Dockerfile.rpm.core` (removed)
  - `k8s/demo/base/serviceradar-core.yaml` (removed/updated)
  - `helm/serviceradar/templates/core.yaml` (removed/updated)
  - `docs/docs/architecture.md` (updated)
  - `INSTALL.md`, `README.md` (updated)
  - Build files: `alias/BUILD.bazel`, `docker/images/BUILD.bazel`, `build/packaging/packages.bzl`
- **Migration**: No runtime migration needed; core-elx is already the production service
- **Risk**: Low - golang core is deprecated and core-elx has been in production
