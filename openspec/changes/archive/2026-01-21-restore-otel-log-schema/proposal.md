# Change: Restore OpenTelemetry log schema in observability logs

## Why
The observability Logs UI no longer shows the expected OTEL log schema/fields and appears to surface only a reduced column set, which breaks troubleshooting workflows and obscures resource/scope metadata.

## What Changes
- Normalize all ingested log sources (OTEL, syslog, SNMP traps, GELF) into the OTEL log record schema and retain OTEL fields in storage and query results.
- Restore OTEL log fields in the Logs UI detail view, including resource/scope/attributes and timestamp/severity/body fields.
- Clarify how non-OTEL sources are mapped into OTEL records for consistency across logs, metrics, and traces.

## Impact
- Affected specs: observability-signals
- Affected code: log ingestion pipeline, SRQL/log queries, Logs UI (web-ng)
- Notes: This is a behavior change to persist and display OTEL schema fields consistently across all log sources.
