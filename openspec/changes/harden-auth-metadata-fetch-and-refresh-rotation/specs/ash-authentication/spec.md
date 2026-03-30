## MODIFIED Requirements
### Requirement: OAuth2 Authentication
The system SHALL support OAuth2 authentication for configured providers (Google, GitHub), and the metadata and token exchange flow SHALL use outbound fetch controls that prevent redirects or resolution changes to private or otherwise disallowed network destinations after validation.

#### Scenario: OIDC metadata fetch is bound to the validated destination
- **GIVEN** an OIDC provider discovery URL is configured
- **WHEN** web-ng validates and fetches discovery metadata, JWKS, or exchanges the authorization code
- **THEN** the outbound request SHALL remain bound to the validated destination
- **AND** the request SHALL fail if resolution changes to a disallowed host or address

### Requirement: Session Management
The system SHALL manage user sessions with configurable expiration and logout capabilities, and refresh tokens SHALL be single-use when exchanged for new credentials.

#### Scenario: Refresh token exchange rotates the token
- **GIVEN** a valid refresh token
- **WHEN** the token is exchanged for new credentials
- **THEN** the system SHALL revoke the used refresh token
- **AND** the caller SHALL receive newly issued credentials

#### Scenario: Reused refresh token is rejected
- **GIVEN** a refresh token that has already been exchanged successfully
- **WHEN** a caller attempts to exchange the same refresh token again
- **THEN** the system SHALL reject the token as revoked

### Requirement: Password Authentication
The system SHALL support password-based authentication with secure hashing using AshAuthentication, and online authentication throttling SHALL remain effective under concurrent request bursts.

#### Scenario: Concurrent login bursts do not bypass throttling
- **GIVEN** a password or token endpoint protected by auth rate limiting
- **WHEN** multiple concurrent requests from the same client hit the endpoint within the same rate-limit window
- **THEN** the system SHALL count the attempts atomically
- **AND** requests beyond the configured limit SHALL be throttled

## ADDED Requirements
### Requirement: SAML Metadata Parsing Prevents External Entity Resolution
The system SHALL parse SAML IdP metadata without resolving external entities, external DTDs, or other external XML resources.

#### Scenario: Metadata with external entity is rejected
- **GIVEN** SAML IdP metadata that references an external entity or DTD
- **WHEN** web-ng parses the metadata
- **THEN** parsing SHALL fail closed
- **AND** web-ng SHALL NOT fetch the external resource

### Requirement: Auth Config Cache Refresh Is Single-Flight
The auth settings cache SHALL ensure that a cache miss or TTL expiry triggers at most one database refresh for the same refresh event.

#### Scenario: Concurrent callers share one refresh
- **GIVEN** the cached auth settings entry is expired
- **WHEN** multiple concurrent requests ask for auth settings
- **THEN** the system SHALL issue one refresh query
- **AND** the concurrent callers SHALL reuse that same refresh result
