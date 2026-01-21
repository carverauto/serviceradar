## Context
Device duplication and cleanup require a reversible delete workflow. We want to hide tombstoned devices by default, allow admins/operators to delete via UI, and automatically purge deleted records after a retention period.

## Goals / Non-Goals
- Goals:
  - Provide soft delete for device inventory with stored deletion metadata.
  - Provide UI affordances for delete (detail + bulk) and show deleted toggle.
  - Add retention controls and automated reaping via AshOban.
- Non-Goals:
  - Automatic merge or resurrection logic for deleted devices.
  - Audit/event export beyond existing merge audit.

## Decisions
- Use `deleted_at` (timestamp) as the tombstone marker, with optional `deleted_by` and `deleted_reason` fields.
- Default inventory reads filter `deleted_at IS NULL`; add `include_deleted` to override.
- UI delete actions require admin/operator roles and confirmation.
- Reaper job runs on a schedule (daily) and deletes tombstoned devices older than `retention_days`.
- Retention settings live under Settings → Network in a new “Inventory Cleanup” sub-tab.

## Risks / Trade-offs
- Deleted devices continue receiving updates but remain hidden. This is acceptable for operator-driven cleanup and can be verified via “Show deleted.”
- Retention purge is irreversible; defaults and confirmation text must be explicit.

## Migration Plan
- Add columns with an Elixir migration and update Ash resource/actions.
- Add default filters and API arg for `include_deleted`.
- Add Settings entry for retention + reaper job wiring.
- Roll out UI controls and confirmation flows.

## Open Questions
- Default retention window (proposed: 30 days).
- Whether to add “Restore device” action (currently out of scope).
