## ADDED Requirements

### Requirement: Endpoint SBOM Object Storage
Datasvc SHALL store endpoint SBOM artifacts as bounded durable objects with explicit ownership, content identity, and provenance metadata.

#### Scenario: Valid endpoint SBOM object stored
- **GIVEN** an authorized endpoint inventory upload provides a CycloneDX JSON artifact within configured size limits
- **WHEN** datasvc stores the artifact
- **THEN** the object SHALL be written under an endpoint inventory object key
- **AND** datasvc SHALL persist artifact format, SHA-256 digest, byte size, scan ID, agent ID, package-set hash, upload reason, and upload timestamp metadata

#### Scenario: Existing endpoint SBOM object reused
- **GIVEN** an authorized endpoint inventory upload references an artifact digest already stored for the same logical endpoint inventory scope
- **WHEN** datasvc or ingestion resolves the artifact reference
- **THEN** the existing object MAY be reused instead of storing duplicate bytes
- **AND** the new scan metadata SHALL reference the reused digest and object key

#### Scenario: Unauthorized endpoint SBOM object rejected
- **GIVEN** a caller without endpoint inventory object write permission attempts to upload an SBOM artifact
- **WHEN** datasvc evaluates the upload request
- **THEN** datasvc SHALL reject the upload
- **AND** no partial object SHALL be committed as the current artifact for the scan

#### Scenario: Oversize endpoint SBOM object rejected
- **GIVEN** an endpoint SBOM upload exceeds the configured object size limit
- **WHEN** datasvc processes the upload stream
- **THEN** datasvc SHALL reject the upload using its bounded object upload behavior
- **AND** ingestion SHALL record the scan artifact as failed rather than current
