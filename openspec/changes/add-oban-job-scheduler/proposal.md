# Change: Oban Job Scheduler for Web-NG

**Status**: Approved

## Why

The Observability traces list depends on the `otel_trace_summaries` materialized view being refreshed. In local docker-compose the CNPG image does not include pg_cron, so the view never refreshes and the UI shows no traces even though raw spans exist. We also want a unified job system for future background tasks with visibility into job state.

## What Changes

1. Add Oban to the web-ng application for background job scheduling.
2. Create and run Oban migrations in web-ng so jobs are stored in CNPG.
3. Add an Oban worker that refreshes `otel_trace_summaries` concurrently.
4. Schedule the refresh job every 2 minutes via a custom Oban scheduler plugin using peer leader election (single scheduler across nodes).
5. Add guardrails to prevent duplicate refreshes (job uniqueness + scheduler coordination).
6. Expose job management via web-ng with a custom admin UI (schedule editing + run visibility) without relying on Oban Web.
7. Define a job catalog and scheduling controls suitable for future jobs (reports, syncs, external fetches).
8. Defer RBAC gating for job management until the RBAC workstream lands.
9. Update CNPG spec requirements to remove the pg_cron dependency.
10. Add a new job-scheduling capability spec that defines Oban usage, scheduling controls, and refresh cadence.

## Impact

- **Affected specs**: `cnpg` (MODIFIED), new `job-scheduling` capability (ADDED)
- **Affected code**:
  - `web-ng/mix.exs` - add Oban dependency
  - `web-ng/config/*` - Oban configuration and queues
  - `web-ng/priv/repo/migrations/` - Oban schema migration
  - `web-ng/lib/serviceradar_web_ng/` - Oban supervisor + refresh worker
  - `web-ng/lib/serviceradar_web_ng_web/` - Admin UI and job management
- **Breaking changes**: None (adds tables and background jobs only)
- **Migration**: run Oban migrations as part of `mix ecto.migrate`
