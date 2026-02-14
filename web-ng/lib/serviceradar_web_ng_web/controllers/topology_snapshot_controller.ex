defmodule ServiceRadarWebNGWeb.TopologySnapshotController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNGWeb.FeatureFlags

  def show(conn, _params) do
    if FeatureFlags.god_view_enabled?() do
      case GodViewStream.latest_snapshot() do
        {:ok, %{snapshot: snapshot, payload: payload}} ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("x-sr-god-view-schema", Integer.to_string(snapshot.schema_version))
          |> put_resp_header("x-sr-god-view-revision", Integer.to_string(snapshot.revision))
          |> put_resp_header("x-sr-god-view-generated-at", DateTime.to_iso8601(snapshot.generated_at))
          |> send_resp(200, payload)

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "snapshot_build_failed", reason: inspect(reason)})
      end
    else
      send_resp(conn, :not_found, "Not Found")
    end
  end
end
