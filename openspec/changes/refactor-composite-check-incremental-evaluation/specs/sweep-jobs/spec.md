## ADDED Requirements

### Requirement: Sweep Ingestion Enqueues No Composite-Check Work

Sweep result ingestion SHALL NOT enqueue a composite-check job or write a
composite-check marker.

Ingestion SHALL stamp `device_agent_availability.updated_at` with `now()`
inside the INSERT statement. That INSERT SHALL be one autocommit statement.
`now()` is `transaction_timestamp()`, fixed when the inserting transaction
begins. Composite checks take the mark as `now()` before the dirty read and
select rows later than that mark minus a fixed two-minute slack. A writer
whose transaction opened within that slack before the mark and committed after
the read is inside the next pass's dirty set. A writer longer than the slack
is outside this contract and is covered by the full pass.

#### Scenario: Ingesting a chunk enqueues nothing

- **GIVEN** a sweep result chunk of N hosts that all resolve to known devices
- **WHEN** the chunk is ingested
- **THEN** the number of Oban jobs SHALL be unchanged
- **AND** the per-agent availability rows for those devices SHALL carry an
  `updated_at` assigned by `now()` inside the INSERT, later than before
  ingestion
