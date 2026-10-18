## ADDED Requirements

### Requirement: Connection discrepancy findings are incident-grouped
The system SHALL convert each alert-eligible connection discrepancy signal into an OCSF Detection Finding, published through JetStream and written by EventWriter. The stateful alert engine SHALL group these findings into incidents by a stable fingerprint: `(kind, device_uid)` for `network_only`, and `(kind, device_uid or coverage rule, exporter)` for `host_only`.

**Severity.** `network_only` incidents SHALL default to high severity and `host_only` incidents to low severity.

**Repeat signals.** A repeated signal for an active incident SHALL update its occurrence count, last-seen time and maximum confidence, and SHALL NOT create a new alert.

**Below threshold.** Signals below the incident threshold SHALL NOT create or update incidents.

#### Scenario: Repeated evasion signals collapse into one incident
- **GIVEN** three `network_only` signals for the same device within the incident's active window
- **WHEN** they are evaluated by the alert engine
- **THEN** one active incident exists for that device, with occurrence count 3 and the highest confidence of the three

#### Scenario: Below-threshold signal does not alert
- **GIVEN** a `network_only` signal with confidence 0.81 and an incident threshold of 0.85
- **WHEN** it is processed
- **THEN** it is queryable in `in:connection_discrepancies`, and no incident is created

#### Scenario: Coverage gaps are low severity and grouped by exporter
- **GIVEN** `host_only` signals from ten devices under one coverage rule and one exporter
- **WHEN** they are processed
- **THEN** one low-severity incident exists for that rule and exporter

### Requirement: Exposure conditions can drive stateful alert rules
The system SHALL let operators create stateful alert rules on exposure conditions, using the same rule builder, grouping, cooldown and re-notify controls as other rules. At least two seeded templates SHALL be provided, disabled by default:
- a new actionable KEV exposure on a device;
- a critical exposure whose listening process received inbound internet connections.

Exposure alerts SHALL be evaluated from exposure transitions and evidence. They SHALL NOT poll the full exposure table.

#### Scenario: New KEV exposure alerts once per device and CVE
- **GIVEN** the KEV exposure template is enabled
- **WHEN** a transition makes a device newly exposed to a KEV-listed CVE
- **THEN** one alert is created for that device and CVE
- **AND** a repeated transition for the same fact within the cooldown does not create a second alert

#### Scenario: Seeded templates are inert until enabled
- **GIVEN** a fresh installation
- **WHEN** exposure transitions arrive
- **THEN** no exposure alerts are created until an operator enables a template
