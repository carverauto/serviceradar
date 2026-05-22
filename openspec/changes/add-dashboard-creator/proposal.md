# Change: Add SRQL dashboard creator

## Why
Operators need a first-party way to turn SRQL queries into saved operational dashboards without building and publishing a custom dashboard package. Issue #3395 asks for ad-hoc dashboards that infer visualization choices from SRQL result fields, persist by dashboard ID, and optionally send scheduled email reports.

The existing dashboard SDK and package host solve trusted custom browser-module dashboards. This change adds a safer core authoring path for normal users: saved SRQL dashboard definitions rendered by web-ng-owned components, with the SDK/package system remaining available for fully custom dashboards.

## What Changes
- Add first-class authored dashboard resources for saved dashboards, panels, visual configuration, ownership metadata, sharing state, and report schedules.
- Add an Analytics dashboards workspace where users can create dashboards from SRQL queries, preview result fields, choose compatible visual types, arrange panels, and save changes.
- Add saved dashboard routes at `/dashboard/:dashboard_id` while preserving `/dashboard` as the existing operations landing page and `/dashboards/:route_slug` as the dashboard-package host.
- Add a bounded SRQL preview/introspection service that executes user queries with enforced limits and derives field metadata used by the visual picker.
- Add scheduled report support using one periodic scanner job that finds due report schedules and enqueues per-due delivery jobs, rather than registering one cron/AshOban schedule per report.
- Add email report delivery history, failure visibility, and retry-safe delivery semantics.

## Impact
- Affected specs: dashboard-creator (new)
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/jobs.ex`
  - `elixir/web-ng/test/**`
