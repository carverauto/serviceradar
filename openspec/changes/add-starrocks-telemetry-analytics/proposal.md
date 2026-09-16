# Change: Add StarRocks telemetry analytics and recover independent dashboard fixes

## Why

The pg_duckdb design in [PR #488](https://github.com/carverauto/serviceradar/pull/488) was withdrawn. [Issue #495](https://github.com/carverauto/serviceradar/issues/495) preserves useful dashboard and telemetry fixes, but long-window analytics still need a new storage and query architecture. The user's subsequent direction selects StarRocks as the proposed replacement; the older handoff's statement that no replacement was selected is historical.

This is a proposal only. No application code, migrations, deployment, data recovery, branch merge, or production configuration change is authorized by this document. Implementation follows proposal approval in later agents/PRs.

## What Changes

- Selectively recover storage-independent fixes and their synthetic tests from the preserved source; add the still-unimplemented full-width favorited-interface charts. See [extraction.md](extraction.md).
- Introduce optional StarRocks analytics as the warehouse for flows, scalar metrics, logs and event history. Keep NetFlow collection independently gated in Helm/Compose. Enabling NetFlow requires StarRocks. When StarRocks is off, remaining telemetry stays on CNPG hypertables. Keep CNPG as the control-plane/current-state database. Serving still follows per-dataset cutover.
- Use operator-managed shared-data StarRocks with dedicated object storage for hosted installations; provide a shared-nothing, durable-disk StarRocks profile for OSS installations without object storage. Existing CNPG installations remain supported until explicitly migrated.
- Keep JetStream first and EventWriter as the single persistence owner. Add bounded Stream Load batching and crash-safe delivery semantics within that owner, preserving independent flow and metric demand domains.
- Add a StarRocks SQL compiler/executor behind existing authorized SRQL entry points, with stable response contracts and explicit dataset routing. Dashboard callers do not issue database-specific SQL.
- Provide an opt-in, read-only StarRocks JDBC catalog onto CNPG so authorized analytics can join local StarRocks telemetry with current-state metadata in the query engine instead of merging those result sets in application code. The primary consumers are flow attribution and flow enrichment (process correlation current-state, prefix tags, device/inventory identity). The catalog is not a telemetry serving path and is not a write path back into CNPG.
- Preserve query correctness, process attribution updates, counter semantics, exact window boundaries and visible errors. Build time-bucket aggregates and verify their use and freshness.
- Provide configurable dataset retention, a hosted default of one year for flows/logs/events/alert history, and longer operator-selected retention. Treat the previous 30-day hot-window preference as a cache-sizing hypothesis, not a storage boundary.
- Require staged backfill, shadow validation, per-dataset cutover, rollback coverage and recovery drills before removing any existing historical storage.
- **BREAKING, opt-in storage contract:** migrated telemetry is persisted in StarRocks rather than CNPG. Direct PostgreSQL consumers must migrate before their dataset switches. The JetStream-first/single-owner invariant is unchanged; update repository guidance to permit the approved destination change before implementing it.

## Impact

- Affected specs: `build-web-ui`, `srql`, `netflow-analytics`, and new `telemetry-analytics`. Existing CNPG capabilities remain applicable to the compatibility backend.
- Affected implementation: EventWriter processors/acknowledgement; Rust SRQL compiler and Rustler boundary; web/core SRQL execution and authorization; direct historical readers and flow attribution; schema lifecycle; Helm/operator integration; Compose; Bazel; retention and recovery; StarRocks JDBC catalog and CNPG reader role for current-state joins.
- Wide architectural scope: shared-data deployment and a MySQL-compatible protocol do not make existing PostgreSQL SQL, Ash/Ecto resources, NIF contracts or readers portable.
- Independent UI work can land before StarRocks. PostgreSQL CAGG optimization is conditional compatibility work, not a prerequisite to StarRocks.
- No wholesale cherry-pick of #488; no new pg_duckdb runtime or archive subsystem. Do not archive-apply either withdrawn proposal.

## Review and implementation boundaries

See [design.md](design.md) for decisions, failure handling, source verification and remaining design gates; [tasks.md](tasks.md) for ordered work packages. All tasks remain unchecked. Performance targets are proposed acceptance criteria, not measured results. The source PR's tests and closed status do not validate an extracted patch or a future deployment.
