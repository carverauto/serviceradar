defmodule ServiceRadarWebNG.Authorization.Permissions do
  @moduledoc false

  use Permit.Permissions, actions_module: ServiceRadarWebNG.Authorization.Actions

  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.User

  @impl true
  def can(%User{role: :admin}) do
    permit()
    |> all(User)
    |> all(AuthSettings)
    |> all(AuthorizationSettings)
  end

  def can(_), do: permit()
end
