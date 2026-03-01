# Change: Add OCSF event analytics CAGG

## Why
The Analytics critical events card is stale and expensive because it scans recent OCSF events on each refresh. We need a pre-aggregated source to keep the card accurate while reducing query cost.

## What Changes
- Add a TimescaleDB continuous aggregate (hourly) for OCSF event severity counts.
- Add retention for the aggregate and an index for time-bucket lookups.
- Update the Analytics page to read from the aggregate first, with a safe fallback.

## Impact
- Affected specs: observability-signals, build-web-ui
- Affected code: core migrations (OCSF events), web-ng Analytics LiveView
