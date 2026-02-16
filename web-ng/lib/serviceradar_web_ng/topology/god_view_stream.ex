defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds God-View snapshot payloads backed by the Rust Arrow encoder.
  """

  import Ecto.Query

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Graph, as: AgeGraph
  alias ServiceRadarWebNG.Topology.RuntimeGraph
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.Native

  @max_link_rows 5_000
  @max_interface_rows 2_000
  @default_real_time_budget_ms 2_000
  @drop_counter_key {__MODULE__, :dropped_updates}
  @packet_metric_names ["ifInUcastPkts", "ifOutUcastPkts", "ifHCInUcastPkts", "ifHCOutUcastPkts"]
  @octet_metric_names ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"]
  @strict_ifindex_protocols MapSet.new(["lldp", "cdp"])

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
         {:ok, payload} <- encode_payload(snapshot) do
      build_ms = duration_ms(started_at)

      if build_ms > budget_ms do
        dropped = increment_dropped_updates()

        emit_snapshot_drop_telemetry(snapshot, build_ms, budget_ms, dropped)
        emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms)
        {:ok, %{snapshot: snapshot, payload: payload}}
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
          normalize_label(Map.get(edge, :label) || edge_label(edge))
        }
      end)

    {:ok,
     Native.encode_snapshot(
       snapshot.schema_version,
       snapshot.revision,
       nodes,
       edges,
       byte_size(root),
       byte_size(affected),
       byte_size(healthy),
       byte_size(unknown)
     )}
  end

  defp build_projection(actor) do
    with {:ok, links} <- fetch_topology_links(actor),
         {:ok, pairs} <- unique_pairs(links),
         {:ok, nodes, edges} <- build_nodes_and_edges(actor, pairs),
         {:ok, indexed_edges} <- index_edges(nodes, edges) do
      nodes = apply_native_layout_with_indexed_edges(nodes, indexed_edges)
      nodes = apply_causal_states(nodes, indexed_edges)
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
    runtime_links = runtime_topology_links()

    case fetch_topology_links_from_graph() do
      {:ok, links} when is_list(links) and links != [] ->
        {:ok, links ++ runtime_links}

      _ ->
        case fetch_topology_links_from_table(actor) do
          {:ok, links} when is_list(links) and links != [] ->
            {:ok, links ++ runtime_links}

          other ->
            if runtime_links != [], do: {:ok, runtime_links}, else: other
        end
    end
  end

  defp runtime_topology_links do
    case RuntimeGraph.get_links() do
      {:ok, links} when is_list(links) -> links
      _ -> []
    end
  end

  defp fetch_topology_links_from_table(actor) do
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

  defp fetch_topology_links_from_graph do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-topology_stale_minutes() * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    escaped_cutoff = AgeGraph.escape(cutoff)

    cypher = """
    MATCH (a:Device)-[:HAS_INTERFACE]->(ai:Interface)-[r:CONNECTS_TO]->(bi:Interface)<-[:HAS_INTERFACE]-(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND (
        toLower(coalesce(r.protocol, r.source, '')) IN ['wireguard-derived', 'snmp-l2', 'snmp-parent', 'snmp-site', 'l3-uplink', 'inferred']
        OR coalesce(r.confidence_tier, 'low') IN ['high', 'medium']
      )
      AND (r.last_observed_at IS NULL OR r.last_observed_at >= '#{escaped_cutoff}')
    RETURN {
      local_device_id: ai.device_id,
      local_device_ip: a.ip,
      local_if_name: ai.name,
      local_if_index: ai.ifindex,
      neighbor_device_id: bi.device_id,
      neighbor_mgmt_addr: b.ip,
      neighbor_system_name: b.name,
      protocol: coalesce(r.protocol, r.source, 'unknown'),
      confidence_tier: coalesce(r.confidence_tier, 'unknown'),
      metadata: {
        source: coalesce(r.source, ''),
        inference: coalesce(r.confidence_reason, ''),
        confidence_tier: coalesce(r.confidence_tier, 'unknown'),
        confidence_score: coalesce(r.confidence_score, 0)
      }
    }
    ORDER BY coalesce(r.last_observed_at, r.observed_at) DESC
    LIMIT #{@max_link_rows}
    """

    case AgeGraph.query(cypher) do
      {:ok, rows} when is_list(rows) ->
        {:ok, Enum.map(rows, &normalize_graph_link/1)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp normalize_graph_link(%{} = row) do
    %{
      local_device_id: map_fetch(row, :local_device_id),
      local_device_ip: map_fetch(row, :local_device_ip),
      local_if_name: map_fetch(row, :local_if_name),
      local_if_index: map_fetch(row, :local_if_index),
      neighbor_device_id: map_fetch(row, :neighbor_device_id),
      neighbor_mgmt_addr: map_fetch(row, :neighbor_mgmt_addr),
      neighbor_system_name: map_fetch(row, :neighbor_system_name),
      protocol: map_fetch(row, :protocol),
      confidence_tier: map_fetch(row, :confidence_tier),
      metadata: map_fetch(row, :metadata) || %{}
    }
  end

  defp normalize_graph_link(_), do: %{}

  defp map_fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp topology_stale_minutes do
    Application.get_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 180)
  end

  defp unique_pairs(links) when is_list(links) do
    pairs =
      Enum.reduce(links, %{}, fn link, acc ->
        local_id = normalize_local_id(link) || fallback_local_id(link)
        neighbor_id = normalize_neighbor_id(link) || fallback_neighbor_id(link)

        cond do
          is_nil(local_id) or is_nil(neighbor_id) or local_id == neighbor_id ->
            acc

          true ->
            {a, b} = canonical_pair(local_id, neighbor_id)

            Map.put_new(acc, {a, b}, %{
              source: local_id,
              target: neighbor_id,
              kind: "topology",
              protocol: Map.get(link, :protocol),
              confidence_tier: confidence_tier(link),
              local_device_ip: normalize_id(Map.get(link, :local_device_ip)),
              neighbor_mgmt_addr: normalize_id(Map.get(link, :neighbor_mgmt_addr)),
              local_if_index: Map.get(link, :local_if_index),
              local_if_name: Map.get(link, :local_if_name),
              metadata: Map.get(link, :metadata) || %{}
            })
        end
      end)

    {:ok, pairs}
  end

  defp build_nodes_and_edges(actor, pairs) do
    pair_edges = Map.values(pairs)
    edge_node_ids = pairs |> Map.keys() |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    with {:ok, devices} <- fetch_devices(actor, edge_node_ids),
         {:ok, seeded_devices} <- fetch_seed_devices(),
         {:ok, resolved_devices} <- resolve_devices_for_topology(edge_node_ids),
         {:ok, interfaces} <- fetch_interfaces(actor, edge_node_ids) do
      devices =
        devices
        |> merge_devices(seeded_devices)
        |> merge_devices(resolved_devices)

      canonical_edges =
        pair_edges
        |> canonicalize_edges(devices)
        |> prune_ap_gateway_inference_edges(devices)
        |> enforce_edge_interface_contracts()
        |> normalize_router_inferred_infra_edges(devices)
        |> normalize_endpoint_attachments(devices)

      canonical_node_ids =
        canonical_edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

      device_by_id = Map.new(devices, &{&1.uid, &1})
      interface_index = index_interfaces(interfaces)
      pps_by_if = load_interface_pps(interface_index)
      bps_by_if = load_interface_bps(interface_index)
      node_ids = node_ids(canonical_node_ids, devices)
      nodes = build_nodes(node_ids, device_by_id, interface_index, pps_by_if)

      edges = canonical_edges |> dedupe_edges()

      with {:ok, edges} <- enrich_edges_via_native(edges, interfaces, pps_by_if, bps_by_if) do
        {:ok, nodes, edges}
      end
    end
  end

  defp prune_ap_gateway_inference_edges(edges, devices)
       when is_list(edges) and is_list(devices) do
    device_by_uid =
      devices
      |> Enum.reduce(%{}, fn device, acc ->
        uid = normalize_id(Map.get(device, :uid))
        if is_binary(uid), do: Map.put(acc, uid, device), else: acc
      end)

    has_direct_neighbor =
      edges
      |> Enum.reduce(MapSet.new(), fn edge, acc ->
        if direct_protocol?(edge) do
          source = normalize_id(Map.get(edge, :source))
          target = normalize_id(Map.get(edge, :target))

          acc
          |> maybe_put_set(source)
          |> maybe_put_set(target)
        else
          acc
        end
      end)

    Enum.reject(edges, fn edge ->
      protocol = edge_protocol(edge)
      source = normalize_id(Map.get(edge, :source))
      target = normalize_id(Map.get(edge, :target))
      source_device = Map.get(device_by_uid, source)
      target_device = Map.get(device_by_uid, target)

      protocol == "l3-uplink" and gateway_corr_edge?(edge) and
        ((ap_device?(source_device) and router_device?(target_device) and
            MapSet.member?(has_direct_neighbor, source)) or
           (ap_device?(target_device) and router_device?(source_device) and
              MapSet.member?(has_direct_neighbor, target)))
    end)
  end

  defp prune_ap_gateway_inference_edges(edges, _devices), do: edges

  defp normalize_router_inferred_infra_edges(edges, devices)
       when is_list(edges) and is_list(devices) do
    device_by_uid =
      Map.new(devices, fn device -> {normalize_id(Map.get(device, :uid)), device} end)

    direct_degree = direct_infra_degree(edges, device_by_uid)

    router_candidates =
      edges
      |> Enum.filter(fn edge ->
        inferred_protocol?(edge) and infra_infra_edge?(edge, device_by_uid) and
          router_uid_for_edge(edge, device_by_uid) != nil
      end)
      |> Enum.group_by(&router_uid_for_edge(&1, device_by_uid))

    keep_best =
      Enum.reduce(router_candidates, MapSet.new(), fn {_router_uid, candidates}, acc ->
        case best_router_inferred_edge(candidates, device_by_uid, direct_degree) do
          nil -> acc
          best -> MapSet.put(acc, edge_identity(best))
        end
      end)

    Enum.filter(edges, fn edge ->
      if inferred_protocol?(edge) and infra_infra_edge?(edge, device_by_uid) and
           router_uid_for_edge(edge, device_by_uid) != nil do
        MapSet.member?(keep_best, edge_identity(edge))
      else
        true
      end
    end)
  end

  defp normalize_router_inferred_infra_edges(edges, _devices), do: edges

  defp normalize_endpoint_attachments(edges, devices)
       when is_list(edges) and is_list(devices) do
    device_by_uid =
      Map.new(devices, fn device -> {normalize_id(Map.get(device, :uid)), device} end)

    endpoint_candidates =
      edges
      |> Enum.filter(&endpoint_attachment_edge?(&1, device_by_uid))
      |> Enum.group_by(&endpoint_uid_for_edge(&1, device_by_uid))

    keep_best =
      Enum.reduce(endpoint_candidates, MapSet.new(), fn {_endpoint_uid, candidates}, acc ->
        case best_endpoint_attachment(candidates, device_by_uid) do
          nil -> acc
          best -> MapSet.put(acc, edge_identity(best))
        end
      end)

    Enum.filter(edges, fn edge ->
      if endpoint_attachment_edge?(edge, device_by_uid) do
        MapSet.member?(keep_best, edge_identity(edge))
      else
        true
      end
    end)
  end

  defp normalize_endpoint_attachments(edges, _devices), do: edges

  defp edge_protocol(edge) do
    edge
    |> Map.get(:protocol)
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp inferred_protocol?(edge) do
    edge_protocol(edge) in ["snmp-l2", "snmp-parent", "snmp-site", "l3-uplink", "inferred"]
  end

  defp direct_protocol?(edge) do
    edge_protocol(edge) in ["lldp", "cdp", "unifi-api", "wireguard-derived"]
  end

  defp edge_identity(edge) do
    a = normalize_id(Map.get(edge, :source))
    b = normalize_id(Map.get(edge, :target))
    protocol = edge_protocol(edge)
    {x, y} = canonical_pair(a || "", b || "")
    {x, y, protocol}
  end

  defp endpoint_attachment_edge?(edge, device_by_uid) do
    endpoint_uid = endpoint_uid_for_edge(edge, device_by_uid)
    infra_uid = infra_uid_for_edge(edge, device_by_uid)
    inferred_protocol?(edge) and is_binary(endpoint_uid) and is_binary(infra_uid)
  end

  defp endpoint_uid_for_edge(edge, device_by_uid) do
    source_uid = normalize_id(Map.get(edge, :source))
    target_uid = normalize_id(Map.get(edge, :target))
    source = Map.get(device_by_uid, source_uid)
    target = Map.get(device_by_uid, target_uid)

    cond do
      endpoint_device?(source) and infrastructure_device?(target) -> source_uid
      endpoint_device?(target) and infrastructure_device?(source) -> target_uid
      true -> nil
    end
  end

  defp infra_uid_for_edge(edge, device_by_uid) do
    source_uid = normalize_id(Map.get(edge, :source))
    target_uid = normalize_id(Map.get(edge, :target))
    source = Map.get(device_by_uid, source_uid)
    target = Map.get(device_by_uid, target_uid)

    cond do
      infrastructure_device?(source) and endpoint_device?(target) -> source_uid
      infrastructure_device?(target) and endpoint_device?(source) -> target_uid
      true -> nil
    end
  end

  defp infra_infra_edge?(edge, device_by_uid) do
    source = Map.get(device_by_uid, normalize_id(Map.get(edge, :source)))
    target = Map.get(device_by_uid, normalize_id(Map.get(edge, :target)))
    infrastructure_device?(source) and infrastructure_device?(target)
  end

  defp router_uid_for_edge(edge, device_by_uid) do
    source_uid = normalize_id(Map.get(edge, :source))
    target_uid = normalize_id(Map.get(edge, :target))
    source = Map.get(device_by_uid, source_uid)
    target = Map.get(device_by_uid, target_uid)

    cond do
      router_device?(source) -> source_uid
      router_device?(target) -> target_uid
      true -> nil
    end
  end

  defp best_endpoint_attachment(candidates, device_by_uid) do
    Enum.max_by(
      candidates,
      fn edge ->
        infra_uid = infra_uid_for_edge(edge, device_by_uid)
        infra = Map.get(device_by_uid, infra_uid)
        {infra_role_rank(infra), edge_rank(edge)}
      end,
      fn -> nil end
    )
  end

  defp best_router_inferred_edge(candidates, device_by_uid, direct_degree) do
    Enum.max_by(
      candidates,
      fn edge ->
        router_uid = router_uid_for_edge(edge, device_by_uid)
        source_uid = normalize_id(Map.get(edge, :source))
        target_uid = normalize_id(Map.get(edge, :target))
        peer_uid = if source_uid == router_uid, do: target_uid, else: source_uid
        peer = Map.get(device_by_uid, peer_uid)
        peer_direct = Map.get(direct_degree, peer_uid, 0)
        {infra_role_rank(peer), peer_direct, edge_rank(edge)}
      end,
      fn -> nil end
    )
  end

  defp direct_infra_degree(edges, device_by_uid) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      if direct_protocol?(edge) and infra_infra_edge?(edge, device_by_uid) do
        source_uid = normalize_id(Map.get(edge, :source))
        target_uid = normalize_id(Map.get(edge, :target))

        acc
        |> Map.update(source_uid, 1, &(&1 + 1))
        |> Map.update(target_uid, 1, &(&1 + 1))
      else
        acc
      end
    end)
  end

  defp infra_role_rank(device) do
    cond do
      switch_device?(device) -> 4
      ap_device?(device) -> 3
      router_device?(device) -> 2
      infrastructure_device?(device) -> 1
      true -> 0
    end
  end

  defp gateway_corr_edge?(edge) do
    metadata = Map.get(edge, :metadata) || %{}
    source = metadata["source"] || metadata[:source]
    inference = metadata["inference"] || metadata[:inference]
    source == "gateway-correlation" and inference == "router_interface_subnet_match"
  end

  defp maybe_put_set(set, value) do
    if is_binary(value), do: MapSet.put(set, value), else: set
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
              (d.uid in ^ids or d.ip in ^ids or d.name in ^ids or d.hostname in ^ids),
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
    resolver = build_device_identifier_resolver(devices)

    edges
    |> Enum.map(fn edge ->
      source =
        resolve_device_id(
          Map.get(edge, :source),
          [Map.get(edge, :local_device_ip)],
          resolver
        )

      target =
        resolve_device_id(
          Map.get(edge, :target),
          [Map.get(edge, :neighbor_mgmt_addr)],
          resolver
        )

      edge
      |> Map.put(:source, source)
      |> Map.put(:target, target)
    end)
    |> Enum.reject(fn edge ->
      is_nil(Map.get(edge, :source)) or is_nil(Map.get(edge, :target)) or
        Map.get(edge, :source) == Map.get(edge, :target)
    end)
  end

  defp canonicalize_edges(_, _), do: []

  defp build_device_identifier_resolver(devices) when is_list(devices) do
    Enum.reduce(devices, %{}, fn device, acc ->
      uid = normalize_id(Map.get(device, :uid))

      if is_binary(uid) do
        acc
        |> Map.put(uid, uid)
        |> put_identifier(uid, Map.get(device, :ip))
        |> put_identifier(uid, Map.get(device, :name))
        |> put_identifier(uid, Map.get(device, :hostname))
        |> put_identifier(uid, Map.get(device, :mac))
        |> put_identifier(uid, Map.get(device, :uid_alt))
        |> put_metadata_identifiers(uid, Map.get(device, :metadata))
      else
        acc
      end
    end)
  end

  defp put_identifier(acc, uid, value) do
    case normalize_id(value) do
      nil -> acc
      key -> Map.put_new(acc, String.downcase(key), uid)
    end
  end

  defp put_metadata_identifiers(acc, uid, metadata) when is_map(metadata) do
    acc
    |> put_identifier(uid, metadata["device_id"] || metadata[:device_id])
    |> put_identifier(uid, metadata["snmp_name"] || metadata[:snmp_name])
    |> put_ip_alias_identifiers(uid, metadata)
  end

  defp put_metadata_identifiers(acc, _uid, _metadata), do: acc

  defp put_ip_alias_identifiers(acc, uid, metadata) when is_map(metadata) do
    Enum.reduce(metadata, acc, fn {raw_key, _value}, inner ->
      key =
        case raw_key do
          atom when is_atom(atom) -> Atom.to_string(atom)
          binary when is_binary(binary) -> binary
          _ -> nil
        end

      cond do
        is_nil(key) ->
          inner

        String.starts_with?(key, "alt_ip:") ->
          ip = String.trim_leading(key, "alt_ip:")
          put_identifier(inner, uid, ip)

        String.starts_with?(key, "ip_alias:") ->
          ip = String.trim_leading(key, "ip_alias:")
          put_identifier(inner, uid, ip)

        true ->
          inner
      end
    end)
  end

  defp resolve_device_id(raw_value, fallbacks, resolver) do
    candidates = [raw_value | List.wrap(fallbacks)]

    Enum.find_value(candidates, fn value ->
      normalized = normalize_id(value)

      cond do
        is_nil(normalized) ->
          nil

        Map.has_key?(resolver, normalized) ->
          Map.get(resolver, normalized)

        Map.has_key?(resolver, String.downcase(normalized)) ->
          Map.get(resolver, String.downcase(normalized))

        true ->
          nil
      end
    end)
  end

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

  defp enforce_edge_interface_contracts(edges) when is_list(edges) do
    Enum.filter(edges, &edge_interface_contract_valid?/1)
  end

  defp enforce_edge_interface_contracts(_), do: []

  defp edge_interface_contract_valid?(edge) when is_map(edge) do
    protocol = edge_protocol(edge)

    if MapSet.member?(@strict_ifindex_protocols, protocol) do
      valid_ifindex?(Map.get(edge, :local_if_index))
    else
      true
    end
  end

  defp edge_interface_contract_valid?(_), do: false

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
        "unifi-api" -> 3
        "snmp-l2" -> 2
        "snmp-parent" -> 1
        "snmp-site" -> 0
        _ -> 0
      end

    telemetry_rank =
      cond do
        is_integer(Map.get(edge, :local_if_index)) -> 2
        is_binary(normalize_id(Map.get(edge, :local_if_name))) -> 1
        true -> 0
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

  defp node_ids(edge_node_ids, devices) do
    seed_or_edge_ids = Enum.map(devices, & &1.uid)

    edge_node_ids
    |> Kernel.++(seed_or_edge_ids)
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

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

  defp apply_native_layout_with_indexed_edges(nodes, indexed_edges)
       when is_list(nodes) and is_list(indexed_edges) do
    if indexed_edges == [] do
      nodes
    else
      case Native.layout_nodes_hypergraph(length(nodes), indexed_edges) do
        coordinates when is_list(coordinates) and length(coordinates) == length(nodes) ->
          Enum.zip(nodes, coordinates)
          |> Enum.map(fn
            {node, {x, y}} when is_integer(x) and is_integer(y) ->
              %{node | x: x, y: y}

            {node, _} ->
              node
          end)

        _ ->
          nodes
      end
    end
  end

  defp apply_native_layout_with_indexed_edges(nodes, _), do: nodes

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

  defp node_kind(nil), do: "external"
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
    cond do
      String.match?(id, ~r/^\d{1,3}(\.\d{1,3}){3}$/) -> id
      true -> nil
    end
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

  defp router_device?(device) when is_map(device) do
    type = Map.get(device, :type) |> to_string() |> String.downcase()
    Map.get(device, :type_id) == 12 or type == "router"
  end

  defp router_device?(_), do: false

  defp switch_device?(device) when is_map(device) do
    type = Map.get(device, :type) |> to_string() |> String.downcase()
    Map.get(device, :type_id) == 10 or String.contains?(type, "switch")
  end

  defp switch_device?(_), do: false

  defp ap_device?(device) when is_map(device) do
    type = Map.get(device, :type) |> to_string() |> String.downcase()
    model = Map.get(device, :model) |> to_string() |> String.downcase()
    role = node_meta_value(device, ["device_role"]) |> to_string() |> String.downcase()

    String.contains?(type, "access point") or String.contains?(role, "ap") or
      String.starts_with?(model, "u6") or String.contains?(model, "uap")
  end

  defp ap_device?(_), do: false

  defp infrastructure_device?(device) when is_map(device) do
    type = node_type(device) |> to_string() |> String.downcase()

    router_device?(device) or switch_device?(device) or ap_device?(device) or
      type in ["firewall", "load_balancer", "ids", "ips", "hub"]
  end

  defp infrastructure_device?(_), do: false

  defp endpoint_device?(device) when is_map(device), do: not infrastructure_device?(device)
  defp endpoint_device?(_), do: false

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
          normalize_i64(Map.get(edge, :local_if_index)),
          normalize_id(Map.get(edge, :local_if_name)) || "",
          encode_json(Map.get(edge, :metadata) || %{})
        }
      end)

    interface_rows =
      interfaces
      |> Enum.map(fn iface ->
        {
          normalize_id(Map.get(iface, :device_id)) || "",
          normalize_id(Map.get(iface, :if_name)) || "",
          normalize_i64(Map.get(iface, :if_index)),
          normalize_u64(interface_capacity_bps(iface) || 0),
          encode_json(Map.get(iface, :metadata) || %{})
        }
      end)
      |> Enum.reject(fn {device_id, _if_name, _if_index, _speed_bps, _metadata} ->
        device_id == ""
      end)

    pps_rows =
      Enum.flat_map(pps_by_if, fn
        {{device_id, if_index}, value} when is_binary(device_id) and is_integer(if_index) ->
          [{device_id, if_index, normalize_u32(value)}]

        _ ->
          []
      end)

    bps_rows =
      Enum.flat_map(bps_by_if, fn
        {{device_id, if_index}, value} when is_binary(device_id) and is_integer(if_index) ->
          [{device_id, if_index, normalize_u64(value)}]

        _ ->
          []
      end)

    case Native.enrich_edges_telemetry(edge_rows, interface_rows, pps_rows, bps_rows) do
      enriched_rows when is_list(enriched_rows) and length(enriched_rows) == length(edges) ->
        result =
          Enum.zip(edges, enriched_rows)
          |> Enum.map(fn
            {edge, {_source, _target, flow_pps, flow_bps, capacity_bps, label}} ->
              Map.merge(edge, %{
                flow_pps: flow_pps,
                flow_bps: flow_bps,
                capacity_bps: capacity_bps,
                label: label
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

  defp load_interface_pps(interface_index) when is_map(interface_index) do
    keys =
      interface_index.by_device_if
      |> Map.keys()
      |> Enum.flat_map(fn
        {:if_index, device_id, if_index} when is_binary(device_id) and is_integer(if_index) ->
          [{device_id, if_index}]

        _ ->
          []
      end)
      |> Enum.uniq()

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
      |> Enum.reduce(%{}, fn {{device_id, if_index}, values}, acc ->
        in_pps = Map.get(values, :in, 0)
        out_pps = Map.get(values, :out, 0)
        Map.put(acc, {device_id, if_index}, in_pps + out_pps)
      end)
    end
  rescue
    _ -> %{}
  end

  defp load_interface_pps(_), do: %{}

  defp load_interface_bps(interface_index) when is_map(interface_index) do
    keys =
      interface_index.by_device_if
      |> Map.keys()
      |> Enum.flat_map(fn
        {:if_index, device_id, if_index} when is_binary(device_id) and is_integer(if_index) ->
          [{device_id, if_index}]

        _ ->
          []
      end)
      |> Enum.uniq()

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
          bits_per_second = bytes_per_second * 8

          Map.update(acc, key, %{dir => bits_per_second}, fn current ->
            current
            |> Map.update(dir, bits_per_second, &max(&1, bits_per_second))
          end)
        end
      end)
      |> Enum.reduce(%{}, fn {{device_id, if_index}, values}, acc ->
        in_bps = Map.get(values, :in, 0)
        out_bps = Map.get(values, :out, 0)
        Map.put(acc, {device_id, if_index}, in_bps + out_bps)
      end)
    end
  rescue
    _ -> %{}
  end

  defp load_interface_bps(_), do: %{}

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

    "#{protocol} #{format_rate(flow_pps || 0)} / #{format_capacity(capacity_bps || 0)}"
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
    signals =
      Enum.map(nodes, fn node ->
        case Map.get(node, :health_signal, :unknown) do
          :healthy -> 0
          :unhealthy -> 1
          _ -> 2
        end
      end)

    states = Native.evaluate_causal_states(signals, indexed_edges)

    Enum.zip(nodes, states)
    |> Enum.map(fn {node, state} ->
      node
      |> Map.put(:state, state)
      |> Map.delete(:health_signal)
    end)
  end

  defp apply_causal_states(nodes, _), do: nodes

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
      normalize_id(Map.get(link, :local_if_name)) ||
      normalize_id(Map.get(link, :agent_id)) ||
      normalize_id(Map.get(link, :gateway_id))
  end

  defp fallback_neighbor_id(link) do
    normalize_id(Map.get(link, :neighbor_mgmt_addr)) ||
      normalize_id(Map.get(link, :neighbor_system_name)) ||
      normalize_id(Map.get(link, :neighbor_chassis_id)) ||
      normalize_id(Map.get(link, :neighbor_port_id)) ||
      normalize_id(Map.get(link, :neighbor_port_descr))
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
  defp normalize_u32(value) when is_integer(value), do: clamp(value, 0, 4_294_967_295)
  defp normalize_u32(_), do: 0
  defp normalize_u64(value) when is_integer(value), do: max(value, 0)
  defp normalize_u64(_), do: 0
  defp normalize_i64(value) when is_integer(value), do: value
  defp normalize_i64(_), do: -1

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

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
