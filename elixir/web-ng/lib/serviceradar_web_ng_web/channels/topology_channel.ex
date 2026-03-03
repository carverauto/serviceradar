defmodule ServiceRadarWebNGWeb.TopologyChannel do
  @moduledoc false
  use Phoenix.Channel

  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNGWeb.FeatureFlags

  require Logger

  @tick_ms 5_000
  @binary_magic "GVB1"

  @impl true
  def join("topology:god_view", _payload, socket) do
    cond do
      !Map.has_key?(socket.assigns, :current_user) ->
        {:error, %{reason: "unauthorized"}}

      !FeatureFlags.god_view_enabled?() ->
        {:error, %{reason: "god_view_disabled"}}

      true ->
        send(self(), :tick)
        {:ok, socket}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    socket =
      case GodViewStream.latest_snapshot() do
        {:ok, %{snapshot: snapshot, payload: payload}} ->
          push(socket, "snapshot_meta", %{pipeline_stats: pipeline_stats(snapshot)})
          push(socket, "snapshot", {:binary, encode_snapshot_frame(snapshot, payload)})

          socket

        {:error, reason} ->
          Logger.error("God-View snapshot error: #{inspect(reason)}")
          push(socket, "snapshot_error", %{reason: "snapshot_unavailable"})
          socket
      end

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, socket}
  end

  defp encode_snapshot_frame(snapshot, payload) do
    schema_version = snapshot.schema_version
    revision = snapshot.revision
    generated_at_ms = DateTime.to_unix(snapshot.generated_at, :millisecond)
    root_meta = bitmap_meta(snapshot, :root_cause)
    affected_meta = bitmap_meta(snapshot, :affected)
    healthy_meta = bitmap_meta(snapshot, :healthy)
    unknown_meta = bitmap_meta(snapshot, :unknown)

    <<
      @binary_magic::binary,
      schema_version::unsigned-integer-size(8),
      revision::unsigned-integer-size(64),
      generated_at_ms::signed-integer-size(64),
      root_meta.bytes::unsigned-integer-size(32),
      affected_meta.bytes::unsigned-integer-size(32),
      healthy_meta.bytes::unsigned-integer-size(32),
      unknown_meta.bytes::unsigned-integer-size(32),
      root_meta.count::unsigned-integer-size(32),
      affected_meta.count::unsigned-integer-size(32),
      healthy_meta.count::unsigned-integer-size(32),
      unknown_meta.count::unsigned-integer-size(32),
      payload::binary
    >>
  end

  defp bitmap_meta(snapshot, key) do
    (snapshot.bitmap_metadata || %{})
    |> Map.get(key, %{bytes: 0, count: 0})
    |> Map.take([:bytes, :count])
    |> Map.merge(%{bytes: 0, count: 0})
  end

  defp pipeline_stats(snapshot) do
    snapshot
    |> Map.get(:pipeline_stats, %{})
    |> Map.take([
      :raw_links,
      :unique_pairs,
      :final_edges,
      :final_nodes,
      :raw_direct,
      :raw_inferred,
      :raw_attachment,
      :pair_direct,
      :pair_inferred,
      :pair_attachment,
      :final_direct,
      :final_inferred,
      :final_attachment,
      :unresolved_endpoints
    ])
  end
end
