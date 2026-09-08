## ADDED Requirements
### Requirement: First-party plugin release import index
The repository SHALL publish a machine-readable first-party Wasm plugin import index with each release that includes every published first-party plugin version intended for control-plane import.

#### Scenario: Release includes plugin import index
- **GIVEN** a ServiceRadar release publishes first-party Wasm plugin OCI artifacts
- **WHEN** the Forgejo release assets are finalized
- **THEN** the release SHALL include a first-party plugin import index asset
- **AND** the index SHALL identify each plugin by ID, version, OCI reference, OCI digest, bundle digest, upload-signature metadata reference, and release tag

#### Scenario: Index omits unpublished plugin
- **GIVEN** a first-party plugin artifact failed publication or verification
- **WHEN** the release import index is generated
- **THEN** that plugin version SHALL be omitted from the import-ready index
- **AND** the release verification workflow SHALL report the missing or invalid artifact

### Requirement: Release verification covers plugin import metadata
The repository release verification workflow SHALL validate the first-party plugin import index against the published OCI artifacts, Cosign signatures, Rekor entries, and upload-signature sidecars before the release is considered plugin-import ready.

#### Scenario: Valid plugin import metadata passes release verification
- **GIVEN** a release import index references a first-party Wasm plugin OCI artifact by digest
- **AND** the OCI artifact has a valid Cosign signature, Rekor entry, and upload-signature sidecar
- **WHEN** the repository verification workflow runs
- **THEN** the import index entry SHALL pass verification
- **AND** the plugin version SHALL be marked import-ready

#### Scenario: Tampered index fails release verification
- **GIVEN** a release import index references an OCI digest that does not match the published plugin artifact
- **WHEN** the repository verification workflow runs
- **THEN** verification SHALL fail
- **AND** the release SHALL NOT be considered plugin-import ready
