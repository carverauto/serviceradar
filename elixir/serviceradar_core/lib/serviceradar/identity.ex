defmodule ServiceRadar.Identity do
  @moduledoc """
  The Identity domain manages users, authentication, and authorization.

  This domain is responsible for:
  - User management and profiles
  - Authentication (password, OAuth2)
  - API token management
  - Session management

  ## Resources

  - `ServiceRadar.Identity.User` - User accounts
  - `ServiceRadar.Identity.ApiToken` - API tokens for programmatic access

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
