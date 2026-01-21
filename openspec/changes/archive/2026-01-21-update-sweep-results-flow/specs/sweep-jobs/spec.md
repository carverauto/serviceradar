## MODIFIED Requirements
### Requirement: Sweep Job Execution Tracking

The system SHALL track sweep job execution status and history with accurate host totals and availability counts derived from sweep results.

#### Scenario: Agent reports sweep completion
- **GIVEN** an agent completing a sweep job
- **WHEN** the sweep finishes
- **THEN** core SHALL record total hosts scanned, hosts available, and hosts failed for the execution
- **AND** the completion time and duration SHALL be recorded
- **AND** the values SHALL reflect cumulative results for the execution (not per-batch deltas)

#### Scenario: Active scan progress updates
- **GIVEN** an in-progress sweep execution
- **WHEN** progress batches are ingested
- **THEN** core SHALL update the execution with cumulative progress metrics
- **AND** the Active Scans UI SHALL display the current totals and completion percentage
