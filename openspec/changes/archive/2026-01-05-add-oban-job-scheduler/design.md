## Context

The traces list relies on `otel_trace_summaries`, a materialized view that is refreshed with pg_cron in environments where the extension exists. The docker-compose CNPG image does not ship pg_cron, so the view never refreshes, leaving traces empty even though span data is present.

## Goals / Non-Goals

- Goals:
  - Schedule `otel_trace_summaries` refreshes via Oban in web-ng.
  - Support horizontal scaling with a single cron scheduler across nodes.
  - Provide admin UI controls for job scheduling and visibility via a custom UI.
  - Centralize background job scheduling in a single system (Oban).
  - Preserve the existing 2-minute refresh cadence.
- Non-Goals:
  - Rebuild the CNPG image to include pg_cron.
  - Change trace aggregation logic or SRQL query semantics.
  - Implement RBAC or admin authorization for job management in this change.

## Decisions

- Decision: Use Oban (web-ng) with the existing CNPG database for scheduling.
- Decision: Implement a dedicated Oban worker that runs `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`.
- Decision: Host the refresh worker in the shared ServiceRadar job module so multiple Elixir nodes can execute it.
- Decision: Schedule the worker via `Oban.Plugins.Cron` at `*/2 * * * *`.
- Decision: Use Oban peer leader election to avoid multi-node duplicate scheduling.
- Decision: Configure job uniqueness to guard against duplicate refreshes.
- Decision: Build a custom admin UI for job visibility and scheduling without relying on Oban Web.
- Decision: Defer access control for job management until RBAC is available.

## Risks / Trade-offs

- Extra load from periodic MV refreshes now originates from web-ng instead of the database.
- Oban requires additional DB tables and migrations; failures could delay refreshes.
- Leader election misconfiguration could result in duplicate cron jobs or no scheduling.
- Admin UI exposure needs access control and audit logging; the job management UI is unauthenticated until RBAC is in place.

## Migration Plan

1. Add Oban dependency and configure it to use the existing CNPG repo.
2. Add Oban migration and run `mix ecto.migrate` in docker compose.
3. Enable Oban global cron mode + peer leader config for multi-node scheduling.
4. Deploy worker and cron schedule; verify `otel_trace_summaries` starts updating.
5. Implement custom admin UI controls in web-ng.
6. Remove reliance on pg_cron in CNPG spec.

## Open Questions
- None.
