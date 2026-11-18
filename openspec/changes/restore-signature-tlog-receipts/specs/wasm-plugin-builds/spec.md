## MODIFIED Requirements

### Requirement: Cosign-signed Wasm plugin artifacts
Published first-party Wasm plugin artifacts SHALL be signed with Cosign as one classic `.sig` signature per digest and SHALL upload a Rekor transparency-log entry. Every signature created from the cutover release on SHALL carry that entry's receipt in the signature's `dev.sigstore.cosign/bundle` annotation.
Signatures created before the cutover release carry no receipt and are not re-signed. The repository verification workflow classifies each digest from the signer's ledger record of whether its signature was created or reused in the run, never from whether a receipt is present, as the `artifact-signing` capability defines. It checks the receipt offline against the pinned Rekor key selected by the receipt's log ID for every signature created in the current run and every reused signature that carries a receipt, verifies a reused signature without a receipt, which can only be pre-cutover, with the release key alone, and fails a digest that is in neither set. It does not look up the log online.

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
- **GIVEN** a first-party Wasm plugin artifact whose signature was created before the cutover release, carries no receipt, and is recorded in the signing ledger as reused by the current run
- **WHEN** the repository verification workflow checks the artifact with the committed public key
- **THEN** signature verification SHALL succeed without a receipt
- **AND** the signature SHALL NOT be re-signed
