# Change: Remove NATS for Internal Health Events

## Why
Internal state/health transitions currently publish to NATS JetStream and are then re-ingested by the EventWriter to write into CNPG. This adds latency, duplicates write paths, and makes internal health persistence depend on broker availability. We want CNPG to be the source of truth for internal health, with Phoenix PubSub for live UI updates, while keeping NATS for external ingestion.

## What Changes
- Internal health/state transitions write `HealthEvent` records directly in CNPG and broadcast via Phoenix PubSub for live UI updates.
- `PublishStateChange` and related internal paths stop publishing these events to NATS (no internal NATS round-trip).
- NATS JetStream remains the ingestion bus for external/edge event streams (logs, metrics, traps, flow, etc.).
- EventWriter continues to consume external NATS subjects only; internal health events are excluded.

## Impact
- Affected specs: `health-events` (new)
- Affected code: `ServiceRadar.Infrastructure.HealthTracker`, `PublishStateChange`, `EventPublisher`/`EventBatcher`, EventWriter config, UI live update hooks.
- Operational impact: internal health persistence no longer depends on NATS availability; EventWriter load reduced for internal events.
