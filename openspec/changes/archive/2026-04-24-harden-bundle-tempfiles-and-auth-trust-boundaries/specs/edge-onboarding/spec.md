## MODIFIED Requirements
### Requirement: Downloadable Installation Bundle
The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script

Bundle archive creation SHALL use secure temporary file handling and SHALL NOT rely on predictable filenames in a shared temporary directory.

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

#### Scenario: Bundle tarball creation avoids predictable temp paths
- **GIVEN** an edge onboarding bundle is being built
- **WHEN** the system stages the tarball before returning it to the caller
- **THEN** it SHALL use secure temporary file handling
- **AND** it SHALL NOT write the tarball to a predictable shared-path filename
