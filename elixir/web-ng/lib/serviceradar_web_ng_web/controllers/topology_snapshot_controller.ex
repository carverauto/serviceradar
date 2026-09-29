defmodule ServiceRadarWebNGWeb.TopologySnapshotController do
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  # The former whole-graph URL now serves an explicitly selected detail page.
  # The world overview is fetched through /topology/tiles.
  def show(conn, params) do
    with :ok <- require_authenticated(conn),
         {:ok, conn} <- require_permission(conn, "analytics.view") do
      ServiceRadarWebNGWeb.TopologyTileController.scene(conn, params)
    else
      %Plug.Conn{} = conn -> conn
    end
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"}) |> halt()
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]

    case RBAC.authorize_current(scope, [permission]) do
      {:ok, current_scope} -> {:ok, assign(conn, :current_scope, current_scope)}
      {:error, _reason} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"}) |> halt()
    end
  end
end
