# Change: Add Enterprise SSO Authentication (OIDC, SAML, Proxy JWT)

## Why
Currently, the application relies on a single bootstrapped admin user with password authentication via AshAuthentication. Enterprise customers require the ability to configure their organization's Identity Provider (IdP) through the UI, enabling users to log in via corporate credentials. Additionally, users need self-service API credential management for programmatic access. This is the authentication phase of a larger auth/authz initiative (#2541).

## What Changes

### Major: Replace AshAuthentication with Guardian + Ueberauth
AshAuthentication was not designed to coexist with Ueberauth/Guardian and creates conflicts:
- Two JWT systems with different signing/verification
- Conflicting session management patterns
- AshAuthentication expects compile-time config; we need runtime configuration
- Token lifecycle confusion (which system issued this token?)

**Migration approach:**
- Remove `AshAuthentication` extension from User resource
- Replace `AshAuthentication.Jwt` with Guardian for all token operations
- Replace `AshAuthentication.Phoenix.Controller` with Guardian plugs + Ueberauth callbacks
- Keep password hashing (Bcrypt), email flows (Swoosh) - just rewire token generation
- Replace auth route macros with explicit routes

### New Capabilities
- **Database Schema**: Add `auth_settings` table for instance-specific SSO configuration
- **Multi-Mode Authentication**: Support "Active SSO" (OIDC/SAML) and "Passive Proxy" (gateway JWT)
- **Runtime Configuration**: Dynamic config loading for Ueberauth strategies from database
- **JIT User Provisioning**: Auto-create users on first SSO login with claim mapping
- **User Self-Service API Credentials**: OAuth2 client credentials flow for programmatic access
- **Admin Configuration UI**: LiveView settings for auth configuration
- **Login Flow Updates**: "Enterprise Login" button, mode-aware routing

### Key Architectural Decisions
- **Guardian**: Single source of truth for all JWT operations (user sessions, API tokens, refresh)
- **Ueberauth**: All external IdP strategies (OIDC, SAML, OAuth2 providers)
- **User/Token Ash Resources**: Keep as data layer, remove AshAuthentication DSL
- **Cloak**: Encrypted storage for client secrets and IdP credentials
- **Permit hooks**: Extension points for future authorization integration

## Impact
- Affected specs: `ash-authentication` (significant modification)
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/identity/user.ex` - Remove AshAuthentication extension
  - `elixir/serviceradar_core/lib/serviceradar/identity/token.ex` - Repurpose for Guardian
  - `web-ng/lib/serviceradar_web_ng_web/controllers/auth_controller.ex` - Complete rewrite
  - `web-ng/lib/serviceradar_web_ng_web/user_auth.ex` - Replace token verification
  - `web-ng/lib/serviceradar_web_ng_web/plugs/api_auth.ex` - Use Guardian verification
  - `web-ng/lib/serviceradar_web_ng_web/router.ex` - Replace auth route macros
  - New: `auth_settings` resource, SSO controllers, user settings UI
- **BREAKING**: Internal token format changes (existing sessions invalidated on deploy)
- **Security**: Requires careful handling of encrypted credentials and SAML signature validation

## Related Issues
- GitHub Issue #2542 (Authentication - this change)
- GitHub Issue #2541 (Parent: Auth + AuthZ initiative)
- Future: Permit authorization integration (separate change)
