## Context
Analytics currently loads recent OCSF events via SRQL and derives severity counts in-memory. This is expensive for large event volumes and appears to stall/stale. TimescaleDB is available and already used for pre-aggregated metrics stats.

## Goals / Non-Goals
- Goals: Provide fast, accurate 24h severity counts for Analytics; avoid scanning `ocsf_events` on each refresh.
- Non-Goals: Replacing SRQL queries for full event lists; altering event ingestion semantics.

## Decisions
- Decision: Create a TimescaleDB continuous aggregate `ocsf_events_hourly_stats` with hourly buckets and severity counts.
- Decision: Refresh the aggregate every 5 minutes with a 5-minute end offset.
- Decision: Retain aggregate data for 24 hours.
- Decision: Keep a fallback to existing SRQL query if the aggregate is missing or unavailable.

## Risks / Trade-offs
- Risk: TimescaleDB extension missing in some environments. Mitigation: guard creation and fall back to SRQL.
- Risk: Aggregate refresh lag. Mitigation: use a short refresh policy and label cards as recent.

## Migration Plan
- Add migration to create the aggregate view, index, refresh policy, and retention policy.
- Deploy core migration before enabling Analytics to read from the aggregate.

## Open Questions
- None.
