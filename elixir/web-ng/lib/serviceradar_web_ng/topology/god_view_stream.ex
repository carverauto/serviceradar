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
  alias ServiceRadar.Camera.Source, as: CameraSource
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
  @god_view_evidence_classes [
    "direct",
    "logical",
    "hosted",
    "inferred",
    "observed",
    "endpoint-attachment",
    "direct-physical",
    "direct-logical",
    "hosted-virtual",
    "inferred-segment",
    "observed-only"
  ]
  @endpoint_cluster_min_members 3
  @endpoint_cluster_expanded_visible_limit 24
  @endpoint_cluster_expanded_topology_sighting_limit 6
  @endpoint_cluster_ambiguous_peer_threshold 12
  @endpoint_cluster_ambiguous_observation_gap 8
  @endpoint_cluster_ambiguous_relative_ratio 0.85
  @endpoint_cluster_access_target_gap_threshold 2
  @endpoint_cluster_access_target_supplement_max_peer_count 1
  @router_endpoint_cluster_min_distinct_subnets 3
  @endpoint_cluster_summary_gap_x 132.0
  @endpoint_cluster_summary_gap_y 54.0
  @max_cluster_camera_tile_candidates 12
  @unplaced_device_query_limit 96
  @unplaced_device_visible_limit 16
  @unplaced_device_type_ids [1, 6, 9, 10, 12, 15, 99]
  @proximity_collision_iterations 8
  @proximity_collision_min_distance 34.0
  @drop_counter_key {__MODULE__, :dropped_updates}
  @layout_cache_key {__MODULE__, :layout_cache}
  @snapshot_cache_key {__MODULE__, :snapshot_cache}

  @spec latest_snapshot(map()) ::
          {:ok, %{snapshot: GodViewSnapshot.snapshot(), payload: binary()}} | {:error, term()}
  def latest_snapshot(opts \\ %{}) do
    snapshot_opts = normalize_snapshot_options(opts)

    coalesce_ms =
      if default_snapshot_options?(snapshot_opts), do: snapshot_coalesce_ms(), else: 0

    case coalesced_snapshot(coalesce_ms) do
      {:ok, result} ->
        {:ok, result}

      :miss ->
        build_latest_snapshot(snapshot_opts)
    end
  end

  defp build_latest_snapshot(snapshot_opts) do
    started_at = System.monotonic_time()
    actor = SystemActor.system(:god_view_stream)
    budget_ms = real_time_budget_ms()

    with {:ok, projection} <- build_projection(actor, snapshot_opts),
         revision =
           snapshot_revision(
             projection.topology_revision,
             projection.causal_revision,
             snapshot_opts
           ),
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

        if default_snapshot_options?(snapshot_opts) do
          put_snapshot_cache(result)
        end

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

  defp build_projection(actor, snapshot_opts) do
    with {:ok, links} <- fetch_topology_links(actor),
         {:ok, nodes, edges, pipeline_stats} <- build_nodes_and_edges(actor, links),
         {:ok, layout_indexed_edges} <- index_edges(nodes, layout_transport_edges(edges)),
         {:ok, causal_indexed_edges} <- index_edges(nodes, causal_transport_edges(edges)) do
      layout_revision = topology_revision(nodes, layout_indexed_edges)
      nodes = maybe_apply_backend_layout(nodes, layout_indexed_edges, layout_revision)
      nodes = apply_causal_states(nodes, causal_indexed_edges)
      edges = promote_projection_attachment_candidates(edges, nodes)

      {nodes, edges, pipeline_stats} =
        apply_endpoint_cluster_projection(nodes, edges, pipeline_stats, snapshot_opts)

      {nodes, edges, pipeline_stats} =
        quarantine_unresolved_endpoint_identities(nodes, edges, pipeline_stats)

      edges = retain_renderable_edges(nodes, edges)
      nodes = retain_renderable_nodes(nodes, edges)
      {:ok, indexed_edges} = index_edges(nodes, edges)
      pipeline_stats = rendered_pipeline_stats(pipeline_stats, nodes, edges)
      emit_pipeline_stats(pipeline_stats)
      topology_revision = topology_revision(nodes, indexed_edges)
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

  defp maybe_apply_backend_layout(nodes, indexed_edges, topology_revision)
       when is_list(nodes) and is_list(indexed_edges) do
    if legacy_backend_layout_authority_enabled?() do
      nodes
      |> apply_native_layout_with_indexed_edges(indexed_edges, topology_revision)
      |> resolve_coordinate_collisions()
      |> resolve_proximity_collisions()
    else
      nodes
    end
  end

  defp retain_renderable_edges(nodes, edges) when is_list(nodes) and is_list(edges) do
    node_ids = MapSet.new(Enum.map(nodes, &Map.get(&1, :id)))

    Enum.filter(edges, fn
      %{source: source, target: target} when is_binary(source) and is_binary(target) ->
        MapSet.member?(node_ids, source) and MapSet.member?(node_ids, target)

      _ ->
        false
    end)
  end

  defp retain_renderable_nodes(nodes, edges) when is_list(nodes) and is_list(edges) do
    connected_ids =
      edges
      |> Enum.flat_map(fn
        %{source: source, target: target} -> [source, target]
        _ -> []
      end)
      |> MapSet.new()

    Enum.filter(nodes, fn
      %{id: id} when is_binary(id) -> MapSet.member?(connected_ids, id)
      _ -> false
    end)
  end

  defp quarantine_unresolved_endpoint_identities(nodes, edges, pipeline_stats)
       when is_list(nodes) and is_list(edges) and is_map(pipeline_stats) do
    nodes_by_id = Map.new(nodes, &{&1.id, &1})

    quarantined_node_ids =
      nodes
      |> Enum.filter(&quarantinable_unresolved_endpoint_node?/1)
      |> Enum.reject(&cluster_member_node?(&1))
      |> MapSet.new(& &1.id)

    if MapSet.size(quarantined_node_ids) == 0 do
      {nodes, edges, pipeline_stats}
    else
      filtered_edges =
        Enum.reject(
          edges,
          &quarantined_unresolved_endpoint_edge?(&1, quarantined_node_ids, nodes_by_id)
        )

      next_pipeline_stats =
        pipeline_stats
        |> Map.put(:quarantined_unresolved_endpoint_nodes, MapSet.size(quarantined_node_ids))
        |> Map.put(:quarantined_unresolved_endpoint_edges, length(edges) - length(filtered_edges))

      {nodes, filtered_edges, next_pipeline_stats}
    end
  end

  defp quarantine_unresolved_endpoint_identities(nodes, edges, pipeline_stats), do: {nodes, edges, pipeline_stats}

  defp quarantinable_unresolved_endpoint_node?(%{id: id} = node) when is_binary(id) do
    details = decode_details_json(Map.get(node, :details_json))
    cluster_kind = normalize_id(Map.get(details, "cluster_kind"))

    String.starts_with?(id, "sr:") and
      is_nil(normalize_ipv4(Map.get(details, "ip"))) and
      blank_node_identity?(Map.get(details, "name")) and
      blank_node_identity?(Map.get(details, "hostname")) and
      cluster_kind not in ["endpoint-member", "endpoint-summary", "endpoint-anchor"]
  end

  defp quarantinable_unresolved_endpoint_node?(_node), do: false

  defp cluster_member_node?(node) when is_map(node) do
    node
    |> Map.get(:details_json)
    |> decode_details_json()
    |> Map.get("cluster_kind") == "endpoint-member"
  end

  defp cluster_member_node?(_node), do: false

  defp quarantined_unresolved_endpoint_edge?(edge, quarantined_node_ids, nodes_by_id)
       when is_map(edge) and is_struct(quarantined_node_ids, MapSet) and is_map(nodes_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))

    endpoint_attachment_edge?(edge) and not cluster_projection_edge?(edge, nodes_by_id) and
      (MapSet.member?(quarantined_node_ids, source) or
         MapSet.member?(quarantined_node_ids, target))
  end

  defp quarantined_unresolved_endpoint_edge?(_edge, _quarantined_node_ids, _nodes_by_id), do: false

  defp cluster_projection_edge?(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    metadata = Map.get(edge, :metadata) || %{}

    Map.get(edge, :protocol) == "cluster" or
      is_binary(Map.get(metadata, "cluster_id")) or
      cluster_summary_node?(Map.get(nodes_by_id, source)) or
      cluster_summary_node?(Map.get(nodes_by_id, target))
  end

  defp cluster_projection_edge?(_edge, _nodes_by_id), do: false

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
    raw_edges =
      raw_links
      |> Enum.map(&runtime_link_to_edge/1)
      |> Enum.reject(&is_nil/1)

    raw_edge_node_ids = raw_edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

    with {:ok, devices} <- fetch_devices(actor, raw_edge_node_ids) do
      initial_device_by_id = Map.new(devices, &{&1.uid, &1})
      edges = collapse_endpoint_attachments(raw_edges, initial_device_by_id)
      edge_node_ids = edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()
      node_pps_by_id = node_pps_by_id(edges)

      with {:ok, unplaced_devices} <- fetch_unplaced_devices(actor, edge_node_ids),
           {:ok, camera_sources_by_device_uid} <-
             fetch_camera_sources(actor, Enum.map(devices ++ unplaced_devices, & &1.uid)) do
        all_devices =
          (devices ++ unplaced_devices)
          |> Enum.uniq_by(& &1.uid)
          |> Enum.sort_by(& &1.uid)

        device_by_id = Map.new(all_devices, &{&1.uid, &1})
        node_ids = node_ids(edge_node_ids, unplaced_devices)
        unplaced_node_ids = unplaced_node_ids(edge_node_ids, unplaced_devices)

        nodes =
          build_nodes(
            node_ids,
            device_by_id,
            node_pps_by_id,
            camera_sources_by_device_uid,
            unplaced_node_ids
          )

        edge_contract_stats = edge_contract_stats(edges)

        unresolved_endpoints =
          Enum.count(edge_node_ids, fn id -> not Map.has_key?(device_by_id, id) end)

        pipeline_stats =
          raw_edges
          |> pipeline_stats(edges, edges, nodes, unresolved_endpoints)
          |> Map.merge(edge_contract_stats)
          |> Map.merge(component_stats(nodes, edges))

        {:ok, nodes, edges, pipeline_stats}
      end
    end
  end

  defp pipeline_stats(raw_links, pair_links, final_edges, final_nodes, unresolved_endpoints)
       when is_list(raw_links) and is_list(pair_links) and is_list(final_edges) and is_list(final_nodes) and
              is_integer(unresolved_endpoints) do
    edge_parity_delta = abs(length(raw_links) - length(final_edges))
    unplaced_nodes = Enum.count(final_nodes, &unplaced_topology_node?/1)

    %{
      raw_links: length(raw_links),
      unique_pairs: length(pair_links),
      final_edges: length(final_edges),
      final_nodes: length(final_nodes),
      unplaced_nodes: unplaced_nodes,
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

  defp collapse_endpoint_attachments(edges, device_by_id) when is_list(edges) and is_map(device_by_id) do
    {attachment_edges, other_edges} =
      Enum.split_with(edges, &attachment_candidate_edge?(&1, device_by_id))

    incident_profiles = attachment_incident_profiles(edges, device_by_id)

    collapsed =
      attachment_edges
      |> Enum.group_by(&attachment_group_key(&1, device_by_id))
      |> Enum.flat_map(fn
        {nil, grouped_edges} ->
          grouped_edges

        {group_key, grouped_edges} ->
          if ambiguous_low_confidence_attachment_group?(group_key, grouped_edges, device_by_id) do
            []
          else
            selected =
              grouped_edges
              |> Enum.max_by(&attachment_edge_rank(&1, device_by_id, incident_profiles))
              |> annotate_attachment_group_observation_count(length(grouped_edges))

            [selected]
          end
      end)
      |> Enum.map(&promote_attachment_candidate_edge(&1, device_by_id))
      |> drop_endpoint_identity_bridges(device_by_id)

    other_edges ++ collapsed
  end

  defp attachment_group_key(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    anchor_id = attachment_anchor_id(edge, device_by_id)

    identity_key =
      cond do
        ip = attachment_identity_ip(edge, device_by_id) -> "ip:" <> ip
        mac = attachment_identity_mac(edge, device_by_id) -> "mac:" <> mac
        true -> attachment_endpoint_id(edge, device_by_id)
      end

    attachment_identity_group_key(identity_key, anchor_id, Map.get(device_by_id, anchor_id))
  end

  defp attachment_group_key(_edge, _device_by_id), do: nil

  defp annotate_attachment_group_observation_count(edge, observation_count)
       when is_map(edge) and is_integer(observation_count) and observation_count > 0 do
    metadata =
      edge
      |> Map.get(:metadata, %{})
      |> Map.put("attachment_observation_count", observation_count)

    edge
    |> Map.put(:metadata, metadata)
    |> Map.put(:attachment_observation_count, observation_count)
  end

  defp annotate_attachment_group_observation_count(edge, _observation_count) when is_map(edge), do: edge

  defp attachment_identity_group_key(identity_key, anchor_id, anchor_device)
       when is_binary(identity_key) and is_binary(anchor_id) do
    if access_attachment_anchor?(anchor_device) do
      "#{identity_key}|anchor:#{anchor_id}"
    else
      identity_key
    end
  end

  defp attachment_identity_group_key(identity_key, _anchor_id, _anchor_device) when is_binary(identity_key),
    do: identity_key

  defp attachment_identity_group_key(_identity_key, _anchor_id, _anchor_device), do: nil

  defp attachment_endpoint_id(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    source_device = Map.get(device_by_id, source)
    target_device = Map.get(device_by_id, target)
    source_endpoint? = endpoint_like_device?(source_device)
    target_endpoint? = endpoint_like_device?(target_device)

    cond do
      source_endpoint? and not target_endpoint? -> source
      target_endpoint? and not source_endpoint? -> target
      true -> target || source
    end
  end

  defp attachment_endpoint_id(_edge, _device_by_id), do: nil

  defp attachment_identity_ip(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    edge
    |> attachment_endpoint_sides(device_by_id)
    |> Enum.flat_map(fn {side, endpoint_id, device} ->
      [node_ip(device, endpoint_id), attachment_side_ip(edge, side, endpoint_id)]
    end)
    |> Enum.map(&normalize_ipv4/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> List.first()
  end

  defp attachment_identity_ip(_edge, _device_by_id), do: nil

  defp attachment_identity_mac(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    edge
    |> attachment_endpoint_sides(device_by_id)
    |> Enum.flat_map(fn {side, endpoint_id, device} ->
      [
        endpoint_id,
        node_meta_value(device, ["mac", "mac_address", "endpoint_mac", "primary_mac"]),
        attachment_side_mac(edge, side)
      ]
    end)
    |> Enum.map(&normalize_mac/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> List.first()
  end

  defp attachment_identity_mac(_edge, _device_by_id), do: nil

  defp attachment_endpoint_sides(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    source_device = Map.get(device_by_id, source)
    target_device = Map.get(device_by_id, target)
    source_endpoint? = endpoint_like_device?(source_device)
    target_endpoint? = endpoint_like_device?(target_device)

    []
    |> maybe_add_endpoint_side(source_endpoint?, {:source, source, source_device})
    |> maybe_add_endpoint_side(target_endpoint?, {:target, target, target_device})
  end

  defp attachment_endpoint_sides(_edge, _device_by_id), do: []

  defp maybe_add_endpoint_side(sides, true, {_side, endpoint_id, _device} = endpoint_side)
       when is_list(sides) and is_binary(endpoint_id) do
    [endpoint_side | sides]
  end

  defp maybe_add_endpoint_side(sides, _include?, _endpoint_side) when is_list(sides), do: sides

  defp attachment_side_ip(edge, :source, _endpoint_id), do: normalize_ipv4(Map.get(edge, :local_device_ip))

  defp attachment_side_ip(edge, :target, _endpoint_id), do: normalize_ipv4(Map.get(edge, :neighbor_mgmt_addr))

  defp attachment_side_ip(_edge, _side, _endpoint_id), do: nil

  defp attachment_side_mac(edge, :source) do
    normalize_mac(Map.get(edge, :local_if_name)) ||
      normalize_mac(Map.get(edge, :local_if_name_ab)) ||
      normalize_mac(Map.get(edge, :local_if_name_ba))
  end

  defp attachment_side_mac(edge, :target) do
    normalize_mac(Map.get(edge, :neighbor_if_name)) ||
      normalize_mac(Map.get(edge, :local_if_name_ba)) ||
      normalize_mac(Map.get(edge, :local_if_name_ab))
  end

  defp attachment_side_mac(_edge, _side), do: nil

  defp attachment_incident_profiles(edges, device_by_id) when is_list(edges) and is_map(device_by_id) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      attachment_edge? = attachment_candidate_edge?(edge, device_by_id)
      update_attachment_incident_profile(acc, edge, attachment_edge?)
    end)
  end

  defp attachment_incident_profiles(_edges, _device_by_id), do: %{}

  defp update_attachment_incident_profile(acc, edge, attachment_edge?) when is_map(acc) and is_map(edge) do
    edge
    |> edge_node_ids()
    |> Enum.reduce(acc, &put_attachment_incident_profile(&2, &1, attachment_edge?))
  end

  defp update_attachment_incident_profile(acc, _edge, _attachment_edge?) when is_map(acc), do: acc

  defp put_attachment_incident_profile(acc, node_id, attachment_edge?)
       when is_map(acc) and is_binary(node_id) and is_boolean(attachment_edge?) do
    attachment_delta = if(attachment_edge?, do: 1, else: 0)
    non_attachment_delta = if(attachment_edge?, do: 0, else: 1)

    Map.update(
      acc,
      node_id,
      %{attachment_count: attachment_delta, non_attachment_count: non_attachment_delta},
      fn profile ->
        %{
          attachment_count: profile.attachment_count + attachment_delta,
          non_attachment_count: profile.non_attachment_count + non_attachment_delta
        }
      end
    )
  end

  defp put_attachment_incident_profile(acc, _node_id, _attachment_edge?) when is_map(acc), do: acc

  defp drop_endpoint_identity_bridges(edges, device_by_id) when is_list(edges) and is_map(device_by_id) do
    Enum.reject(edges, &endpoint_identity_bridge_edge?(&1, device_by_id))
  end

  defp endpoint_identity_bridge_edge?(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    source_device = Map.get(device_by_id, source)
    target_device = Map.get(device_by_id, target)

    endpoint_attachment_edge?(edge) and
      endpoint_like_device?(source_device) and
      endpoint_like_device?(target_device) and
      ((resolved_endpoint_identity?(source, source_device) and
          anonymous_unresolved_node?(target, target_device)) or
         (resolved_endpoint_identity?(target, target_device) and
            anonymous_unresolved_node?(source, source_device)))
  end

  defp endpoint_identity_bridge_edge?(_edge, _device_by_id), do: false

  defp ambiguous_low_confidence_attachment_group?(group_key, grouped_edges, device_by_id)
       when is_binary(group_key) and is_list(grouped_edges) and is_map(device_by_id) do
    if resolved_attachment_group_key?(group_key) do
      false
    else
      distinct_viable_anchors =
        grouped_edges
        |> Enum.map(fn edge ->
          anchor_id = attachment_anchor_id(edge, device_by_id)
          {anchor_id, Map.get(device_by_id, anchor_id)}
        end)
        |> Enum.reject(fn
          {anchor_id, anchor_device} when is_binary(anchor_id) ->
            anonymous_unresolved_node?(anchor_id, anchor_device)

          _ ->
            true
        end)
        |> Enum.uniq_by(&elem(&1, 0))

      length(distinct_viable_anchors) > 1 and
        Enum.all?(grouped_edges, fn edge ->
          attachment_confidence_rank(Map.get(edge, :confidence_tier)) <= 1 and
            normalize_id(Map.get(edge, :confidence_reason)) == "single_identifier_inference"
        end)
    end
  end

  defp ambiguous_low_confidence_attachment_group?(nil, grouped_edges, device_by_id)
       when is_list(grouped_edges) and is_map(device_by_id) do
    distinct_viable_anchors =
      grouped_edges
      |> Enum.map(fn edge ->
        anchor_id = attachment_anchor_id(edge, device_by_id)
        {anchor_id, Map.get(device_by_id, anchor_id)}
      end)
      |> Enum.reject(fn
        {anchor_id, anchor_device} when is_binary(anchor_id) ->
          anonymous_unresolved_node?(anchor_id, anchor_device)

        _ ->
          true
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    length(distinct_viable_anchors) > 1 and
      Enum.all?(grouped_edges, fn edge ->
        attachment_confidence_rank(Map.get(edge, :confidence_tier)) <= 1 and
          normalize_id(Map.get(edge, :confidence_reason)) == "single_identifier_inference"
      end)
  end

  defp ambiguous_low_confidence_attachment_group?(_group_key, _grouped_edges, _device_by_id), do: false

  defp resolved_attachment_group_key?("ip:" <> ip), do: normalize_ipv4(ip) != nil
  defp resolved_attachment_group_key?("mac:" <> mac), do: normalize_mac(mac) != nil
  defp resolved_attachment_group_key?(_group_key), do: false

  defp attachment_anchor_id(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    endpoint_id = attachment_endpoint_id(edge, device_by_id)

    cond do
      endpoint_id == source -> target
      endpoint_id == target -> source
      true -> nil
    end
  end

  defp attachment_anchor_id(_edge, _device_by_id), do: nil

  defp attachment_edge_rank(edge, device_by_id, incident_profiles)
       when is_map(edge) and is_map(device_by_id) and is_map(incident_profiles) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    endpoint_id = attachment_endpoint_id(edge, device_by_id)
    anchor_id = if endpoint_id == source, do: target, else: source
    anchor_device = Map.get(device_by_id, anchor_id)

    anchor_profile =
      Map.get(incident_profiles, anchor_id, %{attachment_count: 0, non_attachment_count: 0})

    confidence_rank = attachment_confidence_rank(Map.get(edge, :confidence_tier))
    flow_pps = normalize_u32(Map.get(edge, :flow_pps, 0))
    telemetry_rank = if Map.get(edge, :telemetry_source) == "interface", do: 1, else: 0
    attachment_rank = if attachment_endpoint_id(edge, device_by_id), do: 1, else: 0

    {
      attachment_anchor_rank(anchor_id, anchor_device, anchor_profile),
      if(infrastructure_device?(anchor_device), do: 1, else: 0),
      if(topology_sighting_device?(anchor_device), do: 0, else: 1),
      confidence_rank,
      telemetry_rank,
      flow_pps,
      attachment_rank,
      to_string(anchor_id || "")
    }
  end

  defp attachment_edge_rank(_edge, _device_by_id, _incident_profiles), do: {0, 0, 0, 0, 0, 0, 0, ""}

  defp attachment_anchor_rank(anchor_id, anchor_device, %{attachment_count: attachment_count})
       when is_integer(attachment_count) do
    cond do
      access_attachment_anchor?(anchor_device) -> 4
      infrastructure_device?(anchor_device) -> 3
      attachment_count >= 4 and not anonymous_unresolved_node?(anchor_id, anchor_device) -> 2
      anonymous_unresolved_node?(anchor_id, anchor_device) -> 0
      attachment_count >= 2 -> 1
      true -> 0
    end
  end

  defp attachment_anchor_rank(anchor_id, anchor_device, _profile) do
    cond do
      access_attachment_anchor?(anchor_device) -> 3
      infrastructure_device?(anchor_device) -> 2
      anonymous_unresolved_node?(anchor_id, anchor_device) -> 0
      true -> 0
    end
  end

  defp attachment_confidence_rank("high"), do: 3
  defp attachment_confidence_rank("medium"), do: 2
  defp attachment_confidence_rank("low"), do: 1
  defp attachment_confidence_rank(_), do: 0

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

  defp fetch_unplaced_devices(actor, connected_node_ids) when is_list(connected_node_ids) do
    connected_node_id_set =
      connected_node_ids
      |> Enum.map(&normalize_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.filter(
        is_managed == true and not is_nil(last_seen_time) and
          type_id in ^@unplaced_device_type_ids
      )
      |> Ash.Query.sort(last_seen_time: :desc, modified_time: :desc)
      |> Ash.Query.limit(@unplaced_device_query_limit)

    case Ash.read(query, actor: actor) do
      {:ok, devices} when is_list(devices) ->
        {:ok, prune_unplaced_devices(devices, connected_node_id_set)}

      {:ok, page} ->
        {:ok, prune_unplaced_devices(page_results(page), connected_node_id_set)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_unplaced_devices(_actor, _connected_node_ids), do: {:ok, []}

  defp prune_unplaced_devices(devices, connected_node_id_set)
       when is_list(devices) and is_struct(connected_node_id_set, MapSet) do
    devices
    |> Enum.reject(fn device ->
      MapSet.member?(connected_node_id_set, normalize_id(Map.get(device, :uid)))
    end)
    |> Enum.filter(&unplaced_topology_candidate?/1)
    |> Enum.uniq_by(& &1.uid)
    |> Enum.take(@unplaced_device_visible_limit)
  end

  defp prune_unplaced_devices(_devices, _connected_node_id_set), do: []

  defp fetch_camera_sources(_actor, []), do: {:ok, %{}}

  defp fetch_camera_sources(actor, device_uids) when is_list(device_uids) do
    device_uids
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.chunk_every(2_000)
    |> Enum.reduce_while({:ok, []}, fn device_uid_chunk, {:ok, acc} ->
      query =
        CameraSource
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(device_uid in ^device_uid_chunk)
        |> Ash.Query.load([:stream_profiles])

      case Ash.read(query, actor: actor) do
        {:ok, sources} when is_list(sources) ->
          {:cont, {:ok, sources ++ acc}}

        {:ok, page} ->
          {:cont, {:ok, page_results(page) ++ acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sources} ->
        grouped =
          sources
          |> Enum.map(&normalize_camera_source_for_topology/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.group_by(& &1.device_uid)

        {:ok, grouped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_ifindex?(value) when is_integer(value), do: value > 0
  defp valid_ifindex?(_value), do: false

  defp node_ids(edge_node_ids, devices) when is_list(devices) do
    edge_connected_node_ids(edge_node_ids) ++ unplaced_node_ids(edge_node_ids, devices)
  end

  defp node_ids(edge_node_ids, _devices), do: edge_connected_node_ids(edge_node_ids)

  defp unplaced_node_ids(edge_node_ids, devices) when is_list(edge_node_ids) and is_list(devices) do
    connected =
      edge_node_ids
      |> Enum.map(&normalize_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    devices
    |> Enum.map(&normalize_id(Map.get(&1, :uid)))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&MapSet.member?(connected, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unplaced_node_ids(_edge_node_ids, _devices), do: []

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

  defp build_nodes(node_ids, device_by_id, node_pps_by_id, camera_sources_by_device_uid, unplaced_node_ids) do
    total = max(length(node_ids), 1)
    unplaced_node_id_set = MapSet.new(unplaced_node_ids || [])

    node_ids
    |> Enum.with_index()
    |> Enum.map(fn {id, idx} ->
      {x, y} = layout_xy(idx, total)
      device = Map.get(device_by_id, id)
      pps = Map.get(node_pps_by_id, id, 0)
      unplaced? = MapSet.member?(unplaced_node_id_set, id)

      %{
        id: id,
        label: node_label(device, id),
        kind: node_kind(device),
        x: x,
        y: y,
        state: 3,
        pps: pps,
        oper_up: nil,
        details_json: node_details_json(device, id, Map.get(camera_sources_by_device_uid, id, []), unplaced?),
        geo_lat: node_geo_lat(device),
        geo_lon: node_geo_lon(device),
        health_signal: health_signal(device)
      }
    end)
    |> disambiguate_duplicate_node_labels()
  end

  defp disambiguate_duplicate_node_labels(nodes) when is_list(nodes) do
    duplicate_labels =
      nodes
      |> Enum.group_by(&duplicate_node_label_key/1)
      |> Enum.reduce(MapSet.new(), fn
        {label, grouped_nodes}, acc when is_binary(label) and label != "" ->
          if length(grouped_nodes) > 1, do: MapSet.put(acc, label), else: acc

        _, acc ->
          acc
      end)

    Enum.map(nodes, fn node ->
      label = duplicate_node_label_key(node)

      if is_binary(label) and MapSet.member?(duplicate_labels, label) do
        case duplicate_node_label_suffix(node) do
          suffix when is_binary(suffix) and suffix != "" ->
            %{node | label: "#{label} (#{suffix})"}

          _ ->
            node
        end
      else
        node
      end
    end)
  end

  defp disambiguate_duplicate_node_labels(nodes), do: nodes

  defp duplicate_node_label_key(%{label: label, details_json: details_json}) when is_binary(label) do
    details = decode_details_json(details_json)

    case normalize_id(Map.get(details, "cluster_kind")) do
      kind when kind in ["endpoint-summary", "endpoint-member"] -> nil
      _ -> normalize_id(label)
    end
  end

  defp duplicate_node_label_key(_node), do: nil

  defp duplicate_node_label_suffix(%{details_json: details_json, id: id, label: label}) do
    details = decode_details_json(details_json)
    ip = normalize_ipv4(Map.get(details, "ip"))
    hostname = normalize_id(Map.get(details, "hostname"))

    cond do
      is_binary(ip) and ip != "" ->
        ip

      is_binary(hostname) and hostname != "" and hostname != label ->
        hostname

      is_binary(id) and id != "" ->
        id
        |> String.replace_prefix("sr:", "")
        |> String.slice(0, 8)

      true ->
        nil
    end
  end

  defp duplicate_node_label_suffix(_node), do: nil

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

  defp layout_transport_edges(edges) when is_list(edges) do
    Enum.reject(edges, &endpoint_attachment_edge?/1)
  end

  defp causal_transport_edges(edges) when is_list(edges) do
    Enum.reject(edges, &endpoint_attachment_edge?/1)
  end

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

  defp node_label(nil, id), do: ip_like_id(id) || id

  defp node_label(device, id) do
    Map.get(device, :name) ||
      Map.get(device, :hostname) ||
      node_ip(device, id) ||
      id
  end

  defp node_kind(nil), do: "endpoint"
  defp node_kind(device), do: node_type(device) || "device"

  defp node_details_json(device, id, camera_sources, unplaced?) do
    device = device || %{}
    device_uid = normalize_id(Map.get(device, :uid)) || id
    camera_state = summarize_camera_state(camera_sources)

    details = %{
      id: id,
      device_uid: device_uid,
      name: Map.get(device, :name),
      hostname: Map.get(device, :hostname),
      ip: node_ip(device, id),
      type: node_type(device),
      type_id: Map.get(device, :type_id),
      vendor: Map.get(device, :vendor_name),
      model: Map.get(device, :model),
      last_seen: node_last_seen(device),
      asn: node_meta_value(device, ["asn", "geo_asn", "armis_asn"]),
      geo_country: node_meta_value(device, ["country", "geo_country", "geoip_country"]),
      geo_city: node_meta_value(device, ["city", "geo_city", "geoip_city"]),
      geo_lat: node_geo_lat(device),
      geo_lon: node_geo_lon(device),
      identity_source: node_meta_value(device, ["identity_source"]),
      identity_state: node_meta_value(device, ["identity_state"]),
      device_role: node_meta_value(device, ["device_role", "_device_role"]),
      topology_plane: if(unplaced?, do: "unplaced", else: "backbone"),
      topology_unplaced: unplaced?,
      topology_placement_reason:
        if(
          unplaced?,
          do: "No strong physical, logical, or hosted placement evidence in the current discovery window."
        ),
      camera_capable: camera_sources != [],
      camera_streams: camera_sources,
      camera_availability_status: camera_state.availability_status,
      camera_availability_reason: camera_state.availability_reason,
      camera_last_activity_at: camera_state.last_activity_at,
      camera_last_event_type: camera_state.last_event_type,
      camera_last_event_message: camera_state.last_event_message
    }

    case Jason.encode(details) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp normalize_camera_source_for_topology(%{} = source) do
    stream_profiles =
      source
      |> Map.get(:stream_profiles, [])
      |> Enum.filter(&(Map.get(&1, :relay_eligible, true) == true))
      |> Enum.map(fn profile ->
        %{
          stream_profile_id: Map.get(profile, :id),
          profile_name: Map.get(profile, :profile_name),
          codec_hint: Map.get(profile, :codec_hint),
          container_hint: Map.get(profile, :container_hint),
          rtsp_transport: Map.get(profile, :rtsp_transport)
        }
      end)
      |> Enum.reject(
        &(missing_topology_camera_value?(Map.get(&1, :stream_profile_id)) or
            missing_topology_camera_value?(Map.get(&1, :profile_name)))
      )

    if missing_topology_camera_value?(Map.get(source, :id)) or
         missing_topology_camera_value?(Map.get(source, :device_uid)) or
         stream_profiles == [] do
      nil
    else
      %{
        camera_source_id: Map.get(source, :id),
        device_uid: Map.get(source, :device_uid),
        display_name:
          Map.get(source, :display_name) ||
            Map.get(source, :vendor_camera_id) ||
            Map.get(source, :device_uid),
        vendor: Map.get(source, :vendor),
        vendor_camera_id: Map.get(source, :vendor_camera_id),
        assigned_agent_id: Map.get(source, :assigned_agent_id),
        assigned_gateway_id: Map.get(source, :assigned_gateway_id),
        availability_status: Map.get(source, :availability_status),
        availability_reason: Map.get(source, :availability_reason),
        last_activity_at: iso8601_value(Map.get(source, :last_activity_at)),
        last_event_at: iso8601_value(Map.get(source, :last_event_at)),
        last_event_type: Map.get(source, :last_event_type),
        last_event_message: Map.get(source, :last_event_message),
        stream_profiles: stream_profiles
      }
    end
  end

  defp normalize_camera_source_for_topology(_source), do: nil

  defp summarize_camera_state(camera_sources) when is_list(camera_sources) do
    latest_source =
      Enum.max_by(camera_sources, &camera_source_sort_key/1, fn -> nil end)

    %{
      availability_status: camera_availability_status(camera_sources),
      availability_reason: latest_source && Map.get(latest_source, :availability_reason),
      last_activity_at: latest_source && Map.get(latest_source, :last_activity_at),
      last_event_type: latest_source && Map.get(latest_source, :last_event_type),
      last_event_message: latest_source && Map.get(latest_source, :last_event_message)
    }
  end

  defp summarize_camera_state(_camera_sources) do
    %{
      availability_status: nil,
      availability_reason: nil,
      last_activity_at: nil,
      last_event_type: nil,
      last_event_message: nil
    }
  end

  defp camera_availability_status(camera_sources) do
    statuses =
      camera_sources
      |> Enum.map(&Map.get(&1, :availability_status))
      |> Enum.reject(&is_nil/1)

    cond do
      statuses == [] -> nil
      Enum.any?(statuses, &(&1 == "unavailable")) -> "unavailable"
      Enum.any?(statuses, &(&1 == "degraded")) -> "degraded"
      Enum.any?(statuses, &(&1 == "available")) -> "available"
      true -> List.first(statuses)
    end
  end

  defp camera_source_sort_key(source) when is_map(source) do
    source
    |> Map.get(:last_activity_at)
    |> case do
      %DateTime{} = dt ->
        DateTime.to_unix(dt, :microsecond)

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> DateTime.to_unix(dt, :microsecond)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp camera_source_sort_key(_source), do: 0

  defp iso8601_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp iso8601_value(value) when is_binary(value), do: value
  defp iso8601_value(_value), do: nil

  defp missing_topology_camera_value?(value) when is_binary(value), do: normalize_id(value) == nil
  defp missing_topology_camera_value?(nil), do: true
  defp missing_topology_camera_value?(_value), do: false

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

  defp normalize_ipv4(value) do
    value
    |> normalize_id()
    |> ip_like_id()
  end

  defp endpoint_cluster_edge_member_subnet(edge, anchor_id) when is_map(edge) and is_binary(anchor_id) do
    cond do
      normalize_id(Map.get(edge, :local_device_id) || Map.get(edge, :source)) == anchor_id ->
        edge
        |> Map.get(:neighbor_mgmt_addr)
        |> normalize_ipv4()
        |> ipv4_subnet_24()

      normalize_id(Map.get(edge, :neighbor_device_id) || Map.get(edge, :target)) == anchor_id ->
        edge
        |> Map.get(:local_device_ip)
        |> normalize_ipv4()
        |> ipv4_subnet_24()

      true ->
        nil
    end
  end

  defp endpoint_cluster_edge_member_subnet(_edge, _anchor_id), do: nil

  defp endpoint_cluster_edge_member_ip(edge, :target) when is_map(edge), do: Map.get(edge, :neighbor_mgmt_addr)

  defp endpoint_cluster_edge_member_ip(edge, :source) when is_map(edge), do: Map.get(edge, :local_device_ip)

  defp endpoint_cluster_edge_member_ip(_edge, _role), do: nil

  defp ipv4_subnet_24(ip) when is_binary(ip) do
    case String.split(ip, ".") do
      [a, b, c, _d] -> Enum.join([a, b, c], ".")
      _ -> nil
    end
  end

  defp ipv4_subnet_24(_ip), do: nil

  defp normalize_mac(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", ":")

    if String.match?(normalized, ~r/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/), do: normalized
  end

  defp normalize_mac(_), do: nil

  defp node_type(nil), do: nil

  defp node_type(device) do
    metadata = Map.get(device, :metadata) || %{}
    details = decode_details_json(Map.get(device, :details_json))

    Map.get(device, :type) ||
      Map.get(device, :kind) ||
      metadata_value(metadata, "type") ||
      metadata_value(metadata, "device_type") ||
      metadata_value(metadata, "category") ||
      Map.get(details, "type") ||
      type_name_from_id(Map.get(device, :type_id))
  end

  defp topology_sighting_device?(%{metadata: metadata}) when is_map(metadata) do
    normalize_id(metadata_value(metadata, "identity_source")) == "mapper_topology_sighting"
  end

  defp topology_sighting_device?(_), do: false

  defp normalized_node_type(device) do
    device
    |> node_type()
    |> normalize_id()
    |> case do
      nil -> nil
      type -> String.downcase(type)
    end
  end

  defp infrastructure_device?(device) do
    case normalized_node_type(device) do
      type
      when type in [
             "router",
             "switch",
             "hub",
             "firewall",
             "load_balancer",
             "access point",
             "ap",
             "ids",
             "ips"
           ] ->
        true

      _ ->
        false
    end
  end

  defp access_attachment_anchor?(device) do
    case normalized_node_type(device) do
      type when type in ["router", "switch", "hub", "access point", "ap"] -> true
      _ -> false
    end
  end

  defp non_router_access_attachment_anchor?(device) when is_map(device) do
    access_attachment_anchor?(device) and not router_attachment_anchor?(device)
  end

  defp non_router_access_attachment_anchor?(_device), do: false

  defp endpoint_like_device?(device) do
    topology_sighting_device?(device) or not infrastructure_device?(device)
  end

  defp anonymous_unresolved_node?(id, nil) when is_binary(id), do: String.starts_with?(id, "sr:")

  defp anonymous_unresolved_node?(id, device) when is_binary(id) and is_map(device) do
    String.starts_with?(id, "sr:") and is_nil(node_ip(device, id)) and
      blank_node_identity?(Map.get(device, :name)) and
      blank_node_identity?(Map.get(device, :hostname))
  end

  defp anonymous_unresolved_node?(_id, _device), do: false

  defp resolved_endpoint_identity?(id, device) when is_binary(id) do
    not is_nil(normalize_ipv4(node_ip(device, id))) or
      not is_nil(normalize_mac(id)) or
      not is_nil(normalize_mac(node_meta_value(device, ["mac", "mac_address", "endpoint_mac", "primary_mac"])))
  end

  defp resolved_endpoint_identity?(_id, _device), do: false

  defp blank_node_identity?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_node_identity?(nil), do: true
  defp blank_node_identity?(_value), do: false

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

  defp node_last_seen(device) when is_map(device) do
    case Map.get(device, :last_seen_time) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      %NaiveDateTime{} = ndt -> NaiveDateTime.to_iso8601(ndt)
      value when is_binary(value) -> value
      _ -> nil
    end
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

  defp health_signal(%{metadata: metadata} = device) when is_map(metadata) do
    case normalize_id(metadata_value(metadata, "identity_source")) do
      "mapper_topology_sighting" -> :unknown
      _ -> health_signal_from_availability(Map.get(device, :is_available))
    end
  end

  defp health_signal(%{is_available: value}), do: health_signal_from_availability(value)
  defp health_signal(_), do: :unknown

  defp health_signal_from_availability(true), do: :healthy
  defp health_signal_from_availability(false), do: :unhealthy
  defp health_signal_from_availability(_), do: :unknown

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
        "logical" -> "LOGICAL"
        "hosted" -> "HOSTED"
        "observed" -> "OBSERVED"
        _ -> "BACKBONE"
      end

    "#{protocol} #{class_token} #{format_rate(flow_pps || 0)} / #{format_capacity(capacity_bps || 0)}"
  end

  defp edge_topology_class(edge) do
    case evidence_class(edge) do
      "endpoint-attachment" -> "endpoints"
      "inferred" -> "inferred"
      "logical" -> "logical"
      "hosted" -> "hosted"
      "observed" -> "observed"
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
          base_reason = causal_row_value(row, :reason, "causal_reason_unavailable")
          override = Map.get(causal_overrides, idx)
          root_index = causal_row_value(row, :root_index, -1)
          parent_index = causal_row_value(row, :parent_index, -1)
          hop_distance = causal_row_value(row, :hop_distance, -1)

          {state, reason, root_index, parent_index, hop_distance} =
            normalize_causal_state(
              base_state,
              base_reason,
              override,
              root_index,
              parent_index,
              hop_distance
            )

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

          {state, reason, root_index, parent_index, hop_distance} =
            normalize_causal_state(
              state,
              "fallback_state_only_engine_result",
              override,
              -1,
              -1,
              -1
            )

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
    end
  end

  defp apply_endpoint_cluster_projection(nodes, edges, pipeline_stats, snapshot_opts)
       when is_list(nodes) and is_list(edges) and is_map(pipeline_stats) and is_map(snapshot_opts) do
    nodes_by_id = Map.new(nodes, &{&1.id, &1})
    incident_flags = endpoint_incident_flags(edges)
    expanded_clusters = Map.get(snapshot_opts, :expanded_clusters, MapSet.new())

    groups =
      edges
      |> endpoint_cluster_groups(nodes_by_id, incident_flags)
      |> Enum.sort_by(& &1.anchor_id)

    if groups == [] do
      {nodes, edges, pipeline_stats}
    else
      summarized_groups =
        Enum.filter(groups, &summarized_endpoint_cluster_group?(&1, nodes_by_id))

      summarized_groups_by_anchor = Enum.group_by(summarized_groups, & &1.anchor_id)

      expanded_groups =
        Enum.filter(summarized_groups, &MapSet.member?(expanded_clusters, &1.cluster_id))

      expanded_groups = Enum.map(expanded_groups, &limit_expanded_cluster_group(&1, nodes_by_id))
      expanded_groups_by_anchor = Enum.group_by(expanded_groups, & &1.anchor_id)

      collapsed_summarized_groups =
        Enum.reject(summarized_groups, &MapSet.member?(expanded_clusters, &1.cluster_id))

      expanded_member_ids =
        expanded_groups
        |> Enum.flat_map(&expanded_group_visible_endpoint_ids/1)
        |> MapSet.new()

      expanded_cluster_nodes =
        build_expanded_cluster_nodes(expanded_groups_by_anchor, expanded_clusters, nodes_by_id)

      expanded_cluster_nodes_by_id = Map.new(expanded_cluster_nodes, &{&1.id, &1})

      nodes =
        nodes_by_id
        |> ensure_expanded_cluster_member_nodes(expanded_groups)
        |> then(fn ensured_nodes_by_id ->
          Enum.reduce(
            expanded_groups,
            ensured_nodes_by_id,
            &layout_expanded_cluster_members(&1, &2, expanded_cluster_nodes_by_id)
          )
        end)
        |> Map.merge(expanded_cluster_nodes_by_id)
        |> merge_cluster_anchor_details(summarized_groups, expanded_clusters)

      collapsed_members =
        collapsed_summarized_groups
        |> Enum.flat_map(& &1.endpoint_ids)
        |> Enum.reject(&MapSet.member?(expanded_member_ids, &1))
        |> MapSet.new()

      expanded_attachment_edge_keys =
        expanded_groups
        |> Enum.flat_map(&Map.get(&1, :edges, []))
        |> MapSet.new(&edge_identity_key/1)

      retained_nodes =
        nodes
        |> Map.values()
        |> Enum.reject(&MapSet.member?(collapsed_members, &1.id))

      cluster_nodes =
        build_collapsed_cluster_nodes(summarized_groups_by_anchor, expanded_clusters, nodes)

      retained_edges =
        edges
        |> Enum.reject(
          &drop_cluster_projection_edge?(
            &1,
            collapsed_members,
            expanded_attachment_edge_keys,
            expanded_groups
          )
        )
        |> Enum.reject(&projected_cluster_attachment_edge?(&1, summarized_groups))

      cluster_edges =
        Enum.map(collapsed_summarized_groups, &build_endpoint_cluster_edge(&1, nodes))

      expanded_cluster_edges =
        expanded_groups
        |> Enum.map(&build_expanded_endpoint_cluster_edge(&1, nodes))
        |> Enum.reject(&is_nil/1)

      expanded_member_edges =
        Enum.flat_map(expanded_groups, &build_expanded_endpoint_member_edges(&1))

      next_pipeline_stats =
        pipeline_stats
        |> Map.put(:clustered_endpoint_summaries, length(cluster_nodes))
        |> Map.put(:expanded_endpoint_clusters, length(expanded_groups))
        |> Map.put(
          :expanded_endpoint_visible_members,
          Enum.reduce(expanded_groups, 0, &(length(expanded_group_visible_endpoint_ids(&1)) + &2))
        )
        |> Map.put(
          :expanded_endpoint_hidden_members,
          Enum.reduce(expanded_groups, 0, &(expanded_group_hidden_member_count(&1) + &2))
        )

      projected_nodes = retained_nodes ++ cluster_nodes

      {projected_nodes, retained_edges ++ cluster_edges ++ expanded_cluster_edges ++ expanded_member_edges,
       next_pipeline_stats}
    end
  end

  defp apply_endpoint_cluster_projection(nodes, edges, pipeline_stats, _snapshot_opts) do
    {nodes, edges, pipeline_stats}
  end

  defp ensure_expanded_cluster_member_nodes(nodes_by_id, expanded_groups)
       when is_map(nodes_by_id) and is_list(expanded_groups) do
    Enum.reduce(expanded_groups, nodes_by_id, &ensure_expanded_cluster_group_member_nodes(&2, &1))
  end

  defp ensure_expanded_cluster_group_member_nodes(nodes_by_id, group) when is_map(nodes_by_id) and is_map(group) do
    group
    |> expanded_group_visible_endpoint_ids()
    |> Enum.reduce(nodes_by_id, fn endpoint_id, acc ->
      cond do
        not is_binary(endpoint_id) ->
          acc

        Map.has_key?(acc, endpoint_id) ->
          acc

        true ->
          Map.put(acc, endpoint_id, build_expanded_endpoint_placeholder_node(endpoint_id, group))
      end
    end)
  end

  defp ensure_expanded_cluster_group_member_nodes(nodes_by_id, _group) when is_map(nodes_by_id), do: nodes_by_id

  defp build_expanded_endpoint_placeholder_node(endpoint_id, group) when is_binary(endpoint_id) and is_map(group) do
    supporting_edge = expanded_endpoint_member_supporting_edge(group, endpoint_id)

    ip =
      expanded_endpoint_member_identity_ip(
        endpoint_id,
        supporting_edge,
        Map.get(group, :anchor_id)
      )

    mac =
      expanded_endpoint_member_identity_mac(
        supporting_edge,
        endpoint_id,
        Map.get(group, :anchor_id)
      )

    %{
      id: endpoint_id,
      label: expanded_endpoint_placeholder_label(ip, mac),
      kind: "endpoint",
      x: 0,
      y: 0,
      state: 3,
      pps:
        case supporting_edge do
          %{} = edge -> normalize_u32(Map.get(edge, :flow_pps, 0))
          _ -> 0
        end,
      oper_up: nil,
      details_json:
        normalize_details_json(%{
          id: endpoint_id,
          ip: ip,
          mac: mac,
          type: "unknown",
          identity_source: "mapper_topology_sighting",
          cluster_placeholder: true,
          cluster_anchor_id: Map.get(group, :anchor_id)
        }),
      geo_lat: nil,
      geo_lon: nil,
      health_signal: :unknown
    }
  end

  defp build_expanded_endpoint_placeholder_node(endpoint_id, _group) when is_binary(endpoint_id) do
    ip = ip_like_id(endpoint_id)

    %{
      id: endpoint_id,
      label: expanded_endpoint_placeholder_label(ip, nil),
      kind: "endpoint",
      x: 0,
      y: 0,
      state: 3,
      pps: 0,
      oper_up: nil,
      details_json:
        normalize_details_json(%{
          id: endpoint_id,
          ip: ip,
          type: "unknown",
          identity_source: "mapper_topology_sighting",
          cluster_placeholder: true
        }),
      geo_lat: nil,
      geo_lon: nil,
      health_signal: :unknown
    }
  end

  defp build_expanded_endpoint_placeholder_node(_endpoint_id, _group), do: %{}

  defp expanded_endpoint_placeholder_label(ip, mac) do
    normalize_id(ip) || normalize_id(mac) || "Unidentified endpoint"
  end

  defp summarized_endpoint_cluster_group?(group, nodes_by_id) when is_map(group) and is_map(nodes_by_id) do
    member_count = length(Map.get(group, :endpoint_ids, []))
    anchor_node = Map.get(nodes_by_id, Map.get(group, :anchor_id))

    member_count >= @endpoint_cluster_min_members and
      endpoint_cluster_anchor_group_allowed?(anchor_node, group, nodes_by_id)
  end

  defp endpoint_cluster_anchor_group_allowed?(anchor_node, group, nodes_by_id)
       when is_map(group) and is_map(nodes_by_id) do
    if is_map(anchor_node) and router_attachment_anchor?(anchor_node) do
      endpoint_cluster_router_group_allowed?(group, nodes_by_id)
    else
      true
    end
  end

  defp endpoint_cluster_router_group_allowed?(group, _nodes_by_id) when is_map(group) do
    group
    |> Map.get(:edges, [])
    |> Enum.map(&endpoint_cluster_edge_member_subnet(&1, Map.get(group, :anchor_id)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
    |> Kernel.>=(@router_endpoint_cluster_min_distinct_subnets)
  end

  defp merge_cluster_anchor_details(nodes_by_id, groups, expanded_clusters)
       when is_map(nodes_by_id) and is_list(groups) and is_struct(expanded_clusters, MapSet) do
    Enum.reduce(groups, nodes_by_id, fn group, acc ->
      case Map.get(acc, group.anchor_id) do
        %{id: anchor_id} = anchor when is_binary(anchor_id) ->
          cluster_camera_tiles = build_cluster_camera_tiles(group, nodes_by_id)

          details_json =
            merge_cluster_membership_details(Map.get(anchor, :details_json), %{
              cluster_id: group.cluster_id,
              cluster_kind: "endpoint-anchor",
              cluster_member_count: length(group.endpoint_ids),
              cluster_expandable: true,
              cluster_expanded: MapSet.member?(expanded_clusters, group.cluster_id),
              cluster_anchor_id: group.anchor_id,
              cluster_anchor_label: Map.get(anchor, :label) || group.anchor_id,
              cluster_anchor_if_index: Map.get(group, :anchor_if_index),
              cluster_anchor_if_name: Map.get(group, :anchor_if_name),
              cluster_camera_tile_count: length(cluster_camera_tiles),
              cluster_camera_tiles: cluster_camera_tiles
            })

          Map.put(acc, anchor_id, %{anchor | details_json: details_json})

        _ ->
          acc
      end
    end)
  end

  defp merge_cluster_anchor_details(nodes_by_id, _groups, _expanded_clusters) when is_map(nodes_by_id), do: nodes_by_id

  defp endpoint_incident_flags(edges) when is_list(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      endpoint_edge? = endpoint_attachment_edge?(edge)
      Enum.reduce(edge_node_ids(edge), acc, &put_endpoint_incident_flag(&2, &1, endpoint_edge?))
    end)
  end

  defp endpoint_cluster_groups(edges, nodes_by_id, incident_flags)
       when is_list(edges) and is_map(nodes_by_id) and is_map(incident_flags) do
    cluster_membership_edges = Enum.filter(edges, &endpoint_cluster_membership_edge?/1)
    peer_counts = endpoint_attachment_peer_counts(cluster_membership_edges)
    known_infrastructure_ips = known_infrastructure_ip_set(nodes_by_id)

    anchor_direction_counts =
      endpoint_cluster_anchor_direction_counts(
        cluster_membership_edges,
        nodes_by_id,
        peer_counts,
        known_infrastructure_ips
      )

    cluster_membership_edges
    |> select_endpoint_cluster_memberships(
      nodes_by_id,
      incident_flags,
      anchor_direction_counts,
      peer_counts,
      known_infrastructure_ips
    )
    |> Enum.reduce(%{}, &accumulate_selected_endpoint_cluster_group/2)
    |> Map.values()
    |> Enum.map(fn group ->
      anchor_node = Map.get(nodes_by_id, Map.get(group, :anchor_id))

      source_endpoint_ids =
        group
        |> Map.get(:source_endpoint_ids, [])
        |> Enum.uniq()
        |> Enum.sort()

      target_endpoint_ids =
        group
        |> Map.get(:target_endpoint_ids, [])
        |> Enum.reject(&(&1 in source_endpoint_ids))
        |> Enum.uniq()
        |> Enum.sort()

      source_identity_endpoint_ids =
        group
        |> Map.get(:source_identity_endpoint_ids, [])
        |> Enum.filter(&(&1 in source_endpoint_ids))
        |> Enum.uniq()
        |> Enum.sort()

      target_identity_endpoint_ids =
        group
        |> Map.get(:target_identity_endpoint_ids, [])
        |> Enum.filter(&(&1 in target_endpoint_ids))
        |> Enum.uniq()
        |> Enum.sort()

      endpoint_ids =
        endpoint_cluster_group_endpoint_ids(
          anchor_node,
          source_endpoint_ids,
          target_endpoint_ids,
          source_identity_endpoint_ids,
          target_identity_endpoint_ids,
          peer_counts
        )

      %{
        group
        | endpoint_ids: endpoint_ids,
          source_endpoint_ids: source_endpoint_ids,
          target_endpoint_ids: target_endpoint_ids,
          source_identity_endpoint_ids: source_identity_endpoint_ids,
          target_identity_endpoint_ids: target_identity_endpoint_ids,
          edges: Enum.reverse(group.edges)
      }
    end)
  end

  defp endpoint_cluster_group_endpoint_ids(
         anchor_node,
         source_endpoint_ids,
         target_endpoint_ids,
         source_identity_endpoint_ids,
         target_identity_endpoint_ids,
         peer_counts
       )
       when is_list(source_endpoint_ids) and is_list(target_endpoint_ids) and is_list(source_identity_endpoint_ids) and
              is_list(target_identity_endpoint_ids) and is_map(peer_counts) do
    cond do
      length(source_identity_endpoint_ids) >= @endpoint_cluster_min_members ->
        source_endpoint_ids ++
          endpoint_cluster_access_target_supplement_ids(
            anchor_node,
            source_endpoint_ids,
            source_identity_endpoint_ids,
            target_identity_endpoint_ids,
            peer_counts
          )

      length(target_identity_endpoint_ids) >= @endpoint_cluster_min_members ->
        target_endpoint_ids

      Enum.empty?(source_endpoint_ids) ->
        target_endpoint_ids

      true ->
        supplement_count =
          max(@endpoint_cluster_min_members, length(source_endpoint_ids) * 2) -
            length(source_endpoint_ids)

        source_endpoint_ids ++ Enum.take(target_endpoint_ids, supplement_count)
    end
  end

  defp endpoint_cluster_access_target_supplement_ids(
         anchor_node,
         source_endpoint_ids,
         source_identity_endpoint_ids,
         target_identity_endpoint_ids,
         peer_counts
       )
       when is_list(source_endpoint_ids) and is_list(source_identity_endpoint_ids) and
              is_list(target_identity_endpoint_ids) and is_map(peer_counts) do
    source_identity_count = length(source_identity_endpoint_ids)
    target_identity_count = length(target_identity_endpoint_ids)

    supplement_limit =
      endpoint_cluster_access_target_supplement_limit(
        anchor_node,
        source_identity_count,
        target_identity_count
      )

    if supplement_limit > 0 do
      target_identity_endpoint_ids
      |> Enum.reject(&(&1 in source_endpoint_ids))
      |> Enum.filter(&endpoint_cluster_access_target_supplement_candidate?(&1, peer_counts))
      |> Enum.take(supplement_limit)
    else
      []
    end
  end

  defp endpoint_cluster_access_target_supplement_ids(
         _anchor_node,
         _source_endpoint_ids,
         _source_identity_endpoint_ids,
         _target_identity_endpoint_ids,
         _peer_counts
       ), do: []

  defp endpoint_cluster_access_target_supplement_candidate?(endpoint_id, peer_counts)
       when is_binary(endpoint_id) and is_map(peer_counts) do
    peer_counts
    |> Map.get(endpoint_id, MapSet.new())
    |> MapSet.size()
    |> Kernel.<=(@endpoint_cluster_access_target_supplement_max_peer_count)
  end

  defp endpoint_cluster_access_target_supplement_candidate?(_endpoint_id, _peer_counts), do: false

  defp endpoint_cluster_access_target_supplement_limit(anchor_node, source_identity_count, target_identity_count)
       when is_integer(source_identity_count) and is_integer(target_identity_count) do
    cond do
      not non_router_access_attachment_anchor?(anchor_node) ->
        0

      target_identity_count <
          source_identity_count + @endpoint_cluster_access_target_gap_threshold ->
        0

      source_identity_count >= 9 ->
        3

      source_identity_count >= 5 ->
        1

      true ->
        0
    end
  end

  defp endpoint_cluster_access_target_supplement_limit(_anchor_node, _source_identity_count, _target_identity_count),
    do: 0

  defp select_endpoint_cluster_memberships(
         edges,
         nodes_by_id,
         incident_flags,
         anchor_direction_counts,
         peer_counts,
         known_infrastructure_ips
       )
       when is_list(edges) and is_map(nodes_by_id) and is_map(incident_flags) and is_map(anchor_direction_counts) and
              is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    candidate_groups =
      Enum.reduce(edges, %{}, fn edge, acc ->
        select_endpoint_cluster_membership_candidate(
          edge,
          acc,
          nodes_by_id,
          incident_flags,
          anchor_direction_counts,
          peer_counts,
          known_infrastructure_ips
        )
      end)

    port_candidate_counts = endpoint_cluster_candidate_port_counts(candidate_groups)

    Enum.flat_map(candidate_groups, fn {endpoint_id, candidates} ->
      resolve_endpoint_cluster_membership_candidates(
        endpoint_id,
        candidates,
        nodes_by_id,
        port_candidate_counts
      )
    end)
  end

  defp select_endpoint_cluster_memberships(
         _edges,
         _nodes_by_id,
         _incident_flags,
         _anchor_direction_counts,
         _peer_counts,
         _known_infrastructure_ips
       ), do: []

  defp endpoint_cluster_candidate_port_counts(candidate_groups) when is_map(candidate_groups) do
    Enum.reduce(candidate_groups, %{}, fn {_membership_key, candidates}, acc ->
      port_keys =
        candidates
        |> Enum.filter(&is_map/1)
        |> Enum.map(&endpoint_cluster_candidate_port_key/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      Enum.reduce(port_keys, acc, fn port_key, inner ->
        Map.update(inner, port_key, 1, &(&1 + 1))
      end)
    end)
  end

  defp endpoint_cluster_candidate_port_counts(_candidate_groups), do: %{}

  defp select_endpoint_cluster_membership_candidate(
         edge,
         acc,
         nodes_by_id,
         incident_flags,
         anchor_direction_counts,
         peer_counts,
         known_infrastructure_ips
       )
       when is_map(acc) and is_map(nodes_by_id) and is_map(incident_flags) and is_map(anchor_direction_counts) and
              is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    edge
    |> endpoint_cluster_member_anchor_pair(
      nodes_by_id,
      incident_flags,
      anchor_direction_counts,
      peer_counts,
      known_infrastructure_ips
    )
    |> update_endpoint_cluster_membership_candidate(edge, acc)
  end

  defp select_endpoint_cluster_membership_candidate(
         _edge,
         acc,
         _nodes_by_id,
         _incident_flags,
         _anchor_direction_counts,
         _peer_counts,
         _known_infrastructure_ips
       )
       when is_map(acc), do: acc

  defp update_endpoint_cluster_membership_candidate({endpoint_id, anchor_id, direction}, edge, acc)
       when is_binary(endpoint_id) and is_binary(anchor_id) and direction in [:source, :target] and is_map(edge) and
              is_map(acc) do
    candidate = %{
      endpoint_id: endpoint_id,
      anchor_id: anchor_id,
      anchor_if_index: endpoint_cluster_anchor_if_index(direction, edge),
      anchor_if_name: endpoint_cluster_anchor_if_name(direction, edge),
      direction: direction,
      edge: edge
    }

    membership_key = endpoint_cluster_membership_key(endpoint_id, direction, edge)
    Map.update(acc, membership_key, [candidate], &[candidate | &1])
  end

  defp update_endpoint_cluster_membership_candidate(_pair, _edge, acc) when is_map(acc), do: acc

  defp resolve_endpoint_cluster_membership_candidates(membership_key, candidates, nodes_by_id, port_candidate_counts)
       when is_binary(membership_key) and is_list(candidates) and is_map(nodes_by_id) and is_map(port_candidate_counts) do
    ranked_candidates =
      candidates
      |> Enum.filter(&is_map/1)
      |> Enum.group_by(&endpoint_cluster_candidate_group_key/1)
      |> Enum.map(fn {_group_key, grouped_candidates} ->
        Enum.reduce(grouped_candidates, nil, fn candidate, best ->
          choose_endpoint_cluster_membership_candidate(candidate, best, port_candidate_counts)
        end)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(
        &endpoint_cluster_membership_candidate_rank(&1, port_candidate_counts),
        :desc
      )

    cond do
      ranked_candidates == [] ->
        []

      ambiguous_endpoint_cluster_membership?(
        membership_key,
        ranked_candidates,
        nodes_by_id,
        port_candidate_counts
      ) ->
        []

      true ->
        [hd(ranked_candidates)]
    end
  end

  defp resolve_endpoint_cluster_membership_candidates(_membership_key, _candidates, _nodes_by_id, _port_candidate_counts),
    do: []

  defp endpoint_cluster_membership_key(endpoint_id, direction, edge)
       when is_binary(endpoint_id) and direction in [:source, :target] and is_map(edge) do
    role = endpoint_cluster_member_role(direction)
    member_ip = edge |> endpoint_cluster_edge_member_ip(role) |> normalize_ipv4()
    member_mac = endpoint_cluster_edge_member_mac(edge, role)

    cond do
      is_binary(member_mac) -> "mac:" <> member_mac
      is_binary(member_ip) -> "ip:" <> member_ip
      true -> endpoint_id
    end
  end

  defp endpoint_cluster_membership_key(endpoint_id, _direction, _edge) when is_binary(endpoint_id), do: endpoint_id

  defp endpoint_cluster_member_role(:source), do: :target
  defp endpoint_cluster_member_role(:target), do: :source

  defp endpoint_cluster_anchor_if_index(:source, edge) when is_map(edge) do
    if_index = Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index)
    if valid_ifindex?(if_index), do: if_index
  end

  defp endpoint_cluster_anchor_if_index(:target, edge) when is_map(edge) do
    if_index = Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index)
    if valid_ifindex?(if_index), do: if_index
  end

  defp endpoint_cluster_anchor_if_index(_direction, _edge), do: nil

  defp endpoint_cluster_anchor_if_name(:source, edge) when is_map(edge) do
    if_name = Map.get(edge, :local_if_name_ab) || Map.get(edge, :local_if_name)
    sanitize_endpoint_cluster_anchor_if_name(if_name)
  end

  defp endpoint_cluster_anchor_if_name(:target, edge) when is_map(edge) do
    if_name = Map.get(edge, :local_if_name_ba) || Map.get(edge, :neighbor_if_name)
    sanitize_endpoint_cluster_anchor_if_name(if_name)
  end

  defp endpoint_cluster_anchor_if_name(_direction, _edge), do: nil

  defp sanitize_endpoint_cluster_anchor_if_name(value) when is_binary(value) do
    trimmed = String.trim(value)
    normalized = String.downcase(trimmed)

    cond do
      not valid_if_name?(trimmed) -> nil
      not is_nil(normalize_mac(trimmed)) -> nil
      String.match?(normalized, ~r/^[0-9a-f]{12}$/) -> nil
      true -> trimmed
    end
  end

  defp sanitize_endpoint_cluster_anchor_if_name(_value), do: nil

  defp endpoint_cluster_candidate_port_key(%{anchor_id: anchor_id, anchor_if_index: anchor_if_index})
       when is_binary(anchor_id) and is_integer(anchor_if_index) and anchor_if_index > 0 do
    anchor_id <> "#if:" <> Integer.to_string(anchor_if_index)
  end

  defp endpoint_cluster_candidate_port_key(%{anchor_id: anchor_id}) when is_binary(anchor_id), do: anchor_id

  defp endpoint_cluster_candidate_port_key(_candidate), do: nil

  defp endpoint_cluster_candidate_group_key(candidate) when is_map(candidate) do
    endpoint_cluster_candidate_port_key(candidate) || Map.get(candidate, :anchor_id)
  end

  defp endpoint_cluster_candidate_group_key(_candidate), do: nil

  defp choose_endpoint_cluster_membership_candidate(candidate, nil, _port_candidate_counts), do: candidate

  defp choose_endpoint_cluster_membership_candidate(candidate, existing, port_candidate_counts) do
    if endpoint_cluster_membership_candidate_better?(candidate, existing, port_candidate_counts) do
      candidate
    else
      existing
    end
  end

  defp endpoint_cluster_membership_candidate_better?(candidate, existing, port_candidate_counts)
       when is_map(candidate) and is_map(existing) and is_map(port_candidate_counts) do
    candidate_rank = endpoint_cluster_membership_candidate_rank(candidate, port_candidate_counts)
    existing_rank = endpoint_cluster_membership_candidate_rank(existing, port_candidate_counts)

    candidate_rank > existing_rank or
      (candidate_rank == existing_rank and
         {Map.get(candidate, :anchor_id, ""), Map.get(candidate, :endpoint_id, "")} <=
           {Map.get(existing, :anchor_id, ""), Map.get(existing, :endpoint_id, "")})
  end

  defp endpoint_cluster_membership_candidate_better?(_candidate, _existing, _port_candidate_counts), do: true

  defp endpoint_cluster_membership_candidate_rank(%{edge: edge} = candidate, port_candidate_counts)
       when is_map(edge) and is_map(port_candidate_counts) do
    {
      -endpoint_cluster_candidate_port_fanout(candidate, port_candidate_counts),
      attachment_observation_count(edge),
      if(Map.get(edge, :telemetry_eligible, false), do: 1, else: 0),
      endpoint_cluster_confidence_rank(Map.get(edge, :confidence_tier)),
      normalize_u64(Map.get(edge, :flow_bps, 0)),
      normalize_u32(Map.get(edge, :flow_pps, 0)),
      normalize_u64(Map.get(edge, :capacity_bps, 0))
    }
  end

  defp endpoint_cluster_membership_candidate_rank(_candidate, _port_candidate_counts), do: {0, 0, 0, 0, 0, 0, 0}

  defp endpoint_cluster_candidate_port_fanout(candidate, port_candidate_counts)
       when is_map(candidate) and is_map(port_candidate_counts) do
    candidate
    |> endpoint_cluster_candidate_port_key()
    |> then(&Map.get(port_candidate_counts, &1, 1_000_000))
  end

  defp endpoint_cluster_candidate_port_fanout(_candidate, _port_candidate_counts), do: 1_000_000

  defp ambiguous_endpoint_cluster_membership?(membership_key, [best, second | _rest], nodes_by_id, port_candidate_counts)
       when is_binary(membership_key) and is_map(best) and is_map(second) and is_map(nodes_by_id) and
              is_map(port_candidate_counts) do
    endpoint_id = Map.get(best, :endpoint_id)
    node = Map.get(nodes_by_id, endpoint_id)

    same_port_fanout =
      endpoint_cluster_candidate_port_fanout(best, port_candidate_counts) ==
        endpoint_cluster_candidate_port_fanout(second, port_candidate_counts)

    same_port_fanout and
      (provisional_topology_sighting_membership?(endpoint_id, node) or
         synthesized_endpoint_cluster_membership_key?(membership_key)) and
      near_tied_endpoint_cluster_membership_candidates?(best, second)
  end

  defp ambiguous_endpoint_cluster_membership?(_membership_key, _candidates, _nodes_by_id, _port_candidate_counts),
    do: false

  defp synthesized_endpoint_cluster_membership_key?(membership_key) when is_binary(membership_key) do
    String.starts_with?(membership_key, "ip:") or String.starts_with?(membership_key, "mac:")
  end

  defp synthesized_endpoint_cluster_membership_key?(_membership_key), do: false

  defp provisional_topology_sighting_membership?(endpoint_id, node) when is_binary(endpoint_id) and is_map(node) do
    topology_sighting_device?(node) and provisional_identity_state?(node) and
      not is_nil(normalize_ipv4(node_ip(node, endpoint_id))) and not infrastructure_device?(node)
  end

  defp provisional_topology_sighting_membership?(_endpoint_id, _node), do: false

  defp near_tied_endpoint_cluster_membership_candidates?(best, second) when is_map(best) and is_map(second) do
    best_observations = endpoint_cluster_candidate_observation_count(best)
    second_observations = endpoint_cluster_candidate_observation_count(second)

    best_observations > 0 and second_observations > 0 and
      best_observations - second_observations <= @endpoint_cluster_ambiguous_observation_gap and
      second_observations / best_observations >= @endpoint_cluster_ambiguous_relative_ratio
  end

  defp near_tied_endpoint_cluster_membership_candidates?(_best, _second), do: false

  defp endpoint_cluster_candidate_observation_count(%{edge: edge}) when is_map(edge),
    do: attachment_observation_count(edge)

  defp endpoint_cluster_candidate_observation_count(_candidate), do: 0

  defp attachment_observation_count(edge) when is_map(edge) do
    metadata = Map.get(edge, :metadata, %{})

    value =
      Map.get(edge, :attachment_observation_count) ||
        Map.get(metadata, "attachment_observation_count")

    case value do
      count when is_integer(count) and count > 0 ->
        count

      count when is_binary(count) ->
        case Integer.parse(count) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp attachment_observation_count(_edge), do: 0

  defp endpoint_cluster_confidence_rank(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "high" -> 3
      "medium" -> 2
      "low" -> 1
      _ -> 0
    end
  end

  defp endpoint_cluster_confidence_rank(_value), do: 0

  defp accumulate_selected_endpoint_cluster_group(
         %{endpoint_id: endpoint_id, anchor_id: anchor_id, direction: direction, edge: edge} = candidate,
         acc
       )
       when is_binary(endpoint_id) and is_binary(anchor_id) and direction in [:source, :target] and is_map(edge) and
              is_map(acc) do
    anchor_if_index =
      Map.get(candidate, :anchor_if_index) || endpoint_cluster_anchor_if_index(direction, edge)

    anchor_if_name =
      Map.get(candidate, :anchor_if_name) || endpoint_cluster_anchor_if_name(direction, edge)

    cluster_id = endpoint_cluster_id(anchor_id, anchor_if_index)

    group =
      endpoint_cluster_group_seed(
        cluster_id,
        anchor_id,
        anchor_if_index,
        anchor_if_name,
        endpoint_id,
        direction,
        edge
      )

    Map.update(
      acc,
      cluster_id,
      group,
      &append_endpoint_cluster_group(&1, endpoint_id, direction, edge)
    )
  end

  defp accumulate_selected_endpoint_cluster_group(_candidate, acc) when is_map(acc), do: acc

  defp endpoint_cluster_group_seed(cluster_id, anchor_id, anchor_if_index, anchor_if_name, endpoint_id, direction, edge)
       when is_binary(cluster_id) and is_binary(anchor_id) and is_binary(endpoint_id) and is_map(edge) do
    %{
      cluster_id: cluster_id,
      anchor_id: anchor_id,
      anchor_if_index: anchor_if_index,
      anchor_if_name: anchor_if_name,
      endpoint_ids: [endpoint_id],
      source_endpoint_ids: maybe_prepend_endpoint_id([], endpoint_id, direction == :source),
      target_endpoint_ids: maybe_prepend_endpoint_id([], endpoint_id, direction == :target),
      source_identity_endpoint_ids:
        maybe_prepend_endpoint_id(
          [],
          endpoint_id,
          source_identity_endpoint_edge?(direction, edge)
        ),
      target_identity_endpoint_ids:
        maybe_prepend_endpoint_id(
          [],
          endpoint_id,
          target_identity_endpoint_edge?(direction, edge)
        ),
      edges: [edge]
    }
  end

  defp endpoint_cluster_group_seed(
         _cluster_id,
         _anchor_id,
         _anchor_if_index,
         _anchor_if_name,
         _endpoint_id,
         _direction,
         _edge
       ), do: %{}

  defp append_endpoint_cluster_group(existing, endpoint_id, direction, edge)
       when is_map(existing) and is_binary(endpoint_id) and direction in [:source, :target] and is_map(edge) do
    %{
      existing
      | endpoint_ids: [endpoint_id | existing.endpoint_ids],
        source_endpoint_ids:
          maybe_prepend_endpoint_id(
            Map.get(existing, :source_endpoint_ids, []),
            endpoint_id,
            direction == :source
          ),
        target_endpoint_ids:
          maybe_prepend_endpoint_id(
            Map.get(existing, :target_endpoint_ids, []),
            endpoint_id,
            direction == :target
          ),
        source_identity_endpoint_ids:
          maybe_prepend_endpoint_id(
            Map.get(existing, :source_identity_endpoint_ids, []),
            endpoint_id,
            source_identity_endpoint_edge?(direction, edge)
          ),
        target_identity_endpoint_ids:
          maybe_prepend_endpoint_id(
            Map.get(existing, :target_identity_endpoint_ids, []),
            endpoint_id,
            target_identity_endpoint_edge?(direction, edge)
          ),
        edges: [edge | existing.edges]
    }
  end

  defp append_endpoint_cluster_group(existing, _endpoint_id, _direction, _edge) when is_map(existing), do: existing

  defp maybe_prepend_endpoint_id(ids, endpoint_id, true) when is_list(ids) and is_binary(endpoint_id),
    do: [endpoint_id | ids]

  defp maybe_prepend_endpoint_id(ids, _endpoint_id, _include?) when is_list(ids), do: ids

  defp source_identity_endpoint_edge?(:source, edge) when is_map(edge),
    do: endpoint_cluster_member_edge_has_identity?(edge, :target)

  defp source_identity_endpoint_edge?(_direction, _edge), do: false

  defp target_identity_endpoint_edge?(:target, edge) when is_map(edge),
    do: endpoint_cluster_member_edge_has_identity?(edge, :source)

  defp target_identity_endpoint_edge?(_direction, _edge), do: false

  defp endpoint_cluster_member_edge_has_identity?(edge, role) when is_map(edge) and role in [:source, :target] do
    edge
    |> endpoint_cluster_edge_member_ip(role)
    |> normalize_ipv4()
    |> is_binary()
  end

  defp endpoint_cluster_member_edge_has_identity?(_edge, _role), do: false

  defp edge_node_ids(edge) when is_map(edge) do
    [normalize_id(Map.get(edge, :source)), normalize_id(Map.get(edge, :target))]
  end

  defp edge_node_ids(_edge), do: []

  defp put_endpoint_incident_flag(acc, node_id, endpoint_edge?)
       when is_map(acc) and is_binary(node_id) and is_boolean(endpoint_edge?) do
    Map.update(
      acc,
      node_id,
      %{endpoint: endpoint_edge?, non_endpoint: not endpoint_edge?},
      fn flags ->
        %{
          endpoint: flags.endpoint or endpoint_edge?,
          non_endpoint: flags.non_endpoint or not endpoint_edge?
        }
      end
    )
  end

  defp put_endpoint_incident_flag(acc, _node_id, _endpoint_edge?) when is_map(acc), do: acc

  defp layout_expanded_cluster_members(group, acc, expanded_cluster_nodes_by_id)
       when is_map(acc) and is_map(expanded_cluster_nodes_by_id) do
    case expanded_cluster_layout_context(group, acc, expanded_cluster_nodes_by_id) do
      {:ok, context} ->
        apply_expanded_cluster_member_layout(acc, group, context)

      :error ->
        acc
    end
  end

  defp layout_expanded_cluster_members(_group, acc, _expanded_cluster_nodes_by_id) when is_map(acc), do: acc

  defp expanded_cluster_layout_context(group, acc, expanded_cluster_nodes_by_id)
       when is_map(group) and is_map(acc) and is_map(expanded_cluster_nodes_by_id) do
    case {Map.get(acc, group.anchor_id), Map.get(expanded_cluster_nodes_by_id, group.cluster_id)} do
      {%{} = anchor, %{x: hub_x, y: hub_y}} ->
        {:ok,
         %{
           anchor: anchor,
           anchor_label: Map.get(anchor, :label) || group.anchor_id,
           hub_x: hub_x,
           hub_y: hub_y,
           member_count: length(group.endpoint_ids)
         }}

      _ ->
        :error
    end
  end

  defp expanded_cluster_layout_context(_group, _acc, _expanded_cluster_nodes_by_id), do: :error

  defp apply_expanded_cluster_member_layout(acc, group, context) when is_map(acc) and is_map(group) and is_map(context) do
    group
    |> expanded_group_visible_endpoint_ids()
    |> Enum.sort()
    |> Enum.reduce(acc, fn endpoint_id, inner ->
      annotate_cluster_member(
        inner,
        endpoint_id,
        group,
        context.member_count,
        context.anchor_label
      )
    end)
  end

  defp annotate_cluster_member(acc, endpoint_id, group, member_count, anchor_label)
       when is_map(acc) and is_binary(endpoint_id) and is_map(group) and is_binary(anchor_label) do
    case Map.get(acc, endpoint_id) do
      %{id: ^endpoint_id} = node ->
        details_json =
          merge_cluster_membership_details(Map.get(node, :details_json), %{
            cluster_id: group.cluster_id,
            cluster_kind: "endpoint-member",
            cluster_member_count: member_count,
            cluster_expandable: true,
            cluster_expanded: true,
            cluster_anchor_id: group.anchor_id,
            cluster_anchor_label: anchor_label,
            cluster_anchor_if_index: Map.get(group, :anchor_if_index),
            cluster_anchor_if_name: Map.get(group, :anchor_if_name)
          })

        Map.put(acc, endpoint_id, %{node | details_json: details_json})

      _ ->
        acc
    end
  end

  defp annotate_cluster_member(acc, _endpoint_id, _group, _member_count, _anchor_label) when is_map(acc), do: acc

  defp drop_cluster_projection_edge?(edge, collapsed_members, expanded_attachment_edge_keys, expanded_groups)
       when is_map(edge) do
    valid_cluster_projection_edge_args?(
      collapsed_members,
      expanded_attachment_edge_keys,
      expanded_groups
    ) and
      endpoint_attachment_edge?(edge) and
      (not MapSet.member?(expanded_attachment_edge_keys, edge_identity_key(edge)) or
         collapsed_endpoint_member_edge?(edge, collapsed_members) or
         expanded_group_attachment_edge?(edge, expanded_groups))
  end

  defp drop_cluster_projection_edge?(_edge, _collapsed_members, _expanded_attachment_edge_keys, _expanded_groups),
    do: false

  defp valid_cluster_projection_edge_args?(collapsed_members, expanded_attachment_edge_keys, expanded_groups)
       when is_struct(collapsed_members, MapSet) and is_struct(expanded_attachment_edge_keys, MapSet) and
              is_list(expanded_groups), do: true

  defp valid_cluster_projection_edge_args?(_collapsed_members, _expanded_attachment_edge_keys, _expanded_groups),
    do: false

  defp expanded_group_attachment_edge?(edge, expanded_groups) when is_map(edge) and is_list(expanded_groups) do
    Enum.any?(expanded_groups, fn group ->
      edge_endpoint_member?(edge, group.endpoint_ids) and
        attachment_anchor_match?(edge, group.anchor_id)
    end)
  end

  defp expanded_group_attachment_edge?(_edge, _expanded_groups), do: false

  defp raw_endpoint_attachment_edge?(edge) when is_map(edge) do
    endpoint_attachment_edge?(edge) and normalize_id(Map.get(edge, :protocol)) != "cluster"
  end

  defp raw_endpoint_attachment_edge?(_edge), do: false

  defp projected_cluster_attachment_edge?(edge, summarized_groups) when is_map(edge) and is_list(summarized_groups) do
    raw_endpoint_attachment_edge?(edge) and
      Enum.any?(summarized_groups, fn group ->
        edge_endpoint_member?(edge, group.endpoint_ids) and
          attachment_anchor_match?(edge, group.anchor_id)
      end)
  end

  defp projected_cluster_attachment_edge?(_edge, _summarized_groups), do: false

  defp build_collapsed_cluster_nodes(summarized_groups_by_anchor, expanded_clusters, nodes)
       when is_map(summarized_groups_by_anchor) and is_struct(expanded_clusters, MapSet) and is_map(nodes) do
    Enum.flat_map(summarized_groups_by_anchor, fn {anchor_id, anchor_groups} ->
      anchor = Map.get(nodes, anchor_id)

      visible_groups =
        Enum.reject(anchor_groups, &MapSet.member?(expanded_clusters, &1.cluster_id))

      group_count = length(anchor_groups)

      visible_groups
      |> Enum.sort_by(& &1.cluster_id)
      |> Enum.with_index()
      |> Enum.map(fn {group, idx} ->
        build_endpoint_cluster_node(group, anchor, idx, group_count, nodes)
      end)
    end)
  end

  defp build_collapsed_cluster_nodes(_summarized_groups_by_anchor, _expanded_clusters, _nodes), do: []

  defp build_expanded_cluster_nodes(groups_by_anchor, expanded_clusters, nodes_by_id)
       when is_map(groups_by_anchor) and is_struct(expanded_clusters, MapSet) and is_map(nodes_by_id) do
    Enum.flat_map(groups_by_anchor, fn {anchor_id, anchor_groups} ->
      anchor = Map.get(nodes_by_id, anchor_id)
      member_count = length(anchor_groups)

      anchor_groups
      |> Enum.sort_by(& &1.cluster_id)
      |> Enum.with_index()
      |> Enum.filter(fn {group, _idx} -> MapSet.member?(expanded_clusters, group.cluster_id) end)
      |> Enum.map(fn {group, idx} ->
        build_expanded_endpoint_cluster_node(group, anchor, idx, member_count, nodes_by_id)
      end)
    end)
  end

  defp build_expanded_cluster_nodes(_groups_by_anchor, _expanded_clusters, _nodes_by_id), do: []

  defp endpoint_cluster_member_anchor_pair(
         edge,
         nodes_by_id,
         incident_flags,
         anchor_direction_counts,
         peer_counts,
         known_infrastructure_ips
       )
       when is_map(edge) and is_map(nodes_by_id) and is_map(incident_flags) and is_map(anchor_direction_counts) and
              is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    source_node = Map.get(nodes_by_id, source)
    target_node = Map.get(nodes_by_id, target)

    source_anchor? = endpoint_cluster_anchor_node?(source, source_node)

    target_leaf? =
      endpoint_cluster_leaf_for_edge?(
        target,
        target_node,
        incident_flags,
        edge,
        :target,
        peer_counts,
        known_infrastructure_ips
      )

    target_anchor? = endpoint_cluster_anchor_node?(target, target_node)

    source_leaf? =
      endpoint_cluster_leaf_for_edge?(
        source,
        source_node,
        incident_flags,
        edge,
        :source,
        peer_counts,
        known_infrastructure_ips
      )

    cond do
      source_anchor? and target_leaf? and is_binary(source) ->
        {target, source, :source}

      target_anchor? and
        source_leaf? and
        is_binary(target) and
          target_side_cluster_fallback_allowed?(target, target_node, anchor_direction_counts) ->
        {source, target, :target}

      true ->
        nil
    end
  end

  defp endpoint_cluster_member_anchor_pair(
         _edge,
         _nodes_by_id,
         _incident_flags,
         _anchor_direction_counts,
         _peer_counts,
         _known_infrastructure_ips
       ), do: nil

  defp endpoint_cluster_leaf_for_edge?(node_id, node, incident_flags, edge, role, peer_counts, known_infrastructure_ips)
       when is_binary(node_id) and is_map(incident_flags) and is_map(edge) and role in [:source, :target] and
              is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    endpoint_cluster_member_node?(
      node_id,
      node,
      Map.get(incident_flags, node_id, %{}),
      peer_counts,
      known_infrastructure_ips
    ) or
      endpoint_cluster_edge_member_with_ip?(
        node_id,
        node,
        edge,
        role,
        peer_counts,
        known_infrastructure_ips
      )
  end

  defp endpoint_cluster_leaf_for_edge?(
         _node_id,
         _node,
         _incident_flags,
         _edge,
         _role,
         _peer_counts,
         _known_infrastructure_ips
       ), do: false

  defp endpoint_cluster_anchor_direction_counts(edges, nodes_by_id, peer_counts, known_infrastructure_ips)
       when is_list(edges) and is_map(nodes_by_id) and is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      source = normalize_id(Map.get(edge, :source))
      target = normalize_id(Map.get(edge, :target))
      source_node = Map.get(nodes_by_id, source)
      target_node = Map.get(nodes_by_id, target)
      source_anchor? = endpoint_cluster_anchor_node?(source, source_node)
      target_anchor? = endpoint_cluster_anchor_node?(target, target_node)

      source_endpoint? =
        endpoint_cluster_endpoint_candidate?(
          source,
          source_node,
          peer_counts,
          known_infrastructure_ips
        )

      target_endpoint? =
        endpoint_cluster_endpoint_candidate?(
          target,
          target_node,
          peer_counts,
          known_infrastructure_ips
        )

      cond do
        source_anchor? and target_endpoint? and is_binary(source) ->
          increment_endpoint_cluster_anchor_direction(acc, source, :source)

        target_anchor? and source_endpoint? and is_binary(target) ->
          increment_endpoint_cluster_anchor_direction(acc, target, :target)

        true ->
          acc
      end
    end)
  end

  defp endpoint_cluster_anchor_direction_counts(_edges, _nodes_by_id, _peer_counts, _known_infrastructure_ips), do: %{}

  defp increment_endpoint_cluster_anchor_direction(acc, anchor_id, direction)
       when is_map(acc) and is_binary(anchor_id) and direction in [:source, :target] do
    Map.update(acc, anchor_id, %{source: 0, target: 0}, fn counts ->
      Map.update!(counts, direction, &(&1 + 1))
    end)
  end

  defp target_side_cluster_fallback_allowed?(anchor_id, anchor_node, anchor_direction_counts)
       when is_binary(anchor_id) and is_map(anchor_direction_counts) do
    case Map.get(anchor_direction_counts, anchor_id, %{source: 0, target: 0}) do
      %{source: source_count} when is_integer(source_count) ->
        not router_attachment_anchor?(anchor_node) and
          source_count <= @endpoint_cluster_min_members

      _ ->
        not router_attachment_anchor?(anchor_node)
    end
  end

  defp target_side_cluster_fallback_allowed?(_anchor_id, _anchor_node, _anchor_direction_counts), do: false

  defp endpoint_cluster_anchor_node?(node_id, node) when is_binary(node_id) and is_map(node) do
    access_attachment_anchor?(node) and not cluster_summary_node?(node)
  end

  defp endpoint_cluster_anchor_node?(_node_id, _node), do: false

  defp endpoint_cluster_member_node?(
         node_id,
         node,
         %{endpoint: true, non_endpoint: false},
         peer_counts,
         known_infrastructure_ips
       )
       when is_binary(node_id) and is_map(node) and is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    endpoint_cluster_leaf_candidate?(node_id, node, peer_counts, known_infrastructure_ips) and
      not cluster_summary_node?(node)
  end

  defp endpoint_cluster_member_node?(
         node_id,
         nil,
         %{endpoint: true, non_endpoint: false},
         peer_counts,
         known_infrastructure_ips
       )
       when is_binary(node_id) and is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    endpoint_cluster_leaf_candidate?(node_id, nil, peer_counts, known_infrastructure_ips)
  end

  defp endpoint_cluster_member_node?(_node_id, _node, _flags, _peer_counts, _known_infrastructure_ips), do: false

  defp endpoint_cluster_endpoint_candidate?(node_id, node, peer_counts, known_infrastructure_ips)
       when is_binary(node_id) and is_map(node) and is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    endpoint_cluster_leaf_candidate?(node_id, node, peer_counts, known_infrastructure_ips)
  end

  defp endpoint_cluster_endpoint_candidate?(node_id, nil, peer_counts, known_infrastructure_ips)
       when is_binary(node_id) and is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    endpoint_cluster_leaf_candidate?(node_id, nil, peer_counts, known_infrastructure_ips)
  end

  defp endpoint_cluster_endpoint_candidate?(_node_id, _node, _peer_counts, _known_infrastructure_ips), do: false

  defp endpoint_cluster_leaf_candidate?(node_id, node, peer_counts, known_infrastructure_ips)
       when is_binary(node_id) and is_map(peer_counts) and is_struct(known_infrastructure_ips, MapSet) do
    cond do
      high_ambiguity_endpoint_attachment_identity?(node_id, node, peer_counts) ->
        false

      weak_provisional_topology_sighting_identity?(node_id, node) ->
        false

      is_map(node) and infrastructure_device?(node) ->
        false

      known_infrastructure_identity?(node_id, node, known_infrastructure_ips) ->
        false

      anonymous_unresolved_node?(node_id, node) ->
        true

      is_map(node) ->
        endpoint_like_node?(node)

      true ->
        false
    end
  end

  defp endpoint_cluster_leaf_candidate?(_node_id, _node, _peer_counts, _known_infrastructure_ips), do: false

  defp endpoint_cluster_edge_member_with_ip?(node_id, node, edge, role, peer_counts, known_infrastructure_ips)
       when is_binary(node_id) and is_map(edge) and role in [:source, :target] and is_map(peer_counts) and
              is_struct(known_infrastructure_ips, MapSet) do
    edge_member_ip =
      edge
      |> endpoint_cluster_edge_member_ip(role)
      |> normalize_ipv4()

    is_nil(node) and endpoint_cluster_unresolved_edge_member_identity?(edge, role) and
      not high_ambiguity_endpoint_attachment_identity?(node_id, node, peer_counts) and
      not weak_edge_only_endpoint_identity?(edge, role) and is_binary(edge_member_ip) and
      not known_infrastructure_ip?(edge_member_ip, known_infrastructure_ips)
  end

  defp endpoint_cluster_edge_member_with_ip?(_node_id, _node, _edge, _role, _peer_counts, _known_infrastructure_ips),
    do: false

  defp endpoint_cluster_unresolved_edge_member_identity?(edge, role) when is_map(edge) and role in [:source, :target] do
    is_binary(endpoint_cluster_edge_member_mac(edge, role))
  end

  defp endpoint_cluster_unresolved_edge_member_identity?(_edge, _role), do: false

  defp weak_provisional_topology_sighting_identity?(node_id, device) when is_binary(node_id) and is_map(device) do
    topology_sighting_device?(device) and provisional_identity_state?(device) and
      is_binary(normalize_ipv4(node_ip(device, node_id))) and
      blank_node_identity?(Map.get(device, :name)) and
      blank_node_identity?(Map.get(device, :hostname)) and
      is_nil(normalize_mac(Map.get(device, :mac))) and
      is_nil(normalize_mac(node_meta_value(device, ["primary_mac", "endpoint_mac", "mac", "mac_address"])))
  end

  defp weak_provisional_topology_sighting_identity?(_node_id, _device), do: false

  defp known_infrastructure_ip_set(nodes_by_id) when is_map(nodes_by_id) do
    Enum.reduce(nodes_by_id, MapSet.new(), fn {node_id, node}, acc ->
      if is_binary(node_id) and is_map(node) and infrastructure_device?(node) and
           not cluster_summary_node?(node) do
        case node |> node_ip(node_id) |> normalize_ipv4() do
          ip when is_binary(ip) -> MapSet.put(acc, ip)
          _ -> acc
        end
      else
        acc
      end
    end)
  end

  defp known_infrastructure_ip_set(_nodes_by_id), do: MapSet.new()

  defp known_infrastructure_identity?(node_id, node, known_infrastructure_ips)
       when is_binary(node_id) and is_struct(known_infrastructure_ips, MapSet) do
    node
    |> node_ip(node_id)
    |> normalize_ipv4()
    |> known_infrastructure_ip?(known_infrastructure_ips)
  end

  defp known_infrastructure_identity?(_node_id, _node, _known_infrastructure_ips), do: false

  defp known_infrastructure_ip?(ip, known_infrastructure_ips)
       when is_binary(ip) and is_struct(known_infrastructure_ips, MapSet) do
    MapSet.member?(known_infrastructure_ips, ip)
  end

  defp known_infrastructure_ip?(_ip, _known_infrastructure_ips), do: false

  defp weak_edge_only_endpoint_identity?(edge, role) when is_map(edge) and role in [:source, :target] do
    endpoint_attachment_edge?(edge) and
      normalize_id(Map.get(edge, :confidence_reason)) == "single_identifier_inference" and
      member_interface_name_unknown?(edge, role) and
      is_nil(endpoint_cluster_edge_member_mac(edge, role))
  end

  defp weak_edge_only_endpoint_identity?(_edge, _role), do: false

  defp member_interface_name_unknown?(edge, :source) when is_map(edge) do
    blank_or_unknown_identity?(Map.get(edge, :local_if_name))
  end

  defp member_interface_name_unknown?(edge, :target) when is_map(edge) do
    blank_or_unknown_identity?(Map.get(edge, :neighbor_if_name))
  end

  defp member_interface_name_unknown?(_edge, _role), do: true

  defp endpoint_cluster_edge_member_mac(edge, :source) when is_map(edge) do
    attachment_side_mac(edge, :source)
  end

  defp endpoint_cluster_edge_member_mac(edge, :target) when is_map(edge) do
    attachment_side_mac(edge, :target)
  end

  defp endpoint_cluster_edge_member_mac(_edge, _role), do: nil

  defp endpoint_like_node?(node) when is_map(node) do
    kind =
      node
      |> Map.get(:kind, "endpoint")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    details =
      node
      |> Map.get(:details_json)
      |> decode_details_json()

    topology_sighting =
      normalize_id(Map.get(details, "identity_source")) == "mapper_topology_sighting"

    topology_sighting or
      kind not in [
        "router",
        "switch",
        "hub",
        "firewall",
        "load_balancer",
        "access point",
        "ap",
        "ids",
        "ips",
        "endpoint-cluster"
      ]
  end

  defp endpoint_like_node?(_node), do: false

  defp provisional_identity_state?(device) when is_map(device) do
    device
    |> Map.get(:metadata, %{})
    |> metadata_value("identity_state")
    |> normalize_id() == "provisional"
  end

  defp provisional_identity_state?(_device), do: false

  defp blank_or_unknown_identity?(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "" -> true
      "unknown" -> true
      _ -> false
    end
  end

  defp blank_or_unknown_identity?(nil), do: true
  defp blank_or_unknown_identity?(_value), do: false

  defp unplaced_topology_candidate?(device) when is_map(device) do
    uid = normalize_id(Map.get(device, :uid))
    type = normalized_node_type(device)
    type_id = Map.get(device, :type_id)
    role = normalize_id(node_meta_value(device, ["device_role", "_device_role"]))
    identity_source = normalize_id(node_meta_value(device, ["identity_source"]))
    display_name = normalize_id(node_label(device, uid))

    managed_role? =
      role in [
        "router",
        "switch",
        "firewall",
        "load_balancer",
        "access point",
        "wireless controller",
        "hypervisor",
        "virtual-guest"
      ]

    managed_type? =
      type in [
        "router",
        "switch",
        "firewall",
        "load balancer",
        "access point",
        "wireless controller",
        "virtual",
        "server"
      ] or type_id in @unplaced_device_type_ids

    managed_role? or
      (managed_type? and is_binary(display_name) and display_name != "" and
         identity_source != "mapper_topology_sighting")
  end

  defp unplaced_topology_candidate?(_device), do: false

  defp unplaced_topology_node?(node) when is_map(node) do
    node
    |> Map.get(:details_json)
    |> decode_details_json()
    |> Map.get("topology_unplaced") == true
  end

  defp unplaced_topology_node?(_node), do: false

  defp router_attachment_anchor?(device) when is_map(device) do
    normalized_node_type(device) in ["router"]
  end

  defp router_attachment_anchor?(_device), do: false

  defp endpoint_attachment_peer_counts(edges) when is_list(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      if endpoint_attachment_edge?(edge) do
        source = normalize_id(Map.get(edge, :source))
        target = normalize_id(Map.get(edge, :target))

        acc
        |> increment_endpoint_attachment_peer_count(source, target)
        |> increment_endpoint_attachment_peer_count(target, source)
      else
        acc
      end
    end)
  end

  defp increment_endpoint_attachment_peer_count(acc, node_id, peer_id)
       when is_map(acc) and is_binary(node_id) and is_binary(peer_id) do
    Map.update(acc, node_id, MapSet.new([peer_id]), &MapSet.put(&1, peer_id))
  end

  defp increment_endpoint_attachment_peer_count(acc, _node_id, _peer_id) when is_map(acc), do: acc

  defp high_ambiguity_endpoint_attachment_identity?(node_id, node, peer_counts)
       when is_binary(node_id) and is_map(peer_counts) do
    anonymous_unresolved_node?(node_id, node) and
      peer_counts
      |> Map.get(node_id, MapSet.new())
      |> MapSet.size()
      |> Kernel.>(@endpoint_cluster_ambiguous_peer_threshold)
  end

  defp high_ambiguity_endpoint_attachment_identity?(_node_id, _node, _peer_counts), do: false

  defp cluster_summary_node?(node) when is_map(node) do
    node
    |> Map.get(:details_json)
    |> decode_details_json()
    |> Map.get("cluster_kind") == "endpoint-summary"
  end

  defp endpoint_cluster_id(anchor_id, anchor_if_index) when is_binary(anchor_id) and is_integer(anchor_if_index) do
    "cluster:endpoints:" <> anchor_id <> ":ifindex:" <> Integer.to_string(anchor_if_index)
  end

  defp endpoint_cluster_id(anchor_id, _anchor_if_index) when is_binary(anchor_id), do: "cluster:endpoints:" <> anchor_id

  defp build_endpoint_cluster_node(group, anchor, idx, total, nodes_by_id) when is_map(group) and is_map(nodes_by_id) do
    endpoints =
      group.endpoint_ids
      |> Enum.map(&Map.get(nodes_by_id, &1))
      |> Enum.reject(&is_nil/1)

    {x, y} = endpoint_cluster_summary_coordinates(anchor, idx, total)
    count = length(group.endpoint_ids)
    visible_count = length(expanded_group_visible_endpoint_ids(group))
    hidden_count = expanded_group_hidden_member_count(group)
    sample = List.first(endpoints) || %{}
    anchor_label = Map.get(anchor || %{}, :label) || Map.get(group, :anchor_id)
    cluster_camera_tiles = build_cluster_camera_tiles(group, nodes_by_id)

    %{
      id: group.cluster_id,
      _cluster_node: true,
      label: "#{count} endpoints",
      kind: "endpoint-cluster",
      x: x,
      y: y,
      state: endpoint_cluster_state(endpoints),
      pps: Enum.reduce(endpoints, 0, &(&1.pps + &2)),
      oper_up: endpoint_cluster_oper_up(endpoints),
      details_json:
        normalize_details_json(%{
          id: group.cluster_id,
          ip: "cluster",
          type: "endpoint cluster",
          cluster_id: group.cluster_id,
          cluster_kind: "endpoint-summary",
          cluster_member_count: count,
          cluster_visible_member_count: visible_count,
          cluster_hidden_member_count: hidden_count,
          cluster_expandable: true,
          cluster_expanded: false,
          cluster_anchor_id: group.anchor_id,
          cluster_anchor_label: anchor_label,
          cluster_anchor_if_index: Map.get(group, :anchor_if_index),
          cluster_anchor_if_name: Map.get(group, :anchor_if_name),
          cluster_camera_tile_count: length(cluster_camera_tiles),
          cluster_camera_tiles: cluster_camera_tiles,
          cluster_sample_ip: endpoint_cluster_sample_ip(sample),
          cluster_sample_label: Map.get(sample, :label),
          identity_source: "backend_endpoint_cluster"
        }),
      geo_lat: nil,
      geo_lon: nil,
      health_signal: :unknown
    }
  end

  defp build_endpoint_cluster_node(_group, _anchor, _idx, _total, _nodes_by_id), do: %{}

  defp build_expanded_endpoint_cluster_node(group, anchor, idx, total, nodes_by_id)
       when is_map(group) and is_map(nodes_by_id) do
    {hub_x, hub_y} = endpoint_cluster_summary_coordinates(anchor, idx, total)

    group
    |> build_endpoint_cluster_node(anchor, idx, total, nodes_by_id)
    |> Map.merge(%{
      x: hub_x,
      y: hub_y,
      details_json:
        group
        |> build_endpoint_cluster_node(anchor, idx, total, nodes_by_id)
        |> Map.get(:details_json)
        |> merge_cluster_membership_details(%{cluster_expanded: true})
    })
  end

  defp build_expanded_endpoint_cluster_node(_group, _anchor, _idx, _total, _nodes_by_id), do: %{}

  defp build_endpoint_cluster_edge(group, nodes_by_id) when is_map(group) and is_map(nodes_by_id) do
    edges = Map.get(group, :edges, [])
    telemetry_eligible = Enum.any?(edges, &(Map.get(&1, :telemetry_eligible) == true))

    %{
      source: group.anchor_id,
      target: group.cluster_id,
      kind: "topology",
      protocol: "cluster",
      evidence_class: "endpoint-attachment",
      confidence_tier: "summary",
      confidence_reason: "clustered_endpoint_summary",
      flow_pps: Enum.reduce(edges, 0, &(normalize_u32(Map.get(&1, :flow_pps, 0)) + &2)),
      flow_bps: Enum.reduce(edges, 0, &(normalize_u64(Map.get(&1, :flow_bps, 0)) + &2)),
      capacity_bps:
        Enum.reduce(edges, 0, fn edge, acc ->
          max(acc, normalize_u64(Map.get(edge, :capacity_bps, 0)))
        end),
      flow_pps_ab: 0,
      flow_pps_ba: 0,
      flow_bps_ab: 0,
      flow_bps_ba: 0,
      telemetry_eligible: telemetry_eligible,
      telemetry_source: if(telemetry_eligible, do: "interface", else: "none"),
      local_if_index_ab: Map.get(group, :anchor_if_index),
      local_if_name_ab: Map.get(group, :anchor_if_name) || "",
      local_if_index_ba: nil,
      local_if_name_ba: "",
      label: "ENDPOINT CLUSTER #{length(group.endpoint_ids)} endpoints",
      metadata: %{
        "relation_type" => "ATTACHED_TO",
        "evidence_class" => "endpoint-attachment",
        "cluster_id" => group.cluster_id,
        "cluster_member_count" => length(group.endpoint_ids),
        "cluster_visible_member_count" => length(expanded_group_visible_endpoint_ids(group)),
        "cluster_hidden_member_count" => expanded_group_hidden_member_count(group)
      }
    }
  end

  defp build_endpoint_cluster_edge(_group, _nodes_by_id), do: %{}

  defp build_expanded_endpoint_cluster_edge(group, nodes_by_id) when is_map(group) and is_map(nodes_by_id) do
    group
    |> build_endpoint_cluster_edge(nodes_by_id)
    |> Map.put(:confidence_reason, "expanded_endpoint_cluster")
  end

  defp build_expanded_endpoint_cluster_edge(_group, _nodes_by_id), do: nil

  defp build_expanded_endpoint_member_edges(group) when is_map(group) do
    group
    |> expanded_group_visible_endpoint_ids()
    |> Enum.map(fn endpoint_id ->
      supporting_edge = expanded_endpoint_member_supporting_edge(group, endpoint_id)
      build_expanded_endpoint_member_edge(group, endpoint_id, supporting_edge)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_expanded_endpoint_member_edges(_group), do: []

  defp expanded_endpoint_member_supporting_edge(group, endpoint_id) when is_map(group) and is_binary(endpoint_id) do
    Enum.find(Map.get(group, :edges, []), fn edge ->
      Map.get(edge, :source) == endpoint_id or Map.get(edge, :target) == endpoint_id
    end)
  end

  defp expanded_endpoint_member_supporting_edge(_group, _endpoint_id), do: nil

  defp build_expanded_endpoint_member_edge(group, endpoint_id, supporting_edge)
       when is_map(group) and is_binary(endpoint_id) and is_map(supporting_edge) do
    telemetry_eligible = Map.get(supporting_edge, :telemetry_eligible, false) == true

    %{
      source: group.cluster_id,
      target: endpoint_id,
      kind: "topology",
      protocol: "cluster",
      evidence_class: "endpoint-attachment",
      confidence_tier: Map.get(supporting_edge, :confidence_tier, "summary"),
      confidence_reason: "expanded_endpoint_member",
      flow_pps: normalize_u32(Map.get(supporting_edge, :flow_pps, 0)),
      flow_bps: normalize_u64(Map.get(supporting_edge, :flow_bps, 0)),
      capacity_bps: normalize_u64(Map.get(supporting_edge, :capacity_bps, 0)),
      flow_pps_ab: 0,
      flow_pps_ba: 0,
      flow_bps_ab: 0,
      flow_bps_ba: 0,
      telemetry_eligible: telemetry_eligible,
      telemetry_source: if(telemetry_eligible, do: "interface", else: "none"),
      local_if_index_ab: Map.get(group, :anchor_if_index),
      local_if_name_ab: Map.get(group, :anchor_if_name) || "",
      local_if_index_ba: nil,
      local_if_name_ba: "",
      label: "ENDPOINT MEMBER",
      metadata: %{
        "relation_type" => "ATTACHED_TO",
        "evidence_class" => "endpoint-attachment",
        "cluster_id" => group.cluster_id,
        "cluster_anchor_id" => group.anchor_id,
        "cluster_visible_member_count" => length(expanded_group_visible_endpoint_ids(group)),
        "cluster_hidden_member_count" => expanded_group_hidden_member_count(group)
      }
    }
  end

  defp build_expanded_endpoint_member_edge(group, endpoint_id, nil) when is_map(group) and is_binary(endpoint_id) do
    %{
      source: group.cluster_id,
      target: endpoint_id,
      kind: "topology",
      protocol: "cluster",
      evidence_class: "endpoint-attachment",
      confidence_tier: "summary",
      confidence_reason: "expanded_endpoint_member_synthesized",
      flow_pps: 0,
      flow_bps: 0,
      capacity_bps: 0,
      flow_pps_ab: 0,
      flow_pps_ba: 0,
      flow_bps_ab: 0,
      flow_bps_ba: 0,
      telemetry_eligible: false,
      telemetry_source: "none",
      local_if_index_ab: Map.get(group, :anchor_if_index),
      local_if_name_ab: Map.get(group, :anchor_if_name) || "",
      local_if_index_ba: nil,
      local_if_name_ba: "",
      label: "ENDPOINT MEMBER",
      metadata: %{
        "relation_type" => "ATTACHED_TO",
        "evidence_class" => "endpoint-attachment",
        "cluster_id" => group.cluster_id,
        "cluster_anchor_id" => group.anchor_id,
        "cluster_visible_member_count" => length(expanded_group_visible_endpoint_ids(group)),
        "cluster_hidden_member_count" => expanded_group_hidden_member_count(group),
        "supporting_edge" => "synthesized"
      }
    }
  end

  defp build_expanded_endpoint_member_edge(_group, _endpoint_id, _supporting_edge), do: nil

  defp limit_expanded_cluster_group(group, nodes_by_id) when is_map(group) and is_map(nodes_by_id) do
    ranked_endpoint_ids =
      group
      |> Map.get(:endpoint_ids, [])
      |> Enum.uniq()
      |> Enum.sort_by(&expanded_cluster_member_rank(&1, group, nodes_by_id), :desc)

    {stable_endpoint_ids, topology_sighting_endpoint_ids} =
      Enum.split_with(
        ranked_endpoint_ids,
        &stable_expanded_cluster_member?(&1, nodes_by_id)
      )

    visible_stable_endpoint_ids =
      Enum.take(stable_endpoint_ids, @endpoint_cluster_expanded_visible_limit)

    remaining_budget =
      max(@endpoint_cluster_expanded_visible_limit - length(visible_stable_endpoint_ids), 0)

    topology_sighting_budget =
      min(remaining_budget, @endpoint_cluster_expanded_topology_sighting_limit)

    visible_endpoint_ids =
      visible_stable_endpoint_ids ++
        Enum.take(topology_sighting_endpoint_ids, topology_sighting_budget)

    Map.put(group, :visible_endpoint_ids, visible_endpoint_ids)
  end

  defp limit_expanded_cluster_group(group, _nodes_by_id) when is_map(group), do: group

  defp stable_expanded_cluster_member?(endpoint_id, nodes_by_id) when is_binary(endpoint_id) and is_map(nodes_by_id) do
    case Map.get(nodes_by_id, endpoint_id) do
      nil -> false
      node -> not topology_sighting_device?(node)
    end
  end

  defp stable_expanded_cluster_member?(_endpoint_id, _nodes_by_id), do: false

  defp expanded_group_visible_endpoint_ids(group) when is_map(group) do
    case Map.get(group, :visible_endpoint_ids) do
      ids when is_list(ids) -> ids
      _ -> Map.get(group, :endpoint_ids, [])
    end
  end

  defp expanded_group_visible_endpoint_ids(_group), do: []

  defp expanded_group_hidden_member_count(group) when is_map(group) do
    total = group |> Map.get(:endpoint_ids, []) |> length()
    visible = group |> expanded_group_visible_endpoint_ids() |> length()
    max(total - visible, 0)
  end

  defp expanded_group_hidden_member_count(_group), do: 0

  defp expanded_cluster_member_rank(endpoint_id, group, nodes_by_id)
       when is_binary(endpoint_id) and is_map(group) and is_map(nodes_by_id) do
    node = Map.get(nodes_by_id, endpoint_id)
    supporting_edge = expanded_endpoint_member_supporting_edge(group, endpoint_id)

    {
      if(resolved_endpoint_identity?(endpoint_id, node), do: 1, else: 0),
      if(is_map(node) and not topology_sighting_device?(node), do: 1, else: 0),
      attachment_confidence_rank(Map.get(supporting_edge || %{}, :confidence_tier)),
      normalize_u32(Map.get(supporting_edge || %{}, :flow_pps, 0)),
      normalize_u64(Map.get(supporting_edge || %{}, :flow_bps, 0)),
      endpoint_id
    }
  end

  defp expanded_cluster_member_rank(endpoint_id, _group, _nodes_by_id) when is_binary(endpoint_id) do
    {0, 0, 0, 0, 0, endpoint_id}
  end

  defp expanded_endpoint_member_identity_ip(endpoint_id, supporting_edge, anchor_id)
       when is_binary(endpoint_id) and is_binary(anchor_id) do
    supporting_edge
    |> expanded_endpoint_member_edge_role(endpoint_id, anchor_id)
    |> case do
      role when role in [:source, :target] ->
        endpoint_cluster_edge_member_ip(supporting_edge, role)

      _ ->
        ip_like_id(endpoint_id)
    end
    |> normalize_ipv4()
  end

  defp expanded_endpoint_member_identity_ip(endpoint_id, _supporting_edge, _anchor_id) when is_binary(endpoint_id),
    do: ip_like_id(endpoint_id)

  defp expanded_endpoint_member_identity_mac(supporting_edge, endpoint_id, anchor_id)
       when is_map(supporting_edge) and is_binary(endpoint_id) and is_binary(anchor_id) do
    supporting_edge
    |> expanded_endpoint_member_edge_role(endpoint_id, anchor_id)
    |> case do
      role when role in [:source, :target] -> attachment_side_mac(supporting_edge, role)
      _ -> nil
    end
  end

  defp expanded_endpoint_member_identity_mac(_supporting_edge, _endpoint_id, _anchor_id), do: nil

  defp expanded_endpoint_member_edge_role(supporting_edge, endpoint_id, anchor_id)
       when is_map(supporting_edge) and is_binary(endpoint_id) and is_binary(anchor_id) do
    source = normalize_id(Map.get(supporting_edge, :source))
    target = normalize_id(Map.get(supporting_edge, :target))

    cond do
      source == endpoint_id -> :source
      target == endpoint_id -> :target
      source == anchor_id -> :target
      target == anchor_id -> :source
      true -> nil
    end
  end

  defp expanded_endpoint_member_edge_role(_supporting_edge, _endpoint_id, _anchor_id), do: nil

  defp endpoint_cluster_state(nodes) when is_list(nodes) do
    states = Enum.map(nodes, &Map.get(&1, :state, 3))

    cond do
      Enum.any?(states, &(&1 == 0)) -> 0
      Enum.any?(states, &(&1 == 1)) -> 1
      Enum.any?(states, &(&1 == 2)) -> 2
      true -> 3
    end
  end

  defp endpoint_cluster_oper_up(nodes) when is_list(nodes) do
    values = Enum.map(nodes, &node_oper_up_value(Map.get(&1, :oper_up)))

    cond do
      Enum.any?(values, &(&1 == 2)) -> false
      Enum.any?(values, &(&1 == 1)) -> true
      true -> nil
    end
  end

  defp endpoint_cluster_summary_coordinates(%{x: anchor_x, y: anchor_y}, idx, total)
       when is_number(anchor_x) and is_number(anchor_y) and is_integer(idx) and is_integer(total) and total > 0 do
    y_offset = (idx - (total - 1) / 2) * @endpoint_cluster_summary_gap_y
    {round(anchor_x + @endpoint_cluster_summary_gap_x), round(anchor_y + y_offset)}
  end

  defp endpoint_cluster_summary_coordinates(_anchor, _idx, _total), do: {0, 0}

  defp endpoint_cluster_sample_ip(node) when is_map(node) do
    node
    |> Map.get(:details_json)
    |> decode_details_json()
    |> Map.get("ip")
  end

  defp endpoint_cluster_sample_ip(_node), do: nil

  defp build_cluster_camera_tiles(group, nodes_by_id) when is_map(group) and is_map(nodes_by_id) do
    group
    |> Map.get(:endpoint_ids, [])
    |> Enum.flat_map(fn endpoint_id ->
      nodes_by_id
      |> Map.get(endpoint_id)
      |> cluster_camera_tiles_for_node()
    end)
    |> Enum.uniq_by(&Map.get(&1, :camera_source_id))
    |> Enum.sort_by(&{Map.get(&1, :camera_label) || "", Map.get(&1, :device_uid) || ""})
    |> Enum.take(@max_cluster_camera_tile_candidates)
  end

  defp build_cluster_camera_tiles(_group, _nodes_by_id), do: []

  defp cluster_camera_tiles_for_node(node) when is_map(node) do
    node
    |> Map.get(:details_json)
    |> decode_details_json()
    |> Map.get("camera_streams", [])
    |> Enum.flat_map(fn source ->
      case cluster_camera_tile_from_source(source) do
        nil -> []
        tile -> [tile]
      end
    end)
  end

  defp cluster_camera_tiles_for_node(_node), do: []

  defp cluster_camera_tile_from_source(source) when is_map(source) do
    profile = cluster_camera_source_profile(source)

    attrs = %{
      camera_source_id: source_value(source, "camera_source_id", :camera_source_id),
      device_uid: source_value(source, "device_uid", :device_uid),
      stream_profile_id: source_value(profile, "stream_profile_id", :stream_profile_id),
      profile_name: source_value(profile, "profile_name", :profile_name),
      camera_label: cluster_camera_source_label(source)
    }

    if incomplete_cluster_camera_tile_attrs?(attrs) do
      nil
    else
      %{
        camera_source_id: attrs.camera_source_id,
        stream_profile_id: attrs.stream_profile_id,
        device_uid: attrs.device_uid,
        camera_label: attrs.camera_label || attrs.device_uid,
        profile_label: attrs.profile_name
      }
    end
  end

  defp cluster_camera_tile_from_source(_source), do: nil

  defp cluster_camera_source_profile(source) when is_map(source) do
    source
    |> Map.get("stream_profiles", Map.get(source, :stream_profiles, []))
    |> List.first()
  end

  defp incomplete_cluster_camera_tile_attrs?(attrs) when is_map(attrs) do
    Enum.any?(~w(camera_source_id device_uid stream_profile_id profile_name)a, fn key ->
      missing_topology_camera_value?(Map.get(attrs, key))
    end)
  end

  defp cluster_camera_source_label(source) when is_map(source) do
    source_value(source, "display_name", :display_name) ||
      source_value(source, "vendor_camera_id", :vendor_camera_id)
  end

  defp source_value(source, string_key, atom_key) when is_map(source) and is_binary(string_key) and is_atom(atom_key) do
    normalize_id(Map.get(source, string_key) || Map.get(source, atom_key))
  end

  defp source_value(_source, _string_key, _atom_key), do: nil

  defp merge_cluster_membership_details(details_json, cluster_details) when is_map(cluster_details) do
    details_json
    |> decode_details_json()
    |> Map.merge(stringify_keys(cluster_details))
    |> normalize_details_json()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp collapsed_endpoint_member_edge?(edge, collapsed_members)
       when is_map(edge) and is_struct(collapsed_members, MapSet) do
    endpoint_attachment_edge?(edge) and
      (MapSet.member?(collapsed_members, Map.get(edge, :source)) or
         MapSet.member?(collapsed_members, Map.get(edge, :target)))
  end

  defp collapsed_endpoint_member_edge?(_edge, _collapsed_members), do: false

  defp edge_endpoint_member?(edge, endpoint_ids) when is_map(edge) and is_list(endpoint_ids) do
    source = Map.get(edge, :source)
    target = Map.get(edge, :target)
    source in endpoint_ids or target in endpoint_ids
  end

  defp edge_endpoint_member?(_edge, _endpoint_ids), do: false

  defp attachment_anchor_match?(edge, anchor_id) when is_map(edge) and is_binary(anchor_id) do
    Map.get(edge, :source) == anchor_id or Map.get(edge, :target) == anchor_id
  end

  defp attachment_anchor_match?(_edge, _anchor_id), do: false

  defp edge_identity_key(edge) when is_map(edge) do
    edge
    |> Map.take([
      :source,
      :target,
      :kind,
      :protocol,
      :evidence_class,
      :confidence_tier,
      :confidence_reason,
      :local_if_index_ab,
      :local_if_name_ab,
      :local_if_index_ba,
      :local_if_name_ba,
      :label
    ])
    |> :erlang.term_to_binary()
  end

  defp edge_identity_key(edge), do: :erlang.term_to_binary(edge)

  defp rendered_pipeline_stats(pipeline_stats, nodes, edges)
       when is_map(pipeline_stats) and is_list(nodes) and is_list(edges) do
    pipeline_stats
    |> Map.put(:final_edges, length(edges))
    |> Map.put(:final_nodes, length(nodes))
    |> Map.put(:final_direct, count_by_evidence(edges, "direct"))
    |> Map.put(:final_inferred, count_by_evidence(edges, "inferred"))
    |> Map.put(:final_attachment, count_by_evidence(edges, "endpoint-attachment"))
    |> Map.merge(component_stats(nodes, edges))
  end

  defp rendered_pipeline_stats(pipeline_stats, _nodes, _edges), do: pipeline_stats

  defp resolve_coordinate_collisions(nodes) when is_list(nodes) do
    nodes_by_id = Map.new(nodes, &{&1.id, &1})

    updated =
      nodes
      |> Enum.group_by(fn node -> {Map.get(node, :x), Map.get(node, :y)} end)
      |> Enum.reduce(nodes_by_id, &resolve_grouped_coordinate_collision/2)

    Enum.map(nodes, fn node -> Map.get(updated, node.id, node) end)
  end

  defp resolve_grouped_coordinate_collision({{x, y}, grouped_nodes}, acc)
       when is_map(acc) and is_number(x) and is_number(y) and is_list(grouped_nodes) and length(grouped_nodes) > 1 do
    {fixed_nodes, movable_nodes} =
      Enum.split_with(grouped_nodes, &Map.get(&1, :_cluster_node, false))

    orbit_colliding_nodes(acc, movable_nodes, length(fixed_nodes), {x, y})
  end

  defp resolve_grouped_coordinate_collision({_xy, _grouped_nodes}, acc) when is_map(acc), do: acc

  defp orbit_colliding_nodes(acc, [], _fixed_count, _origin) when is_map(acc), do: acc

  defp orbit_colliding_nodes(acc, movable_nodes, fixed_count, {x, y})
       when is_map(acc) and is_list(movable_nodes) and is_integer(fixed_count) and is_number(x) and is_number(y) do
    movable_nodes
    |> Enum.sort_by(&to_string(Map.get(&1, :id)))
    |> Enum.with_index(fixed_count)
    |> Enum.reduce(acc, fn {node, idx}, inner ->
      adjusted =
        orbit_colliding_node(node, idx, fixed_count, length(movable_nodes), {x, y})

      Map.put(inner, node.id, adjusted)
    end)
  end

  defp orbit_colliding_node(node, idx, fixed_count, movable_count, {x, y})
       when is_map(node) and is_integer(idx) and is_integer(fixed_count) and is_integer(movable_count) do
    angle = 2 * :math.pi() * idx / (movable_count + fixed_count) + endpoint_angle_offset(node.id)
    radius = 18.0 + div(idx, 8) * 12.0

    %{
      node
      | x: round(x + radius * :math.cos(angle)),
        y: round(y + radius * :math.sin(angle))
    }
  end

  defp resolve_proximity_collisions(nodes) when is_list(nodes) do
    node_by_id = Map.new(nodes, &{&1.id, &1})

    ids =
      nodes
      |> Enum.map(& &1.id)
      |> Enum.sort()

    pairs =
      for {left_id, idx} <- Enum.with_index(ids),
          right_id <- Enum.drop(ids, idx + 1) do
        {left_id, right_id}
      end

    relaxed_positions =
      Enum.reduce(1..@proximity_collision_iterations, map_coordinates(nodes), fn _iteration, positions ->
        Enum.reduce(pairs, positions, fn {left_id, right_id}, acc ->
          separate_nearby_pair(acc, node_by_id, left_id, right_id)
        end)
      end)

    Enum.map(nodes, fn node ->
      case Map.get(relaxed_positions, node.id) do
        {x, y} when is_number(x) and is_number(y) ->
          %{node | x: round(x), y: round(y)}

        _ ->
          node
      end
    end)
  end

  defp map_coordinates(nodes) when is_list(nodes) do
    Map.new(nodes, fn node ->
      {node.id, {Map.get(node, :x, 0) * 1.0, Map.get(node, :y, 0) * 1.0}}
    end)
  end

  defp separate_nearby_pair(positions, node_by_id, left_id, right_id)
       when is_map(positions) and is_map(node_by_id) and is_binary(left_id) and is_binary(right_id) do
    with {left_x, left_y} when is_number(left_x) and is_number(left_y) <-
           Map.get(positions, left_id),
         {right_x, right_y} when is_number(right_x) and is_number(right_y) <-
           Map.get(positions, right_id) do
      dx = right_x - left_x
      dy = right_y - left_y
      distance = :math.sqrt(dx * dx + dy * dy)

      if distance >= @proximity_collision_min_distance do
        positions
      else
        overlap = @proximity_collision_min_distance - distance
        {ux, uy} = separation_unit_vector(left_id, right_id, dx, dy, distance)
        left_mobility = collision_mobility(Map.get(node_by_id, left_id))
        right_mobility = collision_mobility(Map.get(node_by_id, right_id))
        mobility_total = max(left_mobility + right_mobility, 0.001)
        left_share = left_mobility / mobility_total
        right_share = right_mobility / mobility_total
        x_push = overlap * 0.28
        y_push = overlap * 0.92

        positions
        |> Map.put(
          left_id,
          {left_x - ux * x_push * left_share, left_y - uy * y_push * left_share}
        )
        |> Map.put(
          right_id,
          {right_x + ux * x_push * right_share, right_y + uy * y_push * right_share}
        )
      end
    else
      _ -> positions
    end
  end

  defp separate_nearby_pair(positions, _node_by_id, _left_id, _right_id), do: positions

  defp separation_unit_vector(left_id, right_id, dx, dy, distance)
       when is_binary(left_id) and is_binary(right_id) and is_number(dx) and is_number(dy) and is_number(distance) do
    if distance > 0.001 do
      {dx / distance, dy / distance}
    else
      angle = 2 * :math.pi() * :erlang.phash2({left_id, right_id}, 10_000) / 10_000
      {max(:math.cos(angle), 0.18), :math.sin(angle)}
    end
  end

  defp separation_unit_vector(_left_id, _right_id, _dx, _dy, _distance), do: {0.0, 1.0}

  defp collision_mobility(node) when is_map(node) do
    if Map.get(node, :_cluster_node, false) do
      0.0
    else
      case node_layout_weight(node) do
        weight when weight >= 950 -> 0.35
        weight when weight >= 850 -> 0.55
        weight when weight >= 600 -> 0.85
        _ -> 1.2
      end
    end
  end

  defp collision_mobility(_node), do: 1.0

  defp endpoint_angle_offset(anchor_id) when is_binary(anchor_id) do
    2 * :math.pi() * :erlang.phash2(anchor_id, 10_000) / 10_000
  end

  defp endpoint_angle_offset(_), do: 0.0

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

    Enum.reduce(
      fetch_recent_routing_causal_events(),
      %{},
      &apply_routing_event_overrides(&2, indexed_keys, &1)
    )
  end

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

  defp normalize_causal_state(base_state, base_reason, override, root_index, parent_index, hop_distance) do
    state = override_state(base_state, override)
    reason = override_reason(base_reason, override)

    if suppress_proximity_only_affected_state?(base_state, state, base_reason, override) do
      {3, "proximity_only_engine_state_suppressed", -1, -1, -1}
    else
      {state, reason, root_index, parent_index, hop_distance}
    end
  end

  defp suppress_proximity_only_affected_state?(base_state, state, base_reason, override) do
    base_state == 1 and state == 1 and is_nil(override) and
      proximity_only_engine_reason?(base_reason)
  end

  defp proximity_only_engine_reason?(reason) when is_binary(reason) do
    String.starts_with?(reason, "reachable_from_root_within_") or
      reason == "fallback_state_only_engine_result"
  end

  defp proximity_only_engine_reason?(_reason), do: false

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
    Map.get(
      Map.get(link, :metadata) || %{},
      "confidence_tier",
      Map.get(link, :confidence_tier, "unknown")
    )
  end

  defp evidence_class(link) do
    metadata = Map.get(link, :metadata) || %{}

    explicit =
      metadata["evidence_class"] || metadata[:evidence_class] || Map.get(link, :evidence_class)

    relation_type =
      metadata["relation_type"] || metadata[:relation_type] || Map.get(link, :relation_type)

    evidence_class_from_relation_type(relation_type) ||
      normalized_evidence_class(explicit) ||
      "unknown"
  end

  defp endpoint_attachment_edge?(edge) when is_map(edge) do
    evidence_class(edge) == "endpoint-attachment"
  end

  defp endpoint_attachment_edge?(_edge), do: false

  defp endpoint_cluster_membership_edge?(edge) when is_map(edge) do
    endpoint_attachment_edge?(edge) and not weak_endpoint_cluster_membership_edge?(edge)
  end

  defp endpoint_cluster_membership_edge?(_edge), do: false

  defp weak_endpoint_cluster_membership_edge?(edge) when is_map(edge) do
    edge_protocol(edge) == "snmp-l2" and
      normalize_id(Map.get(edge, :confidence_reason)) == "single_identifier_inference" and
      Map.get(edge, :telemetry_source) != "interface"
  end

  defp weak_endpoint_cluster_membership_edge?(_edge), do: false

  defp attachment_candidate_edge?(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    endpoint_attachment_edge?(edge) or
      inferred_segment_attachment_candidate?(edge, device_by_id) or
      single_identifier_attachment_candidate?(edge, device_by_id)
  end

  defp attachment_candidate_edge?(_edge, _device_by_id), do: false

  defp inferred_segment_attachment_candidate?(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    evidence_class(edge) == "inferred" and
      edge_protocol(edge) == "snmp-l2" and
      normalize_id(Map.get(edge, :confidence_reason)) == "arp_fdb_port_mapping" and
      Map.get(edge, :telemetry_source) != "interface" and
      attachment_endpoint_side_count(edge, device_by_id) == 1 and
      attachment_anchor?(edge, device_by_id) and
      attachment_identity_hint?(edge, device_by_id)
  end

  defp inferred_segment_attachment_candidate?(_edge, _device_by_id), do: false

  defp single_identifier_attachment_candidate?(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    evidence_class(edge) in ["direct", "direct-physical"] and
      edge_protocol(edge) == "unifi-api" and
      normalize_id(Map.get(edge, :confidence_reason)) == "single_identifier_inference" and
      attachment_endpoint_side_count(edge, device_by_id) == 1 and
      attachment_anchor?(edge, device_by_id) and
      attachment_identity_hint?(edge, device_by_id)
  end

  defp single_identifier_attachment_candidate?(_edge, _device_by_id), do: false

  defp attachment_endpoint_side_count(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    edge
    |> attachment_endpoint_sides(device_by_id)
    |> length()
  end

  defp attachment_endpoint_side_count(_edge, _device_by_id), do: 0

  defp attachment_anchor?(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    anchor_id = attachment_anchor_id(edge, device_by_id)
    anchor_device = Map.get(device_by_id, anchor_id)
    access_attachment_anchor?(anchor_device) or infrastructure_device?(anchor_device)
  end

  defp attachment_anchor?(_edge, _device_by_id), do: false

  defp attachment_identity_hint?(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    is_binary(attachment_identity_ip(edge, device_by_id)) or
      is_binary(attachment_identity_mac(edge, device_by_id))
  end

  defp attachment_identity_hint?(_edge, _device_by_id), do: false

  defp promote_attachment_candidate_edge(edge, device_by_id) when is_map(edge) and is_map(device_by_id) do
    if inferred_segment_attachment_candidate?(edge, device_by_id) or
         single_identifier_attachment_candidate?(edge, device_by_id) do
      metadata =
        edge
        |> Map.get(:metadata, %{})
        |> Map.put("relation_type", "ATTACHED_TO")
        |> Map.put("evidence_class", "endpoint-attachment")

      promoted =
        edge
        |> Map.put(:evidence_class, "endpoint-attachment")
        |> Map.put(:metadata, metadata)

      Map.put(
        promoted,
        :label,
        edge_label(promoted, Map.get(promoted, :flow_pps, 0), Map.get(promoted, :capacity_bps, 0))
      )
    else
      edge
    end
  end

  defp promote_attachment_candidate_edge(edge, _device_by_id) when is_map(edge), do: edge

  defp promote_projection_attachment_candidates(edges, nodes) when is_list(edges) and is_list(nodes) do
    nodes_by_id = Map.new(nodes, &{normalize_id(Map.get(&1, :id)), &1})
    Enum.map(edges, &promote_projection_attachment_candidate_edge(&1, nodes_by_id))
  end

  defp promote_projection_attachment_candidates(edges, _nodes) when is_list(edges), do: edges
  defp promote_projection_attachment_candidates(_edges, _nodes), do: []

  defp promote_projection_attachment_candidate_edge(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    if inferred_segment_projection_attachment_candidate?(edge, nodes_by_id) or
         single_identifier_projection_attachment_candidate?(edge, nodes_by_id) do
      metadata =
        edge
        |> Map.get(:metadata, %{})
        |> Map.put("relation_type", "ATTACHED_TO")
        |> Map.put("evidence_class", "endpoint-attachment")

      promoted =
        edge
        |> Map.put(:evidence_class, "endpoint-attachment")
        |> Map.put(:metadata, metadata)

      Map.put(
        promoted,
        :label,
        edge_label(promoted, Map.get(promoted, :flow_pps, 0), Map.get(promoted, :capacity_bps, 0))
      )
    else
      edge
    end
  end

  defp promote_projection_attachment_candidate_edge(edge, _nodes_by_id) when is_map(edge), do: edge

  defp inferred_segment_projection_attachment_candidate?(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    evidence_class(edge) == "inferred" and
      edge_protocol(edge) == "snmp-l2" and
      normalize_id(Map.get(edge, :confidence_reason)) == "arp_fdb_port_mapping" and
      Map.get(edge, :telemetry_source) != "interface" and
      projection_attachment_endpoint_side_count(edge, nodes_by_id) == 1 and
      projection_attachment_anchor?(edge, nodes_by_id) and
      projection_attachment_identity_hint?(edge, nodes_by_id)
  end

  defp inferred_segment_projection_attachment_candidate?(_edge, _nodes_by_id), do: false

  defp single_identifier_projection_attachment_candidate?(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    evidence_class(edge) in ["direct", "direct-physical"] and
      edge_protocol(edge) == "unifi-api" and
      normalize_id(Map.get(edge, :confidence_reason)) == "single_identifier_inference" and
      projection_attachment_endpoint_side_count(edge, nodes_by_id) == 1 and
      projection_attachment_anchor?(edge, nodes_by_id) and
      projection_attachment_identity_hint?(edge, nodes_by_id)
  end

  defp single_identifier_projection_attachment_candidate?(_edge, _nodes_by_id), do: false

  defp projection_attachment_endpoint_side_count(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    edge
    |> projection_attachment_endpoint_sides(nodes_by_id)
    |> length()
  end

  defp projection_attachment_endpoint_side_count(_edge, _nodes_by_id), do: 0

  defp projection_attachment_endpoint_sides(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    source_node = Map.get(nodes_by_id, source)
    target_node = Map.get(nodes_by_id, target)

    []
    |> maybe_add_projection_attachment_side(
      projection_attachment_endpoint_node?(source, source_node),
      {:source, source, source_node}
    )
    |> maybe_add_projection_attachment_side(
      projection_attachment_endpoint_node?(target, target_node),
      {:target, target, target_node}
    )
  end

  defp projection_attachment_endpoint_sides(_edge, _nodes_by_id), do: []

  defp maybe_add_projection_attachment_side(sides, true, {_side, endpoint_id, _node} = endpoint_side)
       when is_list(sides) and is_binary(endpoint_id) do
    [endpoint_side | sides]
  end

  defp maybe_add_projection_attachment_side(sides, _include?, _endpoint_side) when is_list(sides), do: sides

  defp projection_attachment_endpoint_node?(node_id, node) when is_binary(node_id) and is_map(node) do
    endpoint_like_node?(node) and not endpoint_cluster_anchor_node?(node_id, node)
  end

  defp projection_attachment_endpoint_node?(_node_id, _node), do: false

  defp projection_attachment_anchor?(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    anchor_id = projection_attachment_anchor_id(edge, nodes_by_id)
    anchor_node = Map.get(nodes_by_id, anchor_id)
    endpoint_cluster_anchor_node?(anchor_id, anchor_node)
  end

  defp projection_attachment_anchor?(_edge, _nodes_by_id), do: false

  defp projection_attachment_anchor_id(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    source = normalize_id(Map.get(edge, :source))
    target = normalize_id(Map.get(edge, :target))
    endpoint_id = projection_attachment_endpoint_id(edge, nodes_by_id)

    cond do
      endpoint_id == source -> target
      endpoint_id == target -> source
      true -> nil
    end
  end

  defp projection_attachment_anchor_id(_edge, _nodes_by_id), do: nil

  defp projection_attachment_endpoint_id(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    case projection_attachment_endpoint_sides(edge, nodes_by_id) do
      [{_side, endpoint_id, _node}] -> endpoint_id
      _ -> nil
    end
  end

  defp projection_attachment_endpoint_id(_edge, _nodes_by_id), do: nil

  defp projection_attachment_identity_hint?(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    is_binary(projection_attachment_identity_ip(edge, nodes_by_id)) or
      is_binary(projection_attachment_identity_mac(edge, nodes_by_id))
  end

  defp projection_attachment_identity_hint?(_edge, _nodes_by_id), do: false

  defp projection_attachment_identity_ip(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    edge
    |> projection_attachment_endpoint_sides(nodes_by_id)
    |> Enum.flat_map(fn {side, endpoint_id, node} ->
      [
        projection_attachment_node_ip(node, endpoint_id),
        endpoint_cluster_edge_member_ip(edge, side)
      ]
    end)
    |> Enum.map(&normalize_ipv4/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> List.first()
  end

  defp projection_attachment_identity_ip(_edge, _nodes_by_id), do: nil

  defp projection_attachment_identity_mac(edge, nodes_by_id) when is_map(edge) and is_map(nodes_by_id) do
    edge
    |> projection_attachment_endpoint_sides(nodes_by_id)
    |> Enum.flat_map(fn {side, endpoint_id, node} ->
      [
        endpoint_id,
        projection_attachment_node_mac(node),
        attachment_side_mac(edge, side)
      ]
    end)
    |> Enum.map(&normalize_mac/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> List.first()
  end

  defp projection_attachment_identity_mac(_edge, _nodes_by_id), do: nil

  defp projection_attachment_node_ip(node, endpoint_id) when is_map(node) and is_binary(endpoint_id) do
    details =
      node
      |> Map.get(:details_json)
      |> decode_details_json()

    normalize_ipv4(Map.get(details, "ip")) || node_ip(node, endpoint_id)
  end

  defp projection_attachment_node_ip(_node, endpoint_id) when is_binary(endpoint_id), do: node_ip(nil, endpoint_id)

  defp projection_attachment_node_ip(_node, _endpoint_id), do: nil

  defp projection_attachment_node_mac(node) when is_map(node) do
    details =
      node
      |> Map.get(:details_json)
      |> decode_details_json()

    normalize_mac(Map.get(details, "mac")) ||
      normalize_mac(Map.get(details, "primary_mac")) ||
      normalize_mac(Map.get(details, "endpoint_mac"))
  end

  defp projection_attachment_node_mac(_node), do: nil

  defp normalized_evidence_class(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "direct-physical" -> "direct"
      "direct-logical" -> "logical"
      "hosted-virtual" -> "hosted"
      "inferred-segment" -> "inferred"
      "observed-only" -> "observed"
      normalized when normalized in @god_view_evidence_classes -> normalized
      _ -> nil
    end
  end

  defp evidence_class_from_relation_type(value) when is_binary(value) do
    case String.upcase(String.trim(value)) do
      "ATTACHED_TO" -> "endpoint-attachment"
      "OBSERVED_TO" -> "observed"
      "INFERRED_TO" -> "inferred"
      "CONNECTS_TO" -> "direct"
      "LOGICAL_PEER" -> "logical"
      "HOSTED_ON" -> "hosted"
      _ -> nil
    end
  end

  defp evidence_class_from_relation_type(_value), do: nil

  defp page_results(%{results: results}) when is_list(results), do: results

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

  defp decode_details_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_details_json(value) when is_map(value), do: value
  defp decode_details_json(_value), do: %{}

  defp normalize_snapshot_options(opts) when is_map(opts) do
    %{
      expanded_clusters:
        opts
        |> Map.get(:expanded_clusters, Map.get(opts, "expanded_clusters", []))
        |> normalize_expanded_clusters()
    }
  end

  defp normalize_snapshot_options(_opts), do: %{expanded_clusters: MapSet.new()}

  defp normalize_expanded_clusters(%MapSet{} = clusters), do: clusters

  defp normalize_expanded_clusters(clusters) when is_list(clusters) do
    clusters
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp normalize_expanded_clusters(_clusters), do: MapSet.new()

  defp default_snapshot_options?(%{expanded_clusters: expanded_clusters}) when is_struct(expanded_clusters, MapSet) do
    MapSet.size(expanded_clusters) == 0
  end

  defp default_snapshot_options?(_opts), do: true

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

  defp snapshot_revision(topology_revision, causal_revision, snapshot_opts) do
    stable_positive_hash({
      topology_revision,
      causal_revision,
      snapshot_option_revision(snapshot_opts)
    })
  end

  defp snapshot_option_revision(%{expanded_clusters: expanded_clusters}) when is_struct(expanded_clusters, MapSet) do
    Enum.sort(expanded_clusters)
  end

  defp snapshot_option_revision(%{}), do: []

  defp stable_positive_hash(term) do
    case :erlang.phash2(term, 4_294_967_295) do
      0 -> 1
      value -> value
    end
  end

  defp legacy_backend_layout_authority_enabled? do
    # Backend-authored geometry is retired. The frontend is the only active
    # layout authority for visible topology, so this legacy path stays
    # permanently disabled while the remaining dead helpers are removed in
    # follow-up cleanup.
    false
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
