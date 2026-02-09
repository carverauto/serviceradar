defmodule ServiceRadarWebNG.RBAC do
  @moduledoc """
  RBAC helpers for web-ng UI and API.
  """

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNG.Accounts.Scope

  def catalog do
    RBAC.catalog()
  end

  def permissions_for_scope(%Scope{permissions: permissions}) when is_list(permissions) do
    permissions
  end

  def permissions_for_scope(%Scope{user: user}) do
    RBAC.permissions_for_user(user)
  end

  def permissions_for_scope(_), do: []

  def can?(%Scope{permissions: permissions}, permission)
      when is_list(permissions) and is_binary(permission) do
    permission in permissions
  end

  def can?(%Scope{user: user}, permission) when is_binary(permission) do
    RBAC.has_permission?(user, permission)
  end

  def can?(_, _), do: false
end
