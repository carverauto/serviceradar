## Context
Poller registration metadata (identity/provenance) and poller operational status (health/last-seen) currently share the same `pollers` row in CNPG. Two code paths write that table:
- Service registry registration/upsert (intended to manage registration metadata).
- Poller status updates (intended to manage operational state).

Today, the poller status UPSERT overwrites registration columns with defaults during conflict updates, which corrupts explicit registrations.

## Goals / Non-Goals
- Goals:
  - Preserve poller registration metadata across status/heartbeat updates.
  - Keep status updates cheap (no read-before-write required).
  - Maintain a clear “ownership” boundary between registration writes and status writes.
- Non-Goals:
  - Redesign the registry schema (separating operational state into a new table).
  - Change the edge onboarding data model or token formats.

## Decisions
- Decision: Treat status/heartbeat writes as *operational-only* updates.
  - The status update SQL MUST NOT modify registration metadata on conflict.
  - Registration metadata remains managed by the service registry registration/upsert path.

### Alternatives considered
- Conditional UPSERT for each column (`CASE`/`COALESCE(NULLIF(...))`).
  - Pros: single SQL path.
  - Cons: ambiguous semantics (cannot distinguish “intentionally set empty” vs “unknown”), increases complexity, easy to regress.
- Read-before-write to preserve fields in application code.
  - Pros: explicit.
  - Cons: adds a read on hot path and still cannot preserve fields that are not represented in the status model.
- Route all heartbeats through the service registry exclusively.
  - Pros: single write system.
  - Cons: would require expanding service registry heartbeat semantics to include `is_healthy`, and coordinating ownership across packages.

## Risks / Trade-offs
- Risk: Call sites that *intended* to update registration metadata via `UpdatePollerStatus` will no longer do so.
  - Mitigation: Audit call sites and keep registration metadata updates explicit via the service registry.

## Migration Plan
No data migration. Existing corrupted rows may require re-registration to restore missing metadata; the change prevents future corruption.

## Open Questions
- Should `UpdatePollerStatus` be renamed/split to make the “operational-only” semantics impossible to misuse?
- Should we add an integrity check/alert when a poller’s registration metadata changes unexpectedly?

