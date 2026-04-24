# job-scheduling Specification

## Purpose
TBD - created by archiving change add-oban-job-scheduler. Update Purpose after archive.
## Requirements
### Requirement: ServiceRadar provides Oban-backed job scheduling
The web-ng application MUST run Oban with CNPG as the job storage backend so background jobs are persisted and observable. Other Elixir nodes MAY join the Oban cluster as peers to share job execution.

#### Scenario: Oban tables exist after migration
- **GIVEN** web-ng has applied database migrations
- **WHEN** `\dt oban_jobs` is executed in the CNPG database
- **THEN** the `oban_jobs` table exists.

### Requirement: Cron scheduling is coordinated across nodes
The system MUST use `Oban.Plugins.Cron` with `Oban.Peers.Database` leader election so only one scheduler instance enqueues recurring jobs in multi-node deployments.

#### Scenario: Single scheduler is elected across multiple nodes
- **GIVEN** web-ng and core nodes are running with Oban peers configured
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
- **THEN** `SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadar.Jobs.RefreshTraceSummariesWorker';` returns a value greater than zero.

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

### Requirement: Oban job failures emit internal OCSF events
The system SHALL record an OCSF Event Log Activity entry in the tenant `ocsf_events` table when a tenant-scoped Oban job exhausts its retry attempts.

#### Scenario: NATS account provisioning job fails after retries
- **GIVEN** the NATS account provisioning job has reached its final retry for a tenant
- **WHEN** the job fails on the last attempt
- **THEN** an `ocsf_events` row SHALL be inserted for the tenant
- **AND** the event SHALL include the job name and attempt count

### Requirement: Scheduling clients handle missing Oban instances

Services that insert or enqueue Oban jobs MUST treat a missing Oban instance/configuration as a recoverable condition and avoid crashing user-facing workflows.

#### Scenario: Oban instance missing during enqueue
- **GIVEN** a service that enqueues jobs in response to a user action
- **AND** the Oban instance is not running or configured in that process
- **WHEN** the service attempts to enqueue a job
- **THEN** the user-facing operation SHALL succeed
- **AND** the system SHALL record that the job scheduling is deferred or skipped
- **AND** operators SHALL have a warning or log entry indicating the scheduler is unavailable

### Requirement: Job Management UI Requires Jobs Permission
The job scheduler UI and any actions that enqueue jobs (for example "Trigger Now") MUST be restricted to actors with permission `settings.jobs.manage`.

#### Scenario: User without permission cannot view job management UI
- **GIVEN** a logged-in user without `settings.jobs.manage`
- **WHEN** the user visits `/admin/jobs`
- **THEN** the system denies access (redirect or error)

#### Scenario: User without permission cannot trigger a job
- **GIVEN** a logged-in user without `settings.jobs.manage`
- **WHEN** the user attempts to trigger a job via `/admin/jobs/:id`
- **THEN** the system denies the action
- **AND** no job is enqueued

### Requirement: Device Tombstone Reaper Job
The system SHALL run a scheduled job that permanently deletes devices whose tombstones are older than a configurable retention window.

#### Scenario: Reaper removes expired tombstones
- **GIVEN** a device with `deleted_at` older than the retention window
- **WHEN** the reaper job runs
- **THEN** the device record SHALL be permanently removed

#### Scenario: Retention window is configurable
- **GIVEN** an admin updates the retention days setting
- **WHEN** the reaper job runs next
- **THEN** it SHALL use the updated retention window

#### Scenario: Reaper schedule is configurable
- **GIVEN** an admin updates the reaper schedule
- **WHEN** the reaper job runs next
- **THEN** it SHALL use the configured schedule

#### Scenario: Manual cleanup execution
- **GIVEN** an admin triggers a manual cleanup
- **WHEN** the cleanup action runs
- **THEN** the reaper job SHALL execute immediately using current settings

