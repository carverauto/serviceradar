## Context
Fresh docker-compose installs show ServiceRadar tables landing in the `public` schema and Timescale hypertable creation errors due to missing `create_hypertable()` when the search_path is `platform, ag_catalog`. This contradicts the platform-only schema rule and results in core-elx migration noise or failure.

## Goals / Non-Goals
- Goals:
  - Ensure all ServiceRadar application tables live in the `platform` schema.
  - Make Timescale hypertable/retention migrations succeed without relying on `public` search_path.
  - Keep migrations idempotent and exclusively Ash-driven.
- Non-Goals:
  - No manual database fixes or ad-hoc SQL outside migrations.
  - No changes to tenant schema naming or multitenancy strategy.

## Decisions
- Decision: Treat `platform` as the sole schema for platform-managed resources; no ServiceRadar tables or indexes remain in `public`.
- Decision: Hypertable/retention migrations must be resilient when `public` is not on the search_path, either by schema-qualifying TimescaleDB functions or installing the extension in a schema visible to the `platform` search_path.
- Decision: Add a startup guard that asserts the absence of ServiceRadar tables in `public` after migrations complete.

## Alternatives considered
- Allow `public` in search_path to reach TimescaleDB functions.
  - Rejected: violates the platform-only schema requirement and still allows accidental table creation in `public`.
- Leave existing public tables and document cleanup.
  - Rejected: not idempotent and shifts responsibility to operators.

## Risks / Trade-offs
- Moving existing public tables into `platform` may require careful migration ordering and could impact large deployments.
  - Mitigation: use idempotent migrations with existence checks and schema-qualified moves.

## Migration Plan
1. Add/adjust Ash resources to explicitly target the `platform` schema.
2. Introduce idempotent migrations to move any ServiceRadar tables/indexes/sequences from `public` to `platform`.
3. Ensure hypertable and retention policy migrations call TimescaleDB functions in a schema-safe way.
4. Add startup validation in core-elx that fails if ServiceRadar tables remain in `public` after migrations.

## Open Questions
- Should TimescaleDB be installed into `platform` or referenced via schema-qualified `public` functions?
- Do we need a compatibility shim for existing deployments with legacy public tables?
