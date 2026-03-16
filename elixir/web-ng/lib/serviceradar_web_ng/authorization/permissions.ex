defmodule ServiceRadarWebNG.Authorization.Permissions do
  @moduledoc false

  use Permit.Permissions, actions_module: ServiceRadarWebNGWeb.Authorization.Actions

  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.RBAC, as: RBACCore
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User

  @impl true
  def can(%User{} = user) do
    user
    |> RBACCore.permissions_for_user()
    |> Enum.reduce(permit(), &grant_permission/2)
  end

  def can(_), do: permit()

  defp grant_permission(permission, permissions) do
    case permission do
      "settings.auth.manage" ->
        permissions
        |> all(User)
        |> all(AuthSettings)
        |> all(AuthorizationSettings)

      "settings.rbac.manage" ->
        all(permissions, RoleProfile)

      _ ->
        permissions
    end
  end
end
