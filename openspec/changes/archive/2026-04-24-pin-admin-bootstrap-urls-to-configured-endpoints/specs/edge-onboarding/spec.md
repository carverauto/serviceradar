## MODIFIED Requirements
### Requirement: One-Liner Install Commands

The system SHALL display platform-specific one-liner install commands that the admin can copy and run on the target system.

#### Scenario: Docker install command displayed

- **GIVEN** a package has been successfully created
- **WHEN** the admin views the success modal
- **THEN** the system displays a Docker-based install command
- **AND** the command can be copied with one click
- **AND** the command prompts for the download token or requires it in a header/body transport
- **AND** the command SHALL NOT embed the download token in the URL
- **AND** the command SHALL use an operator-configured canonical base URL instead of the inbound request host

#### Scenario: Agent enroll command uses explicit core URL

- **GIVEN** an agent package has been successfully created
- **WHEN** the admin views the copied enroll command
- **THEN** the command SHALL include an explicit `--core-url`
- **AND** that URL SHALL come from the operator-configured canonical endpoint URL
- **AND** the copied command SHALL NOT rely on request-host-derived values

#### Scenario: Copy command to clipboard

- **GIVEN** the success modal is displayed with install commands
- **WHEN** the admin clicks the copy button
- **THEN** the command is copied to the system clipboard
- **AND** a confirmation message is shown
