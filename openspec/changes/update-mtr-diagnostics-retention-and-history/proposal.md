# Change: Update MTR diagnostics retention and history

## Why
Issue 3206 and pilot customer feedback show that ServiceRadar's MTR experience is not yet carrying the diagnostic workflow on its own. A user asking whether they can export MTR data to Grafana means the product is hiding retained path history and visual analysis that should be native to ServiceRadar.

Today MTR data is stored in TimescaleDB, but the UI surfaces only a small recent slice in key contexts and retention is installed as a hard-coded database policy. Operators need longer, configurable MTR history, paginated access to all retained polls, SRQL time-range searches, and first-party visuals that make path instability, loss, latency, and hop changes obvious without another tool.

## What Changes
- Make MTR retention configurable at deployment and runtime, with a persisted ServiceRadar setting and a reconciler that applies TimescaleDB retention policies for `platform.mtr_traces` and `platform.mtr_hops`.
- Extend MTR diagnostics and device detail surfaces to browse all retained MTR polls through paginated, filterable history rather than fixed recent windows.
- Add native MTR visual diagnostics for the Grafana-style questions operators are trying to answer: latency/loss trends, path-change timelines, hop heatmaps, target reachability, and source-agent comparison.
- Require SRQL support for MTR date/time ranges so MTR history can be searched by relative or absolute time windows.
- Expose retention status and expected history coverage in the UI so operators understand how much data is retained at the current polling cadence.
- Seed retention defaults during install or upgrade while allowing authorized users to change the value later without editing migrations by hand.

## Impact
- Affected specs: `mtr-diagnostics`, `srql`, `cnpg`
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/` for an MTR settings resource/table and default retention bootstrap
  - `elixir/serviceradar_core/lib/serviceradar/observability/` for MTR retention settings and Timescale policy reconciliation
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/diagnostics_live/` and device detail LiveViews for paginated history and native visuals
  - SRQL catalog/planner support for `in:mtr_traces` and related MTR time filters
  - Helm/Docker Compose values for install-time default retention seeding
