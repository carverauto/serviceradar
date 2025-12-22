## ADDED Requirements
### Requirement: Web-NG provides Oban-backed job scheduling
The web-ng application MUST run Oban with CNPG as the job storage backend so background jobs are persisted and observable.

#### Scenario: Oban tables exist after migration
- **GIVEN** web-ng has applied database migrations
- **WHEN** `\dt oban_jobs` is executed in the CNPG database
- **THEN** the `oban_jobs` table exists.

### Requirement: Cron scheduling is coordinated across nodes
The system MUST use a custom Oban scheduler plugin with peer leader election so only one scheduler instance enqueues recurring jobs in multi-node deployments.

#### Scenario: Single scheduler is elected across multiple nodes
- **GIVEN** two web-ng nodes are running with Oban peers configured
- **WHEN** Oban cron starts
- **THEN** exactly one node is elected as the cron leader and schedules recurring jobs.

### Requirement: Periodic jobs are protected against duplication
The system MUST apply job uniqueness settings for periodic jobs to prevent duplicate execution when scheduling overlaps or leader changes occur.

#### Scenario: Uniqueness prevents duplicate refresh jobs
- **GIVEN** the refresh worker is scheduled with uniqueness constraints
- **WHEN** two cron schedule attempts occur within the uniqueness window
- **THEN** only one job is enqueued in `oban_jobs`.

### Requirement: Trace summaries refresh job is scheduled
The system MUST schedule a recurring Oban job to refresh `otel_trace_summaries` every 2 minutes using the configured schedule source.

#### Scenario: Refresh worker is enqueued on schedule
- **GIVEN** web-ng is running with Oban cron enabled
- **WHEN** 3 minutes elapse
- **THEN** `SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker';` returns a value greater than zero.

#### Scenario: Refresh worker executes concurrent refresh
- **GIVEN** the refresh worker runs
- **WHEN** it executes
- **THEN** it uses `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`.

### Requirement: Job schedules are configurable via admin UI
The system MUST provide an admin UI to view supported jobs and edit their schedules, with changes persisted in the database.

#### Scenario: Admin updates a job schedule
- **GIVEN** an admin user updates the trace refresh schedule in the UI
- **WHEN** the change is saved
- **THEN** the new schedule is stored and used by the cron scheduler.

### Requirement: Job run history is visible in admin UI
The system MUST display recent Oban job runs for supported jobs, including state and timestamps, in the job management UI.

#### Scenario: Admin views job run history
- **GIVEN** recent Oban jobs exist for the refresh worker
- **WHEN** the job management UI is loaded
- **THEN** the latest run state and timestamps are displayed.

### Requirement: Admin can manually enqueue supported jobs
The system MUST allow a user to enqueue supported jobs on demand from the job management UI.

#### Scenario: User triggers refresh job
- **GIVEN** the refresh job is enabled
- **WHEN** the user selects "Run now" for the refresh job
- **THEN** a new job is enqueued in `oban_jobs` for the refresh worker.
