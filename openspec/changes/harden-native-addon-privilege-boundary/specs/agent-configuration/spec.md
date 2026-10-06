## ADDED Requirements

### Requirement: Privileged native add-ons execute only verified root-owned artifacts
The system MUST execute systemd-supervised native add-ons only from an immutable root-owned runtime materialized by the privileged updater from a signed artifact that the updater itself verifies.

#### Scenario: Signed add-on activation
- **GIVEN** a systemd-supervised native add-on assignment with a valid artifact digest and Ed25519 signature
- **WHEN** the non-root agent requests activation
- **THEN** the privileged updater SHALL verify the artifact bytes before extracting them into the root-owned add-on runtime
- **AND** the installed unit SHALL execute the binary from that root-owned runtime
- **AND** the non-root agent SHALL NOT be able to modify the executed binary or installed unit definition

#### Scenario: Staged files are replaced after agent verification
- **GIVEN** the non-root staging tree is modified after the agent verifies an artifact
- **WHEN** privileged activation is requested
- **THEN** the updater SHALL derive the privileged runtime from its own verified read of the original artifact
- **AND** no replaced staged executable or unit text SHALL be installed or executed

#### Scenario: Unsigned privileged add-on
- **GIVEN** a native add-on uses `systemd-service` or `systemd-timer` supervision
- **AND** its assignment has no artifact signature
- **WHEN** activation is requested
- **THEN** activation SHALL fail before capabilities are applied, units are installed, or services are started
- **AND** the previously active verified version SHALL remain active

#### Scenario: Mutable assignment configuration changes
- **GIVEN** a verified privileged add-on is active
- **WHEN** its assignment configuration changes without an artifact version change
- **THEN** the agent SHALL update configuration in a separate writable state path
- **AND** the root-owned executable and bundled unit files SHALL remain unchanged

#### Scenario: Candidate activation fails
- **GIVEN** a verified privileged add-on version is active
- **AND** a newer signed candidate fails unit installation or startup
- **WHEN** activation rolls back
- **THEN** the privileged runtime SHALL restore the previous root-owned version
- **AND** no privileged unit SHALL execute from the agent-writable staging tree
