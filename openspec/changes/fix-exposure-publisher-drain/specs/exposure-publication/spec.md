## MODIFIED Requirements

### Requirement: Snapshot Scopes Publish Through One Publisher Job
The system SHALL publish pending exposure snapshot scopes through one singleton publisher job draining a scopes table, with no per-scope Oban jobs and no `{:snooze, _}` on the singleton publisher path.
A scope needing publication is a row in `platform.exposure_snapshot_scopes`, never an Oban job.
The publisher claims due rows oldest-first, publishes each scope's fenced generation through the existing per-scope engine, finalizes a drained generation inline in its own pass instead of waiting for the maintenance tick, marks the row complete only after its generation completes, and exits returning `:ok` when no claimable row remains. A warehouse scan failure during the inline step waits with the remaining budget and never fails the scope; the maintenance tick still converges it.
Demand paths (reconciliation, finalizer, maintenance worker, prepare completion) insert or re-pend the scope row and ensure the singleton job; a unique-insert ensure while one is available or scheduled is a no-op, an executing job never blocks the next ensure, and a run that finds the session lock held exits quietly.
The engine keeps its direct-drive `perform/1` with the original synchronous-publish-or-snooze contract for direct calls (repair tooling and boundary tests, which pass no job id); nothing enqueues it. A legacy `ExposureSnapshotWorker` row executed from the queue (integer job id) never publishes and never snoozes: it completes immediately when its scope row exists, adopts the scope row when absent, and cancels when it names an invalid scope; a row without `device_ord` names the fleet-wide scope and adopts it.
Completing a scope clears its stale `error` value.

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

#### Scenario: Drained generation completes inline without the tick
- **GIVEN** a scope row `publishing` with its generation drained (`finalizing`, receipts complete, nothing pending)
- **WHEN** the publisher pass runs
- **THEN** the scope is marked `complete` in the same pass with no new generation
- **AND** no maintenance tick runs in between.

#### Scenario: Scan failure waits instead of failing
- **GIVEN** a scope row `publishing` with its generation drained but the warehouse scan failing
- **WHEN** the publisher pass runs
- **THEN** the scope stays `publishing` with no failure recorded
- **AND** a later pass or the maintenance tick completes it once the scan succeeds.

### Requirement: Scopes Publish At Least Once Across Crashes
The system SHALL republish any scope whose generation did not observably complete before the publisher died, with a fresh generation fence.
A `publishing` row whose lease expired is adopted by the next run: a completed generation marks the scope complete with no republish; a still-`publishing` generation is aborted through the session-lock reader-lost proof and the scope republishes; an already `aborted` generation republishes the scope the same way; a `published` or `finalizing` generation is settled inline by the adopting run (finalizer step with the same wait mapping as a normal pass) instead of waiting for the maintenance tick.
Duplicate delivery across the crash is absorbed by envelope-hash idempotency.

#### Scenario: Crash mid-drain resumes without loss or double work
- **GIVEN** scopes A (generation complete), B (generation publishing), C (pending), and D (generation published) when the publisher process dies
- **WHEN** the next publisher run drains the table
- **THEN** A is marked complete with no new generation
- **AND** B's orphaned generation is aborted and B republishes once
- **AND** C publishes
- **AND** D's generation is untouched and D completes without republish once it finishes.

### Requirement: In-Flight Publisher Demand Migrates To Scope Rows
The system SHALL migrate queued `ExposureSnapshotWorker` Oban rows into scope rows exactly once at deploy time, and any legacy row executed from the queue after that adopts into the scopes table instead of publishing.
The migration inserts one `pending` row per distinct scope (`args->>'device_ord'`, NULL when absent) from queued publisher Oban rows (`available`, `scheduled`, `retryable`), then deletes those Oban rows. `executing` rows are left for Oban lifeline, which runs them through the retained direct-drive `perform/1`, so no demand is lost. Rows inserted after the migration by old pods during the roll, and any other queued legacy row, terminate on execution: the row completes immediately when its scope row exists, inserts the scope row `pending` when absent (never touching existing rows), and cancels when it names an invalid scope; a row without `device_ord` names the fleet-wide scope and adopts it. No legacy execution publishes or snoozes, so no old publisher job survives an upgrade.

#### Scenario: Queued scopes survive the upgrade
- **GIVEN** queued publisher Oban rows for device ordinals 5 and 12 and one fleet-wide row
- **WHEN** the migration runs
- **THEN** three pending scope rows exist for ordinals 5, 12, and NULL
- **AND** no queued `ExposureSnapshotWorker` Oban row remains.

#### Scenario: Roll-time legacy row terminates on execution
- **GIVEN** a scheduled legacy `ExposureSnapshotWorker` row for a scope that has a scope row, inserted after the migration ran
- **WHEN** Oban executes it
- **THEN** the row completes without publishing and without touching the scope row.

#### Scenario: Legacy row for unknown scope adopts it
- **GIVEN** a scheduled legacy `ExposureSnapshotWorker` row for a scope with no scope row
- **WHEN** Oban executes it
- **THEN** a `pending` scope row exists for that scope and the row completes.

#### Scenario: Legacy fleet-wide row adopts the fleet-wide scope
- **GIVEN** a scheduled legacy `ExposureSnapshotWorker` row without `device_ord` and no fleet-wide scope row
- **WHEN** Oban executes it
- **THEN** a `pending` scope row exists with NULL `scope_ord` and the row completes.

#### Scenario: Legacy row naming an invalid scope cancels
- **GIVEN** a scheduled legacy `ExposureSnapshotWorker` row whose `device_ord` is not a positive integer
- **WHEN** Oban executes it
- **THEN** the row cancels without creating a scope row.
