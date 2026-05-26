# Change: Enhance Dashboard Authoring Analytics

## Why
The current dashboard creator can save SRQL-backed panels, but it still behaves like a single-query form and does not yet match the richer dashboard/report workflow operators expect. We need dashboards that can combine multiple SRQL datasets, gauge/count dashlets with trend-over-time context, and pivot-table analysis without forcing exports to spreadsheets.

## What Changes
- Promote multi-panel creation so a new dashboard can be composed from multiple named SRQL queries before the first save.
- Add first-class gauge and count dashlets with explicit bindings, labels, thresholds, units, and optional trend-over-time comparison.
- Add pivot-table visualizations backed by SRQL result sets, with row/column/value bindings and aggregate controls.
- Add dashboard viewer affordances for panel duplication/cloning, variable substitution, compacting saved layouts, inline panel actions, refresh visibility, and permission-aware editing controls.
- Keep dashboard package frame queries separate from global `/dashboards` catalog search so package dashboards do not pretend to have one representative SRQL query.
- Extend SRQL builder/support metadata where needed so dashboard authoring can generate query families for current values and historical trend datasets.

## Impact
- Affected specs: build-web-ui, srql
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/authored_dashboard_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_package_live/show.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/**`
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/**`
  - `elixir/web-ng/assets/js/hooks/DashboardWasmHost.js`
  - `elixir/web-ng/test/**`
