# Design: Internal Health Events Without NATS

## Goals
- Persist internal state/health transitions directly in CNPG (`HealthEvent`).
- Use Phoenix PubSub for live UI updates of internal health changes.
- Keep NATS JetStream as the ingestion bus for external/edge event streams.
- Preserve tenant isolation (tenant_id derived from server context, not client payload).

## Non-Goals
- Replacing NATS for external ingestion (syslog/otel/flowgger/traps/etc.).
- Changing NATS tenant isolation or account provisioning.

## Current Flow
1. State transition triggers `PublishStateChange`.
2. `HealthTracker.record_state_change` writes `HealthEvent`.
3. `HealthTracker` publishes to NATS via `EventPublisher`/`EventBatcher`.
4. EventWriter consumes NATS and writes to CNPG (duplicate for internal events).

## Proposed Flow
1. State transition triggers `PublishStateChange`.
2. `HealthTracker.record_state_change` writes `HealthEvent` to CNPG.
3. `HealthTracker` broadcasts a PubSub event for live UI updates.
4. No NATS publish for internal health/state changes.

## PubSub Contract
- Topic: `serviceradar:health_events` (or per-tenant `serviceradar:health_events:<tenant_id>`).
- Payload: `HealthEvent` or normalized map containing `entity_type`, `entity_id`, `tenant_id`, `old_state`, `new_state`, `recorded_at`, `metadata`.

## Compatibility
- EventWriter continues to process external NATS subjects and write to CNPG.
- Internal health consumers switch to DB reads + PubSub updates.
- Optional config flag to gate PubSub emission if needed for staged rollout.

## Data Consistency
- HealthEvent record is the source of truth.
- PubSub is best-effort (live updates only); UI should fall back to DB queries.

## Open Questions
- Should PubSub be per-tenant to reduce fan-out, or global with tenant metadata?
- Do any non-Elixir services subscribe to internal health events today?
