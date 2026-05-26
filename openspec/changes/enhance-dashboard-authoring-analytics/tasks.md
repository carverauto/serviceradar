## 1. Proposal
- [x] 1.1 Validate OpenSpec change.
- [x] 1.2 Confirm approval before feature implementation.

## 2. Dashboard Search Separation
- [x] 2.1 Make dashboard package pages use `in:dashboards` for the global topbar SRQL state.
- [x] 2.2 Keep package frame SRQL overrides isolated to the dashboard host API and URL frame params.
- [ ] 2.3 Add regression coverage for the topbar builder opening without unsupported-query warning.

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
- [ ] 4.3 Render gauge/count dashlets in the dashboard and report paths with accessible labels and empty/error states.
- [ ] 4.4 Add tests for gauge thresholds, count labels, and trend-over-time rendering.

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
