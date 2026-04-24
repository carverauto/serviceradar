## MODIFIED Requirements
### Requirement: OAuth2 Authentication
The system SHALL support OAuth2 authentication for configured providers (Google, GitHub). Any provider discovery metadata used during the flow MUST be validated before follow-up network calls, discovered authorization, token, and key endpoints MUST satisfy the outbound URL policy before the platform redirects a user agent, exchanges an authorization code, or fetches signing keys, and the callback MUST remain bound to previously stored session state and nonce values.

#### Scenario: OAuth2 login with Google
- **GIVEN** OAuth2 is configured for Google
- **WHEN** a user initiates Google login
- **THEN** the system SHALL redirect to Google's OAuth consent screen
- **AND** upon successful authorization, create or link a user account

#### Scenario: OAuth2 callback with missing stored session state is rejected
- **GIVEN** a browser callback reaches the OIDC callback endpoint without the previously stored `state` and `nonce` session values
- **WHEN** the callback includes an authorization code
- **THEN** the system SHALL reject the callback
- **AND** SHALL NOT exchange the code for tokens
- **AND** SHALL NOT authenticate a user from that callback

### Requirement: Active SSO redirect targets are validated before browser redirect
The system SHALL validate any metadata-derived SSO redirect destination before redirecting a browser during an active SSO flow, and the callback MUST remain bound to previously stored session CSRF material.

#### Scenario: SAML metadata returns a disallowed SSO URL
- **GIVEN** a configured SAML provider metadata document contains a SingleSignOnService URL that violates the outbound URL policy
- **WHEN** a user initiates SAML login
- **THEN** the system SHALL reject the login initiation without redirecting the browser to that URL
- **AND** SHALL return an authentication failure

#### Scenario: SAML callback with missing stored CSRF token is rejected
- **GIVEN** a browser callback reaches the SAML consume endpoint without the previously stored session CSRF token
- **WHEN** the callback includes a SAML response and RelayState token
- **THEN** the system SHALL reject the callback
- **AND** SHALL NOT authenticate a user from that response

### Requirement: Password reset email links use the canonical configured endpoint
The system SHALL generate password reset email links from the configured canonical application base URL and SHALL NOT derive those links from inbound request host headers.

#### Scenario: Password reset request ignores spoofed Host header
- **GIVEN** a password reset request arrives with a manipulated `Host` header
- **WHEN** the system sends the reset email
- **THEN** the reset link SHALL use the configured canonical application base URL
- **AND** the spoofed request host SHALL NOT appear in the emailed reset URL
