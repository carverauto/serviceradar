# Change: Prevent poller status updates from clobbering registration metadata

## Why
`UpdatePollerStatus` is called frequently to record operational state (`is_healthy`, `last_seen`) for a poller. Today, that write path overwrites poller registration metadata (`component_id`, `registration_source`, `status`, `spiffe_identity`, `metadata`, and related timestamps) with hardcoded defaults, causing pollers registered via edge onboarding or explicit registration to lose their identity and provenance.

Reference: GitHub issue `#2151` (Poller status updates overwrite registration metadata with defaults).

## What Changes
- Update the CNPG poller status UPSERT so that conflict updates only touch operational fields (e.g., `last_seen`, `is_healthy`, `updated_at`) and do **not** overwrite registration metadata.
- Define/clarify write ownership: registration metadata updates flow through the service registry registration path; status/heartbeat updates flow through the poller status path.
- Add regression coverage to prevent reintroducing metadata clobbering.

## Impact
- Affected specs: `service-registry` (new delta)
- Affected code:
  - `pkg/db/cnpg_registry.go` (poller status UPSERT + args)
  - `pkg/db/pollers.go` (public DB API semantics)
  - `pkg/core/pollers.go` and any other callers that update poller health/last-seen
- No schema changes expected; this is a behavioral fix for write semantics.

