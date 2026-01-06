# Design: Edge Onboarding API Migration

## Context

The edge onboarding system allows operators to provision edge components (pollers, agents, checkers) by:

1. Creating a package with configuration and generating join/download tokens
2. Delivering the package (with valid download token) to get certificates/credentials
3. Managing package lifecycle (revoke, delete, audit events)

Currently implemented in Go (`pkg/core/edge_onboarding.go`, `pkg/core/api/edge_onboarding.go`), this needs to move to Phoenix while maintaining compatibility with existing CLI tools and the Rust edge-onboarding crate that calls these APIs.

## Goals

- Implement all edge onboarding API endpoints in Phoenix
- Maintain API contract compatibility (request/response shapes)
- Support both authenticated and token-gated access to download endpoint
- Read/write to existing database tables (schema owned by Go core)

## Non-Goals

- Certificate generation (remains in core or uses pre-generated bundles)
- SPIRE integration (out of scope for initial migration)
- LiveView UI (separate proposal)
- Deprecating Go endpoints (migration coordination)

## Decisions

### 1. Secrets/Encryption Strategy

**Decision**: Use Phoenix-native encryption for new packages; defer to gRPC call to core for legacy packages that need decryption with existing keys.

**Rationale**: The Go implementation uses AES-GCM with keys from environment or Vault. Options:
- **Option A**: Port encryption to Elixir (requires key access, crypto implementation)
- **Option B**: Call core via gRPC for encrypt/decrypt operations
- **Option C**: Use Phoenix-native encryption (Cloak/Ecto) for new packages

For initial migration, Option C is simplest. Legacy packages created by core can still be delivered via core until fully migrated.

### 2. KV Store Access for Component Templates

**Decision**: Call datasvc gRPC API to list KV keys matching template patterns.

**Rationale**: The Go implementation reads templates from NATS JetStream KV. Options:
- **Option A**: Direct NATS connection from Phoenix (new dependency)
- **Option B**: gRPC call to datasvc which already exposes KV operations
- **Option C**: Cache templates in database table

Option B leverages existing infrastructure without adding NATS as a Phoenix dependency.

### 3. mTLS Bundle Generation

**Decision**: For mTLS security mode, Phoenix generates certificate bundles using Erlang :public_key; for SPIRE mode, return error indicating unsupported (or call core gRPC).

**Rationale**: mTLS mode is self-signed CA-based and can be implemented in pure Elixir. SPIRE mode requires SPIRE Admin API integration which is complex.

### 4. API Response Format

**Decision**: Match exact JSON field names and shapes from Go implementation.

**Rationale**: Existing CLI tools and the Rust edge-onboarding crate parse these responses. Breaking changes would require coordinated updates.

## Component Architecture

```
+------------------+     +-------------------+
|   API Client     |     |   LiveView UI     |
| (CLI/Rust crate) |     | (future proposal) |
+--------+---------+     +---------+---------+
         |                         |
         v                         v
+--------------------------------------------------+
|              Phoenix Router                       |
|  /api/admin/edge-packages/* -> EdgeController    |
+--------------------------------------------------+
         |
         v
+--------------------------------------------------+
|           ServiceRadarWebNG.Edge                 |
|  OnboardingPackages | OnboardingEvents | ...     |
+--------------------------------------------------+
         |                    |
         v                    v
+----------------+    +------------------+
|  Ecto/Repo     |    | datasvc gRPC     |
| (shared tables)|    | (KV templates)   |
+----------------+    +------------------+
         |
         v
+--------------------------------------------------+
|                   PostgreSQL                      |
|  edge_onboarding_packages | edge_onboarding_events|
+--------------------------------------------------+
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Encryption key mismatch with legacy packages | Initially only handle new packages; legacy delivered via core |
| API contract drift | Add property-based tests comparing Phoenix output to expected shapes |
| KV access latency | Cache templates with short TTL; templates change rarely |
| mTLS cert generation complexity | Use Erlang :public_key; well-documented pattern |

## Migration Plan

1. **Phase 1** (this proposal): Implement Phoenix API, route new traffic to Phoenix
2. **Phase 2**: Add LiveView UI for onboarding management
3. **Phase 3**: Update edge proxy to route `/api/admin/edge-packages/*` to Phoenix
4. **Phase 4**: Deprecate core HTTP endpoints
5. **Rollback**: Route traffic back to core if issues discovered

## Open Questions

1. Should we implement SPIRE security mode in Phoenix or defer to core gRPC?
   - Recommendation: Defer initially; focus on mTLS mode which is more common
2. How to handle legacy encrypted packages created by core?
   - Recommendation: Proxy decrypt requests to core gRPC or migrate keys
3. Should download endpoint support archive (tar.gz) format or JSON only?
   - Recommendation: Support both (matches current Go behavior)
