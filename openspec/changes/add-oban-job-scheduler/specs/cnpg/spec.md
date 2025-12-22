## MODIFIED Requirements
### Requirement: Trace summaries materialized view is refreshed periodically
The system MUST automatically refresh the `otel_trace_summaries` materialized view at regular intervals using the web-ng job scheduler (Oban), ensuring dashboard queries see recent trace data without manual intervention.

#### Scenario: Oban refresh job runs without pg_cron
- **GIVEN** a CNPG cluster without the pg_cron extension installed
- **WHEN** the Oban refresh worker runs in web-ng
- **THEN** `SELECT count(*) FROM otel_trace_summaries;` returns a non-zero count after the job completes.

#### Scenario: MV refresh completes without blocking reads
- **GIVEN** the Oban refresh worker is running
- **WHEN** a query `SELECT * FROM otel_trace_summaries LIMIT 10;` is executed during refresh
- **THEN** the query returns results without waiting for the refresh to complete.

#### Scenario: Refresh cadence aligns with 2-minute schedule
- **GIVEN** web-ng is running with the default Oban cron schedule
- **WHEN** 5 minutes elapse
- **THEN** at least two refresh jobs are recorded in `oban_jobs` with worker `ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker`.
