## ADDED Requirements

### Requirement: Endpoint Inventory Collection Is Policy Controlled
The system SHALL collect endpoint software inventory only when an agent has an effective endpoint inventory policy that explicitly enables collection.

#### Scenario: Collection disabled by default
- **GIVEN** an agent has no endpoint inventory policy
- **WHEN** the agent resolves its configuration
- **THEN** no endpoint inventory collector SHALL run
- **AND** no package inventory or SBOM artifact SHALL be uploaded

#### Scenario: OS package inventory enabled
- **GIVEN** an agent has an endpoint inventory policy with OS package inventory enabled
- **WHEN** the scheduled inventory scan runs
- **THEN** the collector SHALL inspect supported local package databases
- **AND** it SHALL emit package names, versions, architecture, package manager source, and available package identifiers into the scan result

#### Scenario: Optional sources remain disabled
- **GIVEN** an endpoint inventory policy enables OS packages only
- **WHEN** the collector runs
- **THEN** it SHALL NOT collect language manifests, listening services, executable paths, or file hashes
- **AND** those sources SHALL require separate policy flags

### Requirement: Endpoint SBOM Artifacts Use CycloneDX JSON
The system SHALL generate and ingest endpoint SBOM artifacts in CycloneDX JSON format for the first supported implementation.

#### Scenario: Collector produces valid SBOM
- **GIVEN** endpoint inventory collection is enabled for an agent
- **WHEN** the collector completes successfully
- **THEN** it SHALL write a CycloneDX JSON SBOM artifact
- **AND** the artifact SHALL include collector identity, scan timestamp, component list, package identifiers when available, and redaction metadata

#### Scenario: Unsupported SBOM format rejected
- **GIVEN** an agent attempts to upload an endpoint SBOM artifact in an unsupported format
- **WHEN** ingestion validates the artifact
- **THEN** the artifact SHALL be rejected
- **AND** the previous successful inventory state SHALL remain current

### Requirement: Endpoint Inventory Is Normalized For Asset Queries
The system SHALL normalize endpoint package and component data into queryable rows linked to the reporting agent and resolved device asset.

#### Scenario: Package rows linked to asset
- **GIVEN** an agent uploads a valid endpoint SBOM artifact
- **WHEN** ingestion normalizes the artifact
- **THEN** package/component rows SHALL be linked to the agent ID, scan ID, and resolved device UID when available
- **AND** rows SHALL include package manager, ecosystem, name, version, architecture, PURL, CPE values, supplier, license, and source evidence where available

#### Scenario: Latest successful scan becomes current
- **GIVEN** a device has an existing current endpoint inventory scan
- **WHEN** a newer valid scan is ingested and normalized successfully
- **THEN** the newer scan SHALL become the current inventory for that agent/device
- **AND** the prior scan SHALL remain historical until retention removes it

#### Scenario: Failed scan does not replace current inventory
- **GIVEN** a device has an existing current endpoint inventory scan
- **WHEN** a newer scan fails validation or normalization
- **THEN** the failed scan SHALL be recorded as failed
- **AND** the existing current inventory SHALL remain unchanged

### Requirement: Endpoint Inventory Retains Provenance
The system SHALL preserve provenance for endpoint inventory scans and artifacts so operators can explain how package data was collected.

#### Scenario: Operator inspects scan metadata
- **GIVEN** endpoint inventory exists for an asset
- **WHEN** an operator views the scan metadata
- **THEN** ServiceRadar SHALL expose scan ID, agent ID, collector version, scan start/end timestamps, enabled sources, artifact digest, artifact size, and ingestion status

#### Scenario: Historical scan expires
- **GIVEN** endpoint inventory retention is configured
- **WHEN** a scan and its raw artifact exceed the retention window
- **THEN** ServiceRadar SHALL remove or compact the historical data according to policy
- **AND** it SHALL NOT delete the current inventory unless that inventory also exceeds a configured current-state retention policy

### Requirement: Endpoint Inventory Applies Privacy Bounds
The system SHALL bound endpoint inventory data collection and redact privacy-sensitive values unless explicitly enabled.

#### Scenario: Paths are redacted by default
- **GIVEN** executable or language manifest collection is enabled without path collection
- **WHEN** the collector emits component evidence
- **THEN** local filesystem paths SHALL be omitted or redacted
- **AND** package identity fields SHALL remain available for inventory queries

#### Scenario: Artifact exceeds size limit
- **GIVEN** a collector writes an endpoint SBOM artifact larger than the configured maximum
- **WHEN** the agent validates the local artifact before upload
- **THEN** the agent SHALL reject the artifact locally
- **AND** it SHALL report the scan as failed with a bounded error message
