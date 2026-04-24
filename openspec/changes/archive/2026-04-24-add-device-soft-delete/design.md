## Context
Device duplication and cleanup require a reversible delete workflow. We want to hide tombstoned devices by default, allow admins/operators to delete via UI, and automatically purge deleted records after a retention period.

## Goals / Non-Goals
- Goals:
  - Provide soft delete for device inventory with stored deletion metadata.
  - Allow explicit restore from the UI and automatic restore when discovery results match a deleted device.
  - Provide UI affordances for delete (detail + bulk) and show deleted toggle.
  - Add retention controls and automated reaping via AshOban with configurable schedule.
- Non-Goals:
  - Automatic merge of deleted devices into new identities beyond existing DIRE rules.
  - Audit/event export beyond existing merge audit.

## Decisions
- Use `deleted_at` (timestamp) as the tombstone marker, with optional `deleted_by` and `deleted_reason` fields.
- Default inventory reads filter `deleted_at IS NULL`; add `include_deleted` to override.
- Add a `restore` action that clears tombstone metadata and returns the device to normal visibility.
- When sweep or integration discovery matches a soft-deleted device, automatically restore it and update availability/last_seen.
- UI delete actions require admin/operator roles and confirmation on the device detail page.
- Reaper job runs on a schedule and deletes tombstoned devices older than `retention_days`.
- Retention settings and reaper schedule live under Settings → Network in a new “Inventory Cleanup” sub-tab, with a manual “Run cleanup now” action.

## Risks / Trade-offs
- Deleted devices may be automatically restored by discovery, which could reintroduce noisy records. Mitigate with clear UI messaging and retention controls.
- Retention purge is irreversible; defaults and confirmation text must be explicit.

## Migration Plan
- Add columns with an Elixir migration and update Ash resource/actions.
- Add default filters and API arg for `include_deleted`.
- Add Settings entry for retention + reaper job wiring.
- Roll out UI controls and confirmation flows.

## Open Questions
- Default retention window (proposed: 30 days).
