defmodule ServiceRadarWebNG.Api.SpatialController do
  use ServiceRadarWebNGWeb, :controller
  import Ecto.Query

  alias ServiceRadar.Spatial.SurveySample

  def index(conn, _params) do
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
