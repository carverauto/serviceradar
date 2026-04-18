# Change: Make observability log live mode opt-in

## Why
The `/observability` logs pane currently subscribes to new log ingestion and auto-refreshes the active log list. That refresh path rebuilds the list from the base query without preserving pagination cursor state, so operators who move off the first page are pulled back to the newest logs as soon as more data arrives.

## What Changes
- Default the logs pane to standard paginated browsing with live updates disabled.
- Add a `Live` control in the log pane header so operators can explicitly opt into streaming behavior.
- Pause live mode when the operator changes pagination, filters, or query state so manual browsing remains stable.
- Limit the change to the logs pane; events, alerts, and other observability tabs keep their existing refresh behavior unless they explicitly opt into the same pattern later.

## Impact
- Affected specs: `observability-signals`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex`, related LiveView tests under `elixir/web-ng/test/phoenix/live/log_live/`
