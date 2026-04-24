## ADDED Requirements

### Requirement: Guardian-Based Token Management
The system SHALL use Guardian for all JWT token operations, replacing AshAuthentication's token system with a unified approach supporting multiple token types and custom claims.

#### Scenario: Access token generation on login
- **GIVEN** a user successfully authenticates via any method
- **WHEN** the authentication is confirmed
- **THEN** the system SHALL generate a Guardian access token
- **AND** the token SHALL include user ID, token type, and expiration claims
- **AND** the token SHALL be signed with the configured signing secret

#### Scenario: Token verification on request
- **GIVEN** a request includes a Bearer token in the Authorization header
- **WHEN** the Guardian pipeline processes the request
- **THEN** the system SHALL decode and verify the token signature
- **AND** validate expiration and required claims
- **AND** load the user resource into the connection assigns

#### Scenario: Refresh token rotation
- **GIVEN** a user has a valid refresh token
- **WHEN** they request a new access token via the refresh endpoint
- **THEN** the system SHALL issue a new access token
- **AND** issue a new refresh token
- **AND** invalidate the old refresh token

### Requirement: Instance-Level Authentication Configuration
The system SHALL support instance-specific authentication configuration stored in the database, allowing administrators to configure SSO providers via the UI without code changes or restarts.

#### Scenario: Default password-only mode
- **GIVEN** a fresh installation with no auth_settings configured
- **WHEN** a user accesses the login page
- **THEN** the system SHALL display the standard password login form
- **AND** SSO options SHALL NOT be visible

#### Scenario: Admin configures OIDC authentication
- **GIVEN** an admin user on the authentication settings page
- **WHEN** the admin selects "Direct SSO" mode and "OIDC" provider type
- **THEN** the system SHALL display fields for Client ID, Client Secret, and Discovery URL
- **AND** sensitive fields SHALL be stored encrypted using Cloak

#### Scenario: Configuration changes apply without restart
- **GIVEN** an admin has saved new authentication configuration
- **WHEN** a user initiates login within 60 seconds
- **THEN** the system SHALL use the updated configuration
- **AND** no application restart SHALL be required

#### Scenario: Config cache invalidation
- **GIVEN** the auth configuration cache has entries
- **WHEN** an admin saves new configuration
- **THEN** the system SHALL broadcast a PubSub event
- **AND** the cache SHALL be invalidated immediately

### Requirement: OIDC Authentication
The system SHALL support OpenID Connect authentication for enterprise identity providers (Google, Azure AD, Okta, generic OIDC providers).

#### Scenario: OIDC login initiation
- **GIVEN** OIDC is configured and enabled
- **WHEN** a user clicks "Enterprise Login"
- **THEN** the system SHALL redirect to the configured IdP authorization endpoint
- **AND** include client_id, redirect_uri, scope, state, and nonce parameters

#### Scenario: OIDC callback success
- **GIVEN** a user has authenticated with the IdP
- **WHEN** the IdP redirects to the callback URL with an authorization code
- **THEN** the system SHALL exchange the code for tokens
- **AND** validate the ID token signature and claims
- **AND** generate a Guardian session token
- **AND** establish a user session

#### Scenario: OIDC discovery configuration
- **GIVEN** an admin enters an OIDC discovery URL
- **WHEN** the configuration is validated
- **THEN** the system SHALL fetch the .well-known/openid-configuration document
- **AND** extract authorization_endpoint, token_endpoint, and jwks_uri

### Requirement: SAML 2.0 Authentication
The system SHALL support SAML 2.0 authentication for enterprise identity providers requiring XML-based assertions.

#### Scenario: SAML login initiation
- **GIVEN** SAML is configured and enabled
- **WHEN** a user clicks "Enterprise Login"
- **THEN** the system SHALL generate a SAML AuthnRequest
- **AND** redirect the user to the IdP Single Sign-On URL

#### Scenario: SAML assertion consumption
- **GIVEN** a user has authenticated with the SAML IdP
- **WHEN** the IdP POSTs an assertion to the ACS endpoint
- **THEN** the system SHALL validate the XML signature against the IdP certificate
- **AND** extract user attributes from the assertion
- **AND** generate a Guardian session token
- **AND** establish a user session

#### Scenario: SAML metadata endpoint
- **GIVEN** SAML is configured
- **WHEN** the IdP administrator requests SP metadata
- **THEN** the system SHALL serve XML metadata at `/auth/saml/metadata`
- **AND** include entityID, ACS URL, and optional signing certificate

#### Scenario: SAML signature validation failure
- **GIVEN** a SAML assertion with an invalid or missing signature
- **WHEN** the assertion is received at the ACS endpoint
- **THEN** the system SHALL reject the assertion
- **AND** log the validation failure with details
- **AND** display an authentication error to the user

### Requirement: Proxy JWT Authentication (Gateway Support)
The system SHALL support passive JWT authentication for deployments behind API gateways (Kong, Ambassador) that handle authentication upstream.

#### Scenario: Gateway JWT extraction and validation
- **GIVEN** proxy JWT mode is enabled with a configured public key or JWKS URL
- **WHEN** a request arrives with a JWT in the configured header
- **THEN** the system SHALL extract the token
- **AND** verify the signature using the stored public key or fetched JWKS
- **AND** validate expiration, issuer, and audience claims

#### Scenario: Gateway-authenticated request processing
- **GIVEN** a valid gateway JWT has been verified
- **WHEN** the request is processed
- **THEN** the system SHALL extract user identity from token claims
- **AND** establish a request-scoped authentication context
- **AND** NOT create a persistent session

#### Scenario: Gateway JWT validation failure
- **GIVEN** a request with an invalid or expired JWT
- **WHEN** the gateway auth plug processes the request
- **THEN** the system SHALL return a 401 Unauthorized response
- **AND** include error details in the response body

#### Scenario: Missing JWT in proxy mode
- **GIVEN** proxy JWT mode is enabled
- **WHEN** a request arrives without a JWT in the expected header
- **THEN** the system SHALL return a 401 Unauthorized response
- **AND** NOT redirect to a login page

### Requirement: Just-In-Time User Provisioning
The system SHALL automatically create local user records when users authenticate via SSO for the first time, mapping IdP claims to user attributes.

#### Scenario: First-time SSO user provisioning
- **GIVEN** a user authenticates via OIDC or SAML for the first time
- **WHEN** their email does not exist in the local user table
- **THEN** the system SHALL create a new user record
- **AND** set the role to "viewer" by default
- **AND** map claims (email, name, sub) to user attributes
- **AND** store the IdP subject identifier as external_id
- **AND** invoke the on_user_created hook

#### Scenario: Returning SSO user login
- **GIVEN** a user has previously authenticated via SSO
- **WHEN** they authenticate again
- **THEN** the system SHALL match by email or external_id
- **AND** update the session without creating a duplicate user
- **AND** invoke the on_user_authenticated hook

#### Scenario: Claim mapping configuration
- **GIVEN** an admin has configured custom claim mappings
- **WHEN** a user is provisioned via SSO
- **THEN** the system SHALL use the configured mappings to extract attributes
- **AND** handle missing optional claims gracefully

### Requirement: Multi-Mode Authentication Selection
The system SHALL support three authentication modes: password-only, active SSO (OIDC/SAML), and passive proxy (gateway JWT), with clear UI for mode selection.

#### Scenario: Mode selection in admin UI
- **GIVEN** an admin is on the authentication settings page
- **WHEN** they select an authentication mode
- **THEN** the system SHALL display configuration fields relevant to that mode
- **AND** hide fields for other modes

#### Scenario: Active SSO mode with password fallback
- **GIVEN** active SSO mode is enabled with allow_password_fallback = true
- **WHEN** a user accesses the login page
- **THEN** the system SHALL display the "Enterprise Login" button prominently
- **AND** provide a "Use password instead" link

#### Scenario: Proxy mode hides login UI
- **GIVEN** proxy JWT mode is enabled
- **WHEN** a user navigates to the login page directly
- **THEN** the system SHALL display a message indicating gateway authentication is required
- **AND** NOT display a login form

### Requirement: Local Admin Backdoor Access
The system SHALL maintain a local admin login path to prevent lockouts from SSO misconfiguration.

#### Scenario: Local admin access when SSO misconfigured
- **GIVEN** SSO is configured but the IdP is unreachable
- **WHEN** an admin navigates to `/auth/local`
- **THEN** the system SHALL display the password login form
- **AND** allow authentication with local credentials

#### Scenario: Local admin rate limiting
- **GIVEN** multiple failed login attempts from an IP address
- **WHEN** the 6th attempt occurs within one minute
- **THEN** the system SHALL reject the attempt
- **AND** return a rate limit error

#### Scenario: Local admin audit logging
- **WHEN** a user authenticates via the local admin backdoor
- **THEN** the system SHALL log the authentication with special audit flag
- **AND** include IP address and timestamp

### Requirement: Authentication Configuration Test
The system SHALL provide a "Test Configuration" feature to validate SSO settings before enabling them.

#### Scenario: OIDC configuration test
- **GIVEN** an admin has entered OIDC configuration
- **WHEN** they click "Test Configuration"
- **THEN** the system SHALL verify the discovery URL is accessible
- **AND** verify it returns valid OIDC metadata
- **AND** display success or detailed error message

#### Scenario: SAML configuration test
- **GIVEN** an admin has entered SAML configuration
- **WHEN** they click "Test Configuration"
- **THEN** the system SHALL verify the metadata URL is accessible
- **AND** parse and validate the IdP metadata XML
- **AND** display the IdP certificate details for verification

### Requirement: User Self-Service API Credentials
The system SHALL allow authenticated users to create and manage OAuth2 client credentials for programmatic API access.

#### Scenario: User creates API client
- **GIVEN** an authenticated user on the User Settings page
- **WHEN** they create a new API client with a name and scopes
- **THEN** the system SHALL generate a client_id (UUID)
- **AND** generate a client_secret (secure random)
- **AND** display the secret exactly once
- **AND** store a Bcrypt hash of the secret

#### Scenario: Client credentials token exchange
- **GIVEN** a valid client_id and client_secret
- **WHEN** a POST request is made to /oauth/token with grant_type=client_credentials
- **THEN** the system SHALL verify the credentials
- **AND** return a Guardian access token with the client's scopes
- **AND** record usage statistics (timestamp, IP)

#### Scenario: API client revocation
- **GIVEN** a user with existing API clients
- **WHEN** they revoke a client
- **THEN** the system SHALL set revoked_at timestamp
- **AND** reject future token requests for that client
- **AND** existing tokens SHALL remain valid until expiration

#### Scenario: API client scope validation
- **GIVEN** a client credentials token request
- **WHEN** the requested scopes exceed the client's allowed scopes
- **THEN** the system SHALL reject the request
- **AND** return an invalid_scope error

#### Scenario: User views API client list
- **GIVEN** an authenticated user on the User Settings API Credentials page
- **WHEN** the page loads
- **THEN** the system SHALL display all their API clients
- **AND** show name, client_id prefix, scopes, last used date, and status
- **AND** provide revoke and delete actions

### Requirement: Authentication Extension Points
The system SHALL provide hooks at key authentication lifecycle events to support future authorization integration (Permit).

#### Scenario: Hook invocation on user creation
- **GIVEN** a new user is created via JIT provisioning
- **WHEN** the user record is saved
- **THEN** the system SHALL invoke the on_user_created hook
- **AND** pass the user struct and authentication source

#### Scenario: Hook invocation on authentication
- **GIVEN** a user successfully authenticates
- **WHEN** the session is established
- **THEN** the system SHALL invoke the on_user_authenticated hook
- **AND** pass the user struct and token claims

#### Scenario: Hook invocation on token generation
- **GIVEN** a token is generated for a user
- **WHEN** the token is encoded
- **THEN** the system SHALL invoke the on_token_generated hook
- **AND** allow the hook to add custom claims (future: Permit context)

## MODIFIED Requirements

### Requirement: Password Authentication
The system SHALL support password-based authentication with secure hashing, using Guardian for token generation instead of AshAuthentication.

#### Scenario: Password login
- **GIVEN** a user with a registered password
- **WHEN** the user submits valid credentials
- **THEN** the system SHALL verify the password using Bcrypt
- **AND** generate a Guardian access token
- **AND** generate a Guardian refresh token
- **AND** create a session

#### Scenario: Password requirements
- **WHEN** a user sets or changes their password
- **THEN** the password MUST be at least 12 characters
- **AND** the password MUST be at most 72 bytes (bcrypt limit)

#### Scenario: Password reset flow
- **GIVEN** a user requests a password reset
- **WHEN** the request is submitted with a valid email
- **THEN** the system SHALL generate a Guardian reset token
- **AND** send an email via Swoosh with the reset link
- **AND** the token SHALL expire after 15 minutes

### Requirement: Session Management
The system SHALL manage user sessions with configurable expiration and logout capabilities, supporting both local and SSO-initiated sessions via Guardian tokens.

#### Scenario: Session expiration
- **GIVEN** a user access token older than 1 hour
- **WHEN** the user makes an authenticated request
- **THEN** the system SHALL reject the request
- **AND** allow refresh if a valid refresh token exists

#### Scenario: Refresh token expiration
- **GIVEN** a user refresh token older than 30 days
- **WHEN** the user attempts to refresh their session
- **THEN** the system SHALL reject the request
- **AND** require re-authentication

#### Scenario: Logout
- **WHEN** a user logs out
- **THEN** the system SHALL invalidate the current tokens
- **AND** remove the session cookie
- **AND** broadcast disconnect to LiveView sockets

#### Scenario: SSO session logout
- **GIVEN** a user authenticated via SSO
- **WHEN** the user logs out
- **THEN** the system SHALL invalidate the local session
- **AND** optionally redirect to the IdP's logout endpoint if SLO is configured

#### Scenario: Gateway session context
- **GIVEN** a request authenticated via gateway JWT
- **WHEN** the request is processed
- **THEN** the system SHALL NOT create a persistent session cookie
- **AND** authentication context SHALL be request-scoped only

### Requirement: API Token Authentication
The system SHALL support Bearer token authentication for API requests, accepting both Guardian session tokens and OAuth2 client credential tokens.

#### Scenario: Bearer token authentication
- **GIVEN** a valid Guardian token
- **WHEN** a request includes the token in the Authorization header
- **THEN** the system SHALL decode and verify the token
- **AND** authenticate the request as the token's subject
- **AND** enforce the token's scope restrictions

#### Scenario: Client credentials token authentication
- **GIVEN** a token issued via client credentials grant
- **WHEN** a request includes the token in the Authorization header
- **THEN** the system SHALL verify the token
- **AND** authenticate the request as the client's owner
- **AND** restrict access to the client's allowed scopes

#### Scenario: Legacy API key authentication
- **GIVEN** an API key in the X-API-Key header
- **WHEN** the request is processed
- **THEN** the system SHALL verify the key against stored hashes
- **AND** authenticate the request if valid
- **AND** record usage statistics

## REMOVED Requirements

### Requirement: Magic Link Email Authentication
**Reason**: Replaced by password authentication with SSO options. Magic links add complexity without significant benefit given enterprise SSO support.
**Migration**: Users authenticate via password or configured SSO provider.

### Requirement: Migration from Phoenix.gen.auth
**Reason**: Migration completed; no longer relevant. System now uses Guardian-based authentication.
**Migration**: N/A - historical requirement.
