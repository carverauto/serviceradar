defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds God-View snapshot payloads backed by the Rust Arrow encoder.

  Canonical edge contract consumed from backend/runtime graph:
  - `source`, `target`: canonical device endpoint IDs.
  - `local_if_index_ab`, `local_if_name_ab`: source-side interface attribution for `source -> target`.
  - `local_if_index_ba`, `local_if_name_ba`: source-side interface attribution for `target -> source`.
  - `flow_pps`, `flow_bps`: aggregate link packet/bit rate.
  - `flow_pps_ab`, `flow_bps_ab`: directional packet/bit rate from `source -> target`.
  - `flow_pps_ba`, `flow_bps_ba`: directional packet/bit rate from `target -> source`.
  - `capacity_bps`: link capacity in bps when known.
  - `telemetry_eligible`: whether edge has interface-attributed telemetry suitable for animation.
  - `protocol`, `evidence_class`, `confidence_tier`, `confidence_reason`: backend topology evidence metadata.
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.BmpSettingsRuntime
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.RuntimeGraph

  require Ash.Query
  require Logger

  @default_real_time_budget_ms 2_000
  @default_snapshot_coalesce_ms 0
  @default_parity_alert_delta 0
  @default_unresolved_directional_ratio_alert 0.6
  @god_view_evidence_classes ["direct", "inferred", "endpoint-attachment"]
  @drop_counter_key {__MODULE__, :dropped_updates}
  @layout_cache_key {__MODULE__, :layout_cache}
  @snapshot_cache_key {__MODULE__, :snapshot_cache}

  @spec latest_snapshot() ::
          {:ok, %{snapshot: GodViewSnapshot.snapshot(), payload: binary()}} | {:error, term()}
  def latest_snapshot do
    coalesce_ms = snapshot_coalesce_ms()

    case coalesced_snapshot(coalesce_ms) do
      {:ok, result} ->
        {:ok, result}

      :miss ->
        build_latest_snapshot()
    end
  end

  defp build_latest_snapshot do
    started_at = System.monotonic_time()
    actor = SystemActor.system(:god_view_stream)
    budget_ms = real_time_budget_ms()

    with {:ok, projection} <- build_projection(actor),
         revision = snapshot_revision(projection.topology_revision, projection.causal_revision),
         snapshot = %{
           schema_version: GodViewSnapshot.schema_version(),
           revision: revision,
           generated_at: DateTime.utc_now(),
           nodes: projection.nodes,
           edges: projection.edges,
           causal_bitmaps: projection.causal_bitmaps,
           bitmap_metadata: projection.bitmap_metadata,
           pipeline_stats: projection.pipeline_stats
         },
         :ok <- GodViewSnapshot.validate(snapshot),
         {:ok, payload} <- encode_payload(snapshot) do
      result = %{snapshot: snapshot, payload: payload}
      build_ms = duration_ms(started_at)

      if build_ms > budget_ms do
        dropped = increment_dropped_updates()

        emit_snapshot_drop_telemetry(snapshot, build_ms, budget_ms, dropped)
        emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms)
        {:error, {:real_time_budget_exceeded, %{build_ms: build_ms, budget_ms: budget_ms}}}
      else
        emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms)
        put_snapshot_cache(result)
        {:ok, result}
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
          normalize_u8(Map.get(node, :state, 3)),
          normalize_label(Map.get(node, :label) || Map.get(node, :id) || "node"),
          normalize_u32(Map.get(node, :pps, 0)),
          normalize_u8(node_oper_up_value(Map.get(node, :oper_up))),
          normalize_details_json(Map.get(node, :details_json))
        }
      end)

    edges =
      Enum.map(snapshot.edges, fn edge ->
        {
          Map.fetch!(node_index, edge.source),
          Map.fetch!(node_index, edge.target),
          normalize_u32(Map.get(edge, :flow_pps, 0)),
          normalize_u64(Map.get(edge, :flow_bps, 0)),
          normalize_u64(Map.get(edge, :capacity_bps, 0)),
          normalize_label(Map.get(edge, :label) || edge_label(edge)),
          normalize_u8(if(Map.get(edge, :telemetry_eligible, true), do: 1, else: 0))
        }
      end)

    edge_meta =
      Enum.map(snapshot.edges, fn edge ->
        {
          normalize_label(edge_topology_class(edge)),
          normalize_label(edge_protocol(edge)),
          normalize_label(evidence_class(edge))
        }
      end)

    edge_directional =
      Enum.map(snapshot.edges, fn edge ->
        {
          normalize_u32(Map.get(edge, :flow_pps_ab, 0)),
          normalize_u32(Map.get(edge, :flow_pps_ba, 0)),
          normalize_u64(Map.get(edge, :flow_bps_ab, 0)),
          normalize_u64(Map.get(edge, :flow_bps_ba, 0))
        }
      end)

    {:ok,
     Native.encode_snapshot(%{
       schema_version: snapshot.schema_version,
       revision: snapshot.revision,
       nodes: nodes,
       edges: edges,
       edge_meta: edge_meta,
       edge_directional: edge_directional,
       root_bitmap_bytes: byte_size(root),
       affected_bitmap_bytes: byte_size(affected),
       healthy_bitmap_bytes: byte_size(healthy),
       unknown_bitmap_bytes: byte_size(unknown)
     })}
  end

  defp build_projection(actor) do
    with {:ok, links} <- fetch_topology_links(actor),
         {:ok, nodes, edges, pipeline_stats} <- build_nodes_and_edges(actor, links),
         {:ok, indexed_edges} <- index_edges(nodes, edges) do
      emit_pipeline_stats(pipeline_stats)
      topology_revision = topology_revision(nodes, indexed_edges)
      nodes = apply_native_layout_with_indexed_edges(nodes, indexed_edges, topology_revision)
      nodes = apply_causal_states(nodes, indexed_edges)
      causal_revision = causal_revision(nodes)
      {causal_bitmaps, bitmap_metadata} = build_bitmaps(nodes)

      {:ok,
       %{
         nodes: nodes,
         edges: edges,
         topology_revision: topology_revision,
         causal_revision: causal_revision,
         causal_bitmaps: causal_bitmaps,
         bitmap_metadata: bitmap_metadata,
         pipeline_stats: pipeline_stats
       }}
    end
  end

  defp fetch_topology_links(_actor) do
    RuntimeGraph.get_links()
  end

  defp runtime_link_to_edge(link) when is_map(link) do
    source = normalize_id(Map.get(link, :local_device_id))
    target = normalize_id(Map.get(link, :neighbor_device_id))

    if is_nil(source) or is_nil(target) or source == target do
      nil
    else
      build_runtime_link_edge(link, source, target)
    end
  end

  defp runtime_link_to_edge(_), do: nil

  defp build_runtime_link_edge(link, source, target) do
    local_if_name = normalize_id(Map.get(link, :local_if_name))
    neighbor_if_name = normalize_id(Map.get(link, :neighbor_if_name))
    flow_pps = normalize_u32(Map.get(link, :flow_pps, 0))
    capacity_bps = normalize_u64(Map.get(link, :capacity_bps, 0))

    %{
      source: source,
      target: target,
      kind: "topology",
      protocol: normalize_id(Map.get(link, :protocol)) || "unknown",
      evidence_class: evidence_class(link),
      confidence_tier: confidence_tier(link),
      confidence_reason: normalize_id(Map.get(link, :confidence_reason)) || "unspecified",
      local_device_ip: normalize_id(Map.get(link, :local_device_ip)),
      neighbor_mgmt_addr: normalize_id(Map.get(link, :neighbor_mgmt_addr)),
      local_if_index: Map.get(link, :local_if_index),
      local_if_name: local_if_name,
      neighbor_if_index: Map.get(link, :neighbor_if_index),
      neighbor_if_name: neighbor_if_name,
      flow_pps: flow_pps,
      flow_bps: normalize_u64(Map.get(link, :flow_bps, 0)),
      capacity_bps: capacity_bps,
      flow_pps_ab: normalize_u32(Map.get(link, :flow_pps_ab, 0)),
      flow_pps_ba: normalize_u32(Map.get(link, :flow_pps_ba, 0)),
      flow_bps_ab: normalize_u64(Map.get(link, :flow_bps_ab, 0)),
      flow_bps_ba: normalize_u64(Map.get(link, :flow_bps_ba, 0)),
      telemetry_eligible: Map.get(link, :telemetry_eligible, false) == true,
      telemetry_source: normalize_id(Map.get(link, :telemetry_source)) || "none",
      local_if_index_ab: Map.get(link, :local_if_index_ab),
      local_if_name_ab: directional_if_name(link, :local_if_name_ab, local_if_name, neighbor_if_name),
      local_if_index_ba: Map.get(link, :local_if_index_ba),
      local_if_name_ba: directional_if_name(link, :local_if_name_ba, neighbor_if_name, local_if_name),
      label: edge_label(link, flow_pps, capacity_bps),
      metadata: Map.get(link, :metadata) || %{}
    }
  end

  defp directional_if_name(link, field, primary_name, fallback_name) do
    normalize_id(Map.get(link, field)) || primary_name || fallback_name || ""
  end

  defp build_nodes_and_edges(actor, raw_links) do
    canonical_edges =
      raw_links
      |> Enum.map(&runtime_link_to_edge/1)
      |> Enum.reject(&is_nil/1)

    edge_node_ids = canonical_edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

    with {:ok, devices} <- fetch_devices(actor, edge_node_ids) do
      device_by_id = Map.new(devices, &{&1.uid, &1})
      node_pps_by_id = node_pps_by_id(canonical_edges)
      node_ids = node_ids(edge_node_ids, devices)
      nodes = build_nodes(node_ids, device_by_id, node_pps_by_id)
      edges = canonical_edges

      edge_contract_stats = edge_contract_stats(edges)

      unresolved_endpoints =
        Enum.count(edge_node_ids, fn id -> not Map.has_key?(device_by_id, id) end)

      pipeline_stats =
        raw_links
        |> pipeline_stats(edges, edges, nodes, unresolved_endpoints)
        |> Map.merge(edge_contract_stats)
        |> Map.merge(component_stats(nodes, edges))

      {:ok, nodes, edges, pipeline_stats}
    end
  end

  defp pipeline_stats(raw_links, pair_links, final_edges, final_nodes, unresolved_endpoints)
       when is_list(raw_links) and is_list(pair_links) and is_list(final_edges) and is_list(final_nodes) and
              is_integer(unresolved_endpoints) do
    edge_parity_delta = abs(length(raw_links) - length(final_edges))

    %{
      raw_links: length(raw_links),
      unique_pairs: length(pair_links),
      final_edges: length(final_edges),
      final_nodes: length(final_nodes),
      edge_parity_delta: edge_parity_delta,
      raw_direct: count_by_evidence(raw_links, "direct"),
      raw_inferred: count_by_evidence(raw_links, "inferred"),
      raw_attachment: count_by_evidence(raw_links, "endpoint-attachment"),
      pair_direct: count_by_evidence(pair_links, "direct"),
      pair_inferred: count_by_evidence(pair_links, "inferred"),
      pair_attachment: count_by_evidence(pair_links, "endpoint-attachment"),
      final_direct: count_by_evidence(final_edges, "direct"),
      final_inferred: count_by_evidence(final_edges, "inferred"),
      final_attachment: count_by_evidence(final_edges, "endpoint-attachment"),
      unresolved_endpoints: unresolved_endpoints
    }
  end

  defp pipeline_stats(_raw_links, _pair_links, _final_edges, _final_nodes, _unresolved_endpoints), do: %{}

  defp component_stats(nodes, edges) when is_list(nodes) and is_list(edges) do
    node_ids =
      nodes
      |> Enum.map(&normalize_id(Map.get(&1, :id)))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    adjacency =
      Enum.reduce(edges, %{}, fn edge, acc ->
        source = normalize_id(Map.get(edge, :source))
        target = normalize_id(Map.get(edge, :target))

        if is_binary(source) and is_binary(target) and source != target do
          acc
          |> Map.update(source, MapSet.new([target]), &MapSet.put(&1, target))
          |> Map.update(target, MapSet.new([source]), &MapSet.put(&1, source))
        else
          acc
        end
      end)

    {components, largest} =
      node_ids
      |> MapSet.to_list()
      |> Enum.reduce({0, 0, MapSet.new()}, fn node, {count, max_size, visited} ->
        if MapSet.member?(visited, node) do
          {count, max_size, visited}
        else
          {component_size, visited} = bfs_component_size(node, adjacency, visited)
          {count + 1, max(max_size, component_size), visited}
        end
      end)
      |> then(fn {count, max_size, _visited} -> {count, max_size} end)

    isolated =
      Enum.count(node_ids, fn node ->
        adjacency |> Map.get(node, MapSet.new()) |> MapSet.size() == 0
      end)

    %{
      connected_components: components,
      largest_component_size: largest,
      isolated_nodes: isolated
    }
  end

  defp component_stats(_nodes, _edges) do
    %{connected_components: 0, largest_component_size: 0, isolated_nodes: 0}
  end

  defp bfs_component_size(start, adjacency, visited) do
    queue = :queue.in(start, :queue.new())
    visited = MapSet.put(visited, start)
    bfs_component_size(queue, adjacency, visited, 0)
  end

  defp bfs_component_size(queue, adjacency, visited, size) do
    case :queue.out(queue) do
      {{:value, node}, rest} ->
        neighbors = Map.get(adjacency, node, MapSet.new())
        {rest, visited} = enqueue_unvisited_neighbors(neighbors, rest, visited)

        bfs_component_size(rest, adjacency, visited, size + 1)

      {:empty, _} ->
        {size, visited}
    end
  end

  defp enqueue_unvisited_neighbors(neighbors, queue, visited) do
    Enum.reduce(neighbors, {queue, visited}, fn neighbor, {q, vis} ->
      if MapSet.member?(vis, neighbor) do
        {q, vis}
      else
        {:queue.in(neighbor, q), MapSet.put(vis, neighbor)}
      end
    end)
  end

  defp emit_pipeline_stats(measurements) when is_map(measurements) do
    :telemetry.execute([:serviceradar, :god_view, :pipeline, :stats], measurements, %{})
    maybe_emit_pipeline_alert(measurements)
    Logger.info("god_view_pipeline_stats #{inspect(measurements)}")
  end

  defp emit_pipeline_stats(_measurements), do: :ok

  defp maybe_emit_pipeline_alert(measurements) when is_map(measurements) do
    final_edges = Map.get(measurements, :final_edges, 0)
    interface_edges = Map.get(measurements, :edge_telemetry_interface, 0)
    parity_delta = Map.get(measurements, :edge_parity_delta, 0)
    unresolved_directional = Map.get(measurements, :edge_unresolved_directional, 0)
    unresolved_ratio = unresolved_ratio(unresolved_directional, final_edges)

    if final_edges > 0 and interface_edges == 0 do
      emit_pipeline_alert(
        "edge_telemetry_interface_zero",
        %{final_edges: final_edges, edge_telemetry_interface: interface_edges}
      )
    end

    if parity_delta > parity_alert_delta_threshold() do
      emit_pipeline_alert(
        "edge_parity_delta_nonzero",
        %{final_edges: final_edges, edge_parity_delta: parity_delta}
      )
    end

    if final_edges > 0 and unresolved_ratio > unresolved_directional_ratio_alert_threshold() do
      emit_pipeline_alert(
        "edge_unresolved_directional_ratio_high",
        %{
          final_edges: final_edges,
          edge_unresolved_directional: unresolved_directional,
          edge_unresolved_directional_ratio: unresolved_ratio
        }
      )
    end
  end

  defp maybe_emit_pipeline_alert(_measurements), do: :ok

  defp emit_pipeline_alert(alert, measurements) when is_binary(alert) and is_map(measurements) do
    :telemetry.execute(
      [:serviceradar, :god_view, :pipeline, :alert],
      measurements,
      %{alert: alert}
    )

    Logger.warning("god_view_pipeline_alert #{alert} #{inspect(measurements)}")
  end

  defp count_by_evidence(items, expected) when is_list(items) and is_binary(expected) do
    Enum.count(items, fn item -> evidence_class(item) == expected end)
  end

  defp edge_protocol(edge) do
    edge
    |> Map.get(:protocol)
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp fetch_devices(_actor, []), do: {:ok, []}

  defp fetch_devices(actor, node_ids) when is_list(node_ids) do
    # Keep query parameter counts bounded for large topology graphs.
    node_ids
    |> Enum.chunk_every(2_000)
    |> Enum.reduce_while({:ok, []}, fn node_id_chunk, {:ok, acc} ->
      query =
        Device
        |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
        |> Ash.Query.filter(uid in ^node_id_chunk)

      case Ash.read(query, actor: actor) do
        {:ok, devices} when is_list(devices) ->
          {:cont, {:ok, devices ++ acc}}

        {:ok, page} ->
          {:cont, {:ok, page_results(page) ++ acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, devices} ->
        {:ok, devices |> Enum.uniq_by(& &1.uid) |> Enum.sort_by(& &1.uid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_ifindex?(value) when is_integer(value), do: value > 0
  defp valid_ifindex?(_value), do: false

  defp node_ids(edge_node_ids, _devices) do
    edge_connected_node_ids(edge_node_ids)
  end

  @doc false
  @spec edge_connected_node_ids([term()]) :: [String.t()]
  def edge_connected_node_ids(edge_node_ids) when is_list(edge_node_ids) do
    edge_node_ids
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def edge_connected_node_ids(_), do: []

  defp build_nodes(node_ids, device_by_id, node_pps_by_id) do
    total = max(length(node_ids), 1)

    node_ids
    |> Enum.with_index()
    |> Enum.map(fn {id, idx} ->
      {x, y} = layout_xy(idx, total)
      device = Map.get(device_by_id, id)
      pps = Map.get(node_pps_by_id, id, 0)

      %{
        id: id,
        label: node_label(device, id),
        kind: node_kind(device),
        x: x,
        y: y,
        state: 3,
        pps: pps,
        oper_up: nil,
        details_json: node_details_json(device, id),
        geo_lat: node_geo_lat(device),
        geo_lon: node_geo_lon(device),
        health_signal: health_signal(device)
      }
    end)
  end

  defp node_pps_by_id(edges) when is_list(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      source = normalize_id(Map.get(edge, :source))
      target = normalize_id(Map.get(edge, :target))
      flow_pps = normalize_u32(Map.get(edge, :flow_pps, 0))

      acc
      |> maybe_add_node_pps(source, flow_pps)
      |> maybe_add_node_pps(target, flow_pps)
    end)
  end

  defp node_pps_by_id(_), do: %{}

  defp maybe_add_node_pps(acc, node_id, value) when is_map(acc) and is_binary(node_id) do
    Map.update(acc, node_id, value, &(&1 + value))
  end

  defp maybe_add_node_pps(acc, _node_id, _value), do: acc

  defp layout_xy(idx, total) do
    radius = 120.0 + total * 0.8
    angle = idx * (2 * :math.pi() / total)
    x = Float.round(320 + radius * :math.cos(angle), 2)
    y = Float.round(160 + radius * :math.sin(angle), 2)
    {x, y}
  end

  defp apply_native_layout_with_indexed_edges(nodes, indexed_edges, topology_revision)
       when is_list(nodes) and is_list(indexed_edges) do
    if indexed_edges == [] do
      nodes
    else
      apply_layout_from_cache_or_native(nodes, indexed_edges, topology_revision)
    end
  end

  defp apply_native_layout_with_indexed_edges(nodes, _, _), do: nodes

  defp apply_layout_from_cache_or_native(nodes, indexed_edges, topology_revision) do
    case layout_coordinates_cache(topology_revision) do
      {:ok, coords_by_id} ->
        apply_cached_coordinates(nodes, coords_by_id)

      :miss ->
        apply_native_layout_and_cache(nodes, indexed_edges, topology_revision)
    end
  end

  defp apply_native_layout_and_cache(nodes, indexed_edges, topology_revision) do
    node_weights = Enum.map(nodes, &node_layout_weight/1)

    case Native.layout_nodes_hypergraph(length(nodes), indexed_edges, node_weights) do
      coordinates when is_list(coordinates) and length(coordinates) == length(nodes) ->
        nodes_with_coords = apply_layout_coordinates(nodes, coordinates)
        put_layout_coordinates_cache(topology_revision, nodes_with_coords)
        nodes_with_coords

      _ ->
        nodes
    end
  end

  defp apply_layout_coordinates(nodes, coordinates) when is_list(nodes) and is_list(coordinates) do
    nodes
    |> Enum.zip(coordinates)
    |> Enum.map(fn
      {node, {x, y}} when is_integer(x) and is_integer(y) ->
        %{node | x: x, y: y}

      {node, _} ->
        node
    end)
  end

  defp apply_layout_coordinates(nodes, _), do: nodes

  defp apply_cached_coordinates(nodes, coords_by_id) when is_list(nodes) and is_map(coords_by_id) do
    Enum.map(nodes, fn node ->
      case Map.get(coords_by_id, node.id) do
        {x, y} when is_integer(x) and is_integer(y) -> %{node | x: x, y: y}
        _ -> node
      end
    end)
  end

  defp apply_cached_coordinates(nodes, _), do: nodes

  defp node_layout_weight(node) when is_map(node) do
    kind =
      node
      |> Map.get(:kind, "endpoint")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    cond do
      kind in ["router", "firewall", "load_balancer"] -> 1000
      kind in ["switch", "hub"] -> 900
      kind in ["access point", "ap"] -> 850
      kind in ["ids", "ips"] -> 800
      kind in ["server", "virtual"] -> 600
      true -> 300
    end
  end

  defp node_layout_weight(_), do: 300

  defp index_edges(nodes, edges) when is_list(nodes) and is_list(edges) do
    node_index =
      nodes
      |> Enum.with_index()
      |> Map.new(fn {node, idx} -> {node.id, idx} end)

    {:ok,
     Enum.map(edges, fn edge ->
       {Map.fetch!(node_index, edge.source), Map.fetch!(node_index, edge.target)}
     end)}
  rescue
    error -> {:error, error}
  end

  defp index_edges(_nodes, _edges), do: {:error, :invalid_nodes}

  defp node_label(nil, id), do: id

  defp node_label(device, id) do
    Map.get(device, :name) ||
      Map.get(device, :hostname) ||
      id
  end

  defp node_kind(nil), do: "endpoint"
  defp node_kind(device), do: node_type(device) || "device"

  defp node_details_json(device, id) do
    details = %{
      id: id,
      name: Map.get(device || %{}, :name),
      hostname: Map.get(device || %{}, :hostname),
      ip: node_ip(device, id),
      type: node_type(device),
      type_id: Map.get(device || %{}, :type_id),
      vendor: Map.get(device || %{}, :vendor_name),
      model: Map.get(device || %{}, :model),
      last_seen:
        case Map.get(device || %{}, :last_seen_time) do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          %NaiveDateTime{} = ndt -> NaiveDateTime.to_iso8601(ndt)
          value when is_binary(value) -> value
          _ -> nil
        end,
      asn: node_meta_value(device, ["asn", "geo_asn", "armis_asn"]),
      geo_country: node_meta_value(device, ["country", "geo_country", "geoip_country"]),
      geo_city: node_meta_value(device, ["city", "geo_city", "geoip_city"]),
      geo_lat: node_geo_lat(device),
      geo_lon: node_geo_lon(device)
    }

    case Jason.encode(details) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp node_ip(nil, id), do: ip_like_id(id)

  defp node_ip(device, id) do
    direct =
      Map.get(device, :ip) ||
        Map.get(device, :mgmt_ip) ||
        Map.get(device, :management_ip) ||
        Map.get(device, :local_device_ip)

    metadata = Map.get(device, :metadata) || %{}

    meta =
      metadata_value(metadata, "ip") ||
        metadata_value(metadata, "mgmt_ip") ||
        metadata_value(metadata, "management_ip") ||
        metadata_value(metadata, "primary_ip") ||
        metadata_value(metadata, "ipv4") ||
        metadata_value(metadata, "host_ip")

    normalize_id(direct) || normalize_id(meta) || ip_like_id(id)
  end

  defp ip_like_id(id) when is_binary(id) do
    if String.match?(id, ~r/^\d{1,3}(\.\d{1,3}){3}$/), do: id
  end

  defp ip_like_id(_), do: nil

  defp node_type(nil), do: nil

  defp node_type(device) do
    metadata = Map.get(device, :metadata) || %{}

    Map.get(device, :type) ||
      metadata_value(metadata, "type") ||
      metadata_value(metadata, "device_type") ||
      metadata_value(metadata, "category") ||
      type_name_from_id(Map.get(device, :type_id))
  end

  defp type_name_from_id(0), do: "unknown"
  defp type_name_from_id(1), do: "server"
  defp type_name_from_id(2), do: "desktop"
  defp type_name_from_id(3), do: "laptop"
  defp type_name_from_id(4), do: "tablet"
  defp type_name_from_id(5), do: "mobile"
  defp type_name_from_id(6), do: "virtual"
  defp type_name_from_id(7), do: "iot"
  defp type_name_from_id(8), do: "browser"
  defp type_name_from_id(9), do: "firewall"
  defp type_name_from_id(10), do: "switch"
  defp type_name_from_id(11), do: "hub"
  defp type_name_from_id(12), do: "router"
  defp type_name_from_id(13), do: "ids"
  defp type_name_from_id(14), do: "ips"
  defp type_name_from_id(15), do: "load_balancer"
  defp type_name_from_id(99), do: "other"
  defp type_name_from_id(_), do: nil

  defp node_geo_lat(device) do
    node_meta_float(device, ["latitude", "geo_lat", "geoip_lat", "lat"])
  end

  defp node_geo_lon(device) do
    node_meta_float(device, ["longitude", "geo_lon", "geoip_lon", "lon"])
  end

  defp node_meta_value(nil, _keys), do: nil

  defp node_meta_value(device, keys) when is_map(device) and is_list(keys) do
    metadata = Map.get(device, :metadata) || %{}

    Enum.find_value(keys, fn key ->
      case metadata_value(metadata, key) do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> Integer.to_string(value)
        value when is_float(value) -> Float.to_string(value)
        _ -> nil
      end
    end)
  end

  defp node_meta_float(nil, _keys), do: nil

  defp node_meta_float(device, keys) when is_map(device) and is_list(keys) do
    metadata = Map.get(device, :metadata) || %{}

    Enum.find_value(keys, fn key ->
      metadata
      |> metadata_value(key)
      |> parse_node_meta_float()
    end)
  end

  defp parse_node_meta_float(value) when is_float(value), do: value
  defp parse_node_meta_float(value) when is_integer(value), do: value * 1.0

  defp parse_node_meta_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      _ -> nil
    end
  end

  defp parse_node_meta_float(_value), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    Map.get(metadata, key) ||
      Enum.find_value(Map.keys(metadata), fn
        atom_key when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: Map.get(metadata, atom_key)

        _ ->
          nil
      end)
  end

  defp metadata_value(_metadata, _key), do: nil

  defp health_signal(%{is_available: true}), do: :healthy
  defp health_signal(%{is_available: false}), do: :unhealthy
  defp health_signal(_), do: :unknown

  defp edge_contract_stats(edges) when is_list(edges) do
    fallback_edges =
      Enum.count(edges, fn edge -> Map.get(edge, :telemetry_source) == "device-fallback" end)

    interface_edges =
      Enum.count(edges, fn edge -> Map.get(edge, :telemetry_source) == "interface" end)

    unresolved_directional =
      Enum.count(edges, fn edge ->
        not directional_attribution_present?(edge, :ab) or
          not directional_attribution_present?(edge, :ba)
      end)

    directional_pps_mismatch =
      Enum.count(edges, fn edge ->
        normalize_u32(Map.get(edge, :flow_pps, 0)) !=
          normalize_u32(Map.get(edge, :flow_pps_ab, 0)) +
            normalize_u32(Map.get(edge, :flow_pps_ba, 0))
      end)

    directional_bps_mismatch =
      Enum.count(edges, fn edge ->
        normalize_u64(Map.get(edge, :flow_bps, 0)) !=
          normalize_u64(Map.get(edge, :flow_bps_ab, 0)) +
            normalize_u64(Map.get(edge, :flow_bps_ba, 0))
      end)

    %{
      edge_telemetry_interface: interface_edges,
      edge_telemetry_fallback: fallback_edges,
      edge_unresolved_directional: unresolved_directional,
      edge_directional_pps_mismatch: directional_pps_mismatch,
      edge_directional_bps_mismatch: directional_bps_mismatch
    }
  end

  defp edge_contract_stats(_), do: %{}

  defp directional_attribution_present?(edge, :ab) do
    valid_ifindex?(Map.get(edge, :local_if_index_ab)) or
      valid_if_name?(Map.get(edge, :local_if_name_ab))
  end

  defp directional_attribution_present?(edge, :ba) do
    valid_ifindex?(Map.get(edge, :local_if_index_ba)) or
      valid_if_name?(Map.get(edge, :local_if_name_ba))
  end

  defp valid_if_name?(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.downcase()
    trimmed not in ["", "unknown", "unk", "none", "n/a", "na", "null", "-"]
  end

  defp valid_if_name?(_), do: false

  defp node_oper_up_value(true), do: 1
  defp node_oper_up_value(false), do: 2
  defp node_oper_up_value(_), do: 0

  defp edge_label(edge), do: edge_label(edge, Map.get(edge, :flow_pps), Map.get(edge, :capacity_bps))

  defp edge_label(edge, flow_pps, capacity_bps) do
    protocol =
      edge
      |> Map.get(:protocol)
      |> to_string()
      |> String.trim()
      |> String.upcase()
      |> case do
        "" -> "LINK"
        value -> value
      end

    class_token =
      edge
      |> Map.get(:evidence_class)
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> case do
        "endpoint-attachment" -> "ENDPOINT"
        "inferred" -> "INFERRED"
        _ -> "BACKBONE"
      end

    "#{protocol} #{class_token} #{format_rate(flow_pps || 0)} / #{format_capacity(capacity_bps || 0)}"
  end

  defp edge_topology_class(edge) do
    case evidence_class(edge) do
      "endpoint-attachment" -> "endpoints"
      "inferred" -> "inferred"
      _ -> "backbone"
    end
  end

  defp format_rate(value) when is_integer(value) do
    cond do
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000, 1)}Mpps"
      value >= 1_000 -> "#{Float.round(value / 1_000, 1)}Kpps"
      true -> "#{value}pps"
    end
  end

  defp format_rate(_), do: "0pps"

  defp format_capacity(value) when is_integer(value) do
    cond do
      value >= 1_000_000_000 -> "#{trunc(value / 1_000_000_000)}G"
      value >= 100_000_000 -> "#{trunc(value / 1_000_000)}M"
      value > 0 -> "#{trunc(value / 1_000_000)}M"
      true -> "UNK"
    end
  end

  defp format_capacity(_), do: "UNK"

  defp apply_causal_states(nodes, indexed_edges) when is_list(nodes) and is_list(indexed_edges) do
    causal_overrides = routing_causal_node_overrides(nodes)

    signals =
      nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, idx} ->
        base_signal =
          case Map.get(node, :health_signal, :unknown) do
            :healthy -> 0
            :unhealthy -> 1
            _ -> 2
          end

        case Map.get(causal_overrides, idx) do
          %{signal: signal} when signal in [0, 1, 2] -> signal
          _ -> base_signal
        end
      end)

    case Native.evaluate_causal_states_with_reasons(signals, indexed_edges) do
      rows when is_list(rows) and length(rows) == length(nodes) ->
        nodes
        |> Enum.with_index()
        |> Enum.zip(rows)
        |> Enum.map(fn {{node, idx}, row} ->
          base_state = causal_row_value(row, :state, 3)
          override = Map.get(causal_overrides, idx)
          state = override_state(base_state, override)

          reason =
            override_reason(causal_row_value(row, :reason, "causal_reason_unavailable"), override)

          root_index = causal_row_value(row, :root_index, -1)
          parent_index = causal_row_value(row, :parent_index, -1)
          hop_distance = causal_row_value(row, :hop_distance, -1)

          details_json =
            merge_causal_reason_details(
              Map.get(node, :details_json),
              state,
              reason,
              root_index,
              parent_index,
              hop_distance
            )

          node
          |> Map.put(:state, state)
          |> Map.put(:details_json, details_json)
          |> Map.delete(:health_signal)
        end)

      _ ->
        states = Native.evaluate_causal_states(signals, indexed_edges)

        nodes
        |> Enum.with_index()
        |> Enum.zip(states)
        |> Enum.map(fn {{node, idx}, state} ->
          override = Map.get(causal_overrides, idx)
          state = override_state(state, override)
          reason = override_reason("fallback_state_only_engine_result", override)

          details_json =
            merge_causal_reason_details(
              Map.get(node, :details_json),
              state,
              reason,
              -1,
              -1,
              -1
            )

          node
          |> Map.put(:state, state)
          |> Map.put(:details_json, details_json)
          |> Map.delete(:health_signal)
        end)
    end
  end

  defp apply_causal_states(nodes, _), do: nodes

  defp routing_causal_node_overrides(nodes) when is_list(nodes) do
    indexed_keys =
      nodes
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {node, idx}, acc ->
        node
        |> node_correlation_keys()
        |> Enum.reduce(acc, fn key, inner ->
          Map.update(inner, key, MapSet.new([idx]), &MapSet.put(&1, idx))
        end)
      end)

    Enum.reduce(fetch_recent_routing_causal_events(), %{}, &apply_routing_event_overrides(&2, indexed_keys, &1))
  end

  defp routing_causal_node_overrides(_), do: %{}

  defp apply_routing_event_overrides(overrides, indexed_keys, event) do
    event_override = event_overlay_override(event)

    event
    |> event_correlation_keys()
    |> Enum.reduce(overrides, fn key, acc ->
      put_routing_override_for_key(acc, indexed_keys, key, event_override)
    end)
  end

  defp put_routing_override_for_key(overrides, indexed_keys, key, event_override) do
    indexed_keys
    |> Map.get(key)
    |> index_key_matches()
    |> Enum.reduce(overrides, &Map.put_new(&2, &1, event_override))
  end

  defp index_key_matches(nil), do: []
  defp index_key_matches(node_indexes), do: MapSet.to_list(node_indexes)

  defp node_correlation_keys(node) when is_map(node) do
    details =
      case Map.get(node, :details_json) do
        value when is_binary(value) ->
          case Jason.decode(value) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    [
      normalize_id(Map.get(node, :id)),
      normalize_id(Map.get(details, "ip")),
      normalize_id(Map.get(details, "hostname"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp node_correlation_keys(_), do: []

  defp event_correlation_keys(event) when is_map(event) do
    metadata = map_value(event, :metadata) || %{}
    routing = map_value(metadata, "routing_correlation") || %{}
    source_identity = map_value(metadata, "source_identity") || %{}
    device = map_value(event, :device) || %{}
    src_endpoint = map_value(event, :src_endpoint) || %{}

    topology_keys =
      case map_value(routing, "topology_keys") do
        values when is_list(values) -> values
        values when is_map(values) -> Map.values(values)
        _ -> []
      end

    [
      map_value(device, "uid"),
      map_value(src_endpoint, "ip"),
      map_value(routing, "router_id"),
      map_value(routing, "router_ip"),
      map_value(routing, "peer_ip"),
      map_value(routing, "target_device_uid"),
      map_value(routing, "target_ip"),
      map_value(source_identity, "device_uid"),
      map_value(source_identity, "router_id"),
      map_value(source_identity, "router_ip"),
      map_value(source_identity, "peer_ip")
      | topology_keys
    ]
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp event_correlation_keys(_), do: []

  defp fetch_recent_routing_causal_events do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-causal_overlay_window_seconds(), :second)
      |> DateTime.truncate(:second)

    source_limit = causal_overlay_source_limit()
    max_events = causal_overlay_max_events()

    bmp_events = fetch_recent_bmp_routing_events(cutoff, source_limit)
    ocsf_events = fetch_recent_ocsf_causal_events(cutoff, source_limit)

    (bmp_events ++ ocsf_events)
    |> dedupe_recent_causal_events()
    |> Enum.take(max_events)
  rescue
    _ -> []
  end

  defp fetch_recent_bmp_routing_events(cutoff, limit) do
    query =
      from(e in "bmp_routing_events",
        where: e.time >= ^cutoff,
        where: coalesce(e.severity_id, 0) >= ^routing_causal_severity_threshold(),
        order_by: [desc: e.time],
        limit: ^limit,
        select: %{
          source: "bmp_routing_events",
          event_time: e.time,
          event_identity: e.metadata["event_identity"],
          metadata: e.metadata,
          device: %{"uid" => e.router_id},
          src_endpoint: %{"ip" => e.peer_ip}
        }
      )

    Repo.all(query)
  rescue
    _ -> []
  end

  defp fetch_recent_ocsf_causal_events(cutoff, limit) do
    query =
      from(e in "ocsf_events",
        where: e.time >= ^cutoff,
        where:
          fragment(
            "(?->>'signal_type' = 'mtr') OR (((?->>'signal_type' = 'bmp') OR (?->>'primary_domain' = 'routing')) AND coalesce(?, 0) >= ?)",
            e.metadata,
            e.metadata,
            e.metadata,
            e.severity_id,
            ^routing_causal_severity_threshold()
          ),
        order_by: [desc: e.time],
        limit: ^limit,
        select: %{
          source: "ocsf_events",
          event_time: e.time,
          event_identity: e.metadata["event_identity"],
          metadata: e.metadata,
          device: e.device,
          src_endpoint: e.src_endpoint
        }
      )

    Repo.all(query)
  rescue
    _ -> []
  end

  defp dedupe_recent_causal_events(events) when is_list(events) do
    events
    |> Enum.sort_by(&event_sort_key/1, :desc)
    |> Enum.reduce({MapSet.new(), []}, fn event, {seen, acc} ->
      key = causal_event_dedupe_key(event)

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [event | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp dedupe_recent_causal_events(_), do: []

  defp event_sort_key(event) when is_map(event) do
    event_time =
      case map_value(event, :event_time) do
        %DateTime{} = value -> value
        _ -> DateTime.from_unix!(0, :second)
      end

    {event_time, source_rank(map_value(event, :source))}
  end

  defp event_sort_key(_), do: {DateTime.from_unix!(0, :second), 0}

  defp source_rank("bmp_routing_events"), do: 2
  defp source_rank("ocsf_events"), do: 1
  defp source_rank(_), do: 0

  defp event_overlay_override(event) when is_map(event) do
    metadata = map_value(event, :metadata) || %{}
    signal_type = normalize_id(map_value(metadata, "signal_type"))
    event_type = normalize_id(map_value(metadata, "event_type"))

    case {signal_type, event_type} do
      {"mtr", "target_outage"} ->
        %{signal: 1, forced_state: 0, reason: "mtr_target_outage"}

      {"mtr", "path_scoped_issue"} ->
        %{signal: 1, forced_state: 1, reason: "mtr_path_scoped_issue"}

      {"mtr", "degraded_path"} ->
        %{signal: 1, forced_state: 1, reason: "mtr_degraded_path"}

      {"mtr", "healthy"} ->
        %{signal: 0, forced_state: 2, reason: "mtr_healthy"}

      _ ->
        %{signal: 1, forced_state: nil, reason: "routing_causal_overlay"}
    end
  end

  defp event_overlay_override(_), do: %{signal: 1, forced_state: nil, reason: "routing_causal_overlay"}

  defp causal_event_dedupe_key(event) when is_map(event) do
    event_identity = map_value(event, :event_identity)
    metadata = map_value(event, :metadata) || %{}
    metadata_identity = map_value(metadata, "event_identity")
    source = map_value(event, :source) || "unknown"
    fallback_time = map_value(event, :event_time)

    event_identity || metadata_identity || "#{source}:#{inspect(fallback_time)}"
  end

  defp causal_event_dedupe_key(_), do: "unknown"

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key)
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp map_value(_, _), do: nil

  defp causal_overlay_window_seconds do
    BmpSettingsRuntime.god_view_causal_overlay_window_seconds()
  end

  defp causal_overlay_max_events do
    BmpSettingsRuntime.god_view_causal_overlay_max_events()
  end

  defp causal_overlay_source_limit do
    max(1, causal_overlay_max_events() * 2)
  end

  defp routing_causal_severity_threshold do
    BmpSettingsRuntime.god_view_routing_causal_severity_threshold()
  end

  defp causal_row_value(row, key, default) when is_map(row) do
    Map.get(row, key, Map.get(row, Atom.to_string(key), default))
  end

  defp causal_row_value(_row, _key, default), do: default

  defp override_state(_base_state, %{forced_state: forced}) when forced in [0, 1, 2, 3], do: forced

  defp override_state(base_state, _), do: base_state

  defp override_reason(_base_reason, %{reason: reason}) when is_binary(reason) and reason != "", do: reason

  defp override_reason(base_reason, _), do: base_reason

  defp merge_causal_reason_details(details_json, state, reason, root_index, parent_index, hop_distance) do
    base =
      case details_json do
        value when is_binary(value) ->
          case Jason.decode(value) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    updated =
      base
      |> Map.put("state_label", causal_state_label(state))
      |> Map.put("causal_reason", to_string(reason))
      |> Map.put("causal_root_index", root_index)
      |> Map.put("causal_parent_index", parent_index)
      |> Map.put("causal_hop_distance", hop_distance)

    case Jason.encode(updated) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp causal_state_label(0), do: "Root Cause"
  defp causal_state_label(1), do: "Affected"
  defp causal_state_label(2), do: "Healthy"
  defp causal_state_label(_), do: "Unknown"

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

  defp normalize_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    if invalid_identifier_token?(trimmed) do
      nil
    else
      trimmed
    end
  end

  defp normalize_id(_), do: nil

  defp invalid_identifier_token?(value) when is_binary(value) do
    lowered = String.downcase(value)
    lowered in ["", "nil", "null", "undefined", "unknown", "n/a", "na", "-"]
  end

  defp confidence_tier(link) do
    Map.get(Map.get(link, :metadata) || %{}, "confidence_tier", Map.get(link, :confidence_tier, "unknown"))
  end

  defp evidence_class(link) do
    metadata = Map.get(link, :metadata) || %{}
    explicit = metadata["evidence_class"] || metadata[:evidence_class] || Map.get(link, :evidence_class)
    relation_type = metadata["relation_type"] || metadata[:relation_type] || Map.get(link, :relation_type)

    normalized_evidence_class(explicit) ||
      evidence_class_from_relation_type(relation_type) ||
      "unknown"
  end

  defp normalized_evidence_class(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      normalized when normalized in @god_view_evidence_classes -> normalized
      _ -> nil
    end
  end

  defp evidence_class_from_relation_type(value) when is_binary(value) do
    case String.upcase(String.trim(value)) do
      "ATTACHED_TO" -> "endpoint-attachment"
      "INFERRED_TO" -> "inferred"
      "CONNECTS_TO" -> "direct"
      _ -> nil
    end
  end

  defp evidence_class_from_relation_type(_value), do: nil

  defp page_results(%{results: results}) when is_list(results), do: results
  defp page_results(_), do: []

  defp normalize_u16(value) when is_integer(value), do: clamp(value, 0, 65_535)

  defp normalize_u16(value) when is_float(value), do: value |> Float.round() |> trunc() |> normalize_u16()

  defp normalize_u16(_), do: 0

  defp normalize_u8(value) when is_integer(value), do: clamp(value, 0, 255)
  defp normalize_u8(_), do: 0
  defp normalize_u32(value) when is_integer(value), do: clamp(value, 0, 4_294_967_295)
  defp normalize_u32(_), do: 0
  defp normalize_u64(value) when is_integer(value), do: max(value, 0)
  defp normalize_u64(_), do: 0

  defp normalize_label(value) when is_binary(value) do
    trimmed = String.trim(value)
    lowered = String.downcase(trimmed)

    cond do
      trimmed == "" -> "node"
      lowered in ["nil", "null", "undefined"] -> "node"
      byte_size(trimmed) > 96 -> binary_part(trimmed, 0, 96)
      true -> trimmed
    end
  end

  defp normalize_label(_), do: "node"

  defp normalize_details_json(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      "{}"
    else
      case Jason.decode(trimmed) do
        {:ok, _decoded} -> trimmed
        _ -> "{}"
      end
    end
  end

  defp normalize_details_json(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp normalize_details_json(_), do: "{}"

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp topology_revision(nodes, indexed_edges) when is_list(nodes) and is_list(indexed_edges) do
    node_ids = nodes |> Enum.map(& &1.id) |> Enum.sort()

    indexed_edges =
      indexed_edges
      |> Enum.map(fn
        {a, b} when is_integer(a) and is_integer(b) and a <= b -> {a, b}
        {a, b} when is_integer(a) and is_integer(b) -> {b, a}
        other -> other
      end)
      |> Enum.sort()

    stable_positive_hash({node_ids, indexed_edges})
  end

  defp topology_revision(_nodes, _indexed_edges), do: 1

  defp causal_revision(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn node -> {Map.get(node, :id), Map.get(node, :state, 3)} end)
    |> Enum.sort()
    |> stable_positive_hash()
  end

  defp causal_revision(_), do: 1

  defp snapshot_revision(topology_revision, causal_revision) do
    stable_positive_hash({topology_revision, causal_revision})
  end

  defp stable_positive_hash(term) do
    case :erlang.phash2(term, 4_294_967_295) do
      0 -> 1
      value -> value
    end
  end

  defp layout_coordinates_cache(topology_revision) when is_integer(topology_revision) do
    case :persistent_term.get(@layout_cache_key, nil) do
      %{topology_revision: ^topology_revision, coords_by_id: coords_by_id}
      when is_map(coords_by_id) ->
        {:ok, coords_by_id}

      _ ->
        :miss
    end
  end

  defp layout_coordinates_cache(_), do: :miss

  defp put_layout_coordinates_cache(topology_revision, nodes) when is_integer(topology_revision) and is_list(nodes) do
    coords_by_id =
      Map.new(nodes, fn node ->
        {node.id, {normalize_u16(Map.get(node, :x, 0)), normalize_u16(Map.get(node, :y, 0))}}
      end)

    :persistent_term.put(@layout_cache_key, %{
      topology_revision: topology_revision,
      coords_by_id: coords_by_id
    })
  end

  defp put_layout_coordinates_cache(_, _), do: :ok

  defp snapshot_coalesce_ms do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_snapshot_coalesce_ms,
      @default_snapshot_coalesce_ms
    )
  end

  defp parity_alert_delta_threshold do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_pipeline_parity_alert_delta,
      @default_parity_alert_delta
    )
  end

  defp unresolved_directional_ratio_alert_threshold do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_pipeline_unresolved_directional_ratio_alert,
      @default_unresolved_directional_ratio_alert
    )
  end

  defp unresolved_ratio(unresolved_directional, final_edges)
       when is_integer(unresolved_directional) and is_integer(final_edges) and final_edges > 0 do
    unresolved_directional / final_edges
  end

  defp unresolved_ratio(_unresolved_directional, _final_edges), do: 0.0

  defp coalesced_snapshot(coalesce_ms) when is_integer(coalesce_ms) and coalesce_ms > 0 do
    case :persistent_term.get(@snapshot_cache_key, nil) do
      %{result: result, built_at_ms: built_at_ms}
      when is_map(result) and is_integer(built_at_ms) ->
        now_ms = System.monotonic_time(:millisecond)

        if now_ms - built_at_ms <= coalesce_ms do
          {:ok, result}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  defp coalesced_snapshot(_), do: :miss

  defp put_snapshot_cache(result) when is_map(result) do
    :persistent_term.put(@snapshot_cache_key, %{
      result: result,
      built_at_ms: System.monotonic_time(:millisecond)
    })
  end

  defp put_snapshot_cache(_), do: :ok

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
