## ADDED Requirements

### Requirement: Device Inventory Exposes Endpoint Software State
Device inventory SHALL expose the latest successful endpoint software inventory state for managed devices that report package/SBOM data.

#### Scenario: Device has current endpoint inventory
- **GIVEN** a managed device has a latest successful endpoint inventory scan
- **WHEN** an operator or API client requests the device inventory detail
- **THEN** the response SHALL include endpoint inventory status, scan timestamp, collector version, package counts, and artifact metadata
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
