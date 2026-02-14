defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds God-View snapshot payloads backed by the Rust Arrow encoder.
  """

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.Native

  @max_link_rows 5_000
  @max_device_rows 250
  @default_real_time_budget_ms 2_000
  @drop_counter_key {__MODULE__, :dropped_updates}

  @spec latest_snapshot() ::
          {:ok, %{snapshot: GodViewSnapshot.snapshot(), payload: binary()}} | {:error, term()}
  def latest_snapshot do
    started_at = System.monotonic_time()
    revision = System.system_time(:millisecond)
    actor = SystemActor.system(:god_view_stream)
    budget_ms = real_time_budget_ms()

    with {:ok, projection} <- build_projection(actor),
         snapshot = %{
           schema_version: GodViewSnapshot.schema_version(),
           revision: revision,
           generated_at: DateTime.utc_now(),
           nodes: projection.nodes,
           edges: projection.edges,
           causal_bitmaps: projection.causal_bitmaps,
           bitmap_metadata: projection.bitmap_metadata
         },
         :ok <- GodViewSnapshot.validate(snapshot),
         payload <- encode_payload(snapshot) do
      build_ms = duration_ms(started_at)

      if build_ms > budget_ms do
        dropped = increment_dropped_updates()

        emit_snapshot_drop_telemetry(snapshot, build_ms, budget_ms, dropped)
        {:error, {:real_time_budget_exceeded, %{build_ms: build_ms, budget_ms: budget_ms}}}
      else
        emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms)
        {:ok, %{snapshot: snapshot, payload: payload}}
      end
    else
      {:error, reason} ->
        emit_snapshot_error_telemetry(reason)
        {:error, reason}
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
        {
          normalize_u16(Map.get(node, :x, 0)),
          normalize_u16(Map.get(node, :y, 0)),
          normalize_u8(Map.get(node, :state, 3))
        }
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

  defp fetch_devices(actor, []), do: fetch_recent_devices(actor)

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

  defp fetch_recent_devices(actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.sort(last_seen_time: :desc, uid: :asc)
      |> Ash.Query.limit(@max_device_rows)

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
    node_index =
      nodes
      |> Enum.with_index()
      |> Map.new(fn {node, idx} -> {node.id, idx} end)

    signals =
      Enum.map(nodes, fn node ->
        case Map.get(node, :health_signal, :unknown) do
          :healthy -> 0
          :unhealthy -> 1
          _ -> 2
        end
      end)

    indexed_edges =
      Enum.map(edges, fn edge ->
        {Map.fetch!(node_index, edge.source), Map.fetch!(node_index, edge.target)}
      end)

    states = Native.evaluate_causal_states(signals, indexed_edges)

    Enum.zip(nodes, states)
    |> Enum.map(fn {node, state} ->
      node
      |> Map.put(:state, state)
      |> Map.delete(:health_signal)
    end)
  end

  defp build_bitmaps(nodes) do
    states = Enum.map(nodes, &Map.get(&1, :state, 3))

    {root, affected, healthy, unknown, {root_count, affected_count, healthy_count, unknown_count}} =
      Native.build_roaring_bitmaps(states)

    bitmaps = %{root_cause: root, affected: affected, healthy: healthy, unknown: unknown}

    metadata = %{
      root_cause: %{bytes: byte_size(root), count: root_count},
      affected: %{bytes: byte_size(affected), count: affected_count},
      healthy: %{bytes: byte_size(healthy), count: healthy_count},
      unknown: %{bytes: byte_size(unknown), count: unknown_count}
    }

    {bitmaps, metadata}
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

  defp normalize_u16(value) when is_integer(value), do: clamp(value, 0, 65_535)

  defp normalize_u16(value) when is_float(value),
    do: value |> Float.round() |> trunc() |> normalize_u16()

  defp normalize_u16(_), do: 0

  defp normalize_u8(value) when is_integer(value), do: clamp(value, 0, 255)
  defp normalize_u8(_), do: 0

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp real_time_budget_ms do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_snapshot_budget_ms,
      @default_real_time_budget_ms
    )
  end

  defp duration_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms) do
    :telemetry.execute(
      [:serviceradar, :god_view, :snapshot, :built],
      %{
        build_ms: build_ms,
        payload_bytes: byte_size(payload),
        node_count: length(snapshot.nodes),
        edge_count: length(snapshot.edges)
      },
      %{
        schema_version: snapshot.schema_version,
        revision: snapshot.revision,
        budget_ms: budget_ms
      }
    )
  end

  defp emit_snapshot_drop_telemetry(snapshot, build_ms, budget_ms, dropped_count) do
    :telemetry.execute(
      [:serviceradar, :god_view, :snapshot, :dropped],
      %{build_ms: build_ms, dropped_count: dropped_count},
      %{
        schema_version: snapshot.schema_version,
        revision: snapshot.revision,
        budget_ms: budget_ms
      }
    )
  end

  defp emit_snapshot_error_telemetry(reason) do
    :telemetry.execute(
      [:serviceradar, :god_view, :snapshot, :error],
      %{count: 1},
      %{reason: inspect(reason)}
    )
  end

  defp increment_dropped_updates do
    counter = dropped_counter()
    :counters.add(counter, 1, 1)
    :counters.get(counter, 1)
  end

  defp dropped_counter do
    case :persistent_term.get(@drop_counter_key, nil) do
      nil ->
        counter = :counters.new(1, [])
        :persistent_term.put(@drop_counter_key, counter)
        counter

      counter ->
        counter
    end
  end
end
