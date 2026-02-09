## ADDED Requirements

### Requirement: Gateway Proxy Authentication Mode
When authentication mode is configured as `passive_proxy`, the system SHALL support authenticating users via an upstream gateway-provided JWT and SHALL establish an authenticated web-ng session suitable for Phoenix LiveView.

#### Scenario: Gateway proxy login establishes a UI session
- **GIVEN** auth settings are enabled and `mode = passive_proxy`
- **AND** the request includes a valid gateway JWT in the configured header
- **WHEN** the user navigates to an authenticated web-ng route
- **THEN** the system SHALL authenticate the request based on the gateway JWT
- **AND** the system SHALL establish an authenticated session for subsequent LiveView navigation

### Requirement: Passive Proxy Requires Verifiable JWT Configuration
When `mode = passive_proxy` is enabled, the system SHALL require a verifiable JWT configuration (JWKS URL or public key PEM) and MUST NOT accept tokens that cannot be cryptographically verified.

#### Scenario: Passive proxy cannot be enabled without JWKS or PEM
- **GIVEN** an administrator configures `mode = passive_proxy`
- **WHEN** neither a JWKS URL nor a public key PEM is configured
- **THEN** the system SHALL reject enabling passive proxy mode

### Requirement: Passive Proxy Prevents Direct Bypass
When `mode = passive_proxy` is enabled, the system SHALL prevent direct access to authenticated UI routes without gateway authentication, except for explicitly allowed administrator-only access paths.

#### Scenario: Direct access without gateway token is denied
- **GIVEN** auth settings are enabled and `mode = passive_proxy`
- **AND** the request does not include a gateway JWT
- **WHEN** the user requests an authenticated UI route
- **THEN** the system SHALL deny access (redirect to login for HTML, 401 for JSON)

#### Scenario: Admin local access path remains available
- **GIVEN** auth settings are enabled and `mode = passive_proxy`
- **WHEN** an administrator uses the documented local admin sign-in path
- **THEN** the system SHALL allow password-based sign-in for that path

