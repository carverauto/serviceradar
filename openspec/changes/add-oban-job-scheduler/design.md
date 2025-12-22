## Context

The traces list relies on `otel_trace_summaries`, a materialized view that is refreshed with pg_cron in environments where the extension exists. The docker-compose CNPG image does not ship pg_cron, so the view never refreshes, leaving traces empty even though span data is present.

## Goals / Non-Goals

- Goals:
  - Schedule `otel_trace_summaries` refreshes via Oban in web-ng.
  - Centralize background job scheduling in a single system (Oban).
  - Preserve the existing 2-minute refresh cadence.
- Non-Goals:
  - Rebuild the CNPG image to include pg_cron.
  - Change trace aggregation logic or SRQL query semantics.

## Decisions

- Decision: Use Oban (web-ng) with the existing CNPG database for scheduling.
- Decision: Implement a dedicated Oban worker that runs `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`.
- Decision: Schedule the worker via Oban's cron plugin at `*/2 * * * *`.

## Risks / Trade-offs

- Extra load from periodic MV refreshes now originates from web-ng instead of the database.
- Oban requires additional DB tables and migrations; failures could delay refreshes.

## Migration Plan

1. Add Oban dependency and configure it to use the existing CNPG repo.
2. Add Oban migration and run `mix ecto.migrate` in docker compose.
3. Deploy worker and cron schedule; verify `otel_trace_summaries` starts updating.
4. Remove reliance on pg_cron in CNPG spec.

## Open Questions

- Should we expose Oban Web (dashboard) for job visibility, and if so should it be dev-only or admin-only?
- Do we want per-environment overrides for refresh cadence beyond a single env var?
