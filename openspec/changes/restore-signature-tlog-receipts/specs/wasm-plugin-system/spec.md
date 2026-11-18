## ADDED Requirements

### Requirement: First-party import verifies the transparency-log receipt offline
ServiceRadar SHALL verify the Rekor receipt embedded in a first-party OCI artifact's classic signature, for a Wasm plugin or a native add-on bundle, against the Rekor public key shipped in the web-ng image, without contacting any public Sigstore service.
The receipt is accepted only when its SignedEntryTimestamp verifies under a pinned Rekor key for its log ID, and its logged body names the same signature, the configured release public key and the payload hash being verified. This does not change the requirement "First-party artifact import needs no public Sigstore service": the registry holding the artifact remains the only network destination.

#### Scenario: Artifact with a valid receipt on an air-gapped installation
- **GIVEN** an installation that can reach its artifact registry and no public Sigstore service
- **AND** a first-party artifact whose classic signature carries a valid receipt
- **WHEN** the artifact is imported
- **THEN** verification SHALL succeed
- **AND** verification SHALL NOT wait on a transparency-log lookup

#### Scenario: Receipt missing on an artifact that requires one
- **GIVEN** a first-party artifact that is not on the pre-cutover allowlist
- **AND** its classic signature carries no receipt
- **WHEN** the artifact is imported
- **THEN** verification SHALL fail without any network call to a Sigstore service
- **AND** the package SHALL NOT be imported

#### Scenario: Receipt for a different log entry
- **GIVEN** a first-party artifact whose receipt has a valid SignedEntryTimestamp for an entry that names a different signature, key or payload hash
- **WHEN** the artifact is imported
- **THEN** verification SHALL fail
- **AND** the package SHALL NOT be imported

#### Scenario: Receipt from an unknown log
- **GIVEN** a receipt whose log ID matches no pinned Rekor key
- **WHEN** the artifact is imported
- **THEN** verification SHALL fail

### Requirement: Pre-cutover first-party artifacts without a receipt
ServiceRadar SHALL accept a first-party OCI artifact by release-key verification alone only when its digest is on the frozen pre-cutover allowlist shipped in the web-ng image.
The allowlist lists every first-party OCI digest published in a Wasm plugin or native add-on release index before the cutover release. It is generated once, at the cutover, and a contract test fails if it changes afterwards. It holds no container image digests. From the cutover release on, every other first-party Wasm plugin or native add-on digest requires a receipt.

#### Scenario: Allowlisted pre-cutover artifact
- **GIVEN** a first-party artifact whose digest is on the pre-cutover allowlist and whose classic signature has no receipt
- **WHEN** the artifact is imported
- **THEN** release-key verification SHALL be sufficient
- **AND** the package SHALL record its receipt status as `absent_allowlisted`

#### Scenario: Allowlist edited after the cutover
- **GIVEN** the committed pre-cutover allowlist differs from the list frozen at the cutover
- **WHEN** the contract tests run
- **THEN** the test SHALL fail

### Requirement: Imported packages record their receipt status
ServiceRadar SHALL store, in the import verification metadata of every imported first-party plugin or add-on package, whether its signature's transparency-log receipt was `verified`, with log index and integrated time, or `absent_allowlisted`.

#### Scenario: Package imported with a verified receipt
- **GIVEN** a first-party artifact whose receipt verifies
- **WHEN** the artifact is imported
- **THEN** the package's verification metadata SHALL record the receipt as `verified`
- **AND** SHALL record its log index and integrated time
