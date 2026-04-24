## 1. Data Model & Core Behavior
- [x] 1.1 Add tombstone fields to devices (deleted_at, deleted_by, deleted_reason optional) via Elixir migration.
- [x] 1.2 Add soft-delete and bulk-delete actions on Device with admin/operator authorization.
- [x] 1.3 Add restore action and automatic restore when discovery results match deleted devices.
- [x] 1.4 Default device reads exclude deleted records; add include_deleted filter for API/UI.

## 2. Reaper Job & Settings
- [x] 2.1 Add retention setting (days) under Settings → Network (new sub-tab) and persist it.
- [x] 2.2 Add AshOban reaper job that purges devices deleted longer than retention window.
- [x] 2.3 Wire job schedule + defaults for the reaper job.
- [x] 2.4 Add manual "run cleanup now" action.

## 3. Web UI
- [x] 3.1 Add Delete action to device details with confirmation and role gating.
- [x] 3.2 Add Restore action for deleted devices with confirmation and role gating.
- [x] 3.3 Add UI toggle/filter to include deleted devices and show tombstone badge/state.

## 4. Tests
- [x] 4.1 Core tests for soft delete filtering and reaper job behavior.
- [x] 4.2 Core tests for restore and auto-resurrection behavior.
- [x] 4.3 Web-ng tests for delete/restore controls, confirmation flow, and role gating.
