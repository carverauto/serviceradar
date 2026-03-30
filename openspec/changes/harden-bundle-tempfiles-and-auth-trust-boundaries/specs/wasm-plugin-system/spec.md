## ADDED Requirements
### Requirement: Trusted Signer Enforcement for GitHub Imports
When GitHub signature verification is required for plugin imports, the system SHALL only accept GitHub commits whose verified signer matches an operator-configured trusted signer allowlist.

#### Scenario: Reject verified commit from untrusted signer
- **GIVEN** GitHub signature verification is required
- **AND** the trusted signer allowlist is configured
- **WHEN** a plugin import references a GitHub commit that GitHub marks as verified but the signer is not in the allowlist
- **THEN** the import SHALL be rejected
- **AND** the package SHALL NOT be staged or approved

#### Scenario: Accept verified commit from trusted signer
- **GIVEN** GitHub signature verification is required
- **AND** the trusted signer allowlist contains the verified signer identity
- **WHEN** a plugin import references that signed commit
- **THEN** the import SHALL proceed
- **AND** the package provenance metadata SHALL record the trusted signer identity
