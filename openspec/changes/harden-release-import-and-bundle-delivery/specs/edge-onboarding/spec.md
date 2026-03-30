## MODIFIED Requirements

### Requirement: Downloadable Installation Bundle
The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script

Bundle delivery SHALL NOT require bearer tokens in URL query strings. Token-gated bundle downloads SHALL use request headers or POST bodies so download tokens do not appear in generated URLs, shell history, browser history, or intermediary access logs.

#### Scenario: Download bundle as archive
- **GIVEN** a package has been successfully created
- **WHEN** the admin downloads the bundle
- **THEN** the system delivers a compressed archive file
- **AND** the archive contains certs/, config/, and install.sh
- **AND** the download token is not carried in the request URL

### Requirement: One-Liner Install Commands
The system SHALL display platform-specific one-liner install commands that the admin can copy and run on the target system.

The generated commands SHALL authenticate bundle downloads without embedding bearer tokens in URL query parameters.

#### Scenario: Docker install command displayed
- **GIVEN** a package has been successfully created
- **WHEN** the admin views the success modal
- **THEN** the system displays a Docker-based install command
- **AND** the command can be copied with one click
- **AND** the command authenticates the bundle request without putting the download token in the URL
