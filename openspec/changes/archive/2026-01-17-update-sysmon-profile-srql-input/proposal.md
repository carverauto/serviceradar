# Change: Sync Sysmon Profile SRQL Input With Builder

## Why
Pasting a valid SRQL query into the Sysmon Profile target query input does not update the query builder, leaving the UI out of sync and making it unclear which devices will be targeted.

## What Changes
- Parse target query input changes and update the query builder when the SRQL can be represented.
- Keep builder sync state accurate (synced vs. not applied) without overwriting raw SRQL input.
- Update device count preview based on the latest target query input.

## Impact
- Affected specs: build-web-ui
- Affected code: web-ng Sysmon Profiles LiveView and associated tests
