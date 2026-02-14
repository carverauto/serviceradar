defmodule ServiceRadarWebNGWeb.TopologyChannel do
  use Phoenix.Channel

  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNGWeb.FeatureFlags

  @tick_ms 5_000

  @impl true
  def join("topology:god_view", _payload, socket) do
    if FeatureFlags.god_view_enabled?() do
      send(self(), :tick)
      {:ok, socket}
    else
      {:error, %{reason: "god_view_disabled"}}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    socket =
      case GodViewStream.latest_snapshot() do
        {:ok, %{snapshot: snapshot, payload: payload}} ->
          push(socket, "snapshot", %{
            encoding: "arrow_ipc_file_base64",
            payload: Base.encode64(payload),
            schema_version: snapshot.schema_version,
            revision: snapshot.revision,
            generated_at: DateTime.to_iso8601(snapshot.generated_at)
          })

          socket

        {:error, reason} ->
          push(socket, "snapshot_error", %{reason: inspect(reason)})
          socket
      end

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, socket}
  end
end
