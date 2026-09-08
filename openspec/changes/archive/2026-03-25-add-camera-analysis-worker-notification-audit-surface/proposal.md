# Change: Add camera analysis worker notification audit surface

## Why
Camera analysis worker alerts now participate in the standard notification-policy path, but operators still cannot tell whether a routed worker alert has actually been notified, how many times it has notified, or when it last notified. During worker incidents, that missing audit context makes it hard to distinguish "eligible for notification" from "already notified and awaiting re-notify or clear".

## What Changes
- Expose bounded notification audit context for routed camera analysis worker alerts from the standard alert lifecycle.
- Show notification delivery counters and last-notified timestamps in the worker management API and `web-ng` worker ops surface.
- Keep the audit view derived from the authoritative routed alert / alert lifecycle rather than a parallel worker notification store.

## Impact
- Affected specs: `observability-signals`, `edge-architecture`, `build-web-ui`
- Affected code: camera analysis worker alert routing context, worker management API/UI, and alert lookup helpers in `serviceradar_core`
