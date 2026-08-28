# Change: Add Reusable Chart Region Selection

## Why
Time-series charts can show an operator where activity changed, but the dashboard currently offers only whole-panel navigation. Operators cannot select the relevant interval before opening the underlying records, and the existing NetFlow brush implementation is tied to one D3 chart rather than being reusable by ServiceRadar's server-rendered SVG charts.

## What Changes
- Add an opt-in, renderer-independent chart range-selection contract that maps pointer, touch, and keyboard input to chart-supplied timestamp buckets.
- Require chart producers to supply exact RFC3339 bucket bounds and rendered x-coordinates so selection remains correct when a chart compresses gaps or spaces points by index.
- Make the dashboard Events Over Time chart the first consumer, navigating a selected interval to the canonical Events observability route with an explicit absolute-range SRQL query.
- Add a separate keyboard-accessible "View all events" action to both populated and empty states while preserving the populated chart's existing general drill-down destination.
- Keep sysmon and interface charts out of this implementation while making the interaction contract available for deliberate follow-up adoption.

## Impact
- Affected specs: `build-web-ui`
- Affected code: dashboard Events Over Time rendering and LiveView navigation, a reusable web-ng chart hook/helper, hook registration, chart interaction styling, and focused JavaScript/Elixir tests under `elixir/web-ng/`
- Related change: `update-dashboard-drilldown-actions` established whole-panel dashboard navigation. Range-enabled charts satisfy that drill-down through the separate keyboard-accessible View all action rather than making the selection surface a generic link. Its broad clickable-panel scenario must be reconciled with this exception before either change is archived.
- No database, ingestion, SRQL grammar, or telemetry-source changes are required.
