## 1. Guardian Foundation

- [x] 1.1 Add guardian, ueberauth, ueberauth_oidcc dependencies to web-ng mix.exs
- [x] 1.2 Create `ServiceRadarWebNGWeb.Auth.Guardian` module with token encoding/decoding
- [x] 1.3 Create `ServiceRadarWebNGWeb.Auth.Pipeline` plug pipeline for Guardian
- [x] 1.4 Create `ServiceRadarWebNGWeb.Auth.ErrorHandler` for auth failures
- [x] 1.5 Create `ServiceRadarWebNGWeb.Auth.ConfigCache` GenServer for runtime config
- [x] 1.6 Create auth_settings database migration in platform schema
- [x] 1.7 Create `ServiceRadar.Identity.AuthSettings` Ash resource with Cloak encrypted fields
- [x] 1.8 Create extension point hooks module (`on_user_created`, `on_user_authenticated`, `on_token_generated`)

## 2. Password Auth Migration

- [x] 2.1 Create `ServiceRadarWebNG.Auth.PasswordController` with Guardian token generation
- [x] 2.2 Create password login LiveView component (replace AshAuthentication.Phoenix components)
- [x] 2.3 Implement password verification using existing Bcrypt hashing
- [x] 2.4 Create password reset flow with Guardian tokens (keep Swoosh email integration)
- [x] 2.5 Update `user_auth.ex` to use Guardian.decode_and_verify/2
- [x] 2.6 Update `api_auth.ex` to use Guardian for bearer token verification
- [ ] 2.7 Add feature flag for old/new auth system switching
- [ ] 2.8 Create parallel routes for new auth (test without breaking existing)
- [ ] 2.9 Write tests for Guardian-based password authentication

## 3. Remove AshAuthentication

- [x] 3.1 Remove `AshAuthentication` extension from User resource
- [x] 3.2 Remove `AshAuthentication.TokenResource` extension from Token resource
- [x] 3.3 Repurpose Token resource for Guardian token storage (if needed for revocation)
- [x] 3.4 Remove `AshAuthentication.Phoenix.Controller` behavior from auth controller
- [x] 3.5 Remove `auth_routes/3`, `reset_route/2`, `sign_out_route/2` macros from router
- [x] 3.6 Replace with explicit Guardian/custom routes
- [x] 3.7 Remove `AshAuthentication.Phoenix.Overrides` module
- [x] 3.8 Remove `AshAuthentication.Checks.AshAuthenticationInteraction` policy bypass
- [x] 3.9 Remove ash_authentication and ash_authentication_phoenix from mix.exs
- [x] 3.10 Update email senders to not use AshAuthentication.Sender behavior

## 4. OIDC Integration

- [x] 4.1 Implement dynamic Ueberauth OIDC strategy configuration from auth_settings
- [x] 4.2 Create `ServiceRadarWebNG.Auth.OIDCController` for request/callback handling
- [x] 4.3 Implement OIDC discovery URL fetching and caching
- [x] 4.4 Implement ID token verification (signature, claims, nonce)
- [x] 4.5 Add JIT user provisioning for OIDC-authenticated users
- [ ] 4.6 Create OIDC configuration section in admin UI
- [ ] 4.7 Implement "Test OIDC Configuration" validation
- [x] 4.8 Add routes for OIDC auth (`/auth/oidc`, `/auth/oidc/callback`)
- [ ] 4.9 Write integration tests with mock OIDC provider

## 5. SAML Integration

- [x] 5.1 Add samly or ueberauth_saml dependency
- [x] 5.2 Implement dynamic SAML strategy configuration from auth_settings
- [x] 5.3 Create ACS endpoint at `/auth/saml/consume`
- [x] 5.4 Create SP metadata endpoint at `/auth/saml/metadata`
- [x] 5.5 Implement SAML assertion signature validation
- [x] 5.6 Add JIT user provisioning for SAML-authenticated users
- [x] 5.7 Create SAML configuration section in admin UI
- [x] 5.8 Display ACS URL and Entity ID for IdP configuration
- [ ] 5.9 Security review of XML parsing and signature validation
- [ ] 5.10 Write integration tests with mock SAML IdP

## 6. Proxy JWT (Gateway) Support

- [x] 6.1 Create `ServiceRadarWebNG.Plugs.GatewayAuth` plug
- [x] 6.2 Implement JWT extraction from configurable header
- [x] 6.3 Implement JWKS fetching and caching for signature verification
- [x] 6.4 Implement issuer, audience, and expiration claim validation
- [x] 6.5 Add JIT user provisioning for gateway-authenticated users
- [ ] 6.6 Create proxy JWT configuration section in admin UI
- [x] 6.7 Hide login UI when proxy mode active
- [ ] 6.8 Write integration tests for gateway JWT validation

## 7. User Self-Service API Credentials

- [x] 7.1 Create oauth_clients database migration
- [x] 7.2 Create `ServiceRadar.Identity.OAuthClient` Ash resource
- [x] 7.3 Implement client_id generation (UUID)
- [x] 7.4 Implement client_secret generation and Bcrypt hashing
- [x] 7.5 Create `/oauth/token` endpoint for client credentials grant
- [x] 7.6 Implement scope validation for client credentials tokens
- [x] 7.7 Create User Settings "API Credentials" LiveView page
- [x] 7.8 Build "Create API Client" form (shows secret once)
- [x] 7.9 Build client list with revoke/delete actions
- [x] 7.10 Implement usage tracking (last_used_at, IP, count)
- [x] 7.11 Update API auth plug to accept client credential tokens
- [ ] 7.12 Write tests for OAuth2 client credentials flow

## 8. Login Flow Updates

- [x] 8.1 Create mode-aware login page component
- [x] 8.2 Show "Enterprise Login" button when active_sso mode enabled
- [x] 8.3 Show password form when password_only or fallback enabled
- [x] 8.4 Create local admin backdoor route at `/auth/local`
- [x] 8.5 Implement rate limiting on `/auth/local` (5 attempts/min/IP)
- [x] 8.6 Add auth mode indicator to login page
- [x] 8.7 Show "gateway authentication required" message in proxy mode

## 9. Admin Configuration UI

- [x] 9.1 Create `/settings/authentication` LiveView route
- [x] 9.2 Build mode selector (Password Only / Direct SSO / Gateway Proxy)
- [x] 9.3 Build OIDC config form (Client ID, Secret, Discovery URL, Scopes)
- [x] 9.4 Build SAML config form (Metadata URL/XML, Entity ID, display ACS URL)
- [x] 9.5 Build Proxy JWT config form (Public Key/JWKS URL, Issuer, Audience, Header)
- [x] 9.6 Add claim mapping configuration UI
- [x] 9.7 Implement save with Cloak encryption for sensitive fields
- [x] 9.8 Add enable/disable toggle with confirmation dialog
- [x] 9.9 Implement PubSub broadcast on config change (cache invalidation)

## 10. Security & Validation

- [ ] 10.1 Implement SAML signature validation with certificate pinning
- [ ] 10.2 Add CSRF protection to all auth initiation endpoints
- [ ] 10.3 Implement nonce/state validation for OIDC flow
- [ ] 10.4 Add rate limiting to SSO callback endpoints
- [ ] 10.5 Log all authentication attempts (success/failure) with audit fields
- [ ] 10.6 Validate OIDC discovery URL accessibility before enabling
- [ ] 10.7 Validate SAML metadata XML schema before enabling
- [ ] 10.8 Implement token revocation for compromised sessions

## 11. Testing & Documentation

- [ ] 11.1 Unit tests for Guardian token encoding/decoding
- [ ] 11.2 Unit tests for ConfigCache caching and invalidation
- [ ] 11.3 Unit tests for JIT user provisioning
- [ ] 11.4 Integration tests for password auth flow
- [ ] 11.5 Integration tests for OIDC flow (mock IdP)
- [ ] 11.6 Integration tests for SAML flow (mock IdP)
- [ ] 11.7 Integration tests for gateway JWT validation
- [ ] 11.8 Integration tests for client credentials flow
- [ ] 11.9 E2E tests with real IdPs (Google, Okta) in staging
- [ ] 11.10 Admin documentation for OIDC setup
- [ ] 11.11 Admin documentation for SAML setup
- [ ] 11.12 Admin documentation for Kong/gateway setup
- [ ] 11.13 Developer documentation for API credential usage
- [ ] 11.14 Troubleshooting runbook for SSO issues
