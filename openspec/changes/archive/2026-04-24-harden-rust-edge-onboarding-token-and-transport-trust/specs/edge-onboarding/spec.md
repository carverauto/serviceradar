## MODIFIED Requirements
### Requirement: Downloadable Installation Bundle

The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script

#### Scenario: Download bundle as archive

- **GIVEN** a package has been successfully created
- **WHEN** the admin clicks "Download Bundle"
- **THEN** the system delivers a compressed archive file
- **AND** the archive contains certs/, config/, and install.sh
- **AND** all certificate files are in PEM format

#### Scenario: Bundle includes install script

- **GIVEN** a bundle is downloaded
- **WHEN** the admin inspects the bundle contents
- **THEN** the bundle contains an install.sh script
- **AND** the script detects available platforms (Docker, systemd)
- **AND** the script provides usage instructions if manual install is required

#### Scenario: Rust onboarding rejects legacy or insecure bootstrap inputs
- **GIVEN** a Rust-based edge checker uses the shared onboarding crate
- **WHEN** it is given a legacy/raw onboarding token, a plaintext `http://` Core API URL, or a scheme-less bootstrap host
- **THEN** the crate SHALL reject the onboarding attempt
- **AND** it SHALL NOT downgrade to plaintext transport or parse a legacy token format

### Requirement: One-Liner Install Commands

The system SHALL display platform-specific one-liner install commands that the admin can copy and run on the target system.

#### Scenario: Docker install command displayed

- **GIVEN** a package has been successfully created
- **WHEN** the admin views the success modal
- **THEN** the system displays a Docker-based install command
- **AND** the command can be copied with one click
- **AND** the command includes the download token for authentication

#### Scenario: Copy command to clipboard

- **GIVEN** the success modal is displayed with install commands
- **WHEN** the admin clicks the copy button
- **THEN** the command is copied to the system clipboard
- **AND** a confirmation message is shown

#### Scenario: Rust onboarding preserves token-authenticated API URL
- **GIVEN** a Rust-based edge checker is given a structured onboarding token with an API URL
- **WHEN** an operator also passes `--host` or `CORE_API_URL`
- **THEN** the crate SHALL continue using the token-authenticated API URL
- **AND** operator input SHALL NOT replace it
