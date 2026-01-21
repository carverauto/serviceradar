# Change: Soft delete devices with UI controls and scheduled reaper

## Why
Operators need a safe way to remove duplicate or noisy device records without permanent data loss, while keeping the UI focused on active inventory. The current device inventory has no delete path, so users must rely on merges or manual database edits.

## What Changes
- Add a soft-delete (tombstone) model for devices with stored deletion metadata.
- Exclude deleted devices from default inventory reads, with an opt-in filter to show deleted items.
- Add device delete controls in the device detail view and a bulk delete action in the devices list (with confirmation).
- Add a configurable retention window and an AshOban reaper job to purge tombstoned devices after X days.
- Add Settings → Network UI to manage the retention window.

## Impact
- Affected specs: device-inventory, build-web-ui, job-scheduling
- Affected code: core device resource + API filters, web-ng device list/detail UI, settings UI, AshOban jobs
