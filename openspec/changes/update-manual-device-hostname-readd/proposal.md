# Change: Re-add hostname-only manual devices after DNS resolution

## Why
Some manually added devices were created before hostname-only entries were reliably resolved to IP addresses. Re-adding a hostname such as `serviceradar.cloud` should not fail or create another duplicate when an older hostname-only or soft-deleted record already exists.

## What Changes
- Resolve hostname-only manual device submissions before matching existing inventory records.
- Treat manual device creation as idempotent when an include-deleted match exists by deterministic manual UID, resolved IP, or hostname.
- Restore and update a tombstoned match with the resolved IP and current manual metadata instead of returning a create failure.
- Merge duplicate active matches when a hostname-only record and resolved-IP record both exist for the same manual submission.

## Impact
- Affected specs: `device-inventory`, `device-identity-reconciliation`
- Affected code: `ServiceRadarWebNG.Devices.ManualDeviceCreator`, manual device LiveView feedback, device creator tests
