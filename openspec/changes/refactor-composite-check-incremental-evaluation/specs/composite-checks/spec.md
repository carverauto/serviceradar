## MODIFIED Requirements

### Requirement: Periodic Evaluation

The system SHALL evaluate each enabled composite check on its configured
interval by resolving the scope query, processing devices in bounded pages,
resolving inputs per page with bounded queries, and writing each page's
results with a bounded number of statements that does not grow with the
number of devices in the page.

The periodic pass SHALL be required in addition to the incremental pass,
because input staleness and scope membership changes produce no row change.

A full pass SHALL advance the check's evaluation high-water mark so that the
following incremental pass does not re-evaluate devices the full pass covered.

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

### Requirement: Event-Driven Refresh

The system SHALL re-evaluate, on a short fixed interval, only the in-scope
devices whose input rows changed since the check's evaluation high-water mark,
selecting that dirty set with a bounded number of indexed queries and
evaluating it through the same paged evaluation the periodic pass uses.

The dirty set SHALL be derived from the input rows' own update timestamps
(per-agent availability rows for the check's vantage-point agents, and device
rows for metadata inputs). No producer of an input signal SHALL enqueue work
or write a marker on behalf of composite checks.

A pass that fails SHALL NOT advance the high-water mark, so the same dirty set
is evaluated by the next pass.

#### Scenario: Sweep result triggers refresh

- **GIVEN** an enabled check with a vantage point on `agent-a`
- **WHEN** a new sweep result for `agent-a` and a device in scope is ingested
- **THEN** that device SHALL be re-evaluated by the next incremental pass
- **AND** the result row SHALL reflect the new observation
- **AND** devices in scope whose input rows did not change SHALL NOT be
  evaluated by that pass

#### Scenario: Ingestion does no composite-check work

- **WHEN** a sweep result chunk is ingested
- **THEN** ingestion SHALL enqueue no background job and write no row on behalf
  of composite checks

#### Scenario: Repeated changes collapse into one evaluation

- **WHEN** several input changes for the same device arrive inside one
  incremental interval
- **THEN** the device SHALL be evaluated once, by the next pass, against the
  newest rows

#### Scenario: Failed pass retries the same dirty set

- **GIVEN** an incremental pass that fails after selecting its dirty set
- **WHEN** the next incremental pass runs
- **THEN** it SHALL select at least the same devices again
