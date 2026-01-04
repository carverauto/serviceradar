## Context
Poller components (Go poller and Elixir poller rewrite) are fully deprecated and no longer deployed. The current runtime path is agent <-> gateway, with gateway handling registration and status propagation. Poller references now create dead code paths, stale configuration, and security risks (e.g., unscoped references).

## Goals / Non-Goals
- Goals:
  - Remove poller-related services, resources, configs, and UI surfaces.
  - Ensure gateway/agent runtime paths remain correct and tenant-scoped.
  - Keep specs, docs, and tests aligned with the live architecture.
- Non-Goals:
  - Reintroduce poller semantics under a new name.
  - Preserve poller data models for backward compatibility unless explicitly required.

## Decisions
- Decision: Remove poller resources and configs rather than aliasing to gateway.
- Decision: Replace poller identifiers in runtime lookups/queries with gateway identifiers where needed.
- Decision: Update specs to remove poller-driven requirements and describe gateway/agent behavior.

## Risks / Trade-offs
- Removing poller tables or APIs may break external tooling depending on legacy endpoints.
- SRQL/UI consumers might assume `pollers` exists; we must identify and update or remove those paths.

## Migration Plan
1. Inventory poller references across code, configs, and docs.
2. Remove poller services/resources/configs and update any runtime call sites to gateway/agent equivalents.
3. Update specs and tests; run lint/test suites.
4. Decide whether to drop poller database tables (Ash migration) or leave for historical data.

## Open Questions
- Should poller database tables be dropped via Ash migration, or left read-only for historical data?
- Should any public API or SRQL entity alias pollers to gateways for compatibility?
- Are there external integrations still reading poller IDs that need a migration plan?
