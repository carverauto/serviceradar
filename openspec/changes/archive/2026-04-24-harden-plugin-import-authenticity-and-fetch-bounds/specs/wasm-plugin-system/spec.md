## ADDED Requirements

### Requirement: Strict Upload Verification Must Require Real Signatures
When unsigned plugin uploads are disabled, the system MUST cryptographically verify uploaded package signatures against configured trusted signing keys.

#### Scenario: Dummy signature metadata is supplied
- **WHEN** an uploaded package includes non-empty signature metadata that does not verify against the package manifest and content hash
- **THEN** the package MUST be rejected or remain unapprovable
- **AND** the system MUST NOT treat signature presence alone as sufficient

### Requirement: GitHub Imports Must Be Resource-Bounded
The GitHub importer MUST enforce manifest and WASM size limits during download, not after full buffering.

#### Scenario: Remote repository serves an oversized WASM blob
- **WHEN** the importer reads a WASM blob that exceeds the configured maximum upload size
- **THEN** the import MUST abort before fully buffering the payload in memory
- **AND** the package MUST be rejected as oversized

### Requirement: Authenticated GitHub Import Must Honor Trusted Repo Boundaries
If a GitHub token is configured, the importer MUST only use it for explicitly trusted repositories or owners.

#### Scenario: User nominates an untrusted private repository
- **WHEN** a repository is outside the configured trusted import boundary
- **THEN** the importer MUST reject the authenticated fetch or avoid using privileged credentials
- **AND** it MUST NOT import private content via the server's GitHub token on behalf of the user

### Requirement: GitHub Import Inputs Must Be Constrained
GitHub import refs, paths, and manifest parsing MUST reject hostile inputs that can escape intended repository context or exhaust parser resources.

#### Scenario: Import request includes traversal-style paths or hostile YAML aliases
- **WHEN** a user submits an unsafe repo-relative path, an invalid ref, or a manifest containing abusive alias expansion
- **THEN** the importer MUST reject the request
- **AND** it MUST NOT fetch unexpected repository content or exhaust parser memory
