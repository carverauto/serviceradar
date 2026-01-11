defmodule ServiceRadar.Identity do
  @moduledoc """
  The Identity domain manages users, tenants, authentication, and authorization.

  This domain is responsible for:
  - User management and profiles
  - Tenant management for multi-tenancy
  - Authentication (password, magic link, OAuth2)
  - API token management
  - Session management

  ## Resources

  - `ServiceRadar.Identity.User` - User accounts
  - `ServiceRadar.Identity.Tenant` - Tenant organizations
  - `ServiceRadar.Identity.ApiToken` - API tokens for programmatic access

  ## Authorization

  All resources in this domain enforce tenant isolation via policies.
  The `super_user` role can bypass tenant restrictions for admin operations.
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
    resource ServiceRadar.Identity.Tenant
    resource ServiceRadar.Identity.TenantMembership
    resource ServiceRadar.Identity.Token
    resource ServiceRadar.Identity.ApiToken
    resource ServiceRadar.Identity.DeviceAliasState
  end

  authorization do
    # Don't globally require actor since AshAuthentication hooks may make
    # internal calls without actor. Authorization is still enforced via policies.
    require_actor? false
    authorize :by_default
  end
end
