## REMOVED Requirements
### Requirement: Magic Link Email Authentication
**Reason**: Magic-link authentication is permanently removed; ServiceRadar only supports password authentication.
**Migration**: Remove magic-link routes, UI entry points, and email senders. Use the password login flow and admin bootstrap.

#### Scenario: Magic link endpoints are unavailable
- **GIVEN** a request is made to a magic-link authentication endpoint
- **WHEN** the request is processed
- **THEN** the system SHALL reject the request with a disabled or not found response
- **AND** no email SHALL be sent

#### Scenario: Magic link login is not offered
- **GIVEN** a user visits the sign-in page
- **WHEN** the page renders authentication options
- **THEN** the UI SHALL NOT present a magic-link login form or link

## ADDED Requirements
### Requirement: Bootstrap Admin Account for Self-Hosted Installs
Self-hosted installations (Docker Compose, Helm, and demo manifests) MUST bootstrap an admin user with display name `admin` and email `root@localhost` on first install. The system MUST generate a random password, hash it with bcrypt, and store the hash in the authentication user store. The plaintext password MUST be written to install-specific secret/volume storage and surfaced to the operator once after successful install.

#### Scenario: Compose bootstrap creates admin user
- **GIVEN** a fresh Docker Compose install with no existing admin user
- **WHEN** the stack finishes initial startup
- **THEN** an admin user with email `root@localhost` exists
- **AND** a randomly generated password is stored in the Compose credential volume
- **AND** the initial credentials are emitted to the operator once via startup logs

#### Scenario: Helm bootstrap creates admin user
- **GIVEN** a fresh Helm installation with no existing admin user
- **WHEN** the bootstrap job completes
- **THEN** an admin user with email `root@localhost` exists
- **AND** a Kubernetes secret contains the generated password
- **AND** Helm install notes surface the login instructions

#### Scenario: Demo manifest bootstrap creates admin user
- **GIVEN** a fresh install of the demo manifests with no existing admin user
- **WHEN** the bootstrap job completes
- **THEN** an admin user with email `root@localhost` exists
- **AND** a Kubernetes secret contains the generated password
- **AND** the job logs or documented output show how to retrieve it

#### Scenario: Bootstrap is idempotent
- **GIVEN** an admin user already exists
- **WHEN** the bootstrap logic runs again
- **THEN** it SHALL NOT overwrite the existing admin password
- **AND** it SHALL report that credentials already exist

### Requirement: Registration Disabled in Default Deployments
User self-registration MUST be disabled in default deployments, and sign-in pages MUST NOT offer registration links.

#### Scenario: Registration UI removed
- **GIVEN** a user views the sign-in page
- **WHEN** the page renders
- **THEN** no registration link or call-to-action is displayed

#### Scenario: Registration endpoints disabled
- **GIVEN** a request attempts to register a new user
- **WHEN** the registration endpoint is called
- **THEN** the system SHALL reject the request with a disabled or not found response
