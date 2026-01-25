## Context
Service status ingestion is append-only (`service_status`). The Services UI dedupes results client-side but still counts stale entries because nothing marks a service as removed when a plugin is revoked/deleted.

## Goals / Non-Goals
- Goals:
  - Maintain a durable current-state registry for service identities.
  - Update the registry on every incoming status.
  - Remove or disable entries when a service assignment is revoked/deleted.
  - Let Services UI read from the registry for present-time counts.
- Non-Goals:
  - Replace historical status storage.
  - Change the plugin result schema.

## Decisions
- **Registry table**: Add a `service_state` table (Ash resource) keyed by service identity fields.
- **Identity**: Use the same identity fields used by the Services UI dedupe (agent_id + partition + service_type + service_name + gateway_id).
- **Update path**: Ingestors upsert `service_state` on every status update.
- **Removal behavior**: On plugin revoke/delete, mark state as `inactive` (e.g., `state=disabled`) and exclude inactive entries from Services summary counts; historical `service_status` rows remain untouched.
- **UI**: Services summary uses `service_state` and refreshes on state updates.

## Risks / Trade-offs
- Requires consistent identity derivation across ingestion and UI.
- May need a staleness policy for non-plugin services (future enhancement).

## Migration Plan
- Add the registry table and upsert it during ingestion.
- Backfill is optional; the table will populate as new statuses arrive.

## Open Questions
- Do we want a staleness timeout to classify services as `unknown` when no updates arrive?
