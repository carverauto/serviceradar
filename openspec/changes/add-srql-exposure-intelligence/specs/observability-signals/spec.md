## ADDED Requirements

### Requirement: Connection discrepancy findings are incident-grouped
The system SHALL convert each alert-eligible connection discrepancy signal into an OCSF Detection Finding, published through JetStream and written by EventWriter. The stateful alert engine SHALL group these findings into incidents by a stable fingerprint: `(kind, device_uid)` for `network_only`, and `(kind, device_uid or coverage rule, exporter)` for `host_only`.

**Severity.** `network_only` incidents SHALL default to high severity and `host_only` incidents to low severity.

**Repeat signals.** A repeated signal for an active incident SHALL update its occurrence count, last-seen time and maximum confidence, and SHALL NOT create a new alert.

**Below threshold.** Signals below their kind's incident threshold (default 0.85 for `network_only`, 0.75 for `host_only`) SHALL NOT create or update incidents.

#### Scenario: Repeated evasion signals collapse into one incident
- **GIVEN** three `network_only` signals for the same device within the incident's active window
- **WHEN** they are evaluated by the alert engine
- **THEN** one active incident exists for that device, with occurrence count 3 and the highest confidence of the three

#### Scenario: Below-threshold signal does not alert
- **GIVEN** a `network_only` signal with confidence 0.81 and an incident threshold of 0.85
- **WHEN** it is processed
- **THEN** it is queryable in `in:connection_discrepancies`, and no incident is created

#### Scenario: Coverage gaps are low severity and grouped by exporter
- **GIVEN** alert-eligible `host_only` signals from ten devices under one coverage rule and one exporter
- **WHEN** they are processed
- **THEN** one low-severity incident exists for that rule and exporter

