# Change: Fix missing interfaces tab visibility and discovery assignment UX

## Why
The interfaces tab is disappearing for network devices (example: tonka01) even when operators expect interfaces to exist. Today the UI hides the tab when SRQL returns no rows, which makes it hard to diagnose discovery issues (e.g., stale data past retention or a mapper job assigned to a non-existent agent). The discovery job editor also allows manual agent-id entry, which can silently misconfigure jobs.

## What Changes
- Validate discovery job agent assignments against the registered agent list and present a dropdown selector in the discovery job editor.
- Persist and expose discovery job run diagnostics (last run timestamp, status, interface count, error) for UI troubleshooting.
- Show the Interfaces tab when a device has a discovery job assignment, and display an empty-state with discovery diagnostics when SRQL returns no interfaces.
- Allow operators to trigger discovery jobs on demand from the discovery jobs table.

## Impact
- Affected specs: `build-web-ui`, `network-discovery`.
- Affected code: `web-ng` device details + discovery settings UI, core discovery job API + validation, mapper run metadata storage.
