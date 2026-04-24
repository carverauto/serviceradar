# Change: Restore log-to-event promotion pipeline

## Why
Event rules created from logs are not producing events in demo. The current demo deployment writes logs via db-event-writer, but no component evaluates log promotion rules, and the canonical `ocsf_events` table is missing in CNPG.

## What Changes
- Create the `ocsf_events` hypertable in the platform schema with the expected OCSF Event Log Activity columns and indexes.
- Add a core-elx log-promotion consumer that listens to processed log subjects and calls `LogPromotion.promote/1` without duplicating log inserts.
- Wire configuration, supervision, and health telemetry so the promotion pipeline is visible and enabled in demo deployments.
- Add coverage for promotion from processed logs and event insertion into `ocsf_events`.

## Impact
- Affected specs: `observability-signals`, `ash-observability`.
- Affected systems: core-elx (promotion consumer), CNPG schema (new hypertable), NATS JetStream consumption, observability UI (events sourced from `ocsf_events`).
- Data impact: new `ocsf_events` table populated by promotion pipeline.
