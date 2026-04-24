# wasm-plugin-builds Specification

## Purpose
TBD - created by archiving change add-bazel-wasm-plugin-publishing. Update Purpose after archive.
## Requirements
### Requirement: Bazel-built first-party Wasm plugin bundles
The repository SHALL build first-party Wasm plugins through Bazel and SHALL emit a canonical plugin bundle artifact for each published plugin.

#### Scenario: Build a first-party plugin bundle
- **GIVEN** a first-party Wasm plugin with source code, `plugin.yaml`, and optional sidecar files
- **WHEN** the Bazel build target runs
- **THEN** Bazel SHALL compile the Wasm payload
- **AND** Bazel SHALL assemble a canonical plugin bundle artifact
- **AND** Bazel SHALL emit digest metadata for that artifact

### Requirement: Harbor publication for first-party Wasm plugins
The repository SHALL publish first-party Wasm plugin bundles to Harbor as OCI artifacts under deterministic repository names and immutable tags.

#### Scenario: Publish a commit-tagged plugin artifact
- **GIVEN** a first-party plugin bundle built from commit `ad617c5f8a067f1e3e93872704754b9f7d006697`
- **WHEN** the publish workflow runs
- **THEN** Harbor SHALL receive an OCI artifact for that plugin
- **AND** the artifact SHALL be addressable by an immutable tag `sha-ad617c5f8a067f1e3e93872704754b9f7d006697`

#### Scenario: Publish preserves OCI-tool compatibility
- **GIVEN** a published first-party Wasm plugin artifact
- **WHEN** an operator inspects or pulls it with a standard OCI client
- **THEN** the artifact SHALL be retrievable without a ServiceRadar-specific registry API

### Requirement: Cosign-signed Wasm plugin artifacts
Published first-party Wasm plugin artifacts SHALL be signed with Cosign and SHALL upload Rekor transparency-log entries by default.

#### Scenario: Published plugin artifact passes verification
- **GIVEN** a published first-party Wasm plugin artifact
- **WHEN** the repository verification workflow checks the artifact with the committed public key
- **THEN** signature verification SHALL succeed
- **AND** Rekor transparency-log verification SHALL succeed

#### Scenario: Unsigned or tlog-missing plugin artifact fails verification
- **GIVEN** a published first-party Wasm plugin artifact missing a valid Cosign signature or Rekor entry
- **WHEN** the repository verification workflow checks the artifact
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be considered deployable
