defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds phase-1 God-View snapshot payloads.

  The binary payload currently encodes a compact fixed header used by the
  frontend hook. It can be replaced by Arrow IPC while keeping the same
  feature-flagged endpoint shape.
  """

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadarWebNG.Topology.CausalEngine
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.Native

  @max_link_rows 5_000
  @max_fallback_nodes 250

  @spec latest_snapshot() ::
          {:ok, %{snapshot: GodViewSnapshot.snapshot(), payload: binary()}} | {:error, term()}
  def latest_snapshot do
    revision = System.system_time(:millisecond)
    actor = SystemActor.system(:god_view_stream)

    projection =
      case build_projection(actor) do
        {:ok, projection} ->
          projection

        {:error, reason} ->
          Logger.warning("GodViewStream projection fallback engaged: #{inspect(reason)}")
          fallback_projection()
      end

    snapshot = %{
      schema_version: GodViewSnapshot.schema_version(),
      revision: revision,
      generated_at: DateTime.utc_now(),
      nodes: projection.nodes,
      edges: projection.edges,
      causal_bitmaps: projection.causal_bitmaps,
      bitmap_metadata: projection.bitmap_metadata
    }

    with :ok <- GodViewSnapshot.validate(snapshot) do
      {:ok, %{snapshot: snapshot, payload: encode_payload(snapshot)}}
    end
  end

  defp encode_payload(snapshot) do
    root = Map.get(snapshot.causal_bitmaps, :root_cause, <<>>)
    affected = Map.get(snapshot.causal_bitmaps, :affected, <<>>)
    healthy = Map.get(snapshot.causal_bitmaps, :healthy, <<>>)
    unknown = Map.get(snapshot.causal_bitmaps, :unknown, <<>>)
    node_index = snapshot.nodes |> Enum.with_index() |> Map.new(fn {n, idx} -> {n.id, idx} end)

    nodes =
      Enum.map(snapshot.nodes, fn node ->
        {Map.get(node, :x, 0), Map.get(node, :y, 0), Map.get(node, :state, 3)}
      end)

    edges =
      Enum.map(snapshot.edges, fn edge ->
        {Map.fetch!(node_index, edge.source), Map.fetch!(node_index, edge.target)}
      end)

    Native.encode_snapshot(
      snapshot.schema_version,
      snapshot.revision,
      nodes,
      edges,
      byte_size(root),
      byte_size(affected),
      byte_size(healthy),
      byte_size(unknown)
    )
  end

  defp build_projection(actor) do
    with {:ok, links} <- fetch_topology_links(actor),
         {:ok, pairs} <- unique_pairs(links),
         {:ok, nodes, edges} <- build_nodes_and_edges(actor, pairs) do
      nodes = apply_causal_states(nodes, edges)
      {causal_bitmaps, bitmap_metadata} = build_bitmaps(nodes)

      {:ok,
       %{
         nodes: nodes,
         edges: edges,
         causal_bitmaps: causal_bitmaps,
         bitmap_metadata: bitmap_metadata
       }}
    end
  end

  defp fetch_topology_links(actor) do
    query =
      TopologyLink
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(@max_link_rows)

    case Ash.read(query, actor: actor) do
      {:ok, links} when is_list(links) -> {:ok, links}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_pairs(links) when is_list(links) do
    pairs =
      Enum.reduce(links, %{}, fn link, acc ->
        local_id = normalize_id(Map.get(link, :local_device_id))
        neighbor_id = normalize_neighbor_id(link)

        cond do
          is_nil(local_id) or is_nil(neighbor_id) or local_id == neighbor_id ->
            acc

          true ->
            {a, b} = canonical_pair(local_id, neighbor_id)

            Map.put_new(acc, {a, b}, %{
              source: a,
              target: b,
              kind: "topology",
              protocol: Map.get(link, :protocol),
              confidence_tier: confidence_tier(link)
            })
        end
      end)

    {:ok, pairs}
  end

  defp build_nodes_and_edges(actor, pairs) do
    pair_edges = Map.values(pairs)
    edge_node_ids = pairs |> Map.keys() |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    with {:ok, devices} <- fetch_devices(actor, edge_node_ids) do
      device_by_id = Map.new(devices, &{&1.uid, &1})
      node_ids = node_ids(edge_node_ids, devices)
      nodes = build_nodes(node_ids, device_by_id)
      edges = pair_edges
      {:ok, nodes, edges}
    end
  end

  defp fetch_devices(actor, []), do: fetch_fallback_devices(actor)

  defp fetch_devices(actor, node_ids) when is_list(node_ids) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.filter(uid in ^node_ids)
      |> Ash.Query.sort(uid: :asc)

    case Ash.read(query, actor: actor) do
      {:ok, devices} when is_list(devices) -> {:ok, devices}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_fallback_devices(actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.sort(last_seen_time: :desc, uid: :asc)
      |> Ash.Query.limit(@max_fallback_nodes)

    case Ash.read(query, actor: actor) do
      {:ok, devices} when is_list(devices) -> {:ok, devices}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp node_ids([], devices), do: devices |> Enum.map(& &1.uid) |> Enum.sort()
  defp node_ids(edge_node_ids, _devices), do: Enum.sort(edge_node_ids)

  defp build_nodes(node_ids, device_by_id) do
    total = max(length(node_ids), 1)

    node_ids
    |> Enum.with_index()
    |> Enum.map(fn {id, idx} ->
      {x, y} = layout_xy(idx, total)
      device = Map.get(device_by_id, id)

      %{
        id: id,
        label: node_label(device, id),
        kind: node_kind(device),
        x: x,
        y: y,
        state: 3,
        health_signal: health_signal(device)
      }
    end)
  end

  defp layout_xy(idx, total) do
    radius = 120.0 + total * 0.8
    angle = idx * (2 * :math.pi() / total)
    x = Float.round(320 + radius * :math.cos(angle), 2)
    y = Float.round(160 + radius * :math.sin(angle), 2)
    {x, y}
  end

  defp node_label(nil, id), do: id

  defp node_label(device, id) do
    Map.get(device, :name) ||
      Map.get(device, :hostname) ||
      id
  end

  defp node_kind(nil), do: "external"
  defp node_kind(device), do: Map.get(device, :type) || "device"

  defp health_signal(%{is_available: true}), do: :healthy
  defp health_signal(%{is_available: false}), do: :unhealthy
  defp health_signal(_), do: :unknown

  defp apply_causal_states(nodes, edges) do
    state_by_id = CausalEngine.evaluate(nodes, edges)

    Enum.map(nodes, fn node ->
      node
      |> Map.put(:state, Map.get(state_by_id, node.id, 3))
      |> Map.delete(:health_signal)
    end)
  end

  defp build_bitmaps(nodes) do
    root = bitmap_for_state(nodes, 0)
    affected = bitmap_for_state(nodes, 1)
    healthy = bitmap_for_state(nodes, 2)
    unknown = bitmap_for_state(nodes, 3)

    counts =
      nodes
      |> Enum.map(&Map.get(&1, :state, 3))
      |> Enum.frequencies()

    bitmaps = %{root_cause: root, affected: affected, healthy: healthy, unknown: unknown}

    metadata = %{
      root_cause: %{bytes: byte_size(root), count: Map.get(counts, 0, 0)},
      affected: %{bytes: byte_size(affected), count: Map.get(counts, 1, 0)},
      healthy: %{bytes: byte_size(healthy), count: Map.get(counts, 2, 0)},
      unknown: %{bytes: byte_size(unknown), count: Map.get(counts, 3, 0)}
    }

    {bitmaps, metadata}
  end

  defp bitmap_for_state(nodes, state) do
    byte_count = div(length(nodes) + 7, 8)
    bytes = :binary.copy(<<0>>, byte_count)

    nodes
    |> Enum.with_index()
    |> Enum.reduce(bytes, fn {node, idx}, acc ->
      if Map.get(node, :state) == state do
        set_bit(acc, idx)
      else
        acc
      end
    end)
  end

  defp set_bit(bytes, idx) do
    byte_idx = div(idx, 8)
    bit_idx = 7 - rem(idx, 8)
    current = :binary.at(bytes, byte_idx)
    updated = Bitwise.bor(current, Bitwise.bsl(1, bit_idx))

    :binary.part(bytes, 0, byte_idx) <>
      <<updated>> <> :binary.part(bytes, byte_idx + 1, byte_size(bytes) - byte_idx - 1)
  end

  defp canonical_pair(a, b) when a <= b, do: {a, b}
  defp canonical_pair(a, b), do: {b, a}

  defp normalize_neighbor_id(link) do
    normalize_id(Map.get(link, :neighbor_device_id)) ||
      normalize_id(Map.get(link, :neighbor_mgmt_addr)) ||
      normalize_id(Map.get(link, :neighbor_system_name))
  end

  defp normalize_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_id(_), do: nil

  defp confidence_tier(link) do
    (Map.get(link, :metadata) || %{})
    |> Map.get("confidence_tier", Map.get(link, :confidence_tier, "unknown"))
  end

  defp page_results(%{results: results}) when is_list(results), do: results
  defp page_results(_), do: []

  defp fallback_projection do
    nodes = fallback_nodes()
    {causal_bitmaps, bitmap_metadata} = build_bitmaps(nodes)

    %{
      nodes: nodes,
      edges: fallback_edges(),
      causal_bitmaps: causal_bitmaps,
      bitmap_metadata: bitmap_metadata
    }
  end

  defp fallback_nodes do
    [
      %{id: "core-1", label: "Core Router", kind: "router", x: 80, y: 180, state: 0},
      %{id: "dist-1", label: "Distribution Switch", kind: "switch", x: 300, y: 180, state: 1},
      %{id: "srv-1", label: "Application Server", kind: "server", x: 520, y: 180, state: 1}
    ]
  end

  defp fallback_edges do
    [
      %{source: "core-1", target: "dist-1", kind: "physical"},
      %{source: "dist-1", target: "srv-1", kind: "physical"}
    ]
  end
end
