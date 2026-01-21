## 1. Data Model & Core Behavior
- [ ] 1.1 Add tombstone fields to devices (deleted_at, deleted_by, deleted_reason optional) via Elixir migration.
- [ ] 1.2 Add soft-delete and bulk-delete actions on Device with admin/operator authorization.
- [ ] 1.3 Default device reads exclude deleted records; add include_deleted filter for API/UI.

## 2. Reaper Job & Settings
- [ ] 2.1 Add retention setting (days) under Settings → Network (new sub-tab) and persist it.
- [ ] 2.2 Add AshOban reaper job that purges devices deleted longer than retention window.
- [ ] 2.3 Wire job schedule + defaults for the reaper job.

## 3. Web UI
- [ ] 3.1 Add Delete action to device details with confirmation and role gating.
- [ ] 3.2 Add Bulk Delete action next to Bulk Editor with confirmation and role gating.
- [ ] 3.3 Add UI toggle/filter to include deleted devices and show tombstone badge/state.

## 4. Tests
- [ ] 4.1 Core tests for soft delete filtering and reaper job behavior.
- [ ] 4.2 Web-ng tests for delete controls, confirmation flow, and role gating.
