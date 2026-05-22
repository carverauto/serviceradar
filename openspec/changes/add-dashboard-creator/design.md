# Design: SRQL Dashboard Creator

## Context
ServiceRadar already has two dashboard surfaces:

- `/dashboard` is the operations landing page and SRQL explorer.
- `/dashboards/:route_slug` hosts approved dashboard packages backed by `DashboardPackage` and `DashboardInstance`.

The dashboard package path is intentionally an admin-approved extension model: external repositories build a browser module, ServiceRadar imports and verifies it, then web-ng supplies SRQL frames, settings, theme, navigation, Mapbox, and lifecycle APIs. That is still the right model for fully custom dashboards.

Issue #3395 asks for something different: an in-product creator for normal ad-hoc dashboards driven by SRQL queries. Those dashboards should not require a separate repository, npm build, signed artifact, or trusted custom JavaScript.

## Goals
- Let users create, edit, view, and share saved dashboards composed of SRQL-backed panels.
- Infer compatible visual options from previewed SRQL result fields.
- Render authored dashboards with web-ng-owned components, not user-provided JavaScript.
- Keep `/dashboard` as the operations landing page while adding `/dashboard/:dashboard_id` for saved dashboards.
- Support scheduled email reports without creating one persistent cron/AshOban schedule per report.

## Non-Goals
- Replacing the dashboard SDK or dashboard package host.
- Supporting arbitrary custom JavaScript in authored dashboards.
- Building a general BI product with joins, semantic models, or cross-dashboard variables in the first iteration.
- Adding multi-tenant routing or per-customer isolation.

## Decisions

### Decision: Use first-class authored dashboard resources
Add new resources under `ServiceRadar.Dashboards` rather than overloading `DashboardPackage`:

- `AuthoredDashboard`: title, description, slug/id, owner, visibility, layout, default time window, variables, status.
- `DashboardPanel`: dashboard ID, title, SRQL query, visual type, visual config, layout position, refresh policy.
- `DashboardReportSchedule`: dashboard ID, recipients, cron/hourly schedule, timezone, enabled flag, next due time, last delivery state.
- `DashboardReportDelivery`: schedule ID, due time, status, rendered metadata, delivery error, message ID.
- `DashboardAccessGrant`: dashboard ID, subject user/group, and view/edit access.

Reusable user groups belong in `ServiceRadar.Identity` as generic `UserGroup`
and `UserGroupMembership` resources. Dashboards consume those groups through
access grants, but the groups are not dashboard-specific so future features can
use the same group model.

Why: package dashboards are versioned trusted renderer artifacts. Authored dashboards are editable database definitions rendered by core UI components. Mixing them would create confusing lifecycle and security semantics.

### Decision: Route saved dashboards at `/dashboard/:dashboard_id`
The existing `/dashboard` route remains the main operations dashboard. Saved authored dashboards use `/dashboard/:dashboard_id`, where `dashboard_id` is a UUID or stable slug owned by `AuthoredDashboard`.

The existing `/dashboards/:route_slug` package-host route stays unchanged.

Authored dashboards support both UUID lookup and user-editable slugs immediately.
Slugs are optional, unique when present, and do not replace the canonical UUID.

### Decision: Keep visualization rendering in web-ng
The creator uses a fixed visual registry in web-ng. Initial visual families:

- table
- single-value/stat
- line or area time series
- bar chart
- categorical breakdown
- status list

Each visual advertises required field shapes. The visual picker only enables compatible visuals after SRQL preview/introspection has inferred field metadata.

### Decision: Preview SRQL with enforced bounds
The preview service executes SRQL through the existing embedded SRQL path, but forces a safe preview limit and records metadata:

- field names
- primitive type hints
- temporal/numeric/categorical classification
- nullability hints
- sample values

Queries that cannot be represented safely still can be saved only if they can render as a table. Invalid or expensive queries show actionable validation errors before save.

### Decision: Scheduled reports use scanner plus per-due jobs
Do not register one AshOban cron job per report schedule. Add one catalogued periodic job, for example `dashboard_report_scheduler`, that runs hourly by default and scans enabled due report schedules. It enqueues a per-due `DashboardReportDeliveryWorker` with uniqueness on `{schedule_id, due_at}`.

This keeps Oban cron cardinality bounded while still allowing retries and delivery history per scheduled report run.

### Decision: Email report output is a bounded snapshot
A report delivery evaluates the dashboard panels with report-safe SRQL limits and sends an email containing:

- dashboard title
- panel summaries
- tabular excerpts or chart image/HTML summaries where supported
- links back to the saved dashboard

PDF/export can be added later behind the same delivery model if needed.

Report recipients may be arbitrary external email addresses in this iteration.
That is intentionally gated by both the global `analytics.reports.schedule`
permission and per-dashboard edit access, because a schedule can exfiltrate the
dashboard's SRQL result snapshot outside ServiceRadar.

### Decision: Public dashboards use the dashboard create permission
The first iteration does not add a narrower publishing permission. Users with
`analytics.dashboards.create` can create public dashboards, while edit/share and
report-schedule operations still require the relevant global permission plus
per-dashboard ownership or edit-grant access.

## Risks / Trade-Offs
- Visual inference can be wrong for ambiguous fields. Mitigation: users can override visual type and field mappings, and table fallback is always available.
- Report execution can become expensive. Mitigation: enforce panel/report limits, capture failures, and run deliveries through a bounded Oban queue.
- `/dashboard/:dashboard_id` is visually close to `/dashboard`. Mitigation: exact `/dashboard` remains the landing page; saved dashboards always include an ID segment.
- Email rendering may lag interactive visuals. Mitigation: start with robust HTML/tabular summaries and use chart snapshots only where deterministic.

## Open Questions
- Should public dashboard creation later get a narrower publishing permission?
- Should report recipients later be restricted to ServiceRadar users/groups or verified domains?
