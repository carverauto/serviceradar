defmodule ServiceRadarWebNGWeb.ObanResolver do
  @moduledoc """
  Resolver for Oban Web dashboard authentication and authorization.

  This is a single-deployment UI.
  Access is controlled by RBAC permission keys.
  """

  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_user(conn) do
    Map.get(conn.assigns, :current_scope)
  end

  @impl true
  def resolve_access(scope) do
    if admin_access?(scope), do: :all, else: {:forbidden, "/analytics"}
  end

  @impl true
  def resolve_instances(_user), do: :all

  @impl true
  def resolve_refresh(_user), do: 5

  defp admin_access?(%{user: _} = scope), do: ServiceRadarWebNG.RBAC.can?(scope, "settings.jobs.manage")

  defp admin_access?(_), do: false
end
