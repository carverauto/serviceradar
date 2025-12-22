# Change: Oban Job Scheduler for Web-NG

**Status**: Draft

## Why

The Observability traces list depends on the `otel_trace_summaries` materialized view being refreshed. In local docker-compose the CNPG image does not include pg_cron, so the view never refreshes and the UI shows no traces even though raw spans exist. We also want a unified job system for future background tasks with visibility into job state.

## What Changes

1. Add Oban to the web-ng application for background job scheduling.
2. Create and run Oban migrations in web-ng so jobs are stored in CNPG.
3. Add an Oban worker that refreshes `otel_trace_summaries` concurrently.
4. Schedule the refresh job every 2 minutes via Oban's cron plugin.
5. Update CNPG spec requirements to remove the pg_cron dependency.
6. Add a new job-scheduling capability spec that defines Oban usage and the refresh job cadence.

## Impact

- **Affected specs**: `cnpg` (MODIFIED), new `job-scheduling` capability (ADDED)
- **Affected code**:
  - `web-ng/mix.exs` - add Oban dependency
  - `web-ng/config/*` - Oban configuration and queues
  - `web-ng/priv/repo/migrations/` - Oban schema migration
  - `web-ng/lib/serviceradar_web_ng/` - Oban supervisor + refresh worker
- **Breaking changes**: None (adds tables and background jobs only)
- **Migration**: run Oban migrations as part of `mix ecto.migrate`
