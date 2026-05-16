defmodule ServiceRadarWebNG.RBAC do
  @moduledoc """
  RBAC helpers for web-ng UI and API.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Accounts],
    exports: :all

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNG.Accounts.Scope

  def catalog do
    RBAC.catalog()
  end

  def permissions_for_scope(%Scope{permissions: %MapSet{} = permissions}) do
    permissions
  end

  def permissions_for_scope(%Scope{user: user}) do
    RBAC.permissions_for_user(user)
  end

  def permissions_for_scope(_), do: MapSet.new()

  def can?(%Scope{permissions: %MapSet{} = permissions}, permission) when is_binary(permission) do
    MapSet.member?(permissions, permission)
  end

  def can?(%Scope{user: user}, permission) when is_binary(permission) do
    RBAC.has_permission?(user, permission)
  end

  def can?(_, _), do: false

  def can_any?(scope, permissions) when is_list(permissions) do
    Enum.any?(permissions, &can?(scope, &1))
  end

  def can_any?(_scope, _permissions), do: false
end
