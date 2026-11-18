## MODIFIED Requirements

### Requirement: Cosign-signed Wasm plugin artifacts
Published first-party Wasm plugin artifacts SHALL be signed with Cosign as one classic `.sig` signature per digest and SHALL upload a Rekor transparency-log entry. Every signature created from the cutover release on SHALL carry that entry's receipt in the signature's `dev.sigstore.cosign/bundle` annotation.
Signatures created before the cutover release carry no receipt and are not re-signed. The repository verification workflow checks the receipt offline against the pinned Rekor public key for every signature created in the current run, as the `artifact-signing` capability defines, and verifies a reused pre-cutover signature with the release key alone. It does not look up the log online.

#### Scenario: Published plugin artifact passes verification
- **GIVEN** a published first-party Wasm plugin artifact whose signature was created from the cutover release on
- **WHEN** the repository verification workflow checks the artifact with the committed public key
- **THEN** signature verification SHALL succeed
- **AND** the embedded Rekor receipt SHALL verify offline against the pinned Rekor public key

#### Scenario: Unsigned or tlog-missing plugin artifact fails verification
- **GIVEN** a first-party Wasm plugin artifact signed in the current run that is missing a valid Cosign signature or an embedded Rekor receipt
- **WHEN** the repository verification workflow checks the artifact
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be considered deployable

#### Scenario: Reused pre-cutover plugin signature
- **GIVEN** a first-party Wasm plugin artifact whose signature was created before the cutover release and is reused by the current run
- **WHEN** the repository verification workflow checks the artifact with the committed public key
- **THEN** signature verification SHALL succeed without a receipt
- **AND** the signature SHALL NOT be re-signed
