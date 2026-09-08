## ADDED Requirements

### Requirement: Bazel-built per-architecture native add-on bundles
The repository SHALL build first-party native add-ons through Bazel and SHALL emit a
canonical, deterministic bundle artifact per published architecture, with digest
metadata, driven by an in-repo add-on inventory analogous to the Wasm plugin
inventory.

#### Scenario: Build a native add-on bundle
- **GIVEN** a first-party add-on with source code, `addon.yaml`, `config.schema.json`, and an inventory entry
- **WHEN** the Bazel build target runs
- **THEN** Bazel SHALL compile the add-on binary for each declared `(os, arch)`
- **AND** Bazel SHALL assemble a canonical bundle artifact per architecture
- **AND** Bazel SHALL emit digest metadata for each artifact

#### Scenario: Add-on enrolls into release artifacts via inventory
- **GIVEN** a new add-on with an entry in the native add-on inventory
- **WHEN** the release artifact targets are evaluated
- **THEN** the add-on's bundles SHALL be enrolled into the release artifacts without per-add-on release wiring

### Requirement: Signed native add-on artifacts
Published first-party native add-on artifacts SHALL be signed with Cosign (uploading
Rekor transparency-log entries by default) and SHALL additionally carry an ed25519
upload-signature. All signing keys SHALL be sourced from the runtime secret store or
environment; no signing private keys SHALL be committed to source. Builds SHALL fail
closed when signing keys are not configured.

#### Scenario: Published add-on artifact passes verification
- **GIVEN** a published first-party native add-on artifact
- **WHEN** the verification workflow checks it with the configured public trust material
- **THEN** Cosign signature verification SHALL succeed
- **AND** Rekor transparency-log verification SHALL succeed
- **AND** the ed25519 upload-signature SHALL verify against a trusted signing key

#### Scenario: Unsigned add-on artifact fails verification
- **GIVEN** a native add-on artifact missing a valid Cosign signature, Rekor entry, or upload-signature
- **WHEN** the verification workflow checks it
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be considered deployable

#### Scenario: Missing signing keys fail the build closed
- **GIVEN** a release build with native add-on signing keys not configured
- **WHEN** the signing step runs
- **THEN** the build SHALL fail
- **AND** SHALL NOT publish an unsigned add-on artifact

### Requirement: Native add-on discovery index publication
The release process SHALL generate a native add-on discovery index listing each
published add-on with its version and per-architecture artifact digests, and SHALL
publish the index as a release asset so the control plane can discover available
add-ons without a ServiceRadar-specific registry API.

#### Scenario: Discovery index is published with the release
- **GIVEN** a release that built and signed native add-on bundles
- **WHEN** the release workflow runs
- **THEN** it SHALL generate a native add-on index with per-architecture digests
- **AND** SHALL publish the index as a release asset
- **AND** the release SHALL assert the index asset is present

#### Scenario: Control plane discovers add-ons from the index
- **GIVEN** a published native add-on discovery index
- **WHEN** the control plane importer lists available add-ons
- **THEN** it SHALL read the index from the release asset
- **AND** SHALL resolve each add-on's per-architecture artifacts for verification and mirroring

### Requirement: Binary size and dependency hygiene
The agent and Go add-on builds SHALL preserve binary-size optimizations and SHALL
guard against regressions. Builds SHALL keep method dead-code elimination enabled and
SHALL fail if a dependency disables it. Builds SHALL forbid importing the Go standard
library `plugin` package (which forces dynamic linking and disables dead-code
elimination). The build SHALL track per-artifact binary sizes across releases and
flag significant regressions.

#### Scenario: Dead-code elimination stays enabled
- **GIVEN** an agent or Go add-on build
- **WHEN** the build's dead-code-elimination guard runs
- **THEN** method dead-code elimination SHALL be enabled
- **AND** the build SHALL fail with the offending call chain if a dependency has disabled it

#### Scenario: Stdlib plugin import is rejected
- **GIVEN** a change that imports the Go standard library `plugin` package into an agent or add-on build
- **WHEN** the build hygiene check runs
- **THEN** the check SHALL fail
- **AND** SHALL identify the import

#### Scenario: Binary size regression is flagged
- **GIVEN** a built agent or add-on artifact
- **WHEN** its size is compared against the recorded baseline
- **THEN** a significant size increase SHALL be flagged for review
