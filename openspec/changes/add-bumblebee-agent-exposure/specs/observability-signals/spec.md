## ADDED Requirements
### Requirement: Bumblebee Exposure Findings
The system SHALL normalize Bumblebee exposure findings into observability state with agent/device provenance, catalog snapshot identity, scanner version, package identity, confidence, severity, and bounded evidence.

#### Scenario: Finding becomes an observability event
- **GIVEN** an agent reports a Bumblebee finding from a completed scan
- **WHEN** the control plane ingests the report
- **THEN** the system SHALL create or update a normalized observability event for that finding
- **AND** the event SHALL preserve agent ID, device identity when known, run ID, finding ID, catalog ID, catalog snapshot ID, and scanner version
- **AND** the event SHALL link to the current device Bumblebee posture when a canonical device UID is available

#### Scenario: Duplicate findings update current state
- **GIVEN** a Bumblebee finding with the same replay-safe identity was already ingested for an agent
- **WHEN** the same finding is reported again from a later completed scan
- **THEN** the system SHALL update last-seen and occurrence metadata
- **AND** it SHALL NOT create duplicate active exposure findings for the same current state

#### Scenario: Completed scan clears stale findings
- **GIVEN** an agent previously had active Bumblebee findings for a catalog snapshot
- **WHEN** a later scan for the same or newer snapshot completes successfully without those findings
- **THEN** the system SHALL mark the stale findings inactive or resolved
- **AND** retain historical provenance for audit and trend analysis

### Requirement: Bumblebee Risk Posture
The system SHALL derive an agent/device Bumblebee risk posture from active findings, contribute that posture to composite device risk, and expose the posture to authorized operators.

#### Scenario: Risk score reflects active findings
- **GIVEN** an agent has active Bumblebee findings with severities from the exposure catalog
- **WHEN** the risk posture is computed
- **THEN** the posture SHALL include a numeric source contribution score, highest severity, active finding count, last successful scan time, and active catalog snapshot ID

#### Scenario: No completed scan is distinguishable from no findings
- **GIVEN** an agent has never completed a Bumblebee scan
- **WHEN** its Bumblebee posture is requested
- **THEN** the system SHALL report scanner state as not yet scanned
- **AND** SHALL NOT present that state as zero risk
