# Change: Track current service state for present-time dashboards

## Why
The Services dashboard currently summarizes an append-only `service_status` stream, so deleted/revoked plugins keep counting until new results arrive or fall out of the SRQL window. We need a persistent "current state" registry so the UI can reflect present-time status immediately when a service is removed.

## What Changes
- Add a `service_state` registry that maintains the latest known state per service identity.
- Update result ingestion to upsert service state on every status update.
- Update plugin revoke/delete flows to remove or disable the corresponding service state.
- Update the Services page summary (and list, if needed) to read from `service_state` and refresh via PubSub.

## Impact
- Affected specs: `service-state-registry`
- Affected code: core ingestion + pubsub, SRQL/services UI, plugin revoke/delete flows
