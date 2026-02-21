# Change: Add NetFlow Visualize Overlays (Bidirectional + Previous Period)

## Why

Akvorado's Visualize experience is strongly shaped by overlays: bidirectional traffic (direct vs reverse) and previous-period comparison. ServiceRadar's `/netflow` page currently supports dimensions and multiple chart types, but does not yet provide these overlays.

## What Changes

- Add Visualize options to enable:
  - `bidirectional`: overlay reverse-direction traffic on the same chart.
  - `previous_period`: overlay the previous time window aligned to the current window.
- Implement overlays in a strictly SRQL-driven way (no Ecto chart queries).
- Support overlays on:
  - `lines` (full overlay series, Akvorado-style)
  - `stacked` (total-only overlays rendered as dashed lines on top of the stacked area)
  - `stacked100` (composition-only overlays rendered as dashed series boundaries)

## Impact

- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/netflow_visualize/query.ex`
  - `elixir/web-ng/assets/js/app.js`
- Affected specs:
  - `netflow-analytics` (UI behavior and chart semantics)
