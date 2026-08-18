---
id: self-authored-dashboards
title: Self-Authored Dashboards
sidebar_label: Self-Authored Dashboards
description: Build ServiceRadar dashboards directly in the web UI from SRQL source queries and guided visualizations.
---

# Self-Authored Dashboards

Self-authored dashboards let operators build dashboards inside the ServiceRadar
web UI without writing a dashboard package. Each dashboard is driven by one or
more SRQL source queries. Each source query can produce one or more compatible
outputs, and those outputs become panels on the dashboard canvas.

Use self-authored dashboards when you want to assemble fleet, site, service,
availability, trend, or troubleshooting views from data already searchable with
SRQL. Use the [Dashboard SDK](./dashboard-sdk.md) when you need to ship a custom
React dashboard package with bespoke rendering code.

## Finding dashboards

Open **Dashboards** from the sidebar. The dashboard library shows dashboards you
own, dashboards shared with you, and dashboards available through your groups.

From the library you can:

- search dashboards with SRQL-style filters such as `in:dashboards`;
- open a dashboard by its generated seven-digit ID or optional slug;
- mark dashboards as favorites;
- set a personal default dashboard when more than one dashboard is available.

Dashboard slugs must start with a letter and may contain lowercase letters,
numbers, and dashes. Pure seven-digit slugs are rejected because those route
segments are reserved for generated dashboard IDs.

## Creating a dashboard

Start from **Analytics** or the dashboard library and choose to create a new
dashboard. A new dashboard starts with only dashboard metadata:

- title;
- optional description;
- optional slug.

Save the dashboard before adding panels. This gives the dashboard a stable
route, owner, generated dashboard ID, and permission boundary before panels are
created.

## Query-first authoring

Dashboard panels are created from source queries. The intended flow is:

1. Open **Dashboard Creator** or **Settings** on a dashboard you can edit.
2. Add a source query with a label and SRQL query.
3. Run the query.
4. Inspect the sample rows and detected fields.
5. Choose a compatible output.
6. Add the output to the canvas.
7. Drag, resize, compact, and save the dashboard layout.

The builder uses the returned schema to guide visualization choices. For
example, a table-shaped query can become a table, but it should not offer an
availability gauge unless the output has fields that can map cleanly to
available and total values. This keeps dashboard creation from becoming a
guess-and-check loop.

## Source query examples

List recent service checks:

```srql
in:services time:last_1h sort:timestamp:desc limit:25
```

Count devices by type:

```srql
in:devices stats:count() as total by type sort:total:desc
```

Build an availability rollup:

```srql
in:devices stats:count() as total, count_if(is_available) as available by type
```

Create a time bucket for trend panels:

```srql
in:services time:last_7d bucket:1h stats:count() as total, count_if(status:"ok") as ok by bucket
```

Use the [SRQL Cookbook](./srql-cookbook.md) and
[SRQL Reference](./srql-language-reference.md) for entity names, filters,
aggregations, and bucket syntax.

Dashboard authoring clients should use `GET /api/srql/catalog` as the canonical
SRQL catalog for entity, field, control-token, and operator completions. Avoid
copying SRQL field lists into browser code or dashboard packages; the catalog
keeps authoring hints aligned with the server-side SRQL surface.

## Visualization types

The dashboard builder can offer visualizations based on query output shape:

- **Table** for row-oriented data.
- **Stat / count** for single-value metrics.
- **Gauge / availability** for ratio outputs such as available versus total.
- **Bar and line charts** for grouped or bucketed numeric data.
- **Pivot tables** for grouped summaries where users need to compare dimensions.

Panel forms should present field selectors and display options rather than raw
JSON. If a visualization requires a field such as a numerator, denominator,
label, timestamp, or metric value, the builder should offer compatible fields
from the source query output.

## Layout

Dashboards use a grid canvas. Editors can drag and resize panels, compact the
layout after removing panels, and save the layout with the dashboard. Operators
should avoid leaving single panels stranded in half-width rows unless that is an
intentional layout choice.

## Sharing and access

Dashboard access is permission-aware:

- owners and users with edit permission can change dashboard settings;
- dashboards can be shared with individual users or reusable user groups;
- users only see dashboards they own or have access to;
- administrators can manage broader dashboard and user-group access according to
  RBAC policy.

Use groups for reusable access boundaries. Groups are not dashboard-specific;
other ServiceRadar features can use the same user groups over time.

## Reports and email delivery

Reports are authored SRQL dashboards, not a separate sidebar product. The
dashboard library has a **Reports** section for system reports such as **New
devices** (`in:devices first_seen:last_30d`). Device pages also show **Added**
next to Last Seen.

Dashboards can be emailed on a schedule when outbound mail is configured under
**Settings -> Mail**. See [Outbound Mail](./outbound-mail.md) for adapters
(Local vs Test vs SMTP) and the SMTP field-by-field setup. Owners can schedule
their own dashboards. Users with the report-schedule permission can also
subscribe to public or shared reports.

Creating or changing a dashboard or schedule is recorded in AshPaperTrail and
shows up in Settings -> Audit -> History.

Report delivery is asynchronous. A scheduled dashboard report should not block
interactive dashboard viewing or editing.

## Operational notes

- Keep SRQL source queries focused. Prefer multiple clear source queries over
  one query that tries to drive unrelated panels.
- Use labels and panel titles that describe the operational question, such as
  "ZZA workstation availability" or "Hypervisor service failures".
- Prefer bucketed queries for trend-over-time panels.
- Use pivot tables when the operator needs to compare multiple dimensions
  without exporting data.
- Use the Dashboard SDK only when the built-in panel types cannot express the
  desired visualization.
