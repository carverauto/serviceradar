## 1. SRQL Inputs

- [x] 1.1 Make compact SRQL bars normal editable form inputs with stable caret behavior.
- [x] 1.2 Keep Monaco-backed SRQL editing opt-in for dashboard panel authoring only.
- [x] 1.3 Ensure rich SRQL editor completions are catalog-backed and visible while typing.

## 2. Dashboard Creation Flow

- [x] 2.1 Change `/analytics` to create dashboard metadata only.
- [x] 2.2 Remove or disable panel actions until the dashboard is saved.
- [x] 2.3 Navigate saved dashboards to their settings/editor workflow for adding panels.

## 3. Panel Authoring

- [x] 3.1 Add a saved-dashboard panel creation path from dashboard settings.
- [x] 3.2 Use SRQL preview output to determine compatible visualizations.
- [x] 3.3 Show schema-derived binding controls for the selected visualization.
- [x] 3.4 Replace raw JSON fields with structured controls for binding, display, visual, and layout settings.
- [x] 3.5 Fix rendered dashboard table/dropdown controls on `/dashboard/1000001`.
- [x] 3.6 Render chart-capable dashboard panels with a Recharts React island while keeping table/pivot fallbacks server-rendered.
- [x] 3.7 Add rendered panel ellipsis menus for refresh, SRQL, edit, duplicate, delete, and export actions.
- [x] 3.8 Add gauge/availability comparison settings for lookback period and trend SRQL.
- [x] 3.9 Render gauge/availability trend deltas with operator-facing copy such as "Compared to 30 days ago".
- [x] 3.10 Make automatic and compact layout fill final-row orphan panels instead of leaving dead space.

## 4. Query-First Builder Follow-Through

- [x] 4.1 Model dashboard source queries as reusable authoring data sources.
- [x] 4.2 Model outputs as source-query-derived visual definitions that can become panels.
- [x] 4.3 Add a query-first authoring flow: run SRQL, inspect sample rows and typed fields, add one or more outputs, then place outputs on the grid.
- [x] 4.4 Replace visual-first panel editing with intent-first choices backed by schema-compatible field selectors.
- [x] 4.5 Keep existing panels working while new guided dashboards can use source queries and outputs.
- [x] 4.6 Add source-query helpers/templates for `stats:` aggregation and `bucket:` downsampling patterns used by trend/gauge dashlets.

## 5. Validation

- [x] 5.1 Compile `elixir/web-ng` and build assets.
- [x] 5.2 Start local web-ng against the `demo` namespace CNPG database.
- [x] 5.3 Run Playwright checks for `/devices` SRQL editing, `/analytics` dashboard creation, dashboard panel authoring, and `/dashboard/1000001` panel controls.
- [x] 5.4 Run a dashboard authoring matrix across roughly 25 SRQL queries and assert offered visualizations match the returned schema.
- [x] 5.5 Verify Recharts-backed panels render in the browser without console errors.
