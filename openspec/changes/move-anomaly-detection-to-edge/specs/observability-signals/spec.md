## ADDED Requirements

### Requirement: Edge-or-central anomaly execution
Per-series metric anomaly detection SHALL be executable at either the edge
(co-located with the agent) or centrally, with exactly one authoritative location
per series at a time. The central engine SHALL remain the fallback for series not
covered by an edge add-on and during rollout, so coverage changes never leave a
series unanalyzed.

#### Scenario: Edge-covered series is not re-analyzed centrally
- **GIVEN** a metric source is covered by an edge anomaly add-on
- **WHEN** its samples are analyzed at the edge and verdicts are emitted upstream
- **THEN** the central anomaly engine SHALL NOT re-run detection for those series
- **AND** the central engine SHALL continue analyzing series not covered at the edge

#### Scenario: Disabling the edge add-on returns series to central analysis
- **GIVEN** a series currently covered by an edge anomaly add-on
- **WHEN** the add-on is disabled or removed
- **THEN** the central engine SHALL resume analyzing that series
- **AND** there SHALL be no required verdict gap across the handover

### Requirement: Anomaly verdict source is observable
Anomaly verdicts SHALL carry their execution source (edge or central), and the
system SHALL expose per-source counts of edge-covered versus centrally analyzed
series, so operators can see coverage and detect gaps before they affect alerting.

#### Scenario: Operator inspects anomaly coverage
- **WHEN** an operator inspects anomaly coverage telemetry
- **THEN** the system SHALL report, per metric source, how many series are analyzed at the edge versus centrally
- **AND** each verdict SHALL be attributable to an edge or central source
