## ADDED Requirements

### Requirement: Sweep Ingestion Enqueues No Composite-Check Work

Sweep result ingestion SHALL NOT enqueue a composite-check job or write a
composite-check marker.

Ingestion SHALL stamp `device_agent_availability.updated_at` with `now()`
inside the INSERT statement. Composite checks discover changed availability
rows from that timestamp.

#### Scenario: Ingesting a chunk enqueues nothing

- **GIVEN** a sweep result chunk of N hosts that all resolve to known devices
- **WHEN** the chunk is ingested
- **THEN** the number of Oban jobs SHALL be unchanged
- **AND** the per-agent availability rows for those devices SHALL carry an
  `updated_at` assigned by `now()` inside the INSERT, later than before
  ingestion
