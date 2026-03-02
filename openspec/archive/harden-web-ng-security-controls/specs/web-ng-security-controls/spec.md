## ADDED Requirements

### Requirement: Plugin Markdown Rendering MUST Be XSS-Safe
The system SHALL sanitize plugin markdown HTML output before rendering and SHALL block dangerous URL schemes and executable markup.

#### Scenario: Dangerous markdown link is neutralized
- **WHEN** plugin content includes markdown such as `[click](javascript:alert(1))`
- **THEN** rendered output MUST NOT include a navigable `javascript:` URL
- **AND** the UI MUST render safe text or a sanitized link instead.

#### Scenario: Inline script/event payload is stripped
- **WHEN** plugin content includes inline script/event attributes in markdown-derived HTML
- **THEN** unsafe tags/attributes MUST be removed before template rendering.

### Requirement: Browser CSP MUST Minimize Inline Execution
The system SHALL emit a CSP that does not broadly allow inline script execution for authenticated browser routes.

#### Scenario: Browser response contains hardened CSP
- **WHEN** a user loads a page through the browser pipeline
- **THEN** the response headers MUST include a CSP policy that omits broad `'unsafe-inline'` script execution.

### Requirement: SAML Assertions MUST Be Cryptographically Verified
The system SHALL reject SAML responses that do not pass cryptographic signature verification against trusted IdP certificates.

#### Scenario: Missing signature material is rejected
- **WHEN** a SAML response lacks valid signature/certificate material
- **THEN** the authentication flow MUST fail with an authentication error
- **AND** no user session MUST be established.

#### Scenario: Structurally valid but cryptographically invalid signature is rejected
- **WHEN** a SAML response contains a signature element that fails cryptographic verification
- **THEN** authentication MUST be denied.

### Requirement: Metadata/JWKS Fetch URLs MUST Enforce SSRF Controls
The system SHALL validate and enforce policy on externally fetched OIDC/SAML/JWKS URLs.

#### Scenario: Local/private target URL is denied
- **WHEN** an admin configures or tests a metadata/JWKS URL targeting loopback, link-local, or private network addresses
- **THEN** the request MUST be rejected before outbound fetch.

#### Scenario: Non-HTTPS URL is denied by default
- **WHEN** an admin configures or tests a non-HTTPS metadata/JWKS URL
- **THEN** validation MUST fail unless an explicit, audited exception policy allows it.
