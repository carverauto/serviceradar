## Context

ServiceRadar currently uses AshAuthentication for password-based login with JWT sessions. This library was designed for simpler use cases and doesn't integrate well with enterprise SSO requirements:

1. **Compile-time configuration** - Ueberauth strategies need runtime config from database
2. **Closed JWT system** - AshAuthentication.Jwt doesn't expose hooks for custom claims or validation
3. **No OAuth2 server capabilities** - Users can't generate client credentials for API access
4. **Strategy conflicts** - Running AshAuthentication alongside Ueberauth creates two token systems

### Stakeholders
- Instance admins configuring SSO
- End users authenticating via corporate credentials
- Developers needing API credentials for automation
- API consumers using gateway-issued tokens
- Platform operators managing deployments

### Constraints
- Must migrate existing users without data loss
- Existing sessions will be invalidated (acceptable for security improvement)
- Single-tenant per instance model
- Permit integration planned for authorization (design hooks now)

## Goals / Non-Goals

### Goals
- Replace AshAuthentication with Guardian + Ueberauth cleanly
- Enable OIDC authentication (Google, Azure AD, Okta, generic)
- Enable SAML 2.0 authentication for enterprise IdPs
- Support passive JWT validation for gateway-proxied deployments
- User self-service API credential management (OAuth2 client credentials)
- Admin UI for SSO configuration without restart
- JIT user provisioning on first SSO login
- Maintain backdoor admin access to prevent lockouts
- Design extension points for Permit authorization

### Non-Goals
- Multi-IdP per instance (single provider at a time)
- SCIM user provisioning
- Group/role sync from IdP claims (future, ties into Permit)
- Authorization policy changes (separate Permit change)
- LDAP direct integration (use OIDC/SAML bridge)

## Decisions

### Decision 1: Replace AshAuthentication with Guardian + Ueberauth

**Choice**: Complete replacement, not coexistence

**What changes:**

| Component | AshAuthentication | Guardian + Ueberauth |
|-----------|-------------------|----------------------|
| JWT signing | `AshAuthentication.Jwt.token_for_user/2` | `Guardian.encode_and_sign/3` |
| JWT verification | `AshAuthentication.Jwt.verify/2` | `Guardian.decode_and_verify/2` |
| Password auth | Built-in strategy | Custom plug + Bcrypt (keep existing hashing) |
| OAuth/OIDC | Limited | Ueberauth strategies (full ecosystem) |
| SAML | Not supported | `ueberauth_saml` / `samly` |
| Session management | Implicit | Explicit Guardian pipelines |
| Token storage | `AshAuthentication.TokenResource` | Custom Token resource with Guardian claims |
| Route generation | `auth_routes/3` macro | Explicit routes |

**Migration steps:**
1. Add Guardian and Ueberauth dependencies
2. Create Guardian implementation module
3. Create new auth controller with Guardian/Ueberauth callbacks
4. Update router with explicit routes
5. Migrate `user_auth.ex` to use Guardian verification
6. Remove AshAuthentication extension from User resource
7. Repurpose Token resource for Guardian tokens
8. Update API auth plug

**Rationale:**
- Single JWT system eliminates token confusion
- Guardian provides hooks for custom claims (Permit context)
- Ueberauth has mature OIDC/SAML support
- Runtime configuration is natural with Ueberauth
- Cleaner separation of concerns

### Decision 2: User Self-Service API Credentials

**Choice**: OAuth2 client credentials flow with user-scoped clients

**Data model:**
```elixir
# New resource: ServiceRadar.Identity.OAuthClient
defmodule ServiceRadar.Identity.OAuthClient do
  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :client_id, :string, allow_nil?: false  # Generated UUID
    attribute :client_secret_hash, :string, allow_nil?: false  # Bcrypt
    attribute :client_secret_prefix, :string  # First 8 chars for lookup
    attribute :scopes, {:array, :atom}, default: [:read]  # [:read, :write, :admin]
    attribute :expires_at, :utc_datetime  # Optional expiration
    attribute :revoked_at, :utc_datetime
    attribute :last_used_at, :utc_datetime
    attribute :last_used_ip, :string
    timestamps()
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User, allow_nil?: false
  end
end
```

**Token exchange flow:**
```
POST /oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=<uuid>
&client_secret=<secret>
&scope=read write

Response:
{
  "access_token": "<jwt>",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "read write"
}
```

**User Settings UI:**
- List existing API clients
- Create new client (shows secret once)
- Revoke/delete clients
- View usage stats (last used, IP)

**Rationale:**
- Standard OAuth2 pattern familiar to developers
- Client credentials separate from user password
- Scoped access (read/write/admin)
- Audit trail via usage tracking
- Future: Permit can check client scopes

### Decision 3: Multi-Mode Authentication Architecture

**Choice**: Three authentication modes stored in `auth_settings.mode`

| Mode | Description | Token Source | Login UI |
|------|-------------|--------------|----------|
| `password_only` | Default | Guardian session token | Password form |
| `active_sso` | Direct IdP | Guardian after OIDC/SAML callback | "Enterprise Login" button |
| `passive_proxy` | Gateway JWT | Validated upstream JWT | Hidden (gateway handles) |

**Mode determines:**
- Which plugs are active in the pipeline
- What the login page displays
- How tokens are verified (Guardian vs external JWKS)

### Decision 4: Runtime Configuration Architecture

**Choice**: Config fetcher with ETS cache and PubSub invalidation

```elixir
defmodule ServiceRadarWebNG.Auth.ConfigCache do
  use GenServer

  # Cache auth_settings with 60s TTL
  # Subscribe to PubSub for immediate invalidation on admin save
  # Provides get_config/0 for plugs and controllers

  def get_config do
    case :ets.lookup(@table, :auth_settings) do
      [{:auth_settings, settings, expires_at}] when expires_at > now() ->
        {:ok, settings}
      _ ->
        refresh_and_return()
    end
  end
end
```

**Ueberauth dynamic config:**
```elixir
# In controller before Ueberauth callback
def request(conn, %{"provider" => provider}) do
  config = ConfigCache.get_config!()

  conn
  |> put_private(:ueberauth_request_options, build_options(config, provider))
  |> Ueberauth.run_request(provider)
end
```

### Decision 5: Guardian Token Architecture

**Choice**: Unified token format with type discrimination

```elixir
defmodule ServiceRadarWebNG.Auth.Guardian do
  use Guardian, otp_app: :serviceradar_web_ng

  # Token types:
  # - "access" - short-lived session token (1 hour)
  # - "refresh" - long-lived refresh token (30 days)
  # - "api" - client credentials token (configurable)

  def subject_for_token(%User{} = user, _claims) do
    {:ok, "user:#{user.id}"}
  end

  def resource_from_claims(%{"sub" => "user:" <> id}) do
    case Identity.get_user(id) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, :user_not_found}
    end
  end

  # Custom claims for Permit integration point
  def build_claims(claims, _resource, opts) do
    claims
    |> Map.put("type", Keyword.get(opts, :token_type, "access"))
    |> Map.put("scopes", Keyword.get(opts, :scopes, []))
    # Future: |> add_permit_context(resource)
  end
end
```

### Decision 6: Permit Integration Points

**Choice**: Behaviour-based hooks called at auth lifecycle events

```elixir
defmodule ServiceRadarWebNG.Auth.Hooks do
  @callback on_user_created(user :: User.t(), source :: atom()) :: :ok
  @callback on_user_authenticated(user :: User.t(), claims :: map()) :: :ok
  @callback on_token_generated(user :: User.t(), token :: String.t(), claims :: map()) :: :ok
end

# Default implementation (no-op until Permit change)
defmodule ServiceRadarWebNG.Auth.DefaultHooks do
  @behaviour ServiceRadarWebNG.Auth.Hooks

  def on_user_created(_user, _source), do: :ok
  def on_user_authenticated(_user, _claims), do: :ok
  def on_token_generated(_user, _token, _claims), do: :ok
end

# Future Permit implementation will:
# - Sync user to Permit PDP on creation
# - Enrich claims with Permit roles/permissions
# - Log authentication events to Permit audit
```

### Decision 7: Credential Encryption

**Choice**: Cloak for all sensitive fields

**Encrypted fields:**
- `auth_settings.oidc_client_secret`
- `auth_settings.saml_private_key`
- `oauth_clients.client_secret_hash` (Bcrypt, not Cloak - for verification)

**Note**: JWT public keys (for proxy mode) stored as PEM text, not encrypted (not secret).

### Decision 8: Fallback Admin Access

**Choice**: `/auth/local` always available

- Independent of `auth_settings.mode`
- Displays password form regardless of SSO config
- Rate limited (5 attempts per IP per minute)
- Audit logged with special flag
- Only shown in UI when SSO is misconfigured or via direct URL

## Data Model

### auth_settings Table

```sql
CREATE TABLE platform.auth_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Mode selection
  mode VARCHAR(20) NOT NULL DEFAULT 'password_only',
    -- 'password_only' | 'active_sso' | 'passive_proxy'

  -- Provider type (when mode = active_sso)
  provider_type VARCHAR(20),  -- 'oidc' | 'saml'

  -- OIDC Configuration
  oidc_client_id VARCHAR(255),
  oidc_client_secret_encrypted BYTEA,
  oidc_discovery_url VARCHAR(500),
  oidc_scopes VARCHAR(255) DEFAULT 'openid email profile',

  -- SAML Configuration
  saml_idp_metadata_url VARCHAR(500),
  saml_idp_metadata_xml TEXT,
  saml_sp_entity_id VARCHAR(255),
  saml_private_key_encrypted BYTEA,

  -- Proxy JWT Configuration
  jwt_public_key_pem TEXT,
  jwt_issuer VARCHAR(255),
  jwt_audience VARCHAR(255),
  jwt_header_name VARCHAR(100) DEFAULT 'Authorization',

  -- Claim mappings (JSON)
  claim_mappings JSONB DEFAULT '{"email": "email", "name": "name", "sub": "sub"}',

  -- Feature flags
  is_enabled BOOLEAN DEFAULT false,
  allow_password_fallback BOOLEAN DEFAULT true,

  -- Audit
  inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Singleton constraint
CREATE UNIQUE INDEX auth_settings_singleton ON platform.auth_settings ((true));
```

### oauth_clients Table

```sql
CREATE TABLE platform.oauth_clients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES platform.ng_users(id) ON DELETE CASCADE,

  name VARCHAR(255) NOT NULL,
  client_id UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  client_secret_hash VARCHAR(255) NOT NULL,  -- Bcrypt
  client_secret_prefix VARCHAR(8) NOT NULL,  -- For display/lookup

  scopes VARCHAR(50)[] NOT NULL DEFAULT ARRAY['read'],
  expires_at TIMESTAMP,
  revoked_at TIMESTAMP,

  last_used_at TIMESTAMP,
  last_used_ip INET,
  use_count INTEGER DEFAULT 0,

  inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX oauth_clients_user_id ON platform.oauth_clients(user_id);
CREATE INDEX oauth_clients_client_id ON platform.oauth_clients(client_id);
```

## Risks / Trade-offs

| Risk | Impact | Mitigation |
|------|--------|------------|
| AshAuthentication removal breaks existing sessions | Medium | Announce maintenance window; sessions re-authenticate |
| SAML XML vulnerabilities | High | Use samly with strict signature validation; security review |
| Complex migration | Medium | Feature flags; incremental rollout; thorough testing |
| Guardian learning curve | Low | Well-documented; team familiar with JWT concepts |
| Two token verification paths (Guardian vs proxy JWKS) | Medium | Clear mode separation; extensive tests |

## Migration Plan

### Phase 1: Guardian Foundation (No user impact)
1. Add Guardian, Ueberauth dependencies
2. Create Guardian implementation module
3. Create new auth controller (not routed yet)
4. Create config cache GenServer
5. Add auth_settings migration

### Phase 2: Password Auth Migration
1. Create Guardian-based password auth flow
2. Update router with new auth routes (parallel to old)
3. Feature flag to switch between old/new
4. Test password login with Guardian tokens
5. Migrate user_auth.ex verification to Guardian

### Phase 3: Remove AshAuthentication
1. Remove AshAuthentication extension from User
2. Remove old auth routes
3. Remove AshAuthentication dependencies
4. Clean up Token resource

### Phase 4: OIDC Integration
1. Add ueberauth_oidcc
2. Implement dynamic OIDC strategy
3. Create callback controller
4. Build admin UI for OIDC config
5. Test with Google, Azure AD, Okta

### Phase 5: SAML Integration
1. Add samly/ueberauth_saml
2. Implement SAML strategy
3. Create ACS and metadata endpoints
4. Build admin UI for SAML config
5. Security review of XML handling

### Phase 6: Proxy JWT Support
1. Create gateway auth plug
2. Implement JWKS verification
3. Build admin UI for proxy config
4. Test with Kong configuration

### Phase 7: User API Credentials
1. Add oauth_clients migration
2. Create OAuthClient resource
3. Implement /oauth/token endpoint
4. Build user settings UI
5. Update API auth plug

### Phase 8: Polish
1. Comprehensive E2E tests
2. Documentation and runbooks
3. Security audit
4. Performance testing (token verification latency)

### Rollback
- Phase 1-2: Feature flag reverts to AshAuthentication
- Phase 3+: Requires code rollback (plan maintenance window)
- Data migrations are additive (no destructive changes)

## Open Questions

1. **Token lifetimes**: Should OIDC/SAML sessions have different lifetimes than password?
   - Propose: Configurable per mode, default 1 hour access / 30 day refresh

2. **Refresh tokens**: Should we implement refresh token rotation?
   - Propose: Yes, for security; old refresh token invalidated on use

3. **Client credential limits**: Max clients per user?
   - Propose: 10 per user, configurable

4. **PKCE for OIDC**: Required or optional?
   - Propose: Required for public clients, optional for confidential

5. **Permit SDK**: Which library for Elixir integration?
   - Research needed: https://permit.curiosum.com/
   - Decision deferred to authorization change
