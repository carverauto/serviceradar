## MODIFIED Requirements
### Requirement: Periodic jobs are protected against duplication
The system MUST apply job uniqueness settings for periodic jobs to prevent duplicate steady-state execution without allowing stale scheduler state to permanently block future runs.

#### Scenario: Uniqueness prevents duplicate refresh jobs
- **GIVEN** the refresh worker is scheduled with uniqueness constraints
- **WHEN** two cron schedule attempts occur within the active uniqueness window
- **THEN** only one job is enqueued in `oban_jobs`

#### Scenario: Orphaned executing state does not block future periodic work
- **GIVEN** a prior periodic job row remains stuck in `executing` after a restart or failover
- **WHEN** the scheduler reaches the next valid run window
- **THEN** the system SHALL be able to enqueue and execute a replacement run
- **AND** uniqueness SHALL NOT require manual database cleanup to restore scheduling

### Requirement: Orphaned periodic Oban jobs are reaped
The system MUST detect periodic Oban jobs that have remained in `executing` beyond their allowed runtime or stale-job threshold, transition them out of the active execution set, and emit an operator-visible signal that cleanup occurred.

#### Scenario: Stale executing periodic job is reaped
- **GIVEN** a periodic Oban job remains in `executing` longer than its configured stale threshold
- **WHEN** stale-job cleanup runs
- **THEN** the job SHALL be transitioned out of `executing` state or removed from the active execution set
- **AND** future periodic runs SHALL no longer be blocked by that orphaned row

#### Scenario: Cleanup is observable
- **GIVEN** a stale periodic Oban job is reaped
- **WHEN** operators inspect logs, telemetry, or job history
- **THEN** they SHALL be able to see that orphaned-job cleanup occurred
- **AND** which worker and job id were affected

### Requirement: Trace summaries refresh job is scheduled
The system MUST schedule a recurring Oban job to maintain `platform.otel_trace_summaries` every 2 minutes using the configured schedule source.

#### Scenario: Refresh worker is enqueued on schedule
- **GIVEN** web-ng is running with Oban cron enabled
- **WHEN** 3 minutes elapse
- **THEN** `SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadar.Jobs.RefreshTraceSummariesWorker';` returns a value greater than zero

#### Scenario: Refresh worker performs incremental maintenance
- **GIVEN** the refresh worker runs
- **WHEN** it executes
- **THEN** it incrementally upserts trace summaries from `platform.otel_traces`
- **AND** it prunes `platform.otel_trace_summaries` rows older than the supported window

### Requirement: Alerts retention cleanup is scheduled
The system MUST schedule a recurring Oban job that prunes `platform.alerts` rows older than the supported alert retention window without requiring manual database cleanup.

#### Scenario: Alert retention worker is enqueued on schedule
- **GIVEN** web-ng is running with Oban cron enabled
- **WHEN** the alert retention cron window elapses
- **THEN** `SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadar.Jobs.AlertsRetentionWorker';` returns a value greater than zero

#### Scenario: Alert retention cleanup prunes expired rows in batches
- **GIVEN** `platform.alerts` contains rows older than the supported retention window
- **WHEN** the alert retention worker executes
- **THEN** it deletes expired rows in bounded batches ordered by `triggered_at`
- **AND** it logs or records how many rows were pruned
