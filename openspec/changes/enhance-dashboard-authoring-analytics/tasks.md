## 1. Proposal
- [x] 1.1 Validate OpenSpec change.
- [x] 1.2 Confirm approval before feature implementation.

## 2. Dashboard Search Separation
- [x] 2.1 Make dashboard package pages use `in:dashboards` for the global topbar SRQL state.
- [x] 2.2 Keep package frame SRQL overrides isolated to the dashboard host API and URL frame params.
- [x] 2.3 Add regression coverage for the topbar builder opening without unsupported-query warning.

## 3. Multi-Query Dashboard Creation
- [x] 3.1 Replace the single-panel new-dashboard form with a pending panel list.
- [x] 3.2 Allow users to add, preview, remove, and reorder multiple SRQL-backed panels before save.
- [x] 3.3 Persist all pending panels transactionally enough that partial failures are reported and do not leave misleading UI state.
- [x] 3.4 Add LiveView coverage for creating a dashboard with multiple SRQL queries.
- [x] 3.5 Add a modal-based panel composer and Gridstack canvas for draft panel layout and sizing.
- [x] 3.6 Honor persisted panel layout in the saved dashboard renderer.

## 4. Gauge and Count Dashlets
- [x] 4.1 Add structured gauge/count dashlet binding controls for value, numerator, denominator, label, unit, and thresholds.
- [x] 4.2 Add trend-over-time configuration for gauge/count dashlets, including comparison query/window and displayed delta.
- [x] 4.3 Render gauge/count dashlets in the dashboard and report paths with accessible labels and empty/error states.
- [x] 4.4 Add tests for gauge thresholds, count labels, and trend-over-time rendering.

## 5. Pivot Tables
- [x] 5.1 Add pivot table as a first-class visual type.
- [x] 5.2 Add row, column, value, aggregate, subtotal, and empty-cell binding controls.
- [x] 5.3 Render pivot tables without requiring spreadsheet export.
- [x] 5.4 Add tests for pivot table grouping, totals, and sparse values.

## 6. Validation
- [x] 6.1 Run focused LiveView/dashboard tests.
- [x] 6.2 Run focused dashboard Ash/resource tests.
- [x] 6.3 Run `mix format` for touched Elixir files.
- [x] 6.4 Run applicable web-ng quality checks before merge.

## 7. Viewer Authoring Affordances
- [x] 7.1 Add inline panel actions for refresh, SRQL inspection, edit-in-settings, CSV export, duplicate, and clone-to-dashboard.
- [x] 7.2 Add dashboard-scoped variable controls and substitute variable values into panel and trend SRQL execution.
- [x] 7.3 Add a compact layout action that reflows saved panels onto the 12-column grid.
- [x] 7.4 Surface panel refresh intervals in rendered panel headers.
- [x] 7.5 Keep viewer/editor controls permission-aware.
- [x] 7.6 Add regression coverage for variables, duplicate/clone, compact layout, and inline actions.

## 8. Remaining Authoring Phases
- [x] 8.1 Replace plain SRQL textareas in the canvas inspector with an editor surface that provides query help and completion metadata.
- [x] 8.2 Add debounced auto-preview for inspector changes and surface inspector errors inline.
- [x] 8.3 Add structured binding controls for gauge/count, pivot, and chart panel outputs.
- [x] 8.4 Replace free-form trend SRQL entry with comparison-window controls that synthesize trend queries.
- [x] 8.5 Persist in-progress dashboard drafts across reloads.
- [x] 8.6 Reduce canvas `data-props` payload size while keeping preview rendering functional.
- [x] 8.7 Replace large CSV `data:` URLs with a streaming authenticated export endpoint.
- [x] 8.8 Move reusable user group management out of the dashboard creator and into a dedicated settings page.
- [x] 8.9 Add regression coverage for inspector editing, draft restore, CSV export, and group route separation.
