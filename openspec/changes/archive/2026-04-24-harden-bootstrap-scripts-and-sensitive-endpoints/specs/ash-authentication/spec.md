## MODIFIED Requirements
### Requirement: OAuth2 Authentication
The system SHALL support OAuth2 authentication for configured providers (Google, GitHub), and account linking between an external identity and an existing local account SHALL NOT occur implicitly based only on a matching email address.

#### Scenario: Existing local account is not auto-linked by email
- **GIVEN** a local user account exists without an established external identity link
- **WHEN** an OIDC or SAML login arrives with a matching email address
- **THEN** the system SHALL NOT silently attach the external identity to that existing account
- **AND** authentication SHALL fail closed unless the account satisfies the explicit linking policy

### Requirement: Password Authentication
The system SHALL support password-based authentication with secure hashing using AshAuthentication, and password reset initiation SHALL be rate limited to reduce abuse.

#### Scenario: Password reset requests are throttled
- **GIVEN** repeated password reset requests originate from the same client within the configured window
- **WHEN** the rate limit threshold is exceeded
- **THEN** the system SHALL reject additional reset requests for that window
- **AND** the endpoint SHALL return a client-safe rate limit response

## ADDED Requirements
### Requirement: SAML ACS Parsing Prevents External Entity Resolution
The system SHALL parse inbound SAML responses and assertions without resolving external entities, external DTDs, or other external XML resources.

#### Scenario: SAML response with external entity is rejected
- **GIVEN** a SAML response payload that references an external entity or DTD
- **WHEN** the ACS endpoint parses the XML
- **THEN** parsing SHALL fail closed
- **AND** the server SHALL NOT fetch the external resource
