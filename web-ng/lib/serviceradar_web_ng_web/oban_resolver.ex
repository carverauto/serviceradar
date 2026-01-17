defmodule ServiceRadarWebNGWeb.ObanResolver do
  @moduledoc """
  Resolver for Oban Web dashboard authentication and authorization.

  This is a tenant instance UI - each instance serves ONE tenant.
  Access is controlled by user role only - no multi-tenant logic needed.
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

  # Admin users can access Oban dashboard
  defp admin_access?(%{user: %{role: role}}) when role in [:admin], do: true
  defp admin_access?(_), do: false
end
