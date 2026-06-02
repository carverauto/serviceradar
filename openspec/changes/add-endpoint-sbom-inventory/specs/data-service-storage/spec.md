## ADDED Requirements

### Requirement: Endpoint SBOM Object Storage
Datasvc SHALL store endpoint SBOM component payload bytes as bounded durable objects with explicit ownership and content identity. Scan-specific provenance metadata SHALL be persisted outside the content-addressed bytes so identical component payloads can deduplicate across hosts.

#### Scenario: Valid endpoint SBOM payload object stored
- **GIVEN** an authorized endpoint inventory upload provides a CycloneDX JSON artifact within configured size limits
- **WHEN** datasvc stores the artifact
- **THEN** the canonicalized component payload bytes SHALL be written under an endpoint inventory object key addressed by artifact hash
- **AND** scan-specific metadata such as scan ID, agent ID, device UID, package-set hash, upload reason, and upload timestamp SHALL be persisted as artifact metadata rows rather than included in the hashed payload bytes

#### Scenario: Existing endpoint SBOM object reused
- **GIVEN** an authorized endpoint inventory upload whose artifact digest matches a content-addressed object already stored
- **WHEN** datasvc or ingestion resolves the artifact reference
- **THEN** the existing object SHALL be reused instead of storing duplicate bytes
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

### Requirement: Endpoint SBOM Artifacts Are Deduplicated Across Hosts
Datasvc SHALL avoid storing duplicate SBOM component payload bytes across hosts that share an identical inventory.

#### Scenario: Identical artifacts across hosts stored once
- **GIVEN** many hosts share an identical golden-image inventory that produces the same artifact hash
- **WHEN** their SBOM artifacts are uploaded
- **THEN** datasvc SHALL store the component payload bytes once, content-addressed by artifact hash
- **AND** each scan SHALL reference the shared object rather than storing duplicate bytes

### Requirement: Endpoint SBOM Bytes Do Not Traverse The Command Stream
SBOM artifact bytes SHALL be uploaded through the durable object path, never through the on-demand command/result stream.

#### Scenario: Artifact upload uses the object path
- **GIVEN** an agent must upload a changed SBOM artifact
- **WHEN** it sends the bytes
- **THEN** it SHALL use the agent-to-gateway relay to datasvc, or a direct datasvc upload, content-addressed by artifact hash
- **AND** it SHALL NOT send artifact bytes as a command result payload

#### Scenario: Command result payload is bounded
- **GIVEN** an on-demand inventory command result
- **WHEN** the result is returned over the command stream
- **THEN** the result payload SHALL be within a configured byte cap
- **AND** an oversize result SHALL be truncated or rejected rather than terminating the shared command stream
