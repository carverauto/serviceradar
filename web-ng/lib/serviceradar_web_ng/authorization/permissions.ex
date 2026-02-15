defmodule ServiceRadarWebNG.Authorization.Permissions do
  @moduledoc false

  use Permit.Permissions, actions_module: ServiceRadarWebNG.Authorization.Actions

  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.RBAC, as: RBACCore
  alias ServiceRadar.Software.SoftwareImage
  alias ServiceRadar.Software.StorageConfig
  alias ServiceRadar.Software.TftpSession

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
        permissions
        |> all(RoleProfile)

      "settings.software.manage" ->
        permissions
        |> all(SoftwareImage)
        |> all(StorageConfig)
        |> all(TftpSession)

      "settings.software.view" ->
        permissions
        |> read(SoftwareImage)
        |> read(StorageConfig)
        |> read(TftpSession)

      _ ->
        permissions
    end
  end
end
