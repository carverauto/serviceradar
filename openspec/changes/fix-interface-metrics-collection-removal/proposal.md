# Change: Fix interface metrics collection removal

## Why
Disabling interface metric collections currently leaves graphs visible and likely continues collecting data. Users expect disabling metrics to immediately stop collection, remove related configuration artifacts (including composite groups), and update the UI state.

## What Changes
- Ensure interface metric selections are persisted and removed deterministically when disabled.
- Stop collection of removed interface metrics on config refresh.
- Remove any composite metric groups tied to disabled interface metrics.
- Update the UI to hide metrics graphs and indicators when metrics are disabled, even if historical data exists.

## Impact
- Affected specs: build-web-ui, device-inventory, snmp-checker.
- Affected code: web-ng interface details/metrics UI, core-elx metrics config persistence and config compiler, agent-gateway config delivery, SNMP checker config handling and collection.
