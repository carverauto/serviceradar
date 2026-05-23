# Design: Dashboard creator visual builder

## Context
The current authored dashboard implementation stores dashboard panels with a single `srql_query`, `visual_type`, `visual_config`, and JSON layout. It renders a small fixed visual set and falls back to a generic table. That is enough for basic demos, but it leaves users manually editing JSON and raw SRQL and cannot express common dashboard patterns such as "query all ZZA devices, calculate available/unavailable counts, and render a gauge."

The web UI already has a reusable SRQL builder stack:

- `ServiceRadarWebNGWeb.SRQL.Builder` for query state, parsing, and SRQL text generation.
- `ServiceRadarWebNGWeb.SRQL.Page` for common LiveView event handling.
- `<.srql_query_builder>` in `ServiceRadarWebNGWeb.SRQLComponents`.
- `ServiceRadarWebNGWeb.SRQL.Catalog` for entity and field metadata.

Dashboard authoring should reuse that system instead of creating another query editor.

## Goals
- Make dashboard authoring approachable for operators who do not want to hand-write SRQL.
- Keep raw SRQL support for advanced users and unsupported builder clauses.
- Allow a dashboard to define multiple named SRQL datasets.
- Bind each visualization to explicit dataset fields, aggregations, and transforms.
- Support table-specific cell renderers such as icons, booleans, status badges, JSON summaries, links, and sparklines.
- Give users control over panel placement, sizing, labels, captions, units, thresholds, and legends.
- Use human-friendly dashboard references in URLs and search results.
- Make `/dashboards` a true dashboard landing page: default to the SDK-built service availability dashboard when available, and still let users discover/switch to other dashboards they can access.
- Support SRQL-driven dashboard discovery from the dashboard hub top navigation.

## Non-Goals
- Adding arbitrary custom JavaScript to authored dashboards.
- Replacing dashboard packages or the SDK for fully custom dashboards.
- Building a general SQL/BI semantic model in this slice.
- Changing SRQL syntax to support joins or cross-query expressions in the parser.

## Decisions

### Decision: Use dashboard datasets as the query unit
Introduce a dashboard-level dataset model, either as a first-class resource or a backwards-compatible panel-owned structure during migration. Each dataset has:

- stable key, display name, and SRQL query
- builder state when the query is builder-compatible
- preview metadata and last validation state
- optional refresh policy

Panels reference datasets by key. A dashboard can have one query per panel, or several panels can share a dataset. Multi-region examples such as ZZA, MSP, and LAX can be modeled as separate datasets with distinct SRQL queries.

### Decision: Store visual bindings separately from visual display config
Split visual configuration into:

- `data_binding`: dataset key, value field, label field, time field, group field, boolean/status field, JSON path, aggregation mode, and optional filters.
- `display_config`: title, caption, labels, units, thresholds, colors, legend, empty state, and table column renderer settings.
- `layout`: x/y/w/h/order/responsive hints.

Why: binding determines what data is read; display config determines how it is shown. Keeping them distinct makes validation and preview predictable.

### Decision: Reuse the existing SRQL builder component
Dashboard editor panels should embed the existing `<.srql_query_builder>` and use `ServiceRadarWebNGWeb.SRQL.Builder` parsing/building functions. Unsupported queries remain editable in raw mode and are marked as builder-unsynced, matching the existing global SRQL behavior.

If the existing component is too page-shell-specific, extract a smaller builder component/event adapter instead of duplicating query-building logic.

### Decision: Human dashboard references are public, UUIDs are internal only
Authored dashboards SHALL expose a unique 7-digit numeric dashboard reference, for example `4821937`. Routes and share links use `/dashboard/:dashboard_ref`, where `dashboard_ref` can be the numeric reference or an optional slug.

Existing internal UUID primary keys may remain for relational integrity if that is the lowest-risk migration, but user-facing URLs, copy links, dashboard hub rows, and SRQL dashboard search results must show the numeric reference and slug, not raw UUIDs.

Slug uniqueness should be case-insensitive and checked before save. Slugs should also reject reserved route words and avoid collisions with other dashboard-visible slugs so the dashboard hub can present unambiguous links.

### Decision: Tables use column schemas, not raw row dumping
Table visuals should store column definitions:

- source field or JSON path
- label
- renderer type
- width/alignment
- sort/display hints
- hidden/default-visible flag

Object fields default to summarized and expandable rendering. Raw JSON can still be available in an expanded detail drawer or copy action, but it must not be dumped into a normal table cell by default.

### Decision: Dashboard hub is SRQL-filtered discovery, not a static card list
The `/dashboards` hub should use the dashboard SRQL entity to discover authored dashboards and dashboard-package instances available to the current user. The hub should default to opening or prominently featuring `service-availability-noc` when that package route is enabled, then let users search and switch dashboards without visiting settings.

The `/dashboards` route should enable the same top SRQL input affordance used by other SRQL-backed pages, scoped to `in:dashboards` by default. The shell title next to the ServiceRadar logo should read "Dashboards" for this route so the user knows they are in the dashboard workspace, not the generic product landing shell.

## Risks / Trade-Offs
- Adding datasets and bindings may require data migration from existing panel records. Mitigation: treat each existing panel query as one generated dataset and create default table bindings.
- The SRQL builder component may assume global page-level event names. Mitigation: namespace dashboard-builder events or extract an event adapter while reusing `ServiceRadarWebNGWeb.SRQL.Builder`.
- Short numeric IDs can collide. Mitigation: database unique constraint and retry generation inside create action/transaction.
- Rich table renderers can become complex. Mitigation: start with a constrained renderer registry and validate configs against preview metadata.

## Migration Plan
1. Add numeric dashboard reference and optional slug fields with unique indexes.
2. Backfill existing authored dashboards with generated numeric references.
3. Update route lookup to accept numeric reference or slug while still optionally resolving old UUIDs for compatibility only during migration.
4. Convert existing panel `srql_query` values into dataset-backed panel bindings.
5. Replace raw visual config text areas with structured controls, keeping an advanced JSON view only for diagnostics.
6. Verify the service availability dashboard package is imported/enabled in demo and add a release/demo bootstrap check so `service-availability-noc` is not silently missing.
