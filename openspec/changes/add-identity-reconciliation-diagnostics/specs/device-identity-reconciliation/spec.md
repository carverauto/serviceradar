## MODIFIED Requirements

### Requirement: Scheduled Reconciliation Backfill
The system SHALL run a scheduled reconciliation job that merges existing duplicate devices sharing strong identifiers, logs summary statistics for each run, and persists a durable run record for each run.

#### Scenario: Scheduled reconciliation merges duplicates and logs results
- **GIVEN** two device IDs that share the same strong identifier within a partition
- **WHEN** the reconciliation job runs
- **THEN** the non-canonical device SHALL be merged into the canonical device
- **AND** the job SHALL emit logs summarizing the number of duplicates scanned and merges performed

#### Scenario: Run summary survives the run
- **WHEN** the reconciliation job completes
- **THEN** the job SHALL persist a run record containing the summary statistics
- **AND** the record SHALL remain queryable after the process that produced it has exited

## ADDED Requirements

### Requirement: Reconciliation Run Record
The system SHALL persist one durable record per scheduled reconciliation run. The record SHALL contain the run identifier, start and completion timestamps, duration, status, the count of duplicate identifier candidates, the duplicate, mergeable, and blocked component counts, the number of devices covered by blocked components, the size of the largest blocked component, the merges performed, the error count, the configured per-run merge cap, whether that cap was reached, the device membership of each blocked component, and the trigger that started the run.

#### Scenario: Completed run is recorded
- **WHEN** a reconciliation run completes without raising
- **THEN** a run record SHALL be written with status `completed`
- **AND** the record SHALL carry every summary counter the run computed

#### Scenario: Cap-reached is recorded, not inferred
- **GIVEN** a reconciliation run whose merges reach the configured per-run cap
- **WHEN** the run completes
- **THEN** the run record SHALL carry the configured cap
- **AND** the run record SHALL record that the cap was reached

#### Scenario: Largest blocked component is retained
- **GIVEN** a run classifies one or more ambiguous components as blocked
- **WHEN** the run completes
- **THEN** the run record SHALL carry the size of the largest blocked component
- **AND** the run record SHALL carry the device uids belonging to each blocked component

### Requirement: Failed Reconciliation Runs Are Recorded
The system SHALL persist a run record when a reconciliation run raises and is rescued. The record SHALL carry status `failed` and a summary of the error, together with whatever counters were established before the failure.

#### Scenario: Rescued run leaves evidence
- **GIVEN** a reconciliation run raises partway through
- **WHEN** the job rescues the exception
- **THEN** a run record SHALL be written with status `failed`
- **AND** the record SHALL include an error summary
- **AND** the absence of a run record SHALL NOT be the only signal that a run failed

### Requirement: Run Recording Never Fails Reconciliation
The system SHALL NOT allow a failure to write the reconciliation run record to fail, roll back, or abort the reconciliation run itself. A failed run-record write SHALL be logged and otherwise ignored.

#### Scenario: Audit write failure does not block merges
- **GIVEN** the reconciliation run record cannot be written
- **WHEN** a reconciliation run completes its merges
- **THEN** the merges SHALL remain committed
- **AND** the run SHALL return its normal result
- **AND** the write failure SHALL be logged

### Requirement: Reconciliation Run Retention
The system SHALL retain reconciliation run records for a configurable window, defaulting to 30 days, and SHALL prune older records as part of each run.

#### Scenario: Old run records are pruned
- **GIVEN** run records exist that are older than the configured retention window
- **WHEN** a subsequent reconciliation run completes
- **THEN** the records older than the window SHALL be deleted
- **AND** records inside the window SHALL be retained

### Requirement: Identity Reconciliation Diagnostics Are Available Without Database Access
The system SHALL make identity reconciliation diagnostics reachable through SRQL and MCP under normal RBAC, without requiring direct database credentials. This SHALL cover live and tombstoned devices, merge audit records, revival audit records, identifier ownership and its currency against present device facts, canonical merge chains, reconciliation run summaries, and the evidence edges of a component.

#### Scenario: Reconcile an inventory list without psql
- **GIVEN** an operator holding `devices.view` and an external inventory list
- **WHEN** the operator uses only SRQL or MCP
- **THEN** the operator SHALL be able to classify each entry as active, tombstoned, or absent from inventory
- **AND** the operator SHALL NOT require direct database credentials

#### Scenario: Explain an inventory count drop
- **GIVEN** devices disappeared from inventory following a reconciliation run
- **WHEN** an operator investigates through SRQL or MCP
- **THEN** the operator SHALL be able to trace each tombstoned device to its current survivor
- **AND** the operator SHALL be able to see the merge reason, source, timestamp, and supporting evidence
- **AND** the operator SHALL be able to see whether the run stopped at its configured work cap
