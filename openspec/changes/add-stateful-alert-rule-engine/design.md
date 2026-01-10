## Context
We need stateful alert rules such as "5 failures in 10 minutes" that operate on
log/event streams, survive restarts, and avoid unbounded CNPG growth. The engine
runs on ERTS and must stay tenant-isolated with a single writer per rule group
in a clustered deployment.

## Goals / Non-Goals
- Goals:
  - Stateful thresholds with configurable group-by keys per rule.
  - Durable state snapshots with bounded storage and safe restart recovery.
  - Cooldown and re-notify support for long-lived incidents.
  - Bounded evaluation history with retention and compression.
- Non-Goals:
  - Complex rule languages beyond threshold windows in this change.
  - User-facing rule builder UI (API-only for now).

## Decisions
- Decision: Use bucketed windows with per-bucket flush
  - Bucket size is a fraction of the window (default 60s) and produces fixed-size
    state snapshots (count per bucket), flushed to CNPG once per bucket.
- Decision: Store durable state snapshots per rule+group key
  - Persisted fields include window seconds, bucket seconds, bucket counts,
    last_seen_at, and last_fired_at. No raw events are stored.
- Decision: Record evaluation history as a lightweight hypertable
  - Store only state transitions (rule fired, recovered, cooldown hit) and keep
    7 days of history with compression to cap storage.
- Decision: Enforce a single evaluator per tenant+rule group
  - Use a partitioned supervisor or distributed registry to avoid duplicate
    alerts when running multiple core nodes.

## Risks / Trade-offs
- Per-bucket flush trades minimal loss (within a bucket) for reduced write load.
  Recovery must rehydrate by reading the latest snapshot plus the in-bucket delta.
- Cooldown settings must balance noise suppression with notification guarantees.

## Migration Plan
- Add tenant tables for rule definitions, rule state snapshots, and evaluation
  history.
- Register retention/compression policies for the evaluation history hypertable.
- Roll out the rule engine with feature flags disabled by default, then enable
  per tenant.

## Open Questions
- Default bucket size for small windows (30s vs 60s).
- Default cooldown and re-notify intervals.
- Which inputs are first-class: logs only, or logs and OCSF events.
