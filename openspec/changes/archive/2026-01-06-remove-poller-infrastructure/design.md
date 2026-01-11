## Context
Poller components (Go poller and Elixir poller rewrite) are fully deprecated and no longer deployed. The current runtime path is agent <-> gateway, with gateway handling registration and status propagation. Poller references now create dead code paths, stale configuration, and security risks (e.g., unscoped references).

## Goals / Non-Goals
- Goals:
  - Remove poller-related services, resources, configs, and UI surfaces.
  - Ensure gateway/agent runtime paths remain correct and tenant-scoped.
  - Keep specs, docs, and tests aligned with the live architecture.
- Non-Goals:
  - Reintroduce poller semantics under a new name.
  - Preserve poller data models or compatibility shims.
  - Refresh legacy Swagger/OpenAPI docs (deprecated and scheduled for removal).

## Decisions
- Decision: Remove poller resources and configs rather than aliasing to gateway.
- Decision: Replace poller identifiers in runtime lookups/queries with gateway identifiers where needed.
- Decision: Update specs to remove poller-driven requirements and describe gateway/agent behavior.
- Decision: Drop poller tables via Ash migrations with no compatibility layer.
- Decision: Retain the UBNT poller used by the mapper/discovery engine.

## Risks / Trade-offs
- Removing poller tables or APIs may break external tooling depending on legacy endpoints.
- SRQL/UI consumers might assume `pollers` exists; we must identify and update or remove those paths.
- Swagger/OpenAPI artifacts still reference pollers until the legacy API docs are removed.

## Migration Plan
1. Inventory poller references across code, configs, and docs.
2. Remove poller services/resources/configs and update any runtime call sites to gateway/agent equivalents.
3. Update specs and tests; run lint/test suites.
4. Drop poller database tables via Ash migration (no compatibility/backfill required).

## Resolved Questions
- Poller tables are dropped via Ash migrations; no compatibility or aliasing is provided.
- Public APIs/SRQL do not alias pollers to gateways; Swagger/OpenAPI is left untouched until deprecated.
- No existing poller data requires backfill; UBNT mapper poller remains in place.
