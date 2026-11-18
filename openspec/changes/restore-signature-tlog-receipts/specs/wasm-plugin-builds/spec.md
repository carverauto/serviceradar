## MODIFIED Requirements

### Requirement: Cosign-signed Wasm plugin artifacts
Published first-party Wasm plugin artifacts SHALL be signed with Cosign as one classic `.sig` signature per digest, SHALL upload a Rekor transparency-log entry, and SHALL carry that entry's receipt in the signature's `dev.sigstore.cosign/bundle` annotation.
The repository verification workflow checks the receipt offline against the pinned Rekor public key, as the `artifact-signing` capability defines. It does not look up the log online.

#### Scenario: Published plugin artifact passes verification
- **GIVEN** a published first-party Wasm plugin artifact
- **WHEN** the repository verification workflow checks the artifact with the committed public key
- **THEN** signature verification SHALL succeed
- **AND** the embedded Rekor receipt SHALL verify offline against the pinned Rekor public key

#### Scenario: Unsigned or tlog-missing plugin artifact fails verification
- **GIVEN** a first-party Wasm plugin artifact signed in the current run that is missing a valid Cosign signature or an embedded Rekor receipt
- **WHEN** the repository verification workflow checks the artifact
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be considered deployable
