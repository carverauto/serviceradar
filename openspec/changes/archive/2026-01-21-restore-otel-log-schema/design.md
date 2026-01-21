## Context
The Logs UI currently presents only a reduced set of fields (Time, Level, Service, Message) and OTEL-specific metadata (resource, scope, attributes, trace/span identifiers) appears missing. This creates inconsistency with OTEL metrics/traces and reduces operator visibility.

## Goals / Non-Goals
- Goals:
  - Preserve OTEL log record fields end-to-end for OTEL sources.
  - Normalize non-OTEL sources into OTEL log records so the UI and queries are consistent.
  - Surface OTEL fields in the Logs UI detail view.
- Non-Goals:
  - Redesigning OCSF event promotion or alerting behavior.
  - Changing log retention policies.

## Decisions
- Decision: Treat the OTEL log record schema as the canonical storage/query shape for all log sources.
- Alternatives considered: Keep source-native schemas and only map in the UI (rejected due to fragmented queries and inconsistent metadata availability).

## Risks / Trade-offs
- Mapping fidelity: Non-OTEL sources may not have direct equivalents for all OTEL fields; mitigated by explicit mapping rules and preserving raw payload as attributes.
- UI performance: Showing additional metadata could increase payload size; mitigate with lazy detail loading and selective columns in list views.

## Migration Plan
- Backfill is optional; prioritize restoring schema for new ingests first.
- If feasible, provide a one-time backfill job to populate OTEL fields for recent log records.

## Open Questions
- Should syslog/GELF raw payloads be preserved as OTEL log attributes or retained in a dedicated raw field?
- Do we require backfill for existing log records to restore UI parity?
