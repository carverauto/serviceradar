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
`last_incremental_at` is nil. A successful full pass SHALL advance both
`last_evaluated_at` and `last_incremental_at` to the database clock taken at
the start of that pass (`SELECT now()` before the read), including when the
scope selected no devices. An incremental pass SHALL NOT advance
`last_evaluated_at`.

A minute tick SHALL insert at most one evaluation job per enabled check. That
job SHALL have one attempt and SHALL NOT insert another job. A failed job
SHALL leave the marks unchanged, and the next tick SHALL run the pass. Disable
and destroy SHALL cancel pending evaluation jobs and SHALL NOT schedule
another.

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
- **AND** a successful full pass SHALL advance `last_incremental_at` and
  `last_evaluated_at`, including when the scope selected no devices

#### Scenario: A failing pass does not schedule another job

- **GIVEN** an enabled check whose evaluation job fails or raises
- **WHEN** that job ends
- **THEN** it SHALL NOT insert another evaluation job
- **AND** neither `last_evaluated_at` nor `last_incremental_at` SHALL advance
- **AND** the next minute tick SHALL run the pass again

#### Scenario: A check save does not fork the schedule

- **GIVEN** an enabled check with an incomplete evaluation job inserted within
  the last 55 seconds
- **WHEN** the check is saved
- **THEN** exactly one incomplete evaluation job SHALL exist for that check

### Requirement: Event-Driven Refresh

The system SHALL re-evaluate, once a minute, only the in-scope devices whose
input timestamps are later than `last_incremental_at` minus
`@watermark_slack`, selecting that dirty set in pages of at most 200 uids and
evaluating it through the same paged evaluation the periodic pass uses.

`last_incremental_at` SHALL gate only the dirty read. The mark SHALL be the
database clock (`SELECT now()`) taken at the start of the pass, before the
dirty read. A successful incremental pass SHALL advance `last_incremental_at`
to that mark, including when it selected nothing. A failed pass SHALL NOT
advance it.

The dirty set SHALL include a device when a `device_agent_availability` row
for one of the check's vantage-point agents has `updated_at` later than
`last_incremental_at - @watermark_slack`, or when a configured
`:device_metadata` path has `metadata['__fact_provenance'][path]['updated_at']`
later than that same lagged mark. `@watermark_slack` SHALL be a module
attribute, default two minutes, and SHALL exceed the longest availability
upsert transaction. The predicate SHALL NOT read `ocsf_devices.modified_time`.
Sweep status writes and `Device.set_availability` SHALL NOT dirty a device. A
metadata key with no provenance timestamp SHALL be covered by the full pass
only.

The availability arm SHALL use the `(agent_id, updated_at)` index. Ingestion
SHALL stamp `device_agent_availability.updated_at` with `now()` inside the
INSERT. `now()` is `transaction_timestamp()`, fixed when the inserting
transaction begins. An insert that began before the pass's `SELECT now()` can
commit after the dirty read with a timestamp before the stored mark. The
lagged window, not that stamp, SHALL make the next pass select that row.
Re-evaluating a device in the overlap
SHALL be idempotent: the same inputs SHALL yield the same verdict, and
`changed_at` SHALL NOT move when the verdict is unchanged.

Before writing a page, the pass SHALL load that page's devices with
`deleted_at` nil and SHALL skip any uid missing from that load. A skipped uid
SHALL get no result row and no verdict transition. The scope filter for a
dirty page SHALL be an SRQL `uid:(...)` list of at most 200 uids.

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

#### Scenario: A commit during the read is selected next pass

- **GIVEN** an incremental pass that stored its start clock as
  `last_incremental_at`
- **WHEN** an availability row commits after that pass's dirty read with
  `updated_at` just before the stored mark
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
