## MODIFIED Requirements
### Requirement: Enterprise Authentication Flows Stay Bound To Verified Identity Sources
The system SHALL require every externally supplied authentication identity to be validated against an explicitly configured trust source before it can establish or map a user session.

#### Scenario: Passive proxy mode rejects unsigned gateway identities
- **GIVEN** passive proxy authentication mode is enabled
- **AND** no gateway JWT JWKS URL or static public key is configured
- **WHEN** a request includes a gateway identity token header
- **THEN** the system SHALL reject the token
- **AND** the system SHALL NOT create or map a user from its claims

#### Scenario: Auth metadata discovery rejects insecure transport
- **GIVEN** the system is validating OIDC, SAML, or JWKS metadata URLs
- **WHEN** a configured metadata URL uses `http://`
- **THEN** the system SHALL reject the URL
- **AND** the system SHALL NOT perform the outbound request
