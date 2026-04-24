## ADDED Requirements

### Requirement: Release artifacts are mirrored into internal distribution storage
The system SHALL mirror rollout artifact payloads into ServiceRadar-managed internal object storage when a release is published or imported. A release SHALL not become rollout-eligible until every required artifact has been staged successfully in internal storage.

#### Scenario: Imported release becomes internally distributable
- **GIVEN** an operator imports a signed repository-hosted release for version `v1.2.3`
- **WHEN** the control plane validates the signed manifest and mirrors each artifact into internal object storage
- **THEN** the release is stored as rollout-eligible
- **AND** the catalog records internal storage references for each supported artifact

#### Scenario: Mirroring failure blocks publication
- **GIVEN** an operator publishes or imports a release whose external artifact cannot be mirrored into internal storage
- **WHEN** the release publication workflow runs
- **THEN** the release is rejected for rollout use
- **AND** the operator receives an error indicating internal artifact staging failed

### Requirement: Manual release publication remains available for developer workflows
The system SHALL preserve a manual release publication path for developer and local validation workflows, even when production rollouts normally use repository-hosted release imports.

#### Scenario: Developer publishes a local validation release
- **GIVEN** a developer wants to test agent release management without pushing a production-style release to the repository host
- **WHEN** the developer manually publishes signed release metadata and artifact source details
- **THEN** the control plane mirrors the artifact into internal storage
- **AND** the release can be rolled out through the same gateway-served delivery path as production releases
