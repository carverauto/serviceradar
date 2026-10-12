## MODIFIED Requirements

### Requirement: Periodic Evaluation

The system SHALL evaluate each enabled composite check on its configured
interval by resolving the scope query, processing devices in bounded pages,
resolving inputs per page with bounded queries, and writing each page's
results with a bounded number of statements that does not grow with the
number of devices in the page.

The periodic pass SHALL be required in addition to the incremental pass,
because input staleness, scope membership changes, and metadata keys with no
provenance timestamp produce no incremental dirty row.

The full pass SHALL run when `evaluation_interval_seconds` has elapsed since
`composite_checks.last_evaluated_at`, when `last_evaluated_at` is nil, or when
`last_incremental_at` is nil. A successful full pass SHALL advance
`last_incremental_at` to `now()` taken before the read and SHALL advance
`last_evaluated_at` to `now()` taken at successful completion, including when
the scope selected no devices. A full pass whose wall time exceeds
`evaluation_interval_seconds` SHALL NOT be due again on the next tick. An
incremental pass SHALL NOT advance `last_evaluated_at`.

A minute tick and an enable SHALL each insert an evaluation job with
`unique: [keys: [:check_id], states: [:available, :scheduled, :executing], period: :infinity]`.
At most one evaluation job in those states SHALL exist per check. A tick that
lands while a job for that check is available, scheduled, or executing SHALL
insert nothing. The next tick after that job completes SHALL insert exactly
one. The job SHALL have one attempt and SHALL NOT insert another job. A
failed job SHALL leave the marks unchanged, and the next tick after it
completes SHALL run the pass. Disable and destroy SHALL cancel pending
evaluation jobs and SHALL NOT schedule another.

The page write SHALL include only devices that are live at write time
(`deleted_at` nil on the page's device load). A uid missing from that load
SHALL get no result row and no verdict transition.

#### Scenario: Scheduled pass evaluates the scope

- **GIVEN** an enabled check with a five minute interval
- **WHEN** the interval elapses
- **THEN** every device in scope SHALL be evaluated
- **AND** each page of results SHALL be written with one multi-row upsert
- **AND** canonical availability, when the check writes it, SHALL be written
  with a set-based update per page rather than one update per device

#### Scenario: Staleness transition is detected without an event

- **GIVEN** a device whose verdict is `isolated_verified` and whose metadata fact
  ages past its max age with no further writes
- **WHEN** the next periodic pass runs
- **THEN** the verdict SHALL become the catch-all verdict
- **AND** `changed_at` SHALL advance

#### Scenario: Scope membership change is picked up

- **GIVEN** a device that newly matches a check's scope query after an inventory
  sync
- **WHEN** the next periodic pass runs
- **THEN** the device SHALL be evaluated and SHALL gain a result row

#### Scenario: Full pass stays due across incremental ticks

- **GIVEN** an enabled check whose last successful full pass is older than
  `evaluation_interval_seconds`
- **AND** later incremental passes have advanced `last_incremental_at`
- **WHEN** the scheduler next runs
- **THEN** it SHALL run a full pass
- **AND** a successful full pass SHALL advance `last_evaluated_at`

#### Scenario: A check with no full pass is due

- **GIVEN** an enabled check whose `last_evaluated_at` is nil
- **WHEN** the scheduler runs
- **THEN** it SHALL run a full pass

#### Scenario: Nil incremental mark runs the full pass

- **GIVEN** an enabled check whose `last_incremental_at` is nil
- **WHEN** the scheduler runs
- **THEN** it SHALL run a full pass
- **AND** a successful full pass SHALL advance `last_incremental_at` to the
  pre-read `now()` and `last_evaluated_at` to `now()` at completion, including
  when the scope selected no devices

#### Scenario: A long full pass does not immediately repeat

- **GIVEN** an enabled check whose full pass runs longer than
  `evaluation_interval_seconds`
- **WHEN** that pass completes successfully
- **THEN** `last_evaluated_at` SHALL be `now()` taken at completion
- **AND** the next tick SHALL NOT run another full pass

#### Scenario: A failing pass does not schedule another job

- **GIVEN** an enabled check whose evaluation job fails or raises
- **WHEN** that job ends
- **THEN** it SHALL NOT insert another evaluation job
- **AND** neither `last_evaluated_at` nor `last_incremental_at` SHALL advance
- **AND** the next minute tick SHALL run the pass again

#### Scenario: A tick during an executing job inserts nothing

- **GIVEN** an enabled check whose evaluation job is executing
- **WHEN** the minute tick runs
- **THEN** it SHALL insert no evaluation job
- **AND** exactly one evaluation job SHALL exist for that check

#### Scenario: A tick after completion inserts one job

- **GIVEN** an enabled check whose previous evaluation job has completed
- **WHEN** the minute tick runs
- **THEN** it SHALL insert exactly one evaluation job for that check

#### Scenario: A check save does not fork the schedule

- **GIVEN** an enabled check with an evaluation job that is available,
  scheduled, or executing
- **WHEN** the check is saved
- **THEN** exactly one evaluation job in those states SHALL exist for that
  check

### Requirement: Event-Driven Refresh

The system SHALL re-evaluate, once a minute, only the in-scope devices whose
input timestamps are later than `last_incremental_at` minus
`@watermark_slack`, selecting that dirty set in pages of at most 200 uids and
evaluating it through the same paged evaluation the periodic pass uses.

`last_incremental_at` SHALL gate only the dirty read. The mark a pass stores
SHALL be the database `now()` taken before the dirty read. A successful
incremental pass SHALL advance `last_incremental_at` to that mark, including
when it selected nothing. A successful full pass SHALL advance
`last_incremental_at` to the same pre-read `now()`. A failed pass SHALL NOT
advance it.

The dirty set SHALL include a device when a `device_agent_availability` row
for one of the check's vantage-point agents has `updated_at` later than
`last_incremental_at - @watermark_slack`, or when a configured
`:device_metadata` path has `metadata['__fact_provenance'][path]['updated_at']`
later than that same lagged mark. `@watermark_slack` SHALL be a module
attribute, default two minutes. The predicate SHALL NOT read
`ocsf_devices.modified_time`. Sweep status writes and
`Device.set_availability` SHALL NOT dirty a device. A metadata key with no
provenance timestamp SHALL be covered by the full pass only.

The availability arm SHALL use the `(agent_id, updated_at)` index. Both
dirty-row writers SHALL be one short statement that stamps `updated_at` with
`now()` inside the statement: the ingestor's autocommit `Repo.insert_all` for
availability, and one Ash update for fact provenance. `now()` is
`transaction_timestamp()`, fixed when that statement's transaction begins. A
writer whose transaction opened within `@watermark_slack` before the mark and
committed after the read SHALL be selected by the next pass. A writer longer
than the slack is out of contract and SHALL be covered by the full pass.
Re-evaluating a device inside the overlap SHALL be idempotent: the same inputs
SHALL yield the same verdict, and `changed_at` SHALL NOT move when the verdict
is unchanged.

Before writing a page, the pass SHALL load that page's devices with
`deleted_at` nil and SHALL skip any uid missing from that load. A skipped uid
SHALL get no result row and no verdict transition. The scope filter for a
dirty page SHALL be an SRQL `uid:(...)` list of at most 200 uids, and that
scope request SHALL pass a limit of at least the page size. SRQL applies a
default limit of 100 when the request omits one.

No producer of an input signal SHALL enqueue a composite-check job or write a
composite-check marker.

#### Scenario: Sweep result triggers refresh

- **GIVEN** an enabled check with a vantage point on `agent-a`
- **WHEN** a new sweep result for `agent-a` and a device in scope is ingested
- **THEN** that device SHALL be re-evaluated by the next incremental pass
- **AND** the result row SHALL reflect the new observation
- **AND** devices in scope whose input timestamps are not later than the
  lagged mark SHALL NOT be evaluated by that pass

#### Scenario: Ingestion does no composite-check work

- **WHEN** a sweep result chunk is ingested
- **THEN** ingestion SHALL enqueue no composite-check job and SHALL write no
  composite-check marker

#### Scenario: Sweep status does not dirty a metadata check

- **GIVEN** an enabled check with a metadata input whose configured provenance
  timestamp is unchanged
- **WHEN** a sweep status write or `set_availability` updates that device
- **THEN** the next incremental pass SHALL NOT select that device for the
  metadata input

#### Scenario: A writer inside the slack commits after the read

- **GIVEN** an incremental pass that stored its pre-read `now()` as
  `last_incremental_at`
- **WHEN** a writer whose transaction opened within `@watermark_slack` before
  that mark commits after the pass's dirty read
- **AND** the row's `updated_at` was assigned by `now()` inside that writer's
  statement
- **THEN** the next incremental pass SHALL select that device
- **AND** `changed_at` SHALL NOT move when the verdict is unchanged

#### Scenario: Merge between the dirty read and the write

- **GIVEN** an in-scope device the dirty read selected
- **WHEN** that device is merged away before the pass writes its result
- **THEN** the pass SHALL NOT write a result row for that uid
- **AND** the pass SHALL emit no verdict transition for that uid

#### Scenario: Repeated changes collapse into one evaluation

- **WHEN** several input changes for the same device arrive inside one
  incremental interval
- **THEN** the device SHALL be evaluated once, by the next pass, against the
  newest rows

#### Scenario: Failed pass retries the same dirty set

- **GIVEN** an incremental pass that fails after selecting its dirty set
- **WHEN** the next incremental pass runs
- **THEN** it SHALL select at least the same devices again
