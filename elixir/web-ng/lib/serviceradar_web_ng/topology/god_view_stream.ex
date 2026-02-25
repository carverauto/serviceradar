defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds God-View snapshot payloads backed by the Rust Arrow encoder.
  """

  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  import Ecto.Query

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Observability.BmpSettingsRuntime
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.RuntimeGraph
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.Native

  @max_interface_rows 2_000
  @default_real_time_budget_ms 2_000
  @default_snapshot_coalesce_ms 0
  @drop_counter_key {__MODULE__, :dropped_updates}
  @layout_cache_key {__MODULE__, :layout_cache}
  @snapshot_cache_key {__MODULE__, :snapshot_cache}
  @packet_metric_names ["ifInUcastPkts", "ifOutUcastPkts", "ifHCInUcastPkts", "ifHCOutUcastPkts"]
  @octet_metric_names ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"]

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
         revision <- snapshot_revision(projection.topology_revision, projection.causal_revision),
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
          normalize_label(Map.get(node, :details_json) || "{}")
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
     Native.encode_snapshot(
       snapshot.schema_version,
       snapshot.revision,
       nodes,
       edges,
       edge_meta,
       edge_directional,
       byte_size(root),
       byte_size(affected),
       byte_size(healthy),
       byte_size(unknown)
     )}
  end

  defp build_projection(actor) do
    with {:ok, links} <- fetch_topology_links(actor),
         {:ok, pairs} <- unique_pairs(links),
         {:ok, nodes, edges, pipeline_stats} <- build_nodes_and_edges(actor, links, pairs),
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

  defp unique_pairs(links) when is_list(links) do
    pairs =
      Enum.reduce(links, %{}, fn link, acc ->
        local_id = normalize_local_id(link) || fallback_local_id(link)
        neighbor_id = normalize_neighbor_id(link) || fallback_neighbor_id(link)

        if is_nil(local_id) or is_nil(neighbor_id) or local_id == neighbor_id do
          acc
        else
          {a, b} = canonical_pair(local_id, neighbor_id)
          candidate = build_pair_candidate(link, local_id, neighbor_id)

          # Backend canonical topology query is ordered by freshest observation first.
          # Keep the first candidate per pair and avoid UI-side pair synthesis/merging.
          Map.put_new(acc, {a, b}, candidate)
        end
      end)

    {:ok, pairs}
  end

  defp unique_pairs(_links), do: {:ok, %{}}

  defp build_pair_candidate(link, local_id, neighbor_id) do
    local_if_index = Map.get(link, :local_if_index)
    local_if_name = normalize_id(Map.get(link, :local_if_name))
    neighbor_if_index = Map.get(link, :neighbor_if_index)
    neighbor_if_name = normalize_id(Map.get(link, :neighbor_if_name))
    remote_port_hint = normalize_neighbor_port_hint(link)

    %{
      source: local_id,
      target: neighbor_id,
      kind: "topology",
      protocol: Map.get(link, :protocol),
      evidence_class: evidence_class(link),
      confidence_tier: confidence_tier(link),
      local_device_ip: normalize_id(Map.get(link, :local_device_ip)),
      neighbor_mgmt_addr: normalize_id(Map.get(link, :neighbor_mgmt_addr)),
      local_if_index: local_if_index,
      local_if_name: local_if_name,
      neighbor_if_index: neighbor_if_index,
      neighbor_if_name: neighbor_if_name,
      metadata: Map.get(link, :metadata) || %{},
      local_if_index_ab: local_if_index,
      local_if_name_ab: local_if_name,
      local_if_index_ba: neighbor_if_index,
      # Reverse attribution should come from canonical neighbor fields emitted by backend.
      local_if_name_ba: neighbor_if_name || remote_port_hint
    }
  end

  defp build_nodes_and_edges(actor, raw_links, pairs) do
    pair_edges = Map.values(pairs)
    edge_node_ids = pairs |> Map.keys() |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()
    topology_endpoint_ids = raw_topology_endpoint_ids(raw_links)
    lookup_ids = Enum.uniq(edge_node_ids ++ topology_endpoint_ids)

    with {:ok, devices} <- fetch_devices(actor, lookup_ids),
         {:ok, seeded_devices} <- fetch_seed_devices(),
         {:ok, resolved_devices} <- resolve_devices_for_topology(lookup_ids),
         {:ok, interfaces} <- fetch_interfaces(actor, edge_node_ids) do
      devices =
        devices
        |> merge_devices(seeded_devices)
        |> merge_devices(resolved_devices)

      canonical_edges =
        pair_edges
        |> canonicalize_edges(devices)
        |> maybe_apply_structural_pruning(devices)
        |> maybe_apply_edge_normalization(devices)

      canonical_node_ids =
        canonical_edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

      device_by_id = Map.new(devices, &{&1.uid, &1})
      interface_index = index_interfaces(interfaces)
      edge_metric_keys = directional_metric_keys(canonical_edges)
      pps_by_if = load_interface_pps(interface_index, edge_metric_keys)
      bps_by_if = load_interface_bps(interface_index, edge_metric_keys)
      pps_by_if_direction = load_interface_pps_direction(interface_index, edge_metric_keys)
      bps_by_if_direction = load_interface_bps_direction(interface_index, edge_metric_keys)
      node_ids = node_ids(canonical_node_ids, devices)
      nodes = build_nodes(node_ids, device_by_id, interface_index, pps_by_if)

      edges = canonical_edges |> dedupe_edges()
      device_totals = device_telemetry_totals(interface_index, pps_by_if, bps_by_if)

      with {:ok, edges} <-
             enrich_edges_via_native(
               edges,
               interfaces,
               pps_by_if_direction,
               bps_by_if_direction
             ) do
        edges = apply_edge_telemetry_fallback(edges, device_totals)
        edge_contract_stats = edge_contract_stats(edges)

        unresolved_endpoints =
          Enum.count(canonical_node_ids, fn id -> not Map.has_key?(device_by_id, id) end)

        pipeline_stats =
          pipeline_stats(raw_links, pair_edges, edges, nodes, unresolved_endpoints)
          |> Map.merge(edge_contract_stats)
          |> Map.merge(component_stats(nodes, edges))

        {:ok, nodes, edges, pipeline_stats}
      end
    end
  end

  defp raw_topology_endpoint_ids(raw_links) when is_list(raw_links) do
    raw_links
    |> Enum.flat_map(fn link ->
      [
        normalize_local_id(link),
        fallback_local_id(link),
        normalize_neighbor_id(link),
        fallback_neighbor_id(link)
      ]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp raw_topology_endpoint_ids(_), do: []

  defp maybe_apply_structural_pruning(edges, devices) do
    _ = devices
    edges
  end

  defp maybe_apply_edge_normalization(edges, devices) do
    _ = devices
    edges
  end

  defp pipeline_stats(raw_links, pair_links, final_edges, final_nodes, unresolved_endpoints)
       when is_list(raw_links) and is_list(pair_links) and is_list(final_edges) and
              is_list(final_nodes) and is_integer(unresolved_endpoints) do
    %{
      raw_links: length(raw_links),
      unique_pairs: length(pair_links),
      final_edges: length(final_edges),
      final_nodes: length(final_nodes),
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

  defp pipeline_stats(_raw_links, _pair_links, _final_edges, _final_nodes, _unresolved_endpoints),
    do: %{}

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
        Map.get(adjacency, node, MapSet.new()) |> MapSet.size() == 0
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

        {rest, visited} =
          Enum.reduce(neighbors, {rest, visited}, fn neighbor, {q, vis} ->
            if MapSet.member?(vis, neighbor) do
              {q, vis}
            else
              {:queue.in(neighbor, q), MapSet.put(vis, neighbor)}
            end
          end)

        bfs_component_size(rest, adjacency, visited, size + 1)

      {:empty, _} ->
        {size, visited}
    end
  end

  defp emit_pipeline_stats(measurements) when is_map(measurements) do
    :telemetry.execute([:serviceradar, :god_view, :pipeline, :stats], measurements, %{})
    Logger.info("god_view_pipeline_stats #{inspect(measurements)}")
  end

  defp emit_pipeline_stats(_measurements), do: :ok

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

  defp fetch_seed_devices do
    query =
      from(mj in "mapper_jobs",
        join: mjs in "mapper_job_seeds",
        on: mjs.mapper_job_id == mj.id,
        join: d in "ocsf_devices",
        on:
          is_nil(d.deleted_at) and
            (d.ip == mjs.seed or d.uid == mjs.seed or d.name == mjs.seed or d.hostname == mjs.seed),
        where: mj.enabled == true,
        order_by: [desc: d.last_seen_time],
        select: %{
          uid: d.uid,
          name: d.name,
          hostname: d.hostname,
          ip: d.ip,
          type: d.type,
          type_id: d.type_id,
          vendor_name: d.vendor_name,
          model: d.model,
          metadata: d.metadata,
          last_seen_time: d.last_seen_time,
          is_available: d.is_available
        }
      )

    {:ok, Repo.all(query)}
  rescue
    _ -> {:ok, []}
  end

  defp resolve_devices_for_topology([]), do: {:ok, []}

  defp resolve_devices_for_topology(raw_ids) when is_list(raw_ids) do
    ids =
      raw_ids
      |> Enum.map(&normalize_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      query =
        from(d in "ocsf_devices",
          where:
            is_nil(d.deleted_at) and
              (d.uid in ^ids or d.ip in ^ids or d.name in ^ids or d.hostname in ^ids or
                 fragment("?->>'device_id' = ANY(?)", d.metadata, ^ids)),
          select: %{
            uid: d.uid,
            name: d.name,
            hostname: d.hostname,
            ip: d.ip,
            type: d.type,
            type_id: d.type_id,
            vendor_name: d.vendor_name,
            model: d.model,
            metadata: d.metadata,
            last_seen_time: d.last_seen_time,
            is_available: d.is_available
          }
        )

      {:ok, Repo.all(query)}
    end
  rescue
    _ -> {:ok, []}
  end

  defp merge_devices(devices, extra_devices) do
    (devices ++ extra_devices)
    |> Enum.reduce(%{}, fn device, acc ->
      uid = normalize_id(Map.get(device, :uid))

      if is_binary(uid) do
        Map.put_new(acc, uid, device)
      else
        acc
      end
    end)
    |> Map.values()
  end

  defp canonicalize_edges(edges, devices) when is_list(edges) do
    alias_map = device_alias_map(devices)
    known_ids = MapSet.new(Map.values(alias_map))

    edges
    |> Enum.map(fn edge ->
      source =
        edge
        |> Map.get(:source)
        |> normalize_id()
        |> canonicalize_endpoint_id(alias_map, known_ids)

      target =
        edge
        |> Map.get(:target)
        |> normalize_id()
        |> canonicalize_endpoint_id(alias_map, known_ids)

      telemetry_eligible = telemetry_eligible_edge?(edge)

      edge
      |> Map.put(:source, source)
      |> Map.put(:target, target)
      |> Map.put(:telemetry_eligible, telemetry_eligible)
    end)
    |> Enum.reject(fn edge ->
      is_nil(Map.get(edge, :source)) or is_nil(Map.get(edge, :target)) or
        Map.get(edge, :source) == Map.get(edge, :target)
    end)
  end

  defp canonicalize_edges(_, _), do: []

  defp canonicalize_endpoint_id(nil, _alias_map, _known_ids), do: nil

  defp canonicalize_endpoint_id(endpoint_id, alias_map, known_ids) when is_binary(endpoint_id) do
    canonical = Map.get(alias_map, endpoint_id, endpoint_id)

    cond do
      MapSet.member?(known_ids, canonical) -> canonical
      interface_like_identifier?(canonical) -> nil
      malformed_identifier?(canonical) -> nil
      true -> canonical
    end
  end

  defp canonicalize_endpoint_id(_endpoint_id, _alias_map, _known_ids), do: nil

  defp device_alias_map(devices) when is_list(devices) do
    Enum.reduce(devices, %{}, fn device, acc ->
      uid = normalize_id(Map.get(device, :uid))

      if is_binary(uid) do
        aliases = device_aliases(device, uid)

        Enum.reduce(aliases, Map.put_new(acc, uid, uid), fn alias_id, inner ->
          Map.put_new(inner, alias_id, uid)
        end)
      else
        acc
      end
    end)
  end

  defp device_alias_map(_), do: %{}

  defp device_aliases(device, uid) when is_map(device) and is_binary(uid) do
    metadata = Map.get(device, :metadata) || %{}

    metadata_aliases =
      metadata
      |> Enum.flat_map(fn
        {key, _value} ->
          case to_string(key) do
            <<"alt_mac:", mac::binary>> ->
              mac
              |> normalize_mac_hex()
              |> case do
                nil -> []
                hex -> ["mac-" <> hex]
              end

            _ ->
              []
          end
      end)

    [
      uid,
      normalize_id(metadata["device_id"]),
      normalize_id(Map.get(device, :ip)),
      normalize_id(Map.get(device, :name)),
      normalize_id(Map.get(device, :hostname))
      | metadata_aliases
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp device_aliases(_device, _uid), do: []

  defp telemetry_eligible_edge?(edge) when is_map(edge) do
    directional_attributed? =
      directional_attribution_present?(edge, :ab) or directional_attribution_present?(edge, :ba)

    cond do
      directional_attributed? -> true
      unifi_unattributed?(edge) -> false
      snmp_interface_attributed?(edge) -> true
      true -> valid_ifindex?(Map.get(edge, :local_if_index))
    end
  end

  defp telemetry_eligible_edge?(_), do: false

  defp unifi_unattributed?(edge) when is_map(edge) do
    edge_protocol(edge) == "unifi-api" and not snmp_interface_attributed?(edge)
  end

  defp unifi_unattributed?(_), do: false

  defp snmp_interface_attributed?(edge) when is_map(edge) do
    valid_ifindex?(Map.get(edge, :local_if_index)) or
      interface_name_attributed?(Map.get(edge, :local_if_name)) or
      directional_attribution_present?(edge, :ab) or
      directional_attribution_present?(edge, :ba)
  end

  defp snmp_interface_attributed?(_), do: false

  defp interface_name_attributed?(value) do
    case normalize_id(value) do
      name when is_binary(name) ->
        not mac_like_identifier?(name) and not placeholder_identifier?(name)

      _ ->
        false
    end
  end

  defp placeholder_identifier?(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))
    normalized in ["unknown", "unk", "none", "n/a", "na", "null", "-"]
  end

  defp placeholder_identifier?(_), do: false

  defp mac_like_identifier?(value) when is_binary(value) do
    normalized = normalize_mac_hex(value)
    is_binary(normalized) and byte_size(normalized) == 12
  end

  defp mac_like_identifier?(_), do: false

  defp normalize_mac_hex(value) when is_binary(value) do
    condensed =
      value
      |> String.downcase()
      |> String.replace(":", "")
      |> String.replace("-", "")

    if Regex.match?(~r/\A[0-9a-f]{12}\z/, condensed), do: condensed, else: nil
  end

  defp normalize_mac_hex(_), do: nil

  defp dedupe_edges(edges) when is_list(edges) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      source = Map.get(edge, :source)
      target = Map.get(edge, :target)

      if is_binary(source) and is_binary(target) and source != target do
        {a, b} = canonical_pair(source, target)

        Map.update(acc, {a, b}, edge, fn existing ->
          if edge_rank(edge) > edge_rank(existing), do: edge, else: existing
        end)
      else
        acc
      end
    end)
    |> Map.values()
  end

  defp dedupe_edges(_), do: []

  defp valid_ifindex?(value) when is_integer(value), do: value > 0
  defp valid_ifindex?(_value), do: false

  defp edge_rank(edge) when is_map(edge) do
    confidence_rank =
      case confidence_tier(edge) do
        "high" -> 3
        "medium" -> 2
        "low" -> 1
        _ -> 0
      end

    protocol_rank =
      case edge_protocol(edge) do
        "wireguard-derived" -> 5
        "lldp" -> 4
        "cdp" -> 4
        "unifi-api" -> if(snmp_interface_attributed?(edge), do: 3, else: 0)
        "snmp-l2" -> 2
        "snmp-parent" -> 1
        "snmp-site" -> 0
        _ -> 0
      end

    telemetry_rank =
      cond do
        directional_attribution_present?(edge, :ab) and
            directional_attribution_present?(edge, :ba) ->
          3

        directional_attribution_present?(edge, :ab) or
            directional_attribution_present?(edge, :ba) ->
          2

        valid_ifindex?(Map.get(edge, :local_if_index)) ->
          2

        is_binary(normalize_id(Map.get(edge, :local_if_name))) ->
          1

        true ->
          0
      end

    {confidence_rank, protocol_rank, telemetry_rank}
  end

  defp edge_rank(_), do: {0, 0, 0}

  defp fetch_interfaces(_actor, []), do: {:ok, []}

  defp fetch_interfaces(actor, node_ids) when is_list(node_ids) do
    query =
      Interface
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(device_id in ^node_ids)
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(@max_interface_rows)

    case Ash.read(query, actor: actor) do
      {:ok, interfaces} when is_list(interfaces) -> {:ok, interfaces}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp build_nodes(node_ids, device_by_id, interface_index, pps_by_if) do
    total = max(length(node_ids), 1)

    node_ids
    |> Enum.with_index()
    |> Enum.map(fn {id, idx} ->
      {x, y} = layout_xy(idx, total)
      device = Map.get(device_by_id, id)
      interface_rows = Map.get(interface_index.by_device, id, [])
      {pps, oper_up} = node_telemetry(interface_rows, pps_by_if)

      %{
        id: id,
        label: node_label(device, id),
        kind: node_kind(device),
        x: x,
        y: y,
        state: 3,
        pps: pps,
        oper_up: oper_up,
        details_json: node_details_json(device, id),
        geo_lat: node_geo_lat(device),
        geo_lon: node_geo_lon(device),
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

  defp apply_native_layout_with_indexed_edges(nodes, indexed_edges, topology_revision)
       when is_list(nodes) and is_list(indexed_edges) do
    if indexed_edges == [] do
      nodes
    else
      case layout_coordinates_cache(topology_revision) do
        {:ok, coords_by_id} ->
          apply_cached_coordinates(nodes, coords_by_id)

        :miss ->
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
    end
  end

  defp apply_native_layout_with_indexed_edges(nodes, _, _), do: nodes

  defp apply_layout_coordinates(nodes, coordinates)
       when is_list(nodes) and is_list(coordinates) do
    Enum.zip(nodes, coordinates)
    |> Enum.map(fn
      {node, {x, y}} when is_integer(x) and is_integer(y) ->
        %{node | x: x, y: y}

      {node, _} ->
        node
    end)
  end

  defp apply_layout_coordinates(nodes, _), do: nodes

  defp apply_cached_coordinates(nodes, coords_by_id)
       when is_list(nodes) and is_map(coords_by_id) do
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
      metadata["ip"] ||
        metadata["mgmt_ip"] ||
        metadata["management_ip"] ||
        metadata["primary_ip"] ||
        metadata["ipv4"] ||
        metadata["host_ip"]

    normalize_id(direct) || normalize_id(meta) || ip_like_id(id)
  end

  defp ip_like_id(id) when is_binary(id) do
    if String.match?(id, ~r/^\d{1,3}(\.\d{1,3}){3}$/), do: id, else: nil
  end

  defp ip_like_id(_), do: nil

  defp node_type(nil), do: nil

  defp node_type(device) do
    metadata = Map.get(device, :metadata) || %{}

    Map.get(device, :type) ||
      metadata["type"] ||
      metadata["device_type"] ||
      metadata["category"] ||
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

    keys
    |> Enum.find_value(fn key ->
      case Map.get(metadata, key) do
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

    keys
    |> Enum.find_value(fn key ->
      case Map.get(metadata, key) do
        value when is_float(value) ->
          value

        value when is_integer(value) ->
          value * 1.0

        value when is_binary(value) ->
          case Float.parse(value) do
            {parsed, _} -> parsed
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp health_signal(%{is_available: true}), do: :healthy
  defp health_signal(%{is_available: false}), do: :unhealthy
  defp health_signal(_), do: :unknown

  defp index_interfaces(interfaces) when is_list(interfaces) do
    Enum.reduce(interfaces, %{by_device: %{}, by_device_if: %{}}, fn iface, acc ->
      device_id = normalize_id(Map.get(iface, :device_id))
      if_name = normalize_id(Map.get(iface, :if_name))
      if_index = Map.get(iface, :if_index)

      if is_nil(device_id) do
        acc
      else
        by_device = Map.update(acc.by_device, device_id, [iface], &[iface | &1])

        by_device_if =
          case interface_lookup_key(device_id, if_name, if_index) do
            nil -> acc.by_device_if
            key -> Map.put_new(acc.by_device_if, key, iface)
          end

        %{acc | by_device: by_device, by_device_if: by_device_if}
      end
    end)
  end

  defp interface_lookup_key(device_id, if_name, if_index) when is_binary(device_id) do
    cond do
      is_integer(if_index) -> {:if_index, device_id, if_index}
      is_binary(if_name) and if_name != "" -> {:if_name, device_id, String.downcase(if_name)}
      true -> nil
    end
  end

  defp interface_lookup_key(_, _, _), do: nil

  defp node_telemetry(interface_rows, pps_by_if) when is_list(interface_rows) do
    pps =
      interface_rows
      |> Enum.map(&interface_packets_per_second(&1, pps_by_if))
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    oper_values =
      interface_rows
      |> Enum.map(&Map.get(&1, :if_oper_status))
      |> Enum.filter(&is_integer/1)

    oper_up =
      cond do
        oper_values == [] -> nil
        Enum.any?(oper_values, &(&1 == 1)) -> true
        true -> false
      end

    {pps, oper_up}
  end

  defp node_telemetry(_, _), do: {0, nil}

  defp enrich_edges_via_native(edges, interfaces, pps_by_if, bps_by_if)
       when is_list(edges) and is_list(interfaces) and is_map(pps_by_if) and is_map(bps_by_if) do
    edge_rows =
      Enum.map(edges, fn edge ->
        {
          normalize_id(Map.get(edge, :source)) || "",
          normalize_id(Map.get(edge, :target)) || "",
          to_string(Map.get(edge, :protocol) || ""),
          {
            normalize_i64(Map.get(edge, :local_if_index_ab)),
            normalize_id(Map.get(edge, :local_if_name_ab)) || "",
            normalize_i64(Map.get(edge, :local_if_index_ba)),
            normalize_id(Map.get(edge, :local_if_name_ba)) || ""
          },
          {
            normalize_u32(Map.get(edge, :flow_pps) || 0),
            normalize_u64(Map.get(edge, :flow_bps) || 0),
            normalize_u64(Map.get(edge, :capacity_bps) || 0)
          }
        }
      end)

    interface_rows =
      interfaces
      |> Enum.flat_map(fn iface ->
        device_id = normalize_id(Map.get(iface, :device_id)) || ""
        if_index = normalize_i64(Map.get(iface, :if_index))
        speed_bps = normalize_u64(interface_capacity_bps(iface) || 0)

        interface_name_candidates(iface)
        |> Enum.map(fn if_name ->
          {device_id, if_name, if_index, speed_bps}
        end)
      end)
      |> Enum.reject(fn {device_id, _if_name, _if_index, _speed_bps} ->
        device_id == ""
      end)

    pps_rows =
      Enum.flat_map(pps_by_if, fn
        {{device_id, if_index}, values} when is_binary(device_id) and is_integer(if_index) ->
          [
            {device_id, if_index, normalize_u32(Map.get(values, :in, 0)),
             normalize_u32(Map.get(values, :out, 0))}
          ]

        _ ->
          []
      end)

    bps_rows =
      Enum.flat_map(bps_by_if, fn
        {{device_id, if_index}, values} when is_binary(device_id) and is_integer(if_index) ->
          [
            {device_id, if_index, normalize_u64(Map.get(values, :in, 0)),
             normalize_u64(Map.get(values, :out, 0))}
          ]

        _ ->
          []
      end)

    case Native.enrich_edges_telemetry(edge_rows, interface_rows, pps_rows, bps_rows) do
      enriched_rows when is_list(enriched_rows) and length(enriched_rows) == length(edges) ->
        result =
          Enum.zip(edges, enriched_rows)
          |> Enum.map(fn
            {edge,
             {_source, _target, flow_pps, flow_bps, capacity_bps, label,
              {flow_pps_ab, flow_pps_ba, flow_bps_ab, flow_bps_ba}}} ->
              Map.merge(edge, %{
                flow_pps: flow_pps,
                flow_bps: flow_bps,
                capacity_bps: capacity_bps,
                label: label,
                flow_pps_ab: flow_pps_ab,
                flow_pps_ba: flow_pps_ba,
                flow_bps_ab: flow_bps_ab,
                flow_bps_ba: flow_bps_ba,
                telemetry_source:
                  if(normalize_u64(flow_bps) > 0 or normalize_u32(flow_pps) > 0,
                    do: "interface",
                    else: "none"
                  )
              })

            {edge, _} ->
              edge
          end)

        {:ok, result}

      _ ->
        {:error, :native_edge_enrichment_failed}
    end
  rescue
    error -> {:error, {:native_edge_enrichment_error, error}}
  end

  defp enrich_edges_via_native(_, _, _, _), do: {:error, :invalid_edge_enrichment_args}

  defp interface_packets_per_second(nil, _pps_by_if), do: nil

  defp interface_packets_per_second(iface, pps_by_if) do
    metadata = Map.get(iface, :metadata) || %{}
    metric_value = interface_pps_value(pps_by_if, iface)

    pick_number([
      metric_value,
      Map.get(iface, :pps),
      metadata["pps"],
      metadata["packets_per_sec"],
      metadata["packets_per_second"],
      metadata["tx_pps"],
      metadata["rx_pps"],
      metadata["if_in_pps"],
      metadata["if_out_pps"],
      sum_numbers([metadata["tx_pps"], metadata["rx_pps"]]),
      sum_numbers([metadata["if_in_pps"], metadata["if_out_pps"]])
    ])
  end

  defp interface_pps_value(pps_by_if, iface) when is_map(pps_by_if) do
    device_id = normalize_id(Map.get(iface, :device_id))
    if_index = Map.get(iface, :if_index)

    if is_binary(device_id) and is_integer(if_index) do
      Map.get(pps_by_if, {device_id, if_index})
    end
  end

  defp interface_pps_value(_, _), do: nil

  defp load_interface_pps(interface_index, extra_keys) when is_map(interface_index) do
    load_interface_pps_direction(interface_index, extra_keys)
    |> Enum.reduce(%{}, fn {{device_id, if_index}, values}, acc ->
      in_pps = Map.get(values, :in, 0)
      out_pps = Map.get(values, :out, 0)
      Map.put(acc, {device_id, if_index}, in_pps + out_pps)
    end)
  rescue
    _ -> %{}
  end

  defp load_interface_pps(_interface_index, _extra_keys), do: %{}

  defp load_interface_pps_direction(interface_index, extra_keys) when is_map(interface_index) do
    keys = metric_query_keys(interface_index, extra_keys)

    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if device_ids == [] or if_indexes == [] do
      %{}
    else
      query =
        from(m in "timeseries_metrics",
          where: m.device_id in ^device_ids,
          where: m.if_index in ^if_indexes,
          where: m.metric_name in ^@packet_metric_names,
          where: m.timestamp > ago(10, "minute"),
          distinct: [m.device_id, m.if_index, m.metric_name],
          order_by: [asc: m.device_id, asc: m.if_index, asc: m.metric_name, desc: m.timestamp],
          select: {m.device_id, m.if_index, m.metric_name, m.value}
        )

      query
      |> Repo.all()
      |> Enum.reduce(%{}, fn {device_id, if_index, metric_name, value}, acc ->
        dir = packet_metric_direction(metric_name)
        numeric_value = value_to_non_negative_int(value)

        if is_nil(dir) or is_nil(numeric_value) do
          acc
        else
          key = {normalize_id(device_id), if_index}

          Map.update(acc, key, %{dir => numeric_value}, fn current ->
            current
            |> Map.update(dir, numeric_value, &max(&1, numeric_value))
          end)
        end
      end)
    end
  rescue
    _ -> %{}
  end

  defp load_interface_pps_direction(_interface_index, _extra_keys), do: %{}

  defp load_interface_bps(interface_index, extra_keys) when is_map(interface_index) do
    load_interface_bps_direction(interface_index, extra_keys)
    |> Enum.reduce(%{}, fn {{device_id, if_index}, values}, acc ->
      in_bps = Map.get(values, :in, 0)
      out_bps = Map.get(values, :out, 0)
      Map.put(acc, {device_id, if_index}, in_bps + out_bps)
    end)
  rescue
    _ -> %{}
  end

  defp load_interface_bps(_interface_index, _extra_keys), do: %{}

  defp load_interface_bps_direction(interface_index, extra_keys) when is_map(interface_index) do
    keys = metric_query_keys(interface_index, extra_keys)

    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if device_ids == [] or if_indexes == [] do
      %{}
    else
      query =
        from(m in "timeseries_metrics",
          where: m.device_id in ^device_ids,
          where: m.if_index in ^if_indexes,
          where: m.metric_name in ^@octet_metric_names,
          where: m.timestamp > ago(10, "minute"),
          distinct: [m.device_id, m.if_index, m.metric_name],
          order_by: [asc: m.device_id, asc: m.if_index, asc: m.metric_name, desc: m.timestamp],
          select: {m.device_id, m.if_index, m.metric_name, m.value}
        )

      query
      |> Repo.all()
      |> Enum.reduce(%{}, fn {device_id, if_index, metric_name, value}, acc ->
        dir = octet_metric_direction(metric_name)
        bytes_per_second = value_to_non_negative_int(value)

        if is_nil(dir) or is_nil(bytes_per_second) do
          acc
        else
          key = {normalize_id(device_id), if_index}
          bits_per_second = octets_rate_to_bps(bytes_per_second)

          Map.update(acc, key, %{dir => bits_per_second}, fn current ->
            current
            |> Map.update(dir, bits_per_second, &max(&1, bits_per_second))
          end)
        end
      end)
    end
  rescue
    _ -> %{}
  end

  defp load_interface_bps_direction(_interface_index, _extra_keys), do: %{}

  defp metric_query_keys(interface_index, extra_keys)
       when is_map(interface_index) and is_list(extra_keys) do
    interface_keys =
      interface_index.by_device_if
      |> Map.keys()
      |> Enum.flat_map(fn
        {:if_index, device_id, if_index} when is_binary(device_id) and is_integer(if_index) ->
          [{device_id, if_index}]

        _ ->
          []
      end)

    (interface_keys ++ extra_keys)
    |> Enum.uniq()
  end

  defp metric_query_keys(_interface_index, extra_keys) when is_list(extra_keys) do
    extra_keys
    |> Enum.filter(fn
      {device_id, if_index} when is_binary(device_id) and is_integer(if_index) -> true
      _ -> false
    end)
    |> Enum.uniq()
  end

  defp directional_metric_keys(edges) when is_list(edges) do
    Enum.flat_map(edges, fn edge ->
      source = normalize_id(Map.get(edge, :source))
      target = normalize_id(Map.get(edge, :target))
      ab_if_index = Map.get(edge, :local_if_index_ab)
      ba_if_index = Map.get(edge, :local_if_index_ba)

      [
        if(is_binary(source) and valid_ifindex?(ab_if_index), do: {source, ab_if_index}),
        if(is_binary(target) and valid_ifindex?(ba_if_index), do: {target, ba_if_index})
      ]
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq()
  end

  defp directional_metric_keys(_), do: []

  @doc false
  def octets_rate_to_bps(value) when is_integer(value) and value > 0, do: value * 8
  def octets_rate_to_bps(_), do: 0

  defp device_telemetry_totals(interface_index, pps_by_if, bps_by_if)
       when is_map(interface_index) and is_map(pps_by_if) and is_map(bps_by_if) do
    devices =
      interface_index
      |> Map.get(:by_device, %{})
      |> Map.keys()

    Enum.reduce(devices, %{}, fn device_id, acc ->
      if_rows = Map.get(interface_index.by_device, device_id, [])

      cap_bps =
        if_rows
        |> Enum.map(&interface_capacity_bps/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> 0 end)

      pps =
        pps_by_if
        |> Enum.filter(fn {{d, _if_index}, _v} -> d == device_id end)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.sum()

      bps =
        bps_by_if
        |> Enum.filter(fn {{d, _if_index}, _v} -> d == device_id end)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.sum()

      Map.put(acc, device_id, %{
        pps: normalize_u32(pps),
        bps: normalize_u64(bps),
        capacity_bps: normalize_u64(cap_bps)
      })
    end)
  end

  defp device_telemetry_totals(_, _, _), do: %{}

  defp apply_edge_telemetry_fallback(edges, device_totals)
       when is_list(edges) and is_map(device_totals) do
    Enum.map(edges, fn edge ->
      if edge_needs_fallback_telemetry?(edge) do
        source = Map.get(device_totals, Map.get(edge, :source), %{})
        target = Map.get(device_totals, Map.get(edge, :target), %{})

        inferred_pps = fallback_signal_scaled(Map.get(source, :pps, 0), Map.get(target, :pps, 0))
        inferred_bps = fallback_signal_scaled(Map.get(source, :bps, 0), Map.get(target, :bps, 0))

        inferred_capacity =
          pair_min_non_zero(
            Map.get(source, :capacity_bps, 0),
            Map.get(target, :capacity_bps, 0)
          )

        flow_pps =
          if normalize_u32(Map.get(edge, :flow_pps, 0)) > 0,
            do: Map.get(edge, :flow_pps, 0),
            else: inferred_pps

        flow_bps =
          if normalize_u64(Map.get(edge, :flow_bps, 0)) > 0,
            do: Map.get(edge, :flow_bps, 0),
            else: inferred_bps

        capacity_bps =
          if normalize_u64(Map.get(edge, :capacity_bps, 0)) > 0,
            do: Map.get(edge, :capacity_bps, 0),
            else: inferred_capacity

        edge
        |> Map.put(:flow_pps, normalize_u32(flow_pps))
        |> Map.put(:flow_bps, normalize_u64(flow_bps))
        |> Map.put(:capacity_bps, normalize_u64(capacity_bps))
        |> Map.put(:telemetry_source, "device-fallback")
        |> Map.put(
          :telemetry_eligible,
          normalize_u64(flow_bps) > 0 or normalize_u32(flow_pps) > 0
        )
        |> Map.put(:label, edge_label(edge, normalize_u32(flow_pps), normalize_u64(capacity_bps)))
      else
        edge
      end
    end)
  end

  defp apply_edge_telemetry_fallback(edges, _), do: edges

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

    fully_attributed_directional =
      Enum.count(edges, fn edge ->
        directional_attribution_present?(edge, :ab) and
          directional_attribution_present?(edge, :ba)
      end)

    direct_missing_interface_telemetry =
      Enum.count(edges, fn edge ->
        evidence_class(edge) == "direct" and
          Map.get(edge, :telemetry_source) != "interface"
      end)

    non_canonical_endpoint_edges =
      Enum.count(edges, fn edge ->
        not canonical_device_id?(Map.get(edge, :source)) or
          not canonical_device_id?(Map.get(edge, :target))
      end)

    %{
      edge_telemetry_interface: interface_edges,
      edge_telemetry_fallback: fallback_edges,
      edge_unresolved_directional: unresolved_directional,
      edge_fully_attributed_directional: fully_attributed_directional,
      edge_direct_missing_interface_telemetry: direct_missing_interface_telemetry,
      edge_non_canonical_endpoints: non_canonical_endpoint_edges
    }
  end

  defp edge_contract_stats(_), do: %{}

  defp canonical_device_id?(value) when is_binary(value), do: String.starts_with?(value, "sr:")
  defp canonical_device_id?(_), do: false

  defp directional_attribution_present?(edge, :ab) do
    valid_ifindex?(Map.get(edge, :local_if_index_ab)) or
      interface_name_attributed?(Map.get(edge, :local_if_name_ab))
  end

  defp directional_attribution_present?(edge, :ba) do
    valid_ifindex?(Map.get(edge, :local_if_index_ba)) or
      interface_name_attributed?(Map.get(edge, :local_if_name_ba))
  end

  defp edge_needs_fallback_telemetry?(edge) when is_map(edge) do
    has_flow? =
      normalize_u64(Map.get(edge, :flow_bps, 0)) > 0 or
        normalize_u32(Map.get(edge, :flow_pps, 0)) > 0

    protocol = edge_protocol(edge)

    # SNMP-L2 links can still land on an interface that has no sampled
    # counters in the latest window; allow bounded device-level fallback
    # so backbone animations do not disappear on sparse polling snapshots.
    not has_flow? and
      (unifi_unattributed?(edge) or
         protocol in ["wireguard-derived", "snmp-parent", "snmp-site"] or
         protocol == "snmp-l2")
  end

  defp edge_needs_fallback_telemetry?(_), do: false

  defp fallback_signal_scaled(a, b) do
    # Keep fallback activity visible but restrained vs fully attributed edge telemetry.
    signal = pair_min_non_zero(a, b)

    if signal > 0 do
      max(1, trunc(signal * 0.14))
    else
      0
    end
  end

  defp pair_min_non_zero(a, b) do
    av = normalize_u64(a)
    bv = normalize_u64(b)

    cond do
      av > 0 and bv > 0 -> min(av, bv)
      av > 0 -> av
      bv > 0 -> bv
      true -> 0
    end
  end

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifInUcastPkts", "ifHCInUcastPkts"],
       do: :in

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifOutUcastPkts", "ifHCOutUcastPkts"],
       do: :out

  defp packet_metric_direction(_), do: nil

  defp octet_metric_direction(metric_name) when metric_name in ["ifInOctets", "ifHCInOctets"],
    do: :in

  defp octet_metric_direction(metric_name) when metric_name in ["ifOutOctets", "ifHCOutOctets"],
    do: :out

  defp octet_metric_direction(_), do: nil

  defp value_to_non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp value_to_non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)
  defp value_to_non_negative_int(%Decimal{} = value), do: decimal_to_non_negative_int(value)

  defp value_to_non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp value_to_non_negative_int(_), do: nil

  defp interface_capacity_bps(nil), do: nil

  defp interface_capacity_bps(iface) do
    metadata = Map.get(iface, :metadata) || %{}

    pick_number([
      Map.get(iface, :speed_bps),
      Map.get(iface, :if_speed),
      metadata["if_speed_bps"],
      metadata["if_speed"],
      metadata["speed_bps"],
      metadata["capacity_bps"]
    ])
  end

  defp interface_name_candidates(iface) when is_map(iface) do
    metadata = Map.get(iface, :metadata) || %{}

    [
      Map.get(iface, :if_name),
      Map.get(iface, :if_descr),
      Map.get(iface, :if_alias),
      metadata["if_name"],
      metadata["if_descr"],
      metadata["if_alias"],
      metadata["name"],
      metadata["description"]
    ]
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> [""]
      values -> values
    end
  end

  defp interface_name_candidates(_), do: [""]

  defp pick_number(values) when is_list(values) do
    values
    |> Enum.find_value(fn
      value when is_integer(value) and value >= 0 ->
        value

      value when is_float(value) and value >= 0 ->
        trunc(Float.round(value))

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end

      %Decimal{} = value ->
        decimal_to_non_negative_int(value)

      _ ->
        nil
    end)
  end

  defp sum_numbers(values) when is_list(values) do
    parsed =
      values
      |> Enum.map(fn
        value when is_integer(value) and value >= 0 -> value
        value when is_float(value) and value >= 0 -> trunc(Float.round(value))
        %Decimal{} = value -> decimal_to_non_negative_int(value)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if parsed == [], do: nil, else: Enum.sum(parsed)
  end

  defp node_oper_up_value(true), do: 1
  defp node_oper_up_value(false), do: 2
  defp node_oper_up_value(_), do: 0

  defp edge_label(edge),
    do: edge_label(edge, Map.get(edge, :flow_pps), Map.get(edge, :capacity_bps))

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

  defp decimal_to_non_negative_int(%Decimal{} = value) do
    case Decimal.compare(value, Decimal.new(0)) do
      :lt ->
        nil

      _ ->
        value
        |> Decimal.to_float()
        |> trunc()
    end
  rescue
    _ -> nil
  end

  defp apply_causal_states(nodes, indexed_edges) when is_list(nodes) and is_list(indexed_edges) do
    routing_overrides = routing_causal_node_indexes(nodes)

    signals =
      Enum.with_index(nodes)
      |> Enum.map(fn {node, idx} ->
        base_signal =
          case Map.get(node, :health_signal, :unknown) do
            :healthy -> 0
            :unhealthy -> 1
            _ -> 2
          end

        if MapSet.member?(routing_overrides, idx), do: 1, else: base_signal
      end)

    case Native.evaluate_causal_states_with_reasons(signals, indexed_edges) do
      rows when is_list(rows) and length(rows) == length(nodes) ->
        Enum.zip(nodes, rows)
        |> Enum.map(fn {node, row} ->
          state = causal_row_value(row, :state, 3)
          reason = causal_row_value(row, :reason, "causal_reason_unavailable")
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

        Enum.zip(nodes, states)
        |> Enum.map(fn {node, state} ->
          details_json =
            merge_causal_reason_details(
              Map.get(node, :details_json),
              state,
              "fallback_state_only_engine_result",
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

  defp routing_causal_node_indexes(nodes) when is_list(nodes) do
    indexed_keys =
      nodes
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {node, idx}, acc ->
        node_correlation_keys(node)
        |> Enum.reduce(acc, fn key, inner ->
          Map.update(inner, key, MapSet.new([idx]), &MapSet.put(&1, idx))
        end)
      end)

    fetch_recent_routing_causal_events()
    |> Enum.reduce(MapSet.new(), fn event, matched ->
      event_correlation_keys(event)
      |> Enum.reduce(matched, fn key, key_acc ->
        case Map.get(indexed_keys, key) do
          nil -> key_acc
          node_indexes -> MapSet.union(key_acc, node_indexes)
        end
      end)
    end)
  end

  defp routing_causal_node_indexes(_), do: MapSet.new()

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
        _ -> []
      end

    [
      map_value(device, "uid"),
      map_value(src_endpoint, "ip"),
      map_value(routing, "router_id"),
      map_value(routing, "router_ip"),
      map_value(routing, "peer_ip"),
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
    ocsf_events = fetch_recent_ocsf_routing_events(cutoff, source_limit)

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

  defp fetch_recent_ocsf_routing_events(cutoff, limit) do
    query =
      from(e in "ocsf_events",
        where: e.time >= ^cutoff,
        where:
          fragment(
            "(?->>'signal_type' = 'bmp') OR (?->>'primary_domain' = 'routing')",
            e.metadata,
            e.metadata
          ),
        where: coalesce(e.severity_id, 0) >= ^routing_causal_severity_threshold(),
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
          if Atom.to_string(atom_key) == key, do: value, else: nil

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

  defp merge_causal_reason_details(
         details_json,
         state,
         reason,
         root_index,
         parent_index,
         hop_distance
       ) do
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

  defp canonical_pair(a, b) when a <= b, do: {a, b}
  defp canonical_pair(a, b), do: {b, a}

  defp normalize_neighbor_id(link) do
    normalize_id(Map.get(link, :neighbor_device_id)) ||
      normalize_id(Map.get(link, :neighbor_mgmt_addr)) ||
      normalize_id(Map.get(link, :neighbor_system_name)) ||
      normalize_id(Map.get(link, :neighbor_chassis_id))
  end

  defp normalize_local_id(link) do
    normalize_id(Map.get(link, :local_device_id)) ||
      normalize_id(Map.get(link, :local_device_ip))
  end

  defp fallback_local_id(link) do
    normalize_id(Map.get(link, :local_device_ip)) ||
      normalize_id(Map.get(link, :agent_id)) ||
      normalize_id(Map.get(link, :gateway_id))
  end

  defp fallback_neighbor_id(link) do
    normalize_id(Map.get(link, :neighbor_mgmt_addr)) ||
      normalize_id(Map.get(link, :neighbor_system_name)) ||
      normalize_id(Map.get(link, :neighbor_chassis_id))
  end

  defp normalize_neighbor_port_hint(link) when is_map(link) do
    # Prefer port description for interface matching (e.g. "eth4"), because some
    # LLDP neighbor_port_id values are chassis MAC-like bytes and not interface names.
    normalize_id(Map.get(link, :neighbor_if_name)) ||
      normalize_id(Map.get(link, :neighbor_port_descr)) ||
      normalize_id(Map.get(link, :neighbor_port_id)) ||
      decode_hex_port_id(Map.get(link, :neighbor_port_id))
  end

  defp normalize_neighbor_port_hint(_), do: nil

  # Some LLDP port IDs arrive as colon-delimited hex bytes (e.g. "50:6f:72:74:20:31" -> "Port 1").
  # Decode those so we can match against discovered interface names for reverse-direction attribution.
  defp decode_hex_port_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- String.contains?(trimmed, ":"),
         parts <- String.split(trimmed, ":", trim: true),
         true <- parts != [],
         true <- Enum.all?(parts, &(String.length(&1) == 2)),
         ints <- Enum.map(parts, &Integer.parse(&1, 16)),
         true <- Enum.all?(ints, &match?({_, ""}, &1)) do
      ints
      |> Enum.map(fn {i, _} -> i end)
      |> :binary.list_to_bin()
      |> normalize_id()
    else
      _ -> nil
    end
  end

  defp decode_hex_port_id(_), do: nil

  defp interface_like_identifier?(value) when is_binary(value) do
    Regex.match?(~r/\A\d+\/\d+\z/, value) or String.starts_with?(value, "Port ")
  end

  defp interface_like_identifier?(_), do: false

  defp malformed_identifier?(value) when is_binary(value) do
    String.contains?(value, <<239, 191, 189>>)
  end

  defp malformed_identifier?(_), do: false

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
    (Map.get(link, :metadata) || %{})
    |> Map.get("confidence_tier", Map.get(link, :confidence_tier, "unknown"))
  end

  defp evidence_class(link) do
    metadata = Map.get(link, :metadata) || %{}

    relation_type =
      metadata["relation_type"] || metadata[:relation_type] || Map.get(link, :relation_type)

    explicit =
      metadata["evidence_class"] || metadata[:evidence_class] || Map.get(link, :evidence_class)

    normalized =
      explicit
      |> to_string()
      |> String.trim()
      |> String.downcase()

    cond do
      normalized in ["direct", "inferred", "endpoint-attachment"] ->
        normalized

      is_binary(relation_type) and String.upcase(String.trim(relation_type)) == "ATTACHED_TO" ->
        "endpoint-attachment"

      is_binary(relation_type) and String.upcase(String.trim(relation_type)) == "INFERRED_TO" ->
        "inferred"

      is_binary(relation_type) and String.upcase(String.trim(relation_type)) == "CONNECTS_TO" ->
        "direct"

      true ->
        protocol =
          link
          |> Map.get(:protocol)
          |> to_string()
          |> String.trim()
          |> String.downcase()

        cond do
          protocol in ["lldp", "cdp", "wireguard-derived"] -> "direct"
          protocol == "snmp-l2" -> "inferred"
          true -> "direct"
        end
    end
  end

  defp page_results(%{results: results}) when is_list(results), do: results
  defp page_results(_), do: []

  defp normalize_u16(value) when is_integer(value), do: clamp(value, 0, 65_535)

  defp normalize_u16(value) when is_float(value),
    do: value |> Float.round() |> trunc() |> normalize_u16()

  defp normalize_u16(_), do: 0

  defp normalize_u8(value) when is_integer(value), do: clamp(value, 0, 255)
  defp normalize_u8(_), do: 0
  defp normalize_u32(value) when is_integer(value), do: clamp(value, 0, 4_294_967_295)
  defp normalize_u32(_), do: 0
  defp normalize_u64(value) when is_integer(value), do: max(value, 0)
  defp normalize_u64(_), do: 0
  defp normalize_i64(value) when is_integer(value), do: value
  defp normalize_i64(_), do: -1

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

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp topology_revision(nodes, indexed_edges)
       when is_list(nodes) and is_list(indexed_edges) do
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

  defp put_layout_coordinates_cache(topology_revision, nodes)
       when is_integer(topology_revision) and is_list(nodes) do
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

  defp coalesced_snapshot(coalesce_ms)
       when is_integer(coalesce_ms) and coalesce_ms > 0 do
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
