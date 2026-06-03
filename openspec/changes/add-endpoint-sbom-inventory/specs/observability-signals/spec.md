## ADDED Requirements

### Requirement: Endpoint Inventory Signals Produce OCSF Events And Alerts
Endpoint inventory change events and vulnerability findings SHALL enter the existing observability signal pipeline as first-class inventory signals.

#### Scenario: Package change event is duplicate-safe
- **GIVEN** ingestion computes a package added, removed, or version-changed event
- **WHEN** the event is emitted to the observability signal pipeline
- **THEN** it SHALL carry a deterministic event ID
- **AND** redelivery SHALL NOT create duplicate `ocsf_events` rows

#### Scenario: Vulnerability finding has canonical device identity
- **GIVEN** an endpoint package matches an advisory coordinate and has a canonical device UID
- **WHEN** a vulnerability finding is emitted
- **THEN** it SHALL be recorded as an OCSF Vulnerability Finding with `class_uid=2004`
- **AND** the event device object SHALL include the canonical device UID directly

#### Scenario: Finding suppressed before reconciliation
- **GIVEN** an endpoint inventory scan has no canonical device UID yet
- **WHEN** a vulnerability match is found
- **THEN** the finding SHALL be suppressed rather than emitted with an empty device object
- **AND** it SHALL become eligible once device identity reconciliation backfills the UID

### Requirement: Endpoint Vulnerability Findings Drive Stateful Alerts
Endpoint vulnerability findings SHALL be eligible for stateful alert evaluation and northbound automation through the standard OCSF event record path.

#### Scenario: Inventory finding evaluated by alert engine
- **GIVEN** a seeded endpoint inventory vulnerability alert rule grouped by device
- **WHEN** an inventory vulnerability finding is recorded
- **THEN** the observability signal path SHALL explicitly invoke stateful alert evaluation
- **AND** evaluation SHALL be async or bounded so fleet-patch volume cannot block the signal ingestor

#### Scenario: Device grouping uses event device uid
- **GIVEN** an endpoint vulnerability finding contains `device.uid`
- **WHEN** a stateful alert rule groups by device
- **THEN** the grouping key SHALL be derived from `device.uid`
- **AND** it SHALL NOT silently fall back to a global group

#### Scenario: Northbound handlers receive finding
- **GIVEN** endpoint vulnerability findings are written through the OCSF event record path
- **WHEN** matching event handler rules exist
- **THEN** ticket, quarantine, webhook, or other northbound handlers SHALL be eligible to run
