## ADDED Requirements

### Requirement: First-Party Wasm OCI Artifacts Publish Upload-Signature Metadata
First-party Wasm plugin OCI artifacts published by the repository SHALL include upload-signature metadata that is compatible with the control-plane uploaded-package verification policy.

#### Scenario: Published Wasm OCI artifact includes upload-signature sidecar
- **GIVEN** a first-party Wasm plugin bundle published to Harbor
- **WHEN** an operator or CI workflow inspects the OCI artifact
- **THEN** the artifact SHALL include the canonical bundle payload
- **AND** it SHALL include an additional upload-signature metadata sidecar
- **AND** the sidecar SHALL identify the signing key and plugin content hash

#### Scenario: Upload-signature payload matches control-plane verification semantics
- **GIVEN** a first-party Wasm plugin manifest and Wasm content hash
- **WHEN** the repository generates the upload-signature sidecar
- **THEN** the Ed25519 signature SHALL cover the same canonical payload used by `web-ng` upload verification
- **AND** the sidecar SHALL be sufficient for a later import workflow to verify package trust without inventing a first-party-only signature format

### Requirement: Release Verification Enforces Wasm Upload Signatures
The repository release and verification workflows SHALL fail first-party Wasm plugin publication when the upload-signature sidecar is missing or invalid.

#### Scenario: Valid upload-signature sidecar passes verification
- **GIVEN** a published first-party Wasm plugin OCI artifact with a valid upload-signature sidecar
- **WHEN** the repository verification workflow runs
- **THEN** the workflow SHALL verify the upload-signature metadata against the trusted public key
- **AND** the artifact SHALL be considered publishable

#### Scenario: Missing or invalid upload-signature sidecar fails verification
- **GIVEN** a published first-party Wasm plugin OCI artifact missing the upload-signature sidecar or containing an invalid Ed25519 signature
- **WHEN** the repository verification workflow runs
- **THEN** verification SHALL fail
- **AND** the release workflow SHALL NOT treat the plugin artifact as successfully published
