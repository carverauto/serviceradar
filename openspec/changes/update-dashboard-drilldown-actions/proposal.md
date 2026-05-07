# Change: Add Dashboard Drill-Down Actions

## Why
The `/dashboard` surface has high-value summary cards that look interactive but do not consistently take operators to the underlying data. This makes the dashboard feel static and forces users to manually hunt for the detail behind important KPIs.

## What Changes
- Make the top operations KPI cards clickable with direct navigation to the matching inventory, security, health, camera, and FieldSurvey drill-in pages.
- Make the FieldSurvey heatmap, Threat Intel summary, Alerts Feed, Observability Metrics cards, and NetFlow map stat strip clickable where they summarize drillable data.
- Preserve existing card layout and light/dark theme quality while adding clear hover/focus states and accessible labels.

## Impact
- Affected specs: `build-web-ui`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/index.ex`, dashboard data helpers, and dashboard CSS in `elixir/web-ng/assets/css/app.css`
