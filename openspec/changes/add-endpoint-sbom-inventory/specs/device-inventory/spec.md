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
- **WHEN** an authorized operator requests full artifact upload or a fresh scan for that agent
- **THEN** if the request triggers a fresh scan, the control plane SHALL require the `endpoint_inventory.force_fresh_scan` permission, force-fresh policy enablement, and an unexhausted per-partition rate limit before dispatch
- **AND** the agent SHALL enforce its per-agent single-flight semaphore before running the scan
- **AND** a request that only uploads the agent's already-cached artifact SHALL require normal inventory authorization and route the bytes through the datasvc relay rather than the command stream
- **AND** the uploaded artifact SHALL become queryable only after normal ingestion validation succeeds

### Requirement: Device Endpoint Inventory Answers Report Freshness And Coverage
Device inventory SHALL report freshness on device answers and coverage on cohort answers.

#### Scenario: Device live answer reports freshness
- **GIVEN** a device-scoped live endpoint software question
- **WHEN** the answer is displayed
- **THEN** it SHALL include the freshness verdict, cache age, and package-set hash

#### Scenario: Cohort answer reports coverage
- **GIVEN** a cohort live endpoint software question
- **WHEN** the answer is displayed
- **THEN** it SHALL distinguish live matches, live non-matches, stale answers, offline agents, expired commands, and latest persisted state

### Requirement: Endpoint Inventory Rows Survive Identity Reconciliation
Device inventory SHALL keep endpoint inventory rows attributed correctly across identity resolution and device merges.

#### Scenario: Pre-enrollment rows backfilled
- **GIVEN** endpoint inventory rows were written with a null canonical device UID before reconciliation
- **WHEN** the reporting agent first acquires a canonical device UID
- **THEN** those rows SHALL be backfilled to the canonical device UID
- **AND** the device detail view SHALL show that inventory rather than reporting it unavailable

#### Scenario: Merge reassigns inventory rows
- **GIVEN** two devices with endpoint inventory are merged
- **WHEN** the merge resolves a surviving canonical UID
- **THEN** endpoint inventory scan and package rows SHALL be reassigned to the surviving canonical UID

### Requirement: Device Inventory Exposes Fleet Software Rollups
Device inventory SHALL expose fleet rollups of endpoint software without scanning the current-state package tables.

#### Scenario: Fleet rollup query
- **GIVEN** an operator asks for the count of devices with a package, version, or CPE
- **WHEN** the system answers
- **THEN** it SHALL serve the count from an incremental fleet aggregate that includes offline and last-known hosts
- **AND** it SHALL NOT run a full scan over current package rows
