## Context
Syslog RFC3164 timestamps omit timezone information. When ingested as OTEL log records, their event timestamps can be hours behind real time, which causes SRQL time filters and ordering to hide fresh syslog entries.

## Goals / Non-Goals
- Goals:
  - Preserve event timestamps while ensuring recent syslog logs appear in time-scoped queries.
  - Use observed timestamps for ordering and filtering without requiring per-device timezone configuration.
- Non-Goals:
  - Inferring per-device timezone from network data.
  - Rewriting stored event timestamps.

## Decisions
- Decision: Use an "effective timestamp" for logs queries, defined as `COALESCE(observed_timestamp, timestamp)`.
- Decision: Populate `observed_timestamp` at ingest for JSON log payloads when missing, using ingest time.

## Risks / Trade-offs
- Ordering by observed time means logs can appear out of event-time order when devices emit delayed messages.
- Severity rollup CAGGs are still based on event timestamps; only raw log queries change behavior.

## Migration Plan
- Update ingestion pipeline and SRQL query planner.
- Validate logs list behavior in demo with mixed syslog/OTEL sources.

## Open Questions
- Should rollup stats and CAGGs be updated to use effective timestamps for log-based dashboards?
