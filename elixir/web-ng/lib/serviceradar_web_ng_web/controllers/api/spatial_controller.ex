defmodule ServiceRadarWebNGWeb.Api.SpatialController do
  use ServiceRadarWebNGWeb, :controller

  import Ecto.Query

  alias ServiceRadar.Spatial.SurveySample
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  def index(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view") do
      # Fetch all SurveySample records and map them to a JSON-friendly format.
      # A realistic implementation might paginate or filter by session_id,
      # but we dump the ingested data for the Deck.GL frontend to aggregate.
      query =
        from s in SurveySample,
          select: %{
            id: s.id,
            session_id: s.session_id,
            bssid: s.bssid,
            ssid: s.ssid,
            rssi: s.rssi,
            frequency: s.frequency,
            x: s.x,
            y: s.y,
            z: s.z,
            latitude: s.latitude,
            longitude: s.longitude,
            timestamp: s.timestamp
          },
          limit: 10_000

      samples = ServiceRadar.Repo.all(query)
      json(conn, %{data: samples})
    end
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        :ok

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]

    if RBAC.can?(scope, permission) do
      :ok
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden"})
      |> halt()
    end
  end
end
