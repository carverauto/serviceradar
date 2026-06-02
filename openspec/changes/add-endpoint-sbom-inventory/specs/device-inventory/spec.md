## ADDED Requirements

### Requirement: Device Inventory Exposes Endpoint Software State
Device inventory SHALL expose the latest successful endpoint software inventory state for managed devices that report package/SBOM data.

#### Scenario: Device has current endpoint inventory
- **GIVEN** a managed device has a latest successful endpoint inventory scan
- **WHEN** an operator or API client requests the device inventory detail
- **THEN** the response SHALL include endpoint inventory status, scan timestamp, last changed scan timestamp, collector version, package counts, package-set hash, unchanged scan metadata, and artifact metadata
- **AND** package/component rows SHALL be queryable by package name, version, package manager, PURL, and CPE where available

#### Scenario: Device has no endpoint inventory
- **GIVEN** a device has never reported endpoint inventory
- **WHEN** an operator or API client requests the device inventory detail
- **THEN** the response SHALL explicitly indicate endpoint inventory is unavailable
- **AND** it SHALL NOT synthesize package state from process, flow, or fixture data

#### Scenario: Device identity changes after inventory ingest
- **GIVEN** an endpoint inventory scan was ingested before device identity reconciliation resolved a canonical UID
- **WHEN** the agent/device identity is later reconciled
- **THEN** endpoint inventory rows SHALL remain linked to the reporting agent
- **AND** the latest device inventory view SHALL resolve those rows to the canonical device UID when possible

### Requirement: Device Inventory Supports Live Endpoint Software Questions
Device inventory SHALL provide an operator-facing path to ask live endpoint software questions through agent-gateway without requiring full inventory upload from every target.

#### Scenario: Device-scoped live query
- **GIVEN** a managed device has a connected agent with endpoint inventory capability
- **WHEN** an operator asks whether that device has a package, PURL, CPE, or version constraint
- **THEN** the system SHALL dispatch an on-demand endpoint inventory command to that agent
- **AND** it SHALL display compact live results with freshness and package-set hash

#### Scenario: Cohort live query
- **GIVEN** an operator targets a cohort of managed devices for an endpoint software query
- **WHEN** the system dispatches the query
- **THEN** it SHALL route commands only to eligible connected agents
- **AND** it SHALL distinguish live matches, live non-matches, offline agents, expired commands, and latest persisted state

#### Scenario: Full upload requested after live match
- **GIVEN** an on-demand query identifies a matching package on an agent
- **WHEN** an authorized operator requests full artifact upload for that agent
- **THEN** the system SHALL trigger a bounded upload or fresh scan according to endpoint inventory policy
- **AND** the uploaded artifact SHALL become queryable only after normal ingestion validation succeeds
