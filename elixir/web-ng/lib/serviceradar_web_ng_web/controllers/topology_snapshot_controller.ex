defmodule ServiceRadarWebNGWeb.TopologySnapshotController do
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.AtlasReader
  alias ServiceRadarWebNG.Topology.AtlasRequest
  alias ServiceRadarWebNGWeb.FeatureFlags

  def revisions(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if FeatureFlags.god_view_enabled?() do
      with :ok <- require_authenticated(conn),
           {:ok, conn} <- require_permission(conn, "analytics.view"),
           {:ok, level_ids} <- AtlasRequest.parse_levels(params),
           {:ok, revisions} <- AtlasReader.revisions(conn.assigns.current_scope, level_ids) do
        json(conn, revisions)
      else
        %Plug.Conn{} = conn -> conn
        {:error, reason} -> atlas_error(conn, reason)
      end
    else
      atlas_error(conn, :god_view_disabled)
    end
  end

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

  defp atlas_error(conn, reason) do
    {status, body} = AtlasRequest.error_response(reason)
    conn = if status == 503, do: put_resp_header(conn, "retry-after", "1"), else: conn
    conn |> put_status(status) |> json(body)
  end
end
