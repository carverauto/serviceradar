## MODIFIED Requirements
### Requirement: Session Management
The system SHALL manage user sessions with configurable expiration and logout capabilities.

Only `access` and `api` JWT token types SHALL be accepted for general API authorization. `refresh` tokens SHALL be accepted only on refresh-token exchange paths.

#### Scenario: Session expiration
- **GIVEN** a user session older than 30 days
- **WHEN** the user makes an authenticated request
- **THEN** the system SHALL reject the request
- **AND** require re-authentication

#### Scenario: Logout
- **WHEN** a user logs out
- **THEN** the system SHALL invalidate the current session token
- **AND** remove the session cookie

#### Scenario: Refresh token rejected on API pipeline
- **GIVEN** a valid refresh token
- **WHEN** it is presented to a normal API authorization pipeline
- **THEN** the request SHALL be rejected as an invalid token type

## ADDED Requirements
### Requirement: Strict Federated Assertion Binding
The system SHALL require federated assertions to be explicitly bound to the configured Service Provider and browser session state.

#### Scenario: SAML assertion missing audience is rejected
- **GIVEN** SAML authentication is configured with an expected SP entity ID
- **WHEN** an assertion omits the audience restriction
- **THEN** the assertion SHALL be rejected

#### Scenario: SAML assertion missing recipient is rejected
- **GIVEN** SAML authentication is configured with an expected ACS URL
- **WHEN** an assertion omits the subject confirmation recipient
- **THEN** the assertion SHALL be rejected

#### Scenario: OIDC ID token missing nonce is rejected
- **GIVEN** an OIDC login flow generated and stored a nonce
- **WHEN** the ID token verification step runs without a matching nonce
- **THEN** the authentication attempt SHALL be rejected

#### Scenario: OIDC ID token missing required identity claims is rejected
- **GIVEN** OIDC login is enabled
- **WHEN** the ID token or mapped claims omit the external subject or email
- **THEN** the provisioning flow SHALL reject the authentication attempt
