defmodule ServiceRadar.Identity do
  @moduledoc """
  The Identity domain manages users, authentication, and authorization.

  This domain is responsible for:
  - User management and profiles
  - Authentication (password, OIDC, SAML, Gateway JWT)
  - API token management via OAuth2 client credentials
  - Session management via Guardian JWT

  ## Resources

  - `ServiceRadar.Identity.User` - User accounts
  - `ServiceRadar.Identity.ApiToken` - API tokens for programmatic access
  - `ServiceRadar.Identity.OAuthClient` - OAuth2 client credentials for self-service API access
  - `ServiceRadar.Identity.AuthSettings` - Instance-level SSO configuration
  - `ServiceRadar.Identity.AuthorizationSettings` - Default role and role mapping configuration

  ## Authentication

  Authentication is handled by Guardian (JWT tokens) and Ueberauth (OIDC/SAML).
  See `ServiceRadarWebNG.Auth.Guardian` for token management.

  ## Authorization

  All resources in this domain enforce authorization via policies.
  """

  use Ash.Domain,
    extensions: [
      # AshJsonApi.Domain,
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Identity.User
    resource ServiceRadar.Identity.RoleProfile
    resource ServiceRadar.Identity.ApiToken
    resource ServiceRadar.Identity.OAuthClient
    resource ServiceRadar.Identity.DeviceAliasState
    resource ServiceRadar.Identity.AuthSettings
    resource ServiceRadar.Identity.AuthorizationSettings
  end

  authorization do
    # Don't globally require actor since internal system operations may need
    # to run without an actor. Authorization is still enforced via policies.
    require_actor? false
    authorize :by_default
  end
end
