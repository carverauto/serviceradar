# edge-onboarding Specification

## Purpose
TBD - created by archiving change improve-edge-onboarding-ux. Update Purpose after archive.
## Requirements
### Requirement: Automatic Certificate Generation on Package Creation

When a tenant admin creates an edge onboarding package through the web UI, the system SHALL automatically generate all required certificates without any manual intervention.

The system SHALL:
1. Check for an existing tenant intermediate CA and generate one if not present
2. Generate a component certificate signed by the tenant CA
3. Include the encrypted certificate bundle in the onboarding package
4. Display certificate fingerprint and validity information after creation

#### Scenario: First package creation generates tenant CA

- **GIVEN** a tenant has no existing intermediate CA
- **WHEN** a tenant admin creates their first edge onboarding package
- **THEN** the system automatically generates a tenant intermediate CA
- **AND** generates a component certificate signed by the new CA
- **AND** the package includes the encrypted certificate bundle
- **AND** no CLI commands or manual steps are required

#### Scenario: Subsequent packages reuse tenant CA

- **GIVEN** a tenant already has an active intermediate CA
- **WHEN** a tenant admin creates an additional edge onboarding package
- **THEN** the system generates a new component certificate using the existing CA
- **AND** the package creation is faster (no CA generation overhead)

#### Scenario: Certificate information displayed after creation

- **GIVEN** a tenant admin has submitted the package creation form
- **WHEN** the package is successfully created
- **THEN** the system displays the certificate fingerprint
- **AND** shows the certificate validity period
- **AND** provides download options for the package bundle

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

### Requirement: Token Expiration Visibility

The system SHALL clearly display token expiration information to help admins understand the time window for deployment.

#### Scenario: Expiration countdown on package details

- **GIVEN** a package exists with a download token
- **WHEN** the admin views the package details
- **THEN** the system displays the expiration date/time
- **AND** if expiring within 24 hours, shows time remaining
- **AND** indicates if the token has already expired

