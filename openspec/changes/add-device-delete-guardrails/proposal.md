# Change: Guardrails and linkage for device deletion

## Why
Deleting devices today can orphan service checks, confuse inventory state, and leave operators unsure why checks still run when a device row disappears. We need consistent safeguards, linkage visibility, and clean lifecycle handling so deletions are safe and reversible without losing device history.

## What Changes
- Block device deletions when the device is agent-managed or has active service checks.
- On delete, automatically mark agent-managed service checks as inactive and hide them from default UI views.
- Introduce a device linkage view that shows associated resources (service checks, agents, groups) before delete.
- Keep device history intact; delete only tombstone devices after a retention window using a reaper job.

## Impact
- Affected specs: device-inventory, build-web-ui, job-scheduling
- Affected code: Device soft-delete actions, ServiceCheck lifecycle/status, web-ng inventory + device detail UI, scheduled reaper jobs
