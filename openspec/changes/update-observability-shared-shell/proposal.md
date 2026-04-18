# Change: Standardize the observability shell across signal pages

## Why
The main `/observability` experience keeps operators inside a stable shell while they move between logs, traces, metrics, events, and alerts. That breaks down for flows, BMP, BGP Routing, and Camera Relays today: flows hides the shared shell, BMP and BGP render their own page chrome, and Camera Relays introduces a separate shell plus a worker-management route that behaves like an extra hidden top-level tab.

This inconsistency makes the observability area feel like multiple unrelated products instead of one navigation surface. Operators lose context when they jump between signal types, and Camera Analysis Workers reads like a hidden top-level destination instead of a subsection of Camera Relays.

## What Changes
- Define a shared observability shell for all top-level observability panes: logs, traces, metrics, events, alerts, flows, BMP, BGP Routing, and Camera Relays.
- Require direct entry into any observability pane to preserve the same top-level shell, active-tab treatment, and navigation affordances instead of rendering pane-specific chrome.
- Remove the flows special case that suppresses the shared shell when the flows pane is active.
- Reframe Camera Analysis Workers as a subsection under Camera Relays rather than a separate top-level observability destination.
- Preserve direct-linkability for camera worker operations by routing them through the Camera Relays surface with subsection state.

## Impact
- Affected specs: `observability-signals`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex`, `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex`, `elixir/web-ng/lib/serviceradar_web_ng_web/live/bmp_live/index.ex`, `elixir/web-ng/lib/serviceradar_web_ng_web/live/bgp_live/index.ex`, `elixir/web-ng/lib/serviceradar_web_ng_web/live/camera_relay_live/index.ex`, `elixir/web-ng/lib/serviceradar_web_ng_web/live/camera_analysis_worker_live/index.ex`, `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
