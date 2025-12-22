## ADDED Requirements
### Requirement: Web-NG provides Oban-backed job scheduling
The web-ng application MUST run Oban with CNPG as the job storage backend so background jobs are persisted and observable.

#### Scenario: Oban tables exist after migration
- **GIVEN** web-ng has applied database migrations
- **WHEN** `\dt oban_jobs` is executed in the CNPG database
- **THEN** the `oban_jobs` table exists.

### Requirement: Trace summaries refresh job is scheduled
The system MUST schedule a recurring Oban job to refresh `otel_trace_summaries` every 2 minutes.

#### Scenario: Refresh worker is enqueued on schedule
- **GIVEN** web-ng is running with Oban cron enabled
- **WHEN** 3 minutes elapse
- **THEN** `SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker';` returns a value greater than zero.

#### Scenario: Refresh worker executes concurrent refresh
- **GIVEN** the refresh worker runs
- **WHEN** it executes
- **THEN** it uses `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`.
