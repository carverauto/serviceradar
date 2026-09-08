## Context

The current NetFlow UI is implemented inside `LogLive.Index` under `/observability` and is also reachable via the `/netflows` route. This makes the NetFlow experience compete for space with logs/traces/metrics concerns and blocks us from building an Akvorado-like analytics UI.

This change introduces a dedicated `/netflow` Visualize page and a state model encoded in the URL so views are bookmarkable and shareable.

## Key Decisions

### Decision: SRQL Remains The Only Query Language

The Visualize page will build and execute SRQL. We will not add a separate SQL-like filter expression language.

### Decision: Versioned Compressed URL State

Visualize options (graph type, time window, units, dimensions, toggles) are represented as a structured state. This state is encoded into the URL via a single query param:

- `nf=v1-<compressed>`

Rules:
- Always include a version prefix (`v1-`) so we can evolve the schema.
- If the param cannot be parsed/validated, fall back to defaults and preserve any raw SRQL query param (`q`) without overwriting it.
- The state codec must be deterministic and safe to parse (bounded sizes).

### Decision: Redirect Strategy

- The old `/observability` netflows tab should redirect to `/netflow` while preserving:
  - `q` (SRQL query)
  - other netflow view params that still apply (limit, geo side, sankey prefix, etc.) as best-effort
- `/netflows` becomes an alias to `/netflow` (redirect) to reduce confusion.

## Rollout Plan

1. Add `/netflow` page with stable layout and defaults (no chart parity yet).
2. Redirect legacy entrypoints to `/netflow`.
3. Subsequent changes extend the page with chart suite, dimension system, enrichment, and rollups.

## Risks

- URL state size: large dimension/filter combinations could produce large URLs.
  - Mitigation: compression + strict validation + fall back to saved views in later phases.

- Backwards compatibility: old bookmarks may include netflow-specific params.
  - Mitigation: preserve `q` always; preserve known params; ignore unknown params.
