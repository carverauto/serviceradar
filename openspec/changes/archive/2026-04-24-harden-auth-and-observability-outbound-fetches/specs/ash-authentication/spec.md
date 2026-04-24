## MODIFIED Requirements
### Requirement: OAuth2 Authentication
The system SHALL support OAuth2 authentication for configured providers (Google, GitHub). Any provider discovery metadata used during the flow MUST be validated before follow-up network calls, and discovered token and key endpoints MUST satisfy the outbound URL policy before the platform exchanges an authorization code or fetches signing keys.

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

#### Scenario: Discovery metadata returns a disallowed token endpoint
- **GIVEN** a configured OAuth2 provider returns discovery metadata with a token endpoint that violates the outbound URL policy
- **WHEN** the platform attempts to exchange an authorization code
- **THEN** the system SHALL reject the token exchange without sending client credentials to that endpoint
- **AND** SHALL return an authentication failure
