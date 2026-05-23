## 1. Proposal and Model
- [x] 1.1 Confirm current authored dashboard schema/resources and choose the lowest-risk dataset migration shape.
- [x] 1.2 Add user-facing 7-digit dashboard reference and optional unique slug fields, constraints, and backfill migration.
- [x] 1.3 Update dashboard lookup, routes, links, hub rows, preferences, grants, and SRQL dashboard search output to use numeric refs/slugs instead of UUIDs.

## 2. SRQL Builder Integration
- [x] 2.1 Extract or adapt the existing SRQL builder component/event flow for embedded dashboard panel use.
- [x] 2.2 Persist builder state alongside raw SRQL for builder-compatible dashboard datasets.
- [x] 2.3 Preserve raw SRQL editing for unsupported queries without letting builder state overwrite unsupported clauses.
- [x] 2.4 Add tests for builder parse/build round trips in dashboard authoring.

## 3. Datasets and Output Binding
- [x] 3.1 Add named dashboard datasets or an equivalent compatible model for multiple SRQL queries per dashboard.
- [x] 3.2 Extend preview/introspection to expose stable field IDs, object/JSON paths, sample values, and aggregate compatibility hints.
- [x] 3.3 Add data binding validation for value, label, time, group, boolean/status, JSON path, and aggregation mappings.
- [x] 3.4 Migrate existing panel queries to dataset-backed default bindings.

## 4. Rich Visualization Registry
- [x] 4.1 Add visual types and config schemas for gauges, availability ratios, status/icon values, sparklines, stat cards, categorical charts, and tables.
- [x] 4.2 Add structured display controls for labels, captions, units, thresholds, colors, legends, and empty states.
- [x] 4.3 Add structured layout controls for position, size, order, and responsive behavior.
- [x] 4.4 Validate visual configs against preview metadata before save.

## 5. Table Rendering
- [x] 5.1 Add table column schema with source field/JSON path, label, renderer, visibility, and alignment.
- [x] 5.2 Replace raw object/JSON table cell output with summary, expandable detail, hidden, or extracted-field rendering.
- [x] 5.3 Add boolean/status/icon renderers and sparkline-in-table rendering where data shape supports it.
- [x] 5.4 Add tests for table rendering of nested JSON, booleans, status fields, and sparse values.

## 6. Validation
- [x] 6.1 Run focused dashboard Ash/resource tests.
- [x] 6.2 Run focused LiveView tests for dashboard creation, builder editing, output bindings, and table renderers.
- [x] 6.3 Run `mix format` and the applicable `elixir/web-ng` quality checks.
- [x] 6.4 Run `openspec validate enhance-dashboard-creator-visual-builder --strict`.

## 7. Dashboard Hub and Default Package
- [x] 7.1 Verify the SDK-built `service-availability-noc` dashboard package exists in source/release artifacts and is imported/enabled in demo.
- [x] 7.2 Make `/dashboards` open or prominently feature `service-availability-noc` as the system default when no user default exists.
- [x] 7.3 Add SRQL-backed filtering/search to `/dashboards`, defaulting to `in:dashboards`.
- [x] 7.4 Enable the top SRQL input bar on `/dashboards` and route query changes back into the hub results.
- [x] 7.5 Change the operations shell context label next to the logo from "ServiceRadar" to "Dashboards" on `/dashboards`.
- [x] 7.6 Add tests for missing default package diagnostics, accessible dashboard switching, SRQL dashboard search, and shell title behavior.
