## ADDED Requirements

### Requirement: Sweep Ingestion Enqueues No Composite-Check Work

Sweep result ingestion SHALL NOT enqueue a composite-check job or write a
composite-check marker.

Ingestion SHALL stamp `device_agent_availability.updated_at` with `now()`
inside the INSERT statement. `now()` is `transaction_timestamp()`, fixed when
the inserting transaction begins. Composite checks store, in one statement
before the dirty read, the mark
`least(now(), coalesce((SELECT min(xact_start) FROM pg_stat_activity WHERE datname = current_database() AND backend_type = 'client backend' AND state <> 'idle' AND xact_start IS NOT NULL), now()))`
and select rows later than that mark minus a 30-second margin for
`pg_stat_activity` statistics lag. A writer whose transaction opened before
that mark and committed after the read is inside the next pass's dirty set.

#### Scenario: Ingesting a chunk enqueues nothing

- **GIVEN** a sweep result chunk of N hosts that all resolve to known devices
- **WHEN** the chunk is ingested
- **THEN** the number of Oban jobs SHALL be unchanged
- **AND** the per-agent availability rows for those devices SHALL carry an
  `updated_at` assigned by `now()` inside the INSERT, later than before
  ingestion
