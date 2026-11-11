# Spec Deltas: fix-sweep-lease-reissue-stall — job-scheduling

## ADDED Requirements

### Requirement: Sub-hourly cron workers use unbounded pending-state uniqueness

Every cron worker scheduled more often than hourly MUST declare uniqueness
over pending states with no period (`period: :infinity`,
`states: [:available, :scheduled]`) so a slow or orphaned run can neither
admit a duplicate tick nor block later ticks on an `executing` row.

#### Scenario: Slow lease pass admits no duplicate tick

- **GIVEN** a `LeasePassWorker` run still executing past the next `*/5` tick
- **WHEN** the scheduler fires the next tick
- **THEN** no second `LeasePassWorker` row SHALL be enqueued while a pending
  tick exists.

#### Scenario: Orphan executing row blocks no tick

- **GIVEN** a `LeasePassWorker` row left `executing` by a dead pod
- **WHEN** the scheduler fires later ticks
- **THEN** new ticks SHALL still enqueue because uniqueness covers only
  pending states.

### Requirement: LeasePassWorker proves its own orphans

`LeasePassWorker` MUST implement the `OrphanRescue` behaviour so the stale-job
reaper rescues provable orphans without waiting for the age threshold. The
proof MUST hold a session advisory lock on a dedicated connection for the
whole run and MUST never report a live run (including a netsplit-partitioned
one) as orphaned. The age-based sweep SHALL remain the fallback.

#### Scenario: Dead pod's lease pass row is rescued promptly

- **GIVEN** a `LeasePassWorker` row `executing` whose node is gone and whose
  advisory lock is free
- **WHEN** the reaper pass runs `rescue_orphaned/1`
- **THEN** the row SHALL return to `available` before the age threshold
  elapses.

### Requirement: Long maintenance workers have a bounded execution timeout

A worker that can hold a whole maintenance queue slot for minutes MUST declare
an execution timeout comfortably above its measured post-fix run time, so no
run parks a slot indefinitely. A timed-out run MUST end in a terminal row and
MUST leave no `executing` row for the age rescue; locks release on death and
the next scheduled tick picks the work up.

#### Scenario: Timed-out lease pass leaves no orphan

- **GIVEN** a `LeasePassWorker` run exceeding its timeout
- **WHEN** Oban ends the run
- **THEN** the row SHALL NOT remain `executing`
- **AND** partial delivery state SHALL resume cleanly on the next tick
  (evidence replay idempotency, unacknowledged pushes replaced).

#### Scenario: Live run is never rescued

- **GIVEN** a `LeasePassWorker` row `executing` whose process holds the
  advisory lock
- **WHEN** the reaper pass runs `rescue_orphaned/1`
- **THEN** the row SHALL be left alone.
