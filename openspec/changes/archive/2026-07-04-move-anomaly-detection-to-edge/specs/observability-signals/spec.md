## ADDED Requirements

### Requirement: Edge anomaly execution
Per-series short-term spike anomaly detection SHALL run at the edge
(co-located with the agent) for agents assigned the native anomaly add-on. Core
SHALL consume and persist edge verdicts through the existing signal path, but it
SHALL NOT run the retired raw-stream per-series anomaly analyzer as a fallback.

#### Scenario: Edge-covered series emits upstream verdicts
- **GIVEN** a metric source is covered by an edge anomaly add-on
- **WHEN** its samples are analyzed at the edge and verdicts are emitted upstream
- **THEN** core SHALL route the verdicts onto the causal signal path
- **AND** core SHALL persist and alert on those verdicts without re-running raw-stream detection

#### Scenario: Disabling the edge add-on stops spike verdicts
- **GIVEN** a series currently covered by an edge anomaly add-on
- **WHEN** the add-on is disabled or removed
- **THEN** the agent SHALL stop sending that series to the add-on
- **AND** raw metrics SHALL continue flowing to JetStream and CNPG for storage, graphs, capacity forecasts, and future aggregate detectors

### Requirement: Edge anomaly coverage is observable
Anomaly verdicts SHALL carry their execution source and the system SHALL expose
add-on assignment/status plus shed-pressure events so operators can see edge
coverage and detect gaps before they affect alerting.

#### Scenario: Operator inspects anomaly coverage
- **WHEN** an operator inspects anomaly coverage telemetry
- **THEN** add-on assignment and status SHALL show which agents are covered
- **AND** each edge spike verdict SHALL be attributable with `verdict_source=edge-spike`
- **AND** add-on capacity shed SHALL be reported as an operational event rather than an anomaly verdict
