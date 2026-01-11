# Design: Remove Deprecated Golang Core Service

## Context

The serviceradar-core golang service was the original control plane for ServiceRadar. It has been replaced by core-elx, an Elixir-based implementation built on the Ash Framework. The golang core handled:

- REST API (port 8090) and gRPC API (port 50052)
- Gateway communication and orchestration
- Alert management and webhooks
- Device/service registration
- Authentication (JWT/JWKS)

The Elixir replacement (core-elx) now handles all these responsibilities as part of the ERTS cluster architecture alongside web-ng and agent-gateway nodes.

**Stakeholders**: Platform team, DevOps, documentation maintainers

## Goals / Non-Goals

### Goals

- Remove all golang core source code and build artifacts
- Clean up packaging (deb/rpm) for the deprecated service
- Remove container build files and kubernetes manifests
- Update documentation to reflect Elixir-only architecture
- Ensure no active services have broken dependencies

### Non-Goals

- Migrating any remaining functionality (already done)
- Removing web-ng or other deprecated services (separate proposal)
- Changing the core-elx implementation
- Updating deployment procedures (already using core-elx)

## Decisions

### Decision 1: Complete removal vs deprecation marking

**Decision**: Complete removal of cmd/core/ and conditional handling of pkg/core/

**Rationale**:
- cmd/core/ is the service entrypoint with no external dependencies - safe to remove entirely
- pkg/core/ may have imports from other packages that need analysis before removal
- If dependencies exist, we'll extract only the required types to a minimal package

**Alternatives considered**:
1. Mark all as deprecated with compile warnings - Rejected: adds clutter, doesn't prevent accidental usage
2. Keep pkg/core indefinitely - Rejected: continues maintenance burden

### Decision 2: Handling pkg/core dependencies

**Decision**: Three-phase approach

1. **Analysis**: Run dependency analysis to identify all imports
2. **Classification**: Categorize imports as from deprecated vs active services
3. **Action**:
   - If only deprecated services import pkg/core → remove entirely
   - If active services import pkg/core → extract minimal types package

**Rationale**: Safe, incremental approach that won't break active services

### Decision 3: Kubernetes manifest handling

**Decision**: Remove standalone golang core manifests, keep core-elx

**Rationale**:
- `k8s/demo/base/serviceradar-core.yaml` defines the golang Deployment
- core-elx has its own deployment configuration
- Removing avoids confusion and accidental deployment of deprecated service

### Decision 4: Documentation strategy

**Decision**: Update in-place rather than creating new pages

**Rationale**:
- Architecture docs should reflect current state
- No need for migration guides (migration already complete)
- Reduces documentation surface area

## Risks / Trade-offs

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking active service imports | High | Thorough dependency analysis before removal |
| Missing references in docs | Medium | Grep-based verification for "serviceradar-core" |
| Build system issues | Medium | Incremental removal with verification at each step |
| Helm chart breakage | Medium | Template validation and staging deployment test |

## Migration Plan

### Phase 1: Analysis (No Code Changes)
1. Run import analysis for pkg/core
2. Document all dependencies
3. Create detailed removal order

### Phase 2: Build System Cleanup
1. Remove Bazel targets for cmd/core
2. Remove packaging artifacts
3. Verify builds pass

### Phase 3: Source Removal
1. Remove cmd/core/
2. Remove or extract pkg/core/ based on analysis
3. Update any dependent imports

### Phase 4: Container/K8s Cleanup
1. Remove Dockerfiles
2. Remove/update K8s manifests
3. Update Helm templates

### Phase 5: Documentation
1. Update architecture docs
2. Update installation docs
3. Update README files

### Rollback

Since this is removal of deprecated code:
- Git revert can restore any accidentally removed code
- No runtime rollback needed (core-elx is already in production)
- Helm chart changes can be reverted independently

## Dependency Analysis Results

Analysis performed on 2026-01-11. Found the following imports of `pkg/core` subpackages:

### Direct Imports (Non-Test Files)

| Package | Imports | Status | Action |
|---------|---------|--------|--------|
| `cmd/core/app/app.go` | `pkg/core`, `pkg/core/api`, `pkg/core/bootstrap` | **Deprecated** | Remove with cmd/core |
| `pkg/mcp/server.go` | `pkg/core/auth` | **Deprecated** | Remove entirely |
| `pkg/models/config.go` | `pkg/core/alerts` | **Deprecated** | Remove Webhooks field |

### Detailed Findings

#### 1. pkg/mcp (Deprecated Package)
- **Status**: Deprecated, not imported by any active code
- **Only reference**: Alias in `alias/BUILD.bazel`
- **Decision**: Remove entirely
- **Impact**: None - no active consumers

#### 2. pkg/models/config.go → alerts.WebhookConfig
- **Imports**: `pkg/core/alerts.WebhookConfig` type
- **Used in**: `CoreServiceConfig.Webhooks` field
- **Decision**: Remove the `Webhooks` field entirely - webhook alerting is deprecated
- **Consumers of CoreServiceConfig**: `cmd/consumers/db-event-writer`, `cmd/consumers/netflow`, `pkg/db`
- **Impact**: None - these consumers only use `CNPG` field, not `Webhooks`

#### 3. pkg/core/auth
- **Only consumer**: `pkg/mcp` (deprecated)
- **Decision**: Remove with pkg/mcp
- **Impact**: None

### Cleanup Steps (No Type Extraction Needed)

1. Remove `Webhooks` field from `CoreServiceConfig` in `pkg/models/config.go`
2. Remove import of `pkg/core/alerts` from `pkg/models/config.go`
3. Remove `pkg/mcp/` directory entirely
4. Remove `pkg/core/` directory entirely
5. Remove `cmd/core/` directory entirely
6. Update BUILD files and aliases
7. Verify build passes

### Packages to Remove

- `cmd/core/` - Service entrypoint (deprecated)
- `pkg/core/` - All subpackages (alerts, api, auth, bootstrap, templateregistry, etc.)
- `pkg/mcp/` - Deprecated MCP implementation

## Open Questions

1. ~~**pkg/natsutil/events.go imports pkg/core**~~ - **RESOLVED**: Initial grep was incorrect; no such import exists
2. **SPIRE identity for golang core** - Is `spire-clusterspiffeid-core.yaml` still needed for core-elx or should it be removed?
3. **Helm values.yaml** - Does the values file have golang-core specific configuration that should be removed?
