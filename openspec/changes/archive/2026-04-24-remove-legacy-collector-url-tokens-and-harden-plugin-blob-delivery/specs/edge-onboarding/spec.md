## MODIFIED Requirements
### Requirement: Downloadable Installation Bundle

The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script

Bundle and enrollment delivery SHALL NOT require bearer tokens in URL query strings. Token-gated package retrieval SHALL use request headers or POST bodies so secrets do not appear in generated URLs, shell history, browser history, or intermediary access logs.

#### Scenario: Download bundle as archive
- **GIVEN** a package has been successfully created
- **WHEN** the admin clicks "Download Bundle"
- **THEN** the system delivers a compressed archive file
- **AND** the archive contains certs/, config/, and install.sh
- **AND** all certificate files are in PEM format
- **AND** the download token is not carried in the request URL

#### Scenario: Bundle includes install script
- **GIVEN** a bundle is downloaded
- **WHEN** the admin inspects the bundle contents
- **THEN** the bundle contains an install.sh script
- **AND** the script detects available platforms (Docker, systemd)
- **AND** the script provides usage instructions if manual install is required

#### Scenario: Collector enrollment rejects legacy URL token flow
- **GIVEN** a collector onboarding package exists
- **WHEN** a client attempts to use the removed legacy `GET /api/enroll/...?...token=...` flow
- **THEN** the platform rejects the request
- **AND** the supported collector flow uses the hardened bundle/download endpoints instead
