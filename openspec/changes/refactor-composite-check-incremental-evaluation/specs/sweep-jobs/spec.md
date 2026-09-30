## ADDED Requirements

### Requirement: Sweep Ingestion Has No Per-Device Side Effects For Derived State

Sweep result ingestion SHALL NOT enqueue background jobs, publish per-device
notifications, or write marker rows on behalf of subsystems that derive state
from availability rows.

Subsystems that derive state from per-agent availability (composite checks
today) SHALL discover changed rows from the rows' own update timestamps.

#### Scenario: Ingesting a chunk enqueues nothing

- **GIVEN** a sweep result chunk of N hosts that all resolve to known devices
- **WHEN** the chunk is ingested
- **THEN** the number of Oban jobs SHALL be unchanged
- **AND** the per-agent availability rows for those devices SHALL carry an
  `updated_at` later than before ingestion
