defmodule ServiceRadarWebNGWeb.TopologyChannel do
  @moduledoc false
  use Phoenix.Channel

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.AtlasReader
  alias ServiceRadarWebNG.Topology.AtlasRequest
  alias ServiceRadarWebNG.Topology.AtlasWatch
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNGWeb.FeatureFlags

  require Logger

  @tick_ms 5_000
  @binary_magic "GVB1"

  @impl true
  def join("topology:god_view", payload, socket) do
    with {:ok, socket} <- authorize(socket),
         {:ok, socket} <- initialize_mode(socket, payload) do
      send(self(), :tick)

      {:ok,
       socket
       |> assign(:last_snapshot_revision, nil)
       |> assign(:expanded_clusters, [])}
    else
      {:error, reason} -> {:error, channel_error(reason)}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_info(:tick, socket) do
    case authorize(socket) do
      {:ok, socket} ->
        socket =
          if socket.assigns[:stream_mode] == :levels,
            do: push_level_invalidations(socket),
            else: push_latest_snapshot(socket)

        Process.send_after(self(), :tick, @tick_ms)
        {:noreply, socket}

      {:error, reason} ->
        push(socket, "topology_error", channel_error(reason))
        {:stop, :normal, socket}
    end
  end

  @impl true
  def handle_in(event, payload, socket) do
    case authorize(socket) do
      {:ok, socket} -> handle_authorized_in(event, payload, socket)
      {:error, reason} -> {:reply, {:error, channel_error(reason)}, socket}
    end
  end

  defp handle_authorized_in("levels:watch", params, socket) do
    case AtlasRequest.parse_levels(params) do
      {:ok, level_ids} ->
        socket =
          socket
          |> assign(:stream_mode, :levels)
          |> assign(:watched_level_ids, level_ids)
          |> assign(:last_level_revisions, nil)

        case AtlasReader.revisions(socket.assigns.current_scope, level_ids) do
          {:ok, revisions} ->
            {:reply, {:ok, AtlasWatch.acknowledgement(revisions)}, assign(socket, :last_level_revisions, revisions)}

          {:error, reason} ->
            {:reply, {:error, channel_error(reason)}, socket}
        end

      {:error, reason} ->
        {:reply, {:error, channel_error(reason)}, socket}
    end
  end

  defp handle_authorized_in(_event, _payload, %{assigns: %{stream_mode: :levels}} = socket) do
    {:reply, {:error, %{reason: "unsupported_event"}}, socket}
  end

  defp handle_authorized_in("cluster:set_expanded", %{"cluster_id" => cluster_id, "expanded" => expanded}, socket)
       when is_binary(cluster_id) do
    expanded_clusters = socket.assigns[:expanded_clusters] || []
    expanded_clusters = next_expanded_clusters(expanded_clusters, cluster_id, expanded)

    socket =
      socket
      |> assign(:expanded_clusters, expanded_clusters)
      |> assign(:last_snapshot_revision, nil)
      |> push_latest_snapshot()

    {:reply, {:ok, %{}}, socket}
  end

  defp handle_authorized_in("cluster:set_expanded", _payload, socket), do: {:reply, {:ok, %{}}, socket}

  defp handle_authorized_in("cluster:collapse_all", _payload, socket) do
    socket =
      socket
      |> assign(:expanded_clusters, [])
      |> assign(:last_snapshot_revision, nil)
      |> push_latest_snapshot()

    {:reply, {:ok, %{}}, socket}
  end

  defp handle_authorized_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unsupported_event"}}, socket}
  end

  defp initialize_mode(socket, %{"mode" => "levels"} = params) do
    with {:ok, level_ids} <- AtlasRequest.parse_levels(params) do
      {:ok,
       socket
       |> assign(:stream_mode, :levels)
       |> assign(:watched_level_ids, level_ids)
       |> assign(:last_level_revisions, nil)}
    end
  end

  defp initialize_mode(_socket, %{"mode" => _mode}), do: {:error, :invalid_mode}
  defp initialize_mode(socket, _params), do: {:ok, assign(socket, :stream_mode, :legacy)}

  defp authorize(socket) do
    case socket.assigns[:current_scope] do
      %Scope{user: user} = scope when not is_nil(user) ->
        if FeatureFlags.god_view_enabled?() do
          case RBAC.authorize_current(scope, ["analytics.view", "devices.view"]) do
            {:ok, current_scope} -> {:ok, assign(socket, :current_scope, current_scope)}
            {:error, _reason} -> {:error, :forbidden}
          end
        else
          {:error, :god_view_disabled}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp channel_error(reason) do
    {_status, body} = AtlasRequest.error_response(reason)
    body |> Map.delete(:error) |> Map.put(:reason, body.error)
  end

  defp push_level_invalidations(socket) do
    case AtlasReader.revisions(socket.assigns.current_scope, socket.assigns.watched_level_ids) do
      {:ok, revisions} ->
        previous = socket.assigns.last_level_revisions

        case AtlasWatch.invalidation(previous, revisions) do
          nil -> :ok
          payload -> push(socket, "topology_invalidated", payload)
        end

        assign(socket, :last_level_revisions, revisions)

      {:error, reason} ->
        push(socket, "topology_error", channel_error(reason))
        socket
    end
  end

  defp push_latest_snapshot(socket) do
    snapshot_opts = %{expanded_clusters: MapSet.new(socket.assigns[:expanded_clusters] || [])}

    case GodViewStream.latest_snapshot(snapshot_opts) do
      {:ok, %{snapshot: snapshot, payload: payload}} ->
        if socket.assigns[:last_snapshot_revision] == snapshot.revision do
          socket
        else
          push(socket, "snapshot_meta", %{pipeline_stats: pipeline_stats(snapshot)})
          push(socket, "snapshot", {:binary, encode_snapshot_frame(snapshot, payload)})
          assign(socket, :last_snapshot_revision, snapshot.revision)
        end

      {:error, reason} ->
        Logger.error("God-View snapshot error: #{inspect(reason)}")
        push(socket, "snapshot_error", %{reason: "snapshot_unavailable"})
        socket
    end
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
    GodViewSnapshot.bitmap_metadata(snapshot, key)
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
      :edge_class_backbone,
      :edge_class_attachment,
      :edge_class_inferred,
      :edge_class_hosted,
      :edge_class_observed,
      :backbone_edge_count,
      :unresolved_endpoints
    ])
  end

  @doc false
  def next_expanded_clusters(expanded_clusters, cluster_id, expanded)
      when is_list(expanded_clusters) and is_binary(cluster_id) do
    cond do
      expanded == true and not Enum.member?(expanded_clusters, cluster_id) ->
        # No cap. Expanding one cluster must never collapse another: the operator opened it
        # deliberately, and evicting the oldest made a fifth expansion silently close the
        # first on a deployment with five clusters. The payload stays bounded by the
        # per-cluster visible-member limit in GodViewStream, not by how many are open.
        Enum.concat(expanded_clusters, [cluster_id])

      expanded == true ->
        expanded_clusters

      true ->
        List.delete(expanded_clusters, cluster_id)
    end
  end
end
