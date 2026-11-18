## ADDED Requirements

### Requirement: First-party artifact import needs no public Sigstore service
ServiceRadar SHALL verify a first-party OCI artifact, whether a Wasm plugin or a native add-on
bundle, against the configured release public key without contacting any public Sigstore
service. The only network destination verification may use is the registry that holds the
artifact.

#### Scenario: Import on an installation without internet access
- **GIVEN** an installation that can reach its artifact registry and no public Sigstore service
- **WHEN** a first-party artifact signed by the release key is imported
- **THEN** signature verification SHALL succeed
- **AND** verification SHALL NOT wait on a transparency-log lookup

#### Scenario: Artifact not signed by the release key
- **GIVEN** a first-party OCI artifact with no signature from the configured release key
- **WHEN** the artifact is imported
- **THEN** verification SHALL fail
- **AND** the package SHALL NOT be imported

#### Scenario: Registry cannot be reached
- **GIVEN** the artifact registry does not answer
- **WHEN** a first-party artifact is verified
- **THEN** verification SHALL end with an error within a bounded time
