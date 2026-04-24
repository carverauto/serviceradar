# Change: Use observed timestamps for log ordering and time filters

## Why
Syslog RFC3164 payloads omit timezone data, so their event timestamps are stored as UTC and appear hours behind OTEL logs. This causes syslog entries to be buried or excluded by default `time:` filters even though the messages were just ingested.

## What Changes
- Record an observed timestamp at ingest when a log payload lacks one, preserving event timestamps while capturing when the system actually received the log.
- Use a log "effective timestamp" (coalescing observed timestamp with event timestamp) for SRQL log time filters and ordering.
- Keep event timestamps intact in storage and query results; only ordering and time range evaluation change.

## Impact
- Affected specs: observability-signals, srql
- Affected code: Go db-event-writer JSON log ingestion, SRQL logs query planner, logs UI query defaults
