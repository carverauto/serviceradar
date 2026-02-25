defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Apache AGE graph.
  """

  require Logger

  alias ServiceRadar.Graph
  @default_stale_minutes 180
  @direct_protocols MapSet.new(["lldp", "cdp", "unifi-api", "wireguard-derived"])
  @strict_ifindex_protocols MapSet.new(["lldp", "cdp"])
  @direct_evidence_classes MapSet.new(["direct"])
  @attachment_evidence_classes MapSet.new(["endpoint-attachment"])
  @inferred_evidence_classes MapSet.new(["inferred"])

  @spec upsert_links([map()]) :: :ok
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    {local_device_ids, neighbor_index, diagnostics} =
      Enum.reduce(
        links,
        {MapSet.new(), %{}, empty_projection_diagnostics()},
        &reduce_topology_link/2
      )

    maybe_prune_unseen_projected_links(neighbor_index)
    maybe_prune_stale_projected_links(MapSet.to_list(local_device_ids))
    maybe_prune_stale_mapper_evidence_links()
    rebuild_canonical_device_links()

    Logger.info("Topology projection diagnostics: #{inspect(diagnostics)}")

    :ok
  end

  @doc """
  Rebuilds canonical device-level topology edges from current mapper evidence in AGE.
  """
  @spec rebuild_canonical_links_from_current() :: :ok
  def rebuild_canonical_links_from_current do
    _ = rebuild_canonical_links_from_current_with_stats()
    :ok
  end

  @doc """
  Rebuilds canonical device-level topology edges from current mapper evidence in AGE and
  returns rebuild counters for observability/recovery decisions.
  """
  @spec rebuild_canonical_links_from_current_with_stats() ::
          {:ok, map()} | {:error, term(), map()}
  def rebuild_canonical_links_from_current_with_stats do
    rebuild_canonical_device_links()
  end

  @doc """
  Returns projection diagnostics for a batch without mutating AGE.
  """
  @spec projection_diagnostics([map()]) :: %{
          accepted: map(),
          rejected: map(),
          total: non_neg_integer()
        }
  def projection_diagnostics(links) when is_list(links) do
    Enum.reduce(links, empty_projection_diagnostics(), fn link, diagnostics ->
      case classify_projection(link) do
        {:ok, %{mode: :backbone, reason: reason}} ->
          increment_diagnostic(diagnostics, :accepted, reason)

        {:ok, %{mode: :auxiliary, reason: reason}} ->
          increment_diagnostic(diagnostics, :accepted, reason)

        {:ok, %{mode: :skip, reason: reason}} ->
          increment_diagnostic(diagnostics, :rejected, reason)

        {:error, :missing_ids} ->
          increment_diagnostic(diagnostics, :rejected, :missing_ids)
      end
    end)
  end

  @doc """
  Pure classifier for mapper topology projection decisions.

  Returns:
  - `{:ok, %{mode: :backbone, relation: "CONNECTS_TO", payload: payload}}`
  - `{:ok, %{mode: :auxiliary, relation: "ATTACHED_TO" | "INFERRED_TO" | "OBSERVED_TO", payload: payload}}`
  - `{:ok, %{mode: :skip, relation: nil, payload: payload}}`
  - `{:error, :missing_ids}` when required identifiers are absent
  """
  @spec classify_projection(map()) ::
          {:ok,
           %{mode: :backbone | :auxiliary | :skip, relation: String.t() | nil, payload: map()}}
          | {:error, :missing_ids}
  def classify_projection(link) when is_map(link) do
    case build_link_payload(link) do
      {:ok, payload} ->
        case projection_mode(payload) do
          {:backbone, reason} ->
            {:ok, %{mode: :backbone, relation: "CONNECTS_TO", payload: payload, reason: reason}}

          {:auxiliary, reason} ->
            {:ok,
             %{
               mode: :auxiliary,
               relation: evidence_relation_type(payload),
               payload: payload,
               reason: reason
             }}

          {:skip, reason} ->
            {:ok, %{mode: :skip, relation: nil, payload: payload, reason: reason}}
        end

      {:error, :missing_ids} = error ->
        error
    end
  end

  defp reduce_topology_link(link, {local_ids, neighbor_index, diagnostics}) do
    case classify_projection(link) do
      {:ok, %{mode: :backbone, payload: payload, reason: reason}} ->
        local_ids = MapSet.put(local_ids, payload.local_device_id)
        upsert_backbone_link_payload(payload)
        diagnostics = increment_diagnostic(diagnostics, :accepted, reason)

        neighbor_index =
          add_neighbor_edge(neighbor_index, payload.local_device_id, payload.neighbor_device_id)

        {local_ids, neighbor_index, diagnostics}

      {:ok, %{mode: :auxiliary, payload: payload, reason: reason}} ->
        upsert_auxiliary_link_payload(payload)
        diagnostics = increment_diagnostic(diagnostics, :accepted, reason)
        {local_ids, neighbor_index, diagnostics}

      {:ok, %{mode: :skip, reason: reason}} ->
        diagnostics = increment_diagnostic(diagnostics, :rejected, reason)
        {local_ids, neighbor_index, diagnostics}

      {:error, :missing_ids} ->
        Logger.debug("Skipping topology link missing device identifiers")
        diagnostics = increment_diagnostic(diagnostics, :rejected, :missing_ids)
        {local_ids, neighbor_index, diagnostics}
    end
  end

  defp add_neighbor_edge(index, local_device_id, neighbor_device_id) do
    update_in(index, [local_device_id], fn
      nil -> MapSet.new([neighbor_device_id])
      existing -> MapSet.put(existing, neighbor_device_id)
    end)
  end

  @spec upsert_interfaces([map()]) :: :ok
  def upsert_interfaces([]), do: :ok

  def upsert_interfaces(interfaces) when is_list(interfaces) do
    Enum.each(interfaces, &upsert_interface/1)
    :ok
  end

  @doc """
  Creates a MANAGED_BY edge from a device to its management device.
  """
  @spec upsert_managed_by(String.t(), String.t()) :: :ok
  def upsert_managed_by(device_uid, management_device_uid)
      when is_binary(device_uid) and is_binary(management_device_uid) do
    cypher = """
    MERGE (child:Device {id: '#{Graph.escape(device_uid)}'})
    MERGE (mgmt:Device {id: '#{Graph.escape(management_device_uid)}'})
    MERGE (child)-[r:MANAGED_BY]->(mgmt)
    SET r.source = 'mapper'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("MANAGED_BY graph upsert failed: #{inspect(reason)}")
    end
  end

  defp upsert_interface(interface) when is_map(interface) do
    case build_interface_payload(interface) do
      {:ok, payload} ->
        upsert_interface_payload(payload)

      {:error, :missing_ids} ->
        Logger.debug("Skipping interface graph upsert missing identifiers")
        :ok
    end
  end

  defp upsert_interface(_interface), do: :ok

  defp build_interface_payload(interface) do
    device_id = non_blank(link_value(interface, :device_id))
    if_name = link_value(interface, :if_name)
    if_index = link_value(interface, :if_index)
    interface_id = interface_id(device_id, if_name, if_index)

    if is_nil(device_id) or is_nil(interface_id) do
      {:error, :missing_ids}
    else
      {:ok,
       %{
         device_id: device_id,
         interface_id: interface_id,
         if_name: if_name,
         if_index: if_index,
         if_descr: link_value(interface, :if_descr),
         if_alias: link_value(interface, :if_alias),
         if_phys_address: link_value(interface, :if_phys_address),
         ip_addresses: link_value(interface, :ip_addresses)
       }}
    end
  end

  defp build_link_payload(link) do
    local_device_id = non_blank(link_value(link, :local_device_id))
    neighbor_device_id = neighbor_device_id(link)
    local_interface_id = local_interface_id(link, local_device_id)
    neighbor_port = neighbor_port(link)
    neighbor_interface_id = neighbor_interface_id(neighbor_device_id, neighbor_port)
    metadata = link_value(link, :metadata) || %{}
    protocol = link_value(link, :protocol) || "unknown"

    evidence_class =
      map_value(metadata, :evidence_class) ||
        default_evidence_class_for_protocol(protocol)

    confidence_tier = confidence_tier(link, metadata)
    confidence_score = confidence_score(link, metadata)
    confidence_reason = confidence_reason(link, metadata)
    observed_at = observed_at(link)

    if is_nil(local_device_id) or is_nil(neighbor_device_id) do
      {:error, :missing_ids}
    else
      {:ok,
       %{
         local_device_id: local_device_id,
         neighbor_device_id: neighbor_device_id,
         local_interface_id: local_interface_id,
         neighbor_interface_id: neighbor_interface_id,
         protocol: protocol,
         local_if_name: link_value(link, :local_if_name),
         local_if_index: link_value(link, :local_if_index),
         neighbor_port_name: neighbor_port,
         neighbor_name: link_value(link, :neighbor_system_name),
         neighbor_ip: link_value(link, :neighbor_mgmt_addr),
         evidence_class: evidence_class,
         confidence_tier: confidence_tier,
         confidence_score: confidence_score,
         confidence_reason: confidence_reason,
         observed_at: observed_at
       }}
    end
  end

  defp local_interface_id(link, local_device_id) do
    interface_id(
      local_device_id,
      link_value(link, :local_if_name),
      link_value(link, :local_if_index)
    ) || default_interface_id(local_device_id, "unknown-local")
  end

  defp neighbor_port(link) do
    Enum.find_value(
      [
        :neighbor_port_id,
        :neighbor_port_descr,
        :neighbor_chassis_id,
        :neighbor_system_name,
        :neighbor_mgmt_addr
      ],
      fn key -> non_blank(link_value(link, key)) end
    )
  end

  defp neighbor_interface_id(neighbor_device_id, neighbor_port) do
    interface_id(neighbor_device_id, neighbor_port, nil) ||
      default_interface_id(neighbor_device_id, "unknown-neighbor")
  end

  defp upsert_interface_payload(payload) do
    cypher = """
    MERGE (d:Device {id: '#{Graph.escape(payload.device_id)}'})
    MERGE (i:Interface {id: '#{Graph.escape(payload.interface_id)}'})
    SET i.device_id = '#{Graph.escape(payload.device_id)}'
    #{set_prop("i", "name", payload.if_name)}
    #{set_prop("i", "ifindex", payload.if_index)}
    #{set_prop("i", "descr", payload.if_descr)}
    #{set_prop("i", "alias", payload.if_alias)}
    #{set_prop("i", "mac", payload.if_phys_address)}
    #{set_prop("i", "ip_addresses", payload.ip_addresses)}
    MERGE (d)-[r:HAS_INTERFACE]->(i)
    SET r.source = 'mapper'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Interface graph upsert failed: #{inspect(reason)}")
    end
  end

  defp upsert_backbone_link_payload(payload) do
    cypher = """
    MERGE (a:Device {id: '#{Graph.escape(payload.local_device_id)}'})
    MERGE (b:Device {id: '#{Graph.escape(payload.neighbor_device_id)}'})
    #{set_prop("b", "name", payload.neighbor_name)}
    #{set_prop("b", "ip", payload.neighbor_ip)}
    MERGE (ai:Interface {id: '#{Graph.escape(payload.local_interface_id)}'})
    SET ai.device_id = '#{Graph.escape(payload.local_device_id)}'
    #{set_prop("ai", "name", payload.local_if_name)}
    #{set_prop("ai", "ifindex", payload.local_if_index)}
    MERGE (bi:Interface {id: '#{Graph.escape(payload.neighbor_interface_id)}'})
    SET bi.device_id = '#{Graph.escape(payload.neighbor_device_id)}'
    #{set_prop("bi", "name", payload.neighbor_port_name)}
    MERGE (a)-[r1:HAS_INTERFACE]->(ai)
    SET r1.source = 'mapper'
    MERGE (b)-[r2:HAS_INTERFACE]->(bi)
    SET r2.source = 'mapper'
    MERGE (ai)-[r:CONNECTS_TO]->(bi)
    SET r.first_observed_at = coalesce(r.first_observed_at, '#{Graph.escape(payload.observed_at)}')
    SET r.ingestor = 'mapper_topology_v1'
    SET r.source = '#{Graph.escape(payload.protocol)}'
    SET r.protocol = '#{Graph.escape(payload.protocol)}'
    SET r.confidence_tier = '#{Graph.escape(payload.confidence_tier)}'
    SET r.confidence_score = #{payload.confidence_score}
    SET r.confidence_reason = '#{Graph.escape(payload.confidence_reason)}'
    SET r.evidence_class = '#{Graph.escape(normalize_evidence_class(payload.evidence_class))}'
    SET r.observed_at = '#{Graph.escape(payload.observed_at)}'
    SET r.last_observed_at = '#{Graph.escape(payload.observed_at)}'
    MERGE (bi)-[rr:CONNECTS_TO]->(ai)
    SET rr.first_observed_at = coalesce(rr.first_observed_at, '#{Graph.escape(payload.observed_at)}')
    SET rr.ingestor = 'mapper_topology_v1'
    SET rr.source = '#{Graph.escape(payload.protocol)}'
    SET rr.protocol = '#{Graph.escape(payload.protocol)}'
    SET rr.confidence_tier = '#{Graph.escape(payload.confidence_tier)}'
    SET rr.confidence_score = #{payload.confidence_score}
    SET rr.confidence_reason = '#{Graph.escape(payload.confidence_reason)}'
    SET rr.evidence_class = '#{Graph.escape(normalize_evidence_class(payload.evidence_class))}'
    SET rr.observed_at = '#{Graph.escape(payload.observed_at)}'
    SET rr.last_observed_at = '#{Graph.escape(payload.observed_at)}'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Topology graph upsert failed: #{inspect(reason)}")
    end
  end

  defp neighbor_device_id(link) do
    link_value(link, :neighbor_device_id) ||
      link_value(link, :neighbor_mgmt_addr) ||
      link_value(link, :neighbor_chassis_id) ||
      link_value(link, :neighbor_system_name)
  end

  defp backbone_projectable_link?(payload) when is_map(payload) do
    evidence_class = normalize_evidence_class(payload.evidence_class)
    protocol = normalize_protocol(payload.protocol)

    MapSet.member?(@direct_evidence_classes, evidence_class) and
      MapSet.member?(@direct_protocols, protocol) and
      interface_contract_valid?(protocol, payload)
  end

  defp backbone_projectable_link?(_payload), do: false

  defp auxiliary_evidence_link?(payload) when is_map(payload) do
    evidence_class = normalize_evidence_class(payload.evidence_class)
    inferred_allowed = inferred_evidence_projectable?(payload)
    attachment_allowed = MapSet.member?(@attachment_evidence_classes, evidence_class)

    inferred_allowed or attachment_allowed
  end

  defp auxiliary_evidence_link?(_payload), do: false

  defp projection_mode(payload) when is_map(payload) do
    cond do
      backbone_projectable_link?(payload) -> {:backbone, :projected_backbone}
      auxiliary_evidence_link?(payload) -> {:auxiliary, auxiliary_reason(payload)}
      true -> {:skip, skip_reason(payload)}
    end
  end

  defp auxiliary_reason(payload) do
    case evidence_relation_type(payload) do
      "ATTACHED_TO" -> :projected_attachment
      "INFERRED_TO" -> :projected_inferred
      _ -> :projected_observed
    end
  end

  defp skip_reason(payload) do
    evidence_class = normalize_evidence_class(payload.evidence_class)
    confidence_reason = normalize_confidence_reason(payload.confidence_reason)
    protocol = normalize_protocol(payload.protocol)
    strict_ifindex? = MapSet.member?(@strict_ifindex_protocols, protocol)

    cond do
      confidence_reason == "single_identifier_inference" and
          not allow_single_identifier_inference_projection?(payload) ->
        :skip_single_identifier_inference

      strict_ifindex? and not valid_ifindex?(payload.local_if_index) ->
        :skip_missing_ifindex

      MapSet.member?(@inferred_evidence_classes, evidence_class) ->
        :skip_inferred_low_confidence

      true ->
        :skip_policy_filtered
    end
  end

  defp empty_projection_diagnostics do
    %{accepted: %{}, rejected: %{}, total: 0}
  end

  defp increment_diagnostic(diag, bucket, reason) when is_map(diag) do
    reason_key = to_string(reason || :unknown)

    diag
    |> update_in([bucket, reason_key], fn
      nil -> 1
      existing -> existing + 1
    end)
    |> Map.update!(:total, &(&1 + 1))
  end

  defp inferred_evidence_projectable?(payload) when is_map(payload) do
    evidence_class = normalize_evidence_class(payload.evidence_class)
    confidence_tier = normalize_confidence_tier(payload.confidence_tier)
    confidence_reason = normalize_confidence_reason(payload.confidence_reason)

    MapSet.member?(@inferred_evidence_classes, evidence_class) and
      (confidence_reason != "single_identifier_inference" or
         allow_single_identifier_inference_projection?(payload)) and
      (confidence_tier in ["high", "medium"] or payload.confidence_score >= 60)
  end

  defp inferred_evidence_projectable?(_payload), do: false

  defp allow_single_identifier_inference_projection?(payload) when is_map(payload) do
    protocol = normalize_protocol(payload.protocol)
    confidence_tier = normalize_confidence_tier(payload.confidence_tier)

    protocol == "snmp-l2" and confidence_tier in ["high", "medium"]
  end

  defp allow_single_identifier_inference_projection?(_payload), do: false

  defp evidence_relation_type(payload) do
    evidence_class = normalize_evidence_class(payload.evidence_class)

    cond do
      MapSet.member?(@attachment_evidence_classes, evidence_class) -> "ATTACHED_TO"
      MapSet.member?(@inferred_evidence_classes, evidence_class) -> "INFERRED_TO"
      true -> "OBSERVED_TO"
    end
  end

  defp upsert_auxiliary_link_payload(payload) do
    relation = evidence_relation_type(payload)

    cypher = """
    MERGE (a:Device {id: '#{Graph.escape(payload.local_device_id)}'})
    MERGE (b:Device {id: '#{Graph.escape(payload.neighbor_device_id)}'})
    #{set_prop("b", "name", payload.neighbor_name)}
    #{set_prop("b", "ip", payload.neighbor_ip)}
    MERGE (ai:Interface {id: '#{Graph.escape(payload.local_interface_id)}'})
    SET ai.device_id = '#{Graph.escape(payload.local_device_id)}'
    #{set_prop("ai", "name", payload.local_if_name)}
    #{set_prop("ai", "ifindex", payload.local_if_index)}
    MERGE (bi:Interface {id: '#{Graph.escape(payload.neighbor_interface_id)}'})
    SET bi.device_id = '#{Graph.escape(payload.neighbor_device_id)}'
    #{set_prop("bi", "name", payload.neighbor_port_name)}
    MERGE (a)-[r1:HAS_INTERFACE]->(ai)
    SET r1.source = 'mapper'
    MERGE (b)-[r2:HAS_INTERFACE]->(bi)
    SET r2.source = 'mapper'
    MERGE (ai)-[r:#{relation}]->(bi)
    SET r.first_observed_at = coalesce(r.first_observed_at, '#{Graph.escape(payload.observed_at)}')
    SET r.ingestor = 'mapper_topology_v1'
    SET r.source = '#{Graph.escape(payload.protocol)}'
    SET r.protocol = '#{Graph.escape(payload.protocol)}'
    SET r.evidence_class = '#{Graph.escape(normalize_evidence_class(payload.evidence_class))}'
    SET r.confidence_tier = '#{Graph.escape(payload.confidence_tier)}'
    SET r.confidence_score = #{payload.confidence_score}
    SET r.confidence_reason = '#{Graph.escape(payload.confidence_reason)}'
    SET r.observed_at = '#{Graph.escape(payload.observed_at)}'
    SET r.last_observed_at = '#{Graph.escape(payload.observed_at)}'
    """

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Auxiliary topology graph upsert failed: #{inspect(reason)}")
    end
  end

  defp interface_contract_valid?(protocol, payload) do
    if MapSet.member?(@strict_ifindex_protocols, protocol) do
      valid_ifindex?(payload.local_if_index)
    else
      true
    end
  end

  defp valid_ifindex?(value) when is_integer(value), do: value > 0
  defp valid_ifindex?(_value), do: false

  defp confidence_tier(link, metadata) do
    link_value(link, :confidence_tier) ||
      map_value(metadata, :confidence_tier) ||
      "low"
  end

  defp confidence_score(link, metadata) do
    link_value(link, :confidence_score)
    |> parse_confidence_score()
    |> case do
      nil ->
        metadata
        |> map_value(:confidence_score)
        |> parse_confidence_score()
        |> Kernel.||(0)

      score ->
        score
    end
  end

  defp confidence_reason(link, metadata) do
    link_value(link, :confidence_reason) ||
      map_value(metadata, :confidence_reason) ||
      "unspecified"
  end

  defp observed_at(link) do
    case link_value(link, :timestamp) do
      %DateTime{} = dt ->
        dt
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      value when is_binary(value) ->
        value

      _ ->
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
    end
  end

  defp prune_unseen_projected_links(neighbor_index) when map_size(neighbor_index) == 0, do: :ok

  defp prune_unseen_projected_links(neighbor_index) do
    Enum.each(neighbor_index, fn {local_device_id, neighbor_ids} ->
      escaped_local = Graph.escape(local_device_id)

      allowed_neighbors =
        neighbor_ids
        |> MapSet.to_list()
        |> Enum.map_join(", ", &"'#{Graph.escape(&1)}'")

      cypher = """
      MATCH (a:Interface)-[r:CONNECTS_TO]->(b:Interface)
      WHERE a.device_id = '#{escaped_local}'
        AND r.ingestor = 'mapper_topology_v1'
        AND (b.device_id IS NULL OR NOT b.device_id IN [#{allowed_neighbors}])
      DELETE r
      """

      case Graph.execute(cypher) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Topology unseen edge pruning failed: #{inspect(reason)}")
      end
    end)
  end

  defp maybe_prune_unseen_projected_links(neighbor_index) do
    if prune_unseen_projected_links_enabled?() do
      prune_unseen_projected_links(neighbor_index)
    else
      :ok
    end
  end

  defp prune_unseen_projected_links_enabled? do
    Application.get_env(
      :serviceradar_core,
      :mapper_topology_prune_unseen_projected_links_enabled,
      false
    ) == true
  end

  defp prune_stale_projected_links([]), do: :ok

  defp prune_stale_projected_links(local_device_ids) do
    stale_cutoff = stale_cutoff_iso8601()
    escaped_ids = Enum.map_join(local_device_ids, ", ", &"'#{Graph.escape(&1)}'")

    cypher = """
    MATCH (a:Interface)-[r:CONNECTS_TO]->(:Interface)
    WHERE a.device_id IN [#{escaped_ids}]
      AND r.ingestor = 'mapper_topology_v1'
      AND r.last_observed_at IS NOT NULL
      AND r.last_observed_at < '#{Graph.escape(stale_cutoff)}'
    DELETE r
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Topology stale edge pruning failed: #{inspect(reason)}")
    end
  end

  defp maybe_prune_stale_projected_links(local_device_ids) do
    if prune_stale_projected_links_enabled?() do
      prune_stale_projected_links(local_device_ids)
    else
      :ok
    end
  end

  defp prune_stale_mapper_evidence_links do
    stale_cutoff = stale_cutoff_iso8601()

    cypher = """
    MATCH ()-[r]->()
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO']
      AND r.last_observed_at IS NOT NULL
      AND r.last_observed_at < '#{Graph.escape(stale_cutoff)}'
    DELETE r
    """

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Topology global stale edge pruning failed: #{inspect(reason)}")
    end
  end

  defp maybe_prune_stale_mapper_evidence_links do
    if prune_stale_projected_links_enabled?() do
      prune_stale_mapper_evidence_links()
    else
      :ok
    end
  end

  defp rebuild_canonical_device_links do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()
    stale_cutoff = stale_cutoff_iso8601()
    upsert_cypher = canonical_rebuild_upsert_query(stale_cutoff)

    case Graph.execute(upsert_cypher) do
      :ok ->
        after_upsert_edges = canonical_edge_count()
        prune_result = prune_stale_canonical_device_links(stale_cutoff)
        after_prune_edges = canonical_edge_count()

        stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          after_upsert_edges: after_upsert_edges,
          after_prune_edges: after_prune_edges,
          stale_cutoff: stale_cutoff
        }

        Logger.info("canonical_topology_rebuild_stats #{inspect(stats)}")
        {:ok, Map.put(stats, :prune_result, prune_result)}

      {:error, reason} ->
        Logger.warning("Canonical topology rebuild failed: #{inspect(reason)}")

        {:error, reason,
         %{
           before_edges: before_edges,
           mapper_evidence_edges: mapper_evidence_edges,
           stale_cutoff: stale_cutoff
         }}
    end
  end

  defp prune_stale_canonical_device_links(stale_cutoff) when is_binary(stale_cutoff) do
    prune_cypher = canonical_rebuild_prune_query(stale_cutoff)

    case Graph.execute(prune_cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Canonical topology stale-edge prune failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  @spec canonical_edge_count_query() :: String.t()
  def canonical_edge_count_query do
    """
    MATCH ()-[r:CANONICAL_TOPOLOGY]->()
    RETURN {count: count(r)}
    """
  end

  @doc false
  @spec mapper_evidence_edge_count_query() :: String.t()
  def mapper_evidence_edge_count_query do
    """
    MATCH ()-[r]->()
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']
    RETURN {count: count(r)}
    """
  end

  defp canonical_edge_count do
    edge_count_from_query(canonical_edge_count_query())
  end

  defp mapper_evidence_edge_count do
    edge_count_from_query(mapper_evidence_edge_count_query())
  end

  defp edge_count_from_query(cypher) when is_binary(cypher) do
    case Graph.query(cypher) do
      {:ok, [row | _]} ->
        row
        |> map_value(:count)
        |> parse_count()

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning("Topology edge count query failed: #{inspect(reason)}")
        0
    end
  end

  defp parse_count(value) when is_integer(value) and value >= 0, do: value

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_count(_), do: 0

  @doc false
  @spec canonical_rebuild_upsert_query(String.t()) :: String.t()
  def canonical_rebuild_upsert_query(stale_cutoff) when is_binary(stale_cutoff) do
    """
    MATCH (ai:Interface)-[r]->(bi:Interface)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']
      AND (r.last_observed_at IS NULL OR r.last_observed_at >= '#{Graph.escape(stale_cutoff)}')
      AND ai.device_id IS NOT NULL
      AND bi.device_id IS NOT NULL
      AND ai.device_id STARTS WITH 'sr:'
      AND bi.device_id STARTS WITH 'sr:'
      AND ai.device_id <> bi.device_id
    WITH
      CASE WHEN ai.device_id <= bi.device_id THEN ai.device_id ELSE bi.device_id END AS src_id,
      CASE WHEN ai.device_id <= bi.device_id THEN bi.device_id ELSE ai.device_id END AS dst_id,
      CASE
        WHEN ai.device_id <= bi.device_id THEN CASE WHEN ai.ifindex > 0 THEN ai.ifindex ELSE NULL END
        ELSE CASE WHEN bi.ifindex > 0 THEN bi.ifindex ELSE NULL END
      END AS local_if_index,
      CASE
        WHEN ai.device_id <= bi.device_id THEN CASE WHEN bi.ifindex > 0 THEN bi.ifindex ELSE NULL END
        ELSE CASE WHEN ai.ifindex > 0 THEN ai.ifindex ELSE NULL END
      END AS neighbor_if_index,
      coalesce(CASE WHEN ai.device_id <= bi.device_id THEN ai.name ELSE bi.name END, 'unknown') AS local_if_name,
      coalesce(CASE WHEN ai.device_id <= bi.device_id THEN bi.name ELSE ai.name END, 'unknown') AS neighbor_if_name,
      type(r) AS relation_type,
      coalesce(r.protocol, r.source, 'unknown') AS protocol,
      coalesce(r.evidence_class, 'inferred') AS evidence_class,
      coalesce(r.confidence_tier, 'unknown') AS confidence_tier,
      coalesce(r.confidence_score, 0) AS confidence_score,
      coalesce(r.confidence_reason, 'unspecified') AS confidence_reason,
      coalesce(r.last_observed_at, r.observed_at) AS last_observed_at,
      CASE type(r)
        WHEN 'CONNECTS_TO' THEN 4
        WHEN 'INFERRED_TO' THEN 3
        WHEN 'ATTACHED_TO' THEN 2
        ELSE 1
      END AS rel_rank,
      CASE coalesce(r.confidence_tier, '')
        WHEN 'high' THEN 3
        WHEN 'medium' THEN 2
        WHEN 'low' THEN 1
        ELSE 0
      END AS conf_rank
    WITH
      src_id,
      dst_id,
      local_if_index,
      neighbor_if_index,
      local_if_name,
      neighbor_if_name,
      relation_type,
      protocol,
      evidence_class,
      confidence_tier,
      confidence_score,
      confidence_reason,
      last_observed_at,
      rel_rank,
      conf_rank
    ORDER BY
      src_id,
      dst_id,
      rel_rank DESC,
      conf_rank DESC,
      last_observed_at DESC
    WITH src_id, dst_id, collect({
      relation_type: relation_type,
      protocol: protocol,
      evidence_class: evidence_class,
      confidence_tier: confidence_tier,
      confidence_score: confidence_score,
      confidence_reason: confidence_reason,
      last_observed_at: last_observed_at,
      local_if_index: local_if_index,
      neighbor_if_index: neighbor_if_index,
      local_if_name: local_if_name,
      neighbor_if_name: neighbor_if_name
    }) AS candidates
    WITH src_id, dst_id, head(candidates) AS best, candidates
    UNWIND candidates AS c
    WITH
      src_id,
      dst_id,
      best,
      max(CASE WHEN c.local_if_index IS NOT NULL AND c.local_if_index > 0 THEN c.local_if_index ELSE -1 END) AS best_local_if_index,
      max(CASE WHEN c.neighbor_if_index IS NOT NULL AND c.neighbor_if_index > 0 THEN c.neighbor_if_index ELSE -1 END) AS best_neighbor_if_index,
      max(CASE WHEN c.local_if_name IS NOT NULL AND c.local_if_name <> '' AND toLower(c.local_if_name) <> 'unknown' THEN c.local_if_name ELSE '' END) AS best_local_if_name,
      max(CASE WHEN c.neighbor_if_name IS NOT NULL AND c.neighbor_if_name <> '' AND toLower(c.neighbor_if_name) <> 'unknown' THEN c.neighbor_if_name ELSE '' END) AS best_neighbor_if_name
    MERGE (a:Device {id: src_id})
    MERGE (b:Device {id: dst_id})
    MERGE (a)-[cr:CANONICAL_TOPOLOGY]->(b)
    SET cr.ingestor = 'mapper_topology_v1'
    SET cr.relation_type = best.relation_type
    SET cr.protocol = best.protocol
    SET cr.evidence_class = best.evidence_class
    SET cr.confidence_tier = best.confidence_tier
    SET cr.confidence_score = best.confidence_score
    SET cr.confidence_reason = best.confidence_reason
    SET cr.last_observed_at = best.last_observed_at
    SET cr.local_if_index =
      CASE
        WHEN best_local_if_index > 0 THEN best_local_if_index
        ELSE best.local_if_index
      END
    SET cr.neighbor_if_index =
      CASE
        WHEN best_neighbor_if_index > 0 THEN best_neighbor_if_index
        ELSE best.neighbor_if_index
      END
    SET cr.local_if_name =
      CASE
        WHEN best_local_if_name <> '' THEN best_local_if_name
        ELSE best.local_if_name
      END
    SET cr.neighbor_if_name =
      CASE
        WHEN best_neighbor_if_name <> '' THEN best_neighbor_if_name
        ELSE best.neighbor_if_name
      END
    """
  end

  @doc false
  @spec canonical_rebuild_prune_query(String.t()) :: String.t()
  def canonical_rebuild_prune_query(stale_cutoff) when is_binary(stale_cutoff) do
    """
    MATCH ()-[r:CANONICAL_TOPOLOGY]->()
    WHERE r.ingestor = 'mapper_topology_v1'
      AND r.last_observed_at IS NOT NULL
      AND r.last_observed_at < '#{Graph.escape(stale_cutoff)}'
    DELETE r
    """
  end

  @doc false
  @spec prune_stale_projected_links_enabled?() :: boolean()
  def prune_stale_projected_links_enabled? do
    Application.get_env(
      :serviceradar_core,
      :mapper_topology_prune_stale_projected_links_enabled,
      false
    ) == true
  end

  defp stale_cutoff_iso8601 do
    stale_minutes =
      Application.get_env(
        :serviceradar_core,
        :mapper_topology_edge_stale_minutes,
        @default_stale_minutes
      )
      |> normalize_positive_int(@default_stale_minutes)

    DateTime.utc_now()
    |> DateTime.add(-stale_minutes * 60, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default

  defp parse_confidence_score(value) when is_integer(value), do: value

  defp parse_confidence_score(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_confidence_score(_value), do: nil

  defp normalize_protocol(nil), do: "unknown"

  defp normalize_protocol(protocol) do
    protocol
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_evidence_class(nil), do: "inferred"

  defp normalize_evidence_class(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_confidence_tier(nil), do: "low"

  defp normalize_confidence_tier(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_confidence_reason(nil), do: ""

  defp normalize_confidence_reason(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp default_evidence_class_for_protocol(protocol) do
    if MapSet.member?(@direct_protocols, normalize_protocol(protocol)) do
      "direct"
    else
      "inferred"
    end
  end

  defp link_value(link, key) do
    Map.get(link, key) || Map.get(link, to_string(key))
  end

  defp interface_id(nil, _if_name, _if_index), do: nil

  defp interface_id(device_id, if_name, if_index) do
    cond do
      is_binary(if_name) and String.trim(if_name) != "" ->
        "#{device_id}/#{String.trim(if_name)}"

      is_integer(if_index) ->
        "#{device_id}/ifindex:#{if_index}"

      true ->
        nil
    end
  end

  defp default_interface_id(nil, _label), do: nil
  defp default_interface_id(device_id, label), do: "#{device_id}/#{label}"

  defp non_blank(nil), do: nil

  defp non_blank(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.downcase(trimmed) in ["nil", "null", "undefined"] -> nil
      true -> trimmed
    end
  end

  defp non_blank(value) when is_atom(value) do
    if value in [nil, :null, :undefined], do: nil, else: Atom.to_string(value)
  end

  defp non_blank(value), do: value |> to_string() |> non_blank()

  defp set_prop(_node, _field, nil), do: ""
  defp set_prop(_node, _field, ""), do: ""

  defp set_prop(node, field, value) when is_list(value) do
    list = Enum.map_join(value, ", ", &cypher_value/1)
    "SET #{node}.#{field} = [#{list}]"
  end

  defp set_prop(node, field, value) do
    "SET #{node}.#{field} = #{cypher_value(value)}"
  end

  defp cypher_value(value) when is_integer(value), do: Integer.to_string(value)
  defp cypher_value(value) when is_float(value), do: Float.to_string(value)
  defp cypher_value(value) when is_binary(value), do: "'#{Graph.escape(value)}'"
  defp cypher_value(value) when is_atom(value), do: "'#{Graph.escape(value)}'"
  defp cypher_value(_value), do: "null"
end
