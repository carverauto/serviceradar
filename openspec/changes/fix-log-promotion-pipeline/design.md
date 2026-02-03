## Context
- Demo uses `db-event-writer` to persist logs from JetStream subjects (`logs.*.processed`).
- `LogPromotion.promote/1` exists in core-elx but is only invoked from the EventWriter logs processor, which is disabled in demo.
- The canonical `ocsf_events` table is missing in demo CNPG, so promotion inserts cannot succeed even if triggered.

## Goals / Non-Goals
- Goals:
  - Restore log-to-event promotion without duplicating log ingestion.
  - Ensure `ocsf_events` exists in the platform schema and is queryable by the Events UI.
  - Keep rule evaluation in core-elx (Ash-first).
- Non-Goals:
  - Replacing the db-event-writer ingestion pipeline.
  - Rewriting log promotion rules or the SRQL query layer.

## Decisions
- Decision: Add a dedicated log-promotion consumer in core-elx that subscribes to `logs.*.processed` and invokes `LogPromotion.promote/1`.
  - Rationale: Avoids duplicate log writes and keeps rule evaluation in Ash/core.
- Decision: Keep `LogPromotion` inserting directly into `ocsf_events` (no NATS re-publish) to minimize additional moving parts.
  - Rationale: Existing code already builds OCSF events and writes to DB; the missing pieces are the table and the trigger.

## Risks / Trade-offs
- Risk: Promotion consumer failure could stall event creation even though logs are persisted.
  - Mitigation: Add health telemetry and explicit logging; keep JetStream consumer durable for retries.
- Risk: Processed log payload shape diverges from `LogPromotion` expectations.
  - Mitigation: Reuse existing log parser from EventWriter and validate with tests against processed log samples.

## Migration Plan
1. Add `ocsf_events` hypertable migration and deploy.
2. Deploy core-elx with promotion consumer enabled.
3. Verify new events appear for matching rules; monitor promotion telemetry.
4. Roll back by disabling the consumer if needed (logs remain intact).

## Open Questions
- Should promotion consumer use a separate durable name for each partition, or a single shared durable per deployment?
- Do we need to support backfill promotion for historical logs, or only new log traffic?
