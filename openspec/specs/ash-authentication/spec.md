# ash-authentication Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: Magic Link Email Authentication
The system SHALL support passwordless authentication via magic link emails using AshAuthentication.

#### Scenario: Magic link login flow
- **GIVEN** a registered user with email user@example.com
- **WHEN** the user requests a magic link login
- **THEN** the system SHALL send an email with a single-use authentication link
- **AND** clicking the link SHALL authenticate the user and create a session

#### Scenario: Magic link expiration
- **GIVEN** a magic link token older than 15 minutes
- **WHEN** the user attempts to use the link
- **THEN** the system SHALL reject the authentication attempt
- **AND** display an appropriate error message

### Requirement: Password Authentication
The system SHALL support password-based authentication with secure hashing using AshAuthentication.

#### Scenario: Password login
- **GIVEN** a user with a registered password
- **WHEN** the user submits valid credentials
- **THEN** the system SHALL authenticate the user
- **AND** create a session token

#### Scenario: Password requirements
- **WHEN** a user sets or changes their password
- **THEN** the password MUST be at least 12 characters
- **AND** the password MUST be at most 72 bytes (bcrypt limit)

### Requirement: OAuth2 Authentication
The system SHALL support OAuth2 authentication for configured providers (Google, GitHub).

#### Scenario: OAuth2 login with Google
- **GIVEN** OAuth2 is configured for Google
- **WHEN** a user initiates Google login
- **THEN** the system SHALL redirect to Google's OAuth consent screen
- **AND** upon successful authorization, create or link a user account

#### Scenario: OAuth2 account linking
- **GIVEN** an existing user authenticated via password
- **WHEN** the user authenticates via OAuth2 with the same email
- **THEN** the system SHALL link the OAuth2 identity to the existing account
- **AND** not create a duplicate user

### Requirement: API Token Authentication
The system SHALL support long-lived API tokens for programmatic access using AshAuthentication.

#### Scenario: API token generation
- **GIVEN** an authenticated admin user
- **WHEN** the user requests a new API token
- **THEN** the system SHALL generate a cryptographically secure token
- **AND** store a hashed version in the database
- **AND** display the token exactly once

#### Scenario: API token authentication
- **GIVEN** a valid API token
- **WHEN** a request includes the token in the Authorization header
- **THEN** the system SHALL authenticate the request as the token's owner
- **AND** enforce the token's scope restrictions

### Requirement: Session Management
The system SHALL manage user sessions with configurable expiration and logout capabilities.

#### Scenario: Session expiration
- **GIVEN** a user session older than 30 days
- **WHEN** the user makes an authenticated request
- **THEN** the system SHALL reject the request
- **AND** require re-authentication

#### Scenario: Logout
- **WHEN** a user logs out
- **THEN** the system SHALL invalidate the current session token
- **AND** remove the session cookie

### Requirement: Migration from Phoenix.gen.auth
The system SHALL provide a migration path from the existing Phoenix.gen.auth implementation to AshAuthentication.

#### Scenario: Existing user migration
- **GIVEN** users in the ng_users table from Phoenix.gen.auth
- **WHEN** AshAuthentication is enabled
- **THEN** existing users SHALL be able to authenticate
- **AND** existing hashed passwords SHALL remain valid

