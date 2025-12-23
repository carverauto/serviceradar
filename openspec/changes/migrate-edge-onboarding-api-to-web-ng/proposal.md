# Change: Migrate Edge Onboarding API from serviceradar-core to web-ng

## Why

The edge onboarding API currently lives in the Go-based `serviceradar-core` service. As part of the `serviceradar-web-ng` Phoenix consolidation strategy (see `add-serviceradar-web-ng-foundation`), all user-facing APIs should be served by Phoenix. Migrating the edge onboarding API to web-ng:

1. Reduces operational complexity by eliminating HTTP traffic to core
2. Enables richer LiveView-based onboarding UIs with real-time updates
3. Aligns with the architectural goal of core operating as ingestion-only daemon
4. Consolidates authentication/authorization in a single Phoenix boundary

## What Changes

### API Endpoints to Migrate

All endpoints under `/api/admin/edge-packages` and `/api/admin/component-templates`:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/edge-packages/defaults` | Get default selectors and metadata |
| GET | `/edge-packages` | List edge onboarding packages (with filters) |
| POST | `/edge-packages` | Create new edge onboarding package |
| GET | `/edge-packages/{id}` | Get single package details |
| DELETE | `/edge-packages/{id}` | Soft-delete a package |
| GET | `/edge-packages/{id}/events` | List audit events for a package |
| POST | `/edge-packages/{id}/download` | Deliver package (returns tokens/certs) |
| POST | `/edge-packages/{id}/revoke` | Revoke a package |
| GET | `/component-templates` | List available checker templates |

### Phoenix Implementation

1. **Edge Context** (`ServiceRadarWebNG.Edge`) - Expand existing module with:
   - `OnboardingPackages` - CRUD operations via Ecto
   - `OnboardingEvents` - Audit log queries
   - `ComponentTemplates` - Template listing from KV store

2. **API Controllers** (`ServiceRadarWebNG.EdgeController`) - JSON API handlers

3. **LiveView UI** - Edge onboarding management interface at `/edge`:
   - Package list with status filtering
   - Package creation wizard
   - Package details with event timeline
   - Token display/copy UI for delivery

4. **Security** - Token-based download endpoint allows unauthenticated access when valid download token is provided (matches current core behavior)

### Migration Path

- **Phase 1**: Implement Phoenix API endpoints (this proposal)
- **Phase 2**: Add LiveView UI for onboarding management (future proposal)
- **Phase 3**: Deprecate core HTTP endpoints; update edge proxy routing

## Impact

- Affected specs: `serviceradar-web-ng` (MODIFIED)
- Affected code:
  - New: `web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex`
  - New: `web-ng/lib/serviceradar_web_ng/edge/onboarding_events.ex`
  - New: `web-ng/lib/serviceradar_web_ng/edge/component_templates.ex`
  - New: `web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex`
  - Modified: `web-ng/lib/serviceradar_web_ng/edge.ex` (expand context)
  - Modified: `web-ng/lib/serviceradar_web_ng_web/router.ex` (add routes)

## Dependencies

- Existing `edge_onboarding_packages` table (schema owned by Go core)
- Existing `edge_onboarding_events` table (schema owned by Go core)
- KV store access for component templates (via NATS JetStream)
- Secrets service for token encryption/decryption (to be ported or called via gRPC)

## Out of Scope

- mTLS/SPIRE certificate generation (remains in core; Phoenix returns pre-generated bundles)
- LiveView UI (separate proposal)
- Deprecating core HTTP endpoints (separate migration task)
