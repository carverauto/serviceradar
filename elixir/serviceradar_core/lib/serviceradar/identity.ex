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
    show? true
  end

  authorization do
    require_actor? true
    authorize :by_default
  end

  resources do
    resource ServiceRadar.Identity.User
    resource ServiceRadar.Identity.Tenant
    resource ServiceRadar.Identity.Token
    resource ServiceRadar.Identity.ApiToken
  end
end
