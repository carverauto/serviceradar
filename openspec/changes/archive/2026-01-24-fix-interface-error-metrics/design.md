## Context
Interface metrics collection is configurable via SNMP profiles, but configured error counters (ifInErrors/ifOutErrors) are not visible in SRQL or the interface charts. The current pipeline appears to drop or ignore these fields between collection, ingestion, and query projection.

## Goals / Non-Goals
- Goals:
  - Persist configured interface error counters alongside other interface metrics.
  - Surface error counters in SRQL interface queries (latest and time-series).
  - Display error counters in the interface UI with a clear empty-state when missing.
- Non-Goals:
  - Adding new interface metric types beyond existing error counters.
  - Changing retention policies or rollup strategies for interface metrics.

## Decisions
- Decision: Treat interface error counters as first-class interface metrics using the same canonical field naming as existing interface counters (e.g., `in_errors`, `out_errors`).
- Decision: SRQL `in:interfaces` will always project error counter fields when the interface metrics entity is queried, returning nulls if data is unavailable.
- Decision: UI charts render error counters when fields are present; otherwise show a “no data yet” state with guidance to verify collection.

## Risks / Trade-offs
- Risk: If schema changes are required, migration/backfill may be needed to avoid breaking older records.
- Risk: Adding fields to SRQL projections could slightly increase payload size; mitigated by limiting to interface metrics endpoints only.

## Migration Plan
- Add/adjust schema fields for interface error counters if missing.
- Deploy collector + ingestion changes first to populate new fields.
- Update SRQL and UI after data is flowing; optionally backfill if a historical view is required.

## Open Questions
- Are interface error counters currently stored under a different field name or entity (e.g., device metrics) that needs to be remapped?
- Does the interface metrics storage schema already include error counters but the SRQL projection omits them?
