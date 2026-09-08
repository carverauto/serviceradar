# Change: Update Services dashboard to reflect real-time status

## Why
The `/services` dashboard is reporting misleading aggregate counts (e.g., multiple “unique services” for a single configured service) and includes sections that are not useful (gateways list, service-type card). Operators need a “what is happening right now” view of service health based on each service’s latest status.

## What Changes
- Compute summary metrics from the **latest status per service identity** (not the total count of status records).
- Remove the gateways section from `/services`.
- Replace the service-type summary block with a status distribution by check.
- Ensure the page auto-refreshes on new status updates without manual reload.

## Impact
- Affected specs: `build-web-ui`
- Affected code: `web-ng` LiveView for `/services`, SRQL queries that drive summary counts, service status pubsub refresh.
