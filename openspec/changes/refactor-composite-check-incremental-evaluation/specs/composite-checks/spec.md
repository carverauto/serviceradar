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
`composite_checks.last_evaluated_at`, and when `last_evaluated_at` is nil. A
successful full pass SHALL advance `last_evaluated_at`. An incremental pass
SHALL NOT advance `last_evaluated_at`.

A successful full pass that evaluated at least one device SHALL also advance
`last_incremental_at` to the database clock taken at the start of that pass
(`SELECT now()` before the read), so the following incremental pass does not
re-evaluate devices the full pass covered. A full pass that selected no
devices SHALL NOT advance a nil `last_incremental_at`.

The shared page evaluation SHALL follow each uid to its canonical device
before writing, and SHALL NOT write a result for a merged-away uid.

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

### Requirement: Event-Driven Refresh

The system SHALL re-evaluate, on a short fixed interval, only the in-scope
devices whose input rows changed since `last_incremental_at`, selecting that
dirty set with a bounded number of queries and evaluating it through the same
paged evaluation the periodic pass uses.

`last_incremental_at` SHALL gate only the dirty read. The mark SHALL be the
database clock (`SELECT now()`) taken at the start of the pass, before the
dirty read. A successful incremental pass whose mark is already set, or that
selected at least one device, SHALL advance it to that mark. A pass that
fails SHALL NOT advance it. A pass that selected nothing SHALL NOT advance a
nil mark.

The dirty set SHALL include a device when a `device_agent_availability` row
for one of the check's vantage-point agents has `updated_at` later than the
mark, or when a configured `:device_metadata` path has
`metadata['__fact_provenance'][path]['updated_at']` later than the mark. The
predicate SHALL NOT read `ocsf_devices.modified_time`. Sweep status writes and
`Device.set_availability` SHALL NOT dirty a device. A metadata key with no
provenance timestamp SHALL be covered by the full pass only.

The availability arm SHALL use the `(agent_id, updated_at)` index. Ingestion
SHALL stamp `device_agent_availability.updated_at` with `now()` inside the
INSERT, so a row committed after a pass's read cannot carry a timestamp before
that pass's mark.

Before writing a page, the pass SHALL batch
`Resolver.follow_canonical_device_id` for that page in one query, SHALL skip a
uid that does not resolve to a live device, and SHALL NOT write a result for
a merged-away uid.

No producer of an input signal SHALL enqueue a composite-check job or write a
composite-check marker.

#### Scenario: Sweep result triggers refresh

- **GIVEN** an enabled check with a vantage point on `agent-a`
- **WHEN** a new sweep result for `agent-a` and a device in scope is ingested
- **THEN** that device SHALL be re-evaluated by the next incremental pass
- **AND** the result row SHALL reflect the new observation
- **AND** devices in scope whose input rows did not change SHALL NOT be
  evaluated by that pass

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

#### Scenario: Empty pass leaves a nil mark

- **GIVEN** a check whose `last_incremental_at` is nil
- **WHEN** a pass selects no devices
- **THEN** `last_incremental_at` SHALL remain nil

#### Scenario: Merge between the dirty read and the write

- **GIVEN** an in-scope device the dirty read selected
- **WHEN** that device is merged away before the pass writes its result
- **THEN** the pass SHALL NOT write a result row for the merged-away uid
- **AND** the pass SHALL skip the uid when the canonical follow does not
  resolve to a live device

#### Scenario: Repeated changes collapse into one evaluation

- **WHEN** several input changes for the same device arrive inside one
  incremental interval
- **THEN** the device SHALL be evaluated once, by the next pass, against the
  newest rows

#### Scenario: Failed pass retries the same dirty set

- **GIVEN** an incremental pass that fails after selecting its dirty set
- **WHEN** the next incremental pass runs
- **THEN** it SHALL select at least the same devices again
