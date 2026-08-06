## ADDED Requirements
### Requirement: Private Dashboard Git Source Credentials
The system SHALL store private dashboard Git source credentials encrypted at rest and SHALL use them only for server-side package import operations.

#### Scenario: Deploy key private material is redacted
- **GIVEN** a private dashboard Git source has a generated deploy keypair
- **WHEN** any API or UI reads the source
- **THEN** the public key MAY be returned
- **AND** the private key SHALL NOT be returned
- **AND** logs and audit events SHALL NOT include private key material

#### Scenario: Server-side private Git fetch
- **GIVEN** a private dashboard Git source references an encrypted deploy key
- **WHEN** a dashboard import uses that source
- **THEN** the server SHALL fetch the requested repository ref with that key
- **AND** the renderer and manifest SHALL be mirrored into ServiceRadar package storage
- **AND** agents and browsers SHALL receive only ServiceRadar package references, never repository credentials

### Requirement: Private Dashboard Git Source Safety Controls
The system SHALL constrain private Git dashboard imports with host verification, ref resolution, artifact limits, and repository path validation.

#### Scenario: Host key mismatch is rejected
- **GIVEN** a private dashboard Git source has a stored known-host fingerprint
- **WHEN** the upstream host presents a different key
- **THEN** the import SHALL fail closed
- **AND** the failure SHALL be recorded without exposing credential material

#### Scenario: Import stores immutable source metadata
- **GIVEN** a private Git import succeeds from a branch or tag ref
- **WHEN** the dashboard package record is persisted
- **THEN** it SHALL store the resolved commit SHA
- **AND** it SHALL store the normalized manifest path and renderer path
- **AND** repeat imports SHALL validate renderer digest against the manifest before enabling the package
