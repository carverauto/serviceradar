## ADDED Requirements

### Requirement: Native add-on importer verify-then-mirror
The control plane SHALL import native add-ons from the published discovery index by
reusing the WASM verify-then-mirror pipeline: fetch only from a trusted-host allowlist
with bounded size, verify the digest, the Cosign signature (including Rekor), and the
ed25519 upload-signature, and only then mirror the per-architecture artifacts into
ServiceRadar object storage and stage an `AddonPackage`.

#### Scenario: Verified add-on is mirrored and staged
- **GIVEN** a native add-on entry in the discovery index whose artifacts pass digest, Cosign, and upload-signature verification
- **WHEN** the importer runs
- **THEN** it SHALL mirror each per-architecture artifact into object storage
- **AND** SHALL stage an `AddonPackage` recording the resolved object keys, digests, and signature references

#### Scenario: Verification failure aborts the import
- **GIVEN** an add-on artifact that fails digest, Cosign, or upload-signature verification
- **WHEN** the importer runs
- **THEN** it SHALL NOT mirror the artifact
- **AND** SHALL NOT stage an `AddonPackage` for it

#### Scenario: Untrusted host is rejected
- **GIVEN** a discovery index that references an artifact host not on the trusted-host allowlist
- **WHEN** the importer attempts to fetch it
- **THEN** the fetch SHALL be refused
