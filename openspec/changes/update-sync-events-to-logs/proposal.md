# Change: Sync Lifecycle Logs Instead of Events

## Why
Integration sync lifecycle updates (start/finish) are operational noise and should not appear as notable events by default. They should be stored as logs with metadata so failures can be promoted when needed.

## What Changes
- Record integration sync lifecycle updates as OTEL log records instead of OCSF events.
- Ensure log records include structured fields (stage/result/source) to support promotion rules.
- Keep log-to-event promotion as the only path for creating events from sync failures/timeouts.

## Impact
- Affected specs: observability-signals
- Affected code: sync ingestion pipeline, sync event writer, log promotion rules
