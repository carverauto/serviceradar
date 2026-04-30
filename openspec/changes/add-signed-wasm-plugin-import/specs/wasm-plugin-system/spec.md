## ADDED Requirements
### Requirement: First-party repository plugin discovery
The control plane SHALL discover first-party Wasm plugin versions from the configured ServiceRadar Forgejo repository release import index.

#### Scenario: Recent release exposes importable plugins
- **GIVEN** the deployment is configured with the pinned ServiceRadar Forgejo repository
- **AND** a recent release includes a valid first-party plugin import index
- **WHEN** an operator opens the plugin package UI or triggers plugin repository sync
- **THEN** the system SHALL list the discovered plugin IDs, names, versions, release tags, and import status
- **AND** it SHALL identify plugin versions whose required artifacts are missing or not import-ready

#### Scenario: Untrusted repository is rejected
- **GIVEN** repository import is configured with a host other than the pinned Forgejo host
- **WHEN** the system attempts to discover first-party plugin releases
- **THEN** discovery SHALL fail closed
- **AND** no plugin package SHALL be staged from that repository

### Requirement: Signed first-party plugin import
The control plane SHALL import first-party Wasm plugin versions only after verifying the release index, OCI artifact digest, Cosign signature, Rekor entry, and upload-signature sidecar.

#### Scenario: Verified first-party plugin is staged
- **GIVEN** a first-party plugin import index entry references a published Harbor OCI artifact by digest
- **AND** the artifact has valid Cosign and upload-signature metadata
- **WHEN** the import workflow runs
- **THEN** the control plane SHALL fetch the artifact payload
- **AND** validate the bundle using the standard plugin bundle/package validation path
- **AND** mirror the package contents into ServiceRadar-managed plugin storage
- **AND** create or update a staged plugin package with source and verification metadata

#### Scenario: Invalid signature blocks import
- **GIVEN** a first-party plugin import index entry references an artifact with an invalid Cosign signature, missing Rekor entry, invalid upload signature, or mismatched digest
- **WHEN** the import workflow runs
- **THEN** the control plane SHALL reject the import
- **AND** no distributable plugin package SHALL be created or updated from that artifact
- **AND** the UI SHALL expose the verification failure reason

### Requirement: Automatic first-party plugin sync stages only
The system SHALL support a scheduled first-party plugin sync that imports newly verified first-party plugin versions without approving, assigning, or executing them automatically.

#### Scenario: Scheduled sync stages new version
- **GIVEN** automatic first-party plugin sync is enabled
- **AND** a new signed plugin version appears in a trusted Forgejo release index
- **WHEN** the sync job runs
- **THEN** the system SHALL import and stage the verified package
- **AND** the package SHALL remain unassignable until an authorized operator approves it

#### Scenario: Existing artifact is not reimported
- **GIVEN** a plugin package version has already been imported from a source artifact digest
- **WHEN** the sync job sees the same plugin ID, version, and digest again
- **THEN** the system SHALL skip remirroring the artifact
- **AND** preserve the existing review status and approval metadata

### Requirement: First-party plugin provenance in UI
The plugin package UI SHALL present first-party repository plugin discovery, import, verification, and provenance state alongside the existing staged review workflow.

#### Scenario: Operator reviews imported first-party plugin
- **GIVEN** a verified first-party plugin package has been staged by repository import
- **WHEN** an authorized operator opens the plugin package detail or review modal
- **THEN** the UI SHALL show the source release tag, repository URL, OCI reference, artifact digest, signing key identity, verification timestamp, requested capabilities, approved capabilities, and current review status
- **AND** the operator SHALL be able to approve, deny, revoke, or assign the package according to existing RBAC and status rules

#### Scenario: Repository plugin catalog shows import actions
- **GIVEN** the repository discovery result includes an import-ready plugin version not yet staged
- **WHEN** an operator with plugin staging permission views the plugin package UI
- **THEN** the UI SHALL offer an import action for that version
- **AND** operators without staging permission SHALL see the version and status without an import control
