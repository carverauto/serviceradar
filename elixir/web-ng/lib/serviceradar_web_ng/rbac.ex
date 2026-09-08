defmodule ServiceRadarWebNG.RBAC do
  @moduledoc """
  RBAC helpers for web-ng UI and API.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Accounts],
    exports: :all

  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Identity.RBAC, as: CoreRBAC
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope

  def catalog do
    CoreRBAC.catalog()
  end

  def permissions_for_scope(%Scope{permissions: %MapSet{} = permissions}) do
    permissions
  end

  def permissions_for_scope(%Scope{user: user}) do
    CoreRBAC.permissions_for_user(user)
  end

  def permissions_for_scope(_), do: MapSet.new()

  def can?(%Scope{user: %User{}, permissions: %MapSet{} = permissions}, permission) when is_binary(permission) do
    CoreRBAC.Catalog.holds?(permissions, permission)
  end

  def can?(%Scope{user: user, permissions: %MapSet{} = permissions}, permission)
      when not is_nil(user) and is_binary(permission) do
    CoreRBAC.Catalog.holds?(permissions, permission)
  end

  def can?(%Scope{permissions: %MapSet{} = permissions}, permission) when is_binary(permission) do
    CoreRBAC.Catalog.holds?(permissions, permission)
  end

  def can?(%Scope{user: user}, permission) when is_binary(permission) do
    CoreRBAC.has_permission?(user, permission)
  end

  def can?(_, _), do: false

  def can_any?(scope, permissions) when is_list(permissions) do
    Enum.any?(permissions, &can?(scope, &1))
  end

  def can_any?(_scope, _permissions), do: false

  @doc """
  Rebuilds a logged-in user's current authority before a sensitive action.

  The scope's cached permissions are never used as evidence. Identity claims
  remain tied to the authenticated browser session while the user and
  permission set are replaced with their current persisted values.
  """
  def authorize_current(%Scope{} = scope, permissions) do
    case CurrentUserAuthority.authorize(scope, permissions) do
      {:ok, %{user: user, permissions: current_permissions}} ->
        {:ok, %{scope | user: user, permissions: current_permissions}}

      _ ->
        {:error, :permission_revoked}
    end
  end

  def authorize_current(_scope, _permissions), do: {:error, :permission_revoked}

  def authorize_current_any(%Scope{} = scope, permissions) when is_list(permissions) do
    Enum.reduce_while(permissions, {:error, :permission_revoked}, fn permission, _denied ->
      case authorize_current(scope, [permission]) do
        {:ok, refreshed_scope} -> {:halt, {:ok, refreshed_scope}}
        _ -> {:cont, {:error, :permission_revoked}}
      end
    end)
  end

  def authorize_current_any(_scope, _permissions), do: {:error, :permission_revoked}
end
