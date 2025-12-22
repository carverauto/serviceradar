defmodule ServiceRadarWebNGWeb.ObanResolver do
  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_user(conn) do
    Map.get(conn.assigns, :current_scope)
  end

  @impl true
  def resolve_access(_user), do: :all

  @impl true
  def resolve_instances(_user), do: :all

  @impl true
  def resolve_refresh(_user), do: 5
end
