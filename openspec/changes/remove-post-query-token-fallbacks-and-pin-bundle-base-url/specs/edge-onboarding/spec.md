## MODIFIED Requirements
### Requirement: Downloadable Installation Bundle

The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script
6. Canonical control-plane endpoint URLs derived from operator configuration, not inbound request host headers

#### Scenario: Download bundle as archive

- **GIVEN** a package has been successfully created
- **WHEN** the admin clicks "Download Bundle"
- **THEN** the system delivers a compressed archive file
- **AND** the archive contains certs/, config/, and install.sh
- **AND** all certificate files are in PEM format

#### Scenario: Bundle ignores spoofed request host

- **GIVEN** a token-gated bundle request arrives with a manipulated `Host` header
- **WHEN** the system generates the onboarding bundle
- **THEN** embedded install commands and configuration SHALL use the operator-configured canonical base URL
- **AND** the spoofed request host SHALL NOT appear in the generated bundle

### Requirement: One-Liner Install Commands

The system SHALL display platform-specific one-liner install commands that the admin can copy and run on the target system.

#### Scenario: Docker install command displayed

- **GIVEN** a package has been successfully created
- **WHEN** the admin views the success modal
- **THEN** the system displays a Docker-based install command
- **AND** the command can be copied with one click
- **AND** the command prompts for the download token or requires it in a header/body transport
- **AND** the command SHALL NOT embed the download token in the URL

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

### Requirement: Token-gated POST delivery rejects URL query bearer tokens

Token-gated POST delivery endpoints for onboarding and collector package retrieval SHALL accept bearer material only from explicit headers or POST request bodies and SHALL reject bearer tokens supplied through URL query parameters.

#### Scenario: Header token accepted

- **GIVEN** a valid download token is supplied in the `x-serviceradar-download-token` header
- **WHEN** a client POSTs to a token-gated bundle or package delivery endpoint
- **THEN** the system SHALL process the request normally

#### Scenario: Query-string token rejected

- **GIVEN** a valid download token is supplied only in the URL query string
- **WHEN** a client POSTs to a token-gated bundle or package delivery endpoint
- **THEN** the system SHALL reject the request as unauthorized or invalid
- **AND** the query-string token SHALL NOT be treated as a valid credential source
