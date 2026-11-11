## ADDED Requirements

### Requirement: Snapshot Scopes Publish Through One Publisher Job
The system SHALL publish pending exposure snapshot scopes through one singleton publisher job draining a scopes table, with no per-scope Oban jobs and no `{:snooze, _}` on the singleton publisher path.
A scope needing publication is a row in `platform.exposure_snapshot_scopes`, never an Oban job.
The publisher claims due rows oldest-first, publishes each scope's fenced generation through the existing per-scope engine, marks the row complete only after its generation completes, and exits returning `:ok` when no claimable row remains.
Demand paths (reconciliation, finalizer, maintenance worker, prepare completion) insert or re-pend the scope row and ensure the singleton job; a unique-insert ensure while one is available or scheduled is a no-op, an executing job never blocks the next ensure, and a run that finds the session lock held exits quietly.
The engine keeps its direct-drive `perform/1` with the original synchronous-publish-or-snooze contract for repair tooling and boundary tests; nothing enqueues it.

#### Scenario: One execution drains many scopes
- **GIVEN** pending scope rows for three device ordinals and no publisher job
- **WHEN** demand ensures the publisher once
- **THEN** one job execution completes all three scopes
- **AND** no `ExposureSnapshotWorker` Oban row is created
- **AND** no further publisher execution runs until new demand arrives.

#### Scenario: Empty table means no work
- **GIVEN** no pending, adoptable, or due scope rows
- **WHEN** the publisher runs
- **THEN** it returns `:ok` without opening any generation.

### Requirement: Scope Publication Order Is FIFO
The system SHALL claim due scope rows in row-id order.
Generations fence independent source views, so order affects latency only; the fleet-wide (NULL) scope takes its FIFO turn with no priority.

#### Scenario: Scopes publish oldest first
- **GIVEN** pending scopes inserted for ordinals 9, 3, and 7 in that order
- **WHEN** the publisher drains the table
- **THEN** generations open in the order 9, 3, 7.

### Requirement: Scopes Publish At Least Once Across Crashes
The system SHALL republish any scope whose generation did not observably complete before the publisher died, with a fresh generation fence.
A `publishing` row whose lease expired is adopted by the next run: a completed generation marks the scope complete with no republish; a still-`publishing` generation is aborted through the session-lock reader-lost proof and the scope republishes; a `published` or `finalizing` generation belongs to the maintenance/finalizer pipeline and is left alone until it completes.
Duplicate delivery across the crash is absorbed by envelope-hash idempotency.

#### Scenario: Crash mid-drain resumes without loss or double work
- **GIVEN** scopes A (generation complete), B (generation publishing), C (pending), and D (generation published) when the publisher process dies
- **WHEN** the next publisher run drains the table
- **THEN** A is marked complete with no new generation
- **AND** B's orphaned generation is aborted and B republishes once
- **AND** C publishes
- **AND** D's generation is untouched and D completes without republish once it finishes.

### Requirement: Failing Scopes Neither Block Others Nor Vanish
The system SHALL isolate per-scope failures: a scope error records attempts and backs off `not_before` while the loop continues draining, and past the attempts cap the row goes `dead` with error telemetry while persisting with its error.
A poison scope never blocks other scopes, and failed or dead rows are never deleted by the publisher; the next demand signal re-pends a dead row.

#### Scenario: Poison scope is contained
- **GIVEN** scopes A (poisoned, fails every attempt), B, and C pending
- **WHEN** the publisher drains the table
- **THEN** B and C complete in the same execution
- **AND** A ends `dead` with attempts recorded and dead-letter telemetry emitted
- **AND** the attempt returns `:ok`.

### Requirement: In-Flight Publisher Demand Migrates To Scope Rows
The system SHALL migrate queued `ExposureSnapshotWorker` Oban rows into scope rows exactly once at deploy time.
The migration inserts one `pending` row per distinct scope (`args->>'device_ord'`, NULL when absent) from queued publisher Oban rows (`available`, `scheduled`, `retryable`), then deletes those Oban rows. `executing` rows are left for Oban lifeline, which runs them through the retained direct-drive `perform/1`, so no demand is lost and no old publisher job can run afterward except a lifeline-resumed row that still publishes through the engine.

#### Scenario: Queued scopes survive the upgrade
- **GIVEN** queued publisher Oban rows for device ordinals 5 and 12 and one fleet-wide row
- **WHEN** the migration runs
- **THEN** three pending scope rows exist for ordinals 5, 12, and NULL
- **AND** no queued `ExposureSnapshotWorker` Oban row remains.

### Requirement: Stalled Drains Are Re-Ensured By The Maintenance Backstop
The system SHALL re-ensure the publisher when unrestored scope work exists (`pending`, `publishing`, `preparing`, or `failed` rows).
The every-minute maintenance worker checks this on its existing pass; over-ensuring is free because a run that finds the session lock held or the table quiet exits immediately, and combined with per-signal ensures, a publisher that exits on an exhausted wait budget always has a path back while work remains.

#### Scenario: Exited publisher is woken by the backstop
- **GIVEN** pending scopes after a publisher exited on its wait budget
- **WHEN** the maintenance worker runs
- **THEN** a publisher job is ensured.
