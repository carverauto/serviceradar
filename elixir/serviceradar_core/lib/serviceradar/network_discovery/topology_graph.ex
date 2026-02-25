defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Apache AGE graph.
  """

  import Ecto.Query

  require Logger

  alias ServiceRadar.Graph
  alias ServiceRadar.Repo
  @default_stale_minutes 180
  @telemetry_window_minutes 30
  @telemetry_min_sample_spacing_seconds 20
  @telemetry_max_samples_per_series 8
  @packet_metric_names ["ifInUcastPkts", "ifOutUcastPkts", "ifHCInUcastPkts", "ifHCOutUcastPkts"]
  @octet_metric_names ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"]
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
         neighbor_if_index: link_value(link, :neighbor_if_index),
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
    #{set_prop("bi", "ifindex", payload.neighbor_if_index)}
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
    #{set_prop("r", "local_if_index", payload.local_if_index)}
    #{set_prop("r", "neighbor_if_index", payload.neighbor_if_index)}
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
    #{set_prop("rr", "local_if_index", payload.neighbor_if_index)}
    #{set_prop("rr", "neighbor_if_index", payload.local_if_index)}
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
    stale_cutoff = stale_cutoff_iso8601()
    upsert_cypher = canonical_rebuild_upsert_query(stale_cutoff)

    case Graph.execute(upsert_cypher) do
      :ok ->
        refresh_canonical_edge_telemetry(stale_cutoff)
        prune_stale_canonical_device_links(stale_cutoff)
        prune_non_canonical_device_links()

      {:error, reason} ->
        Logger.warning("Canonical topology rebuild failed: #{inspect(reason)}")
    end
  end

  defp prune_stale_canonical_device_links(stale_cutoff) when is_binary(stale_cutoff) do
    prune_cypher = canonical_rebuild_prune_query(stale_cutoff)

    case Graph.execute(prune_cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Canonical topology stale-edge prune failed: #{inspect(reason)}")
    end
  end

  defp prune_non_canonical_device_links do
    cypher = """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE NOT (
      a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
    )
    DELETE r
    """

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Canonical topology non-canonical edge prune failed: #{inspect(reason)}")
    end
  end

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
        WHEN ai.device_id <= bi.device_id THEN coalesce(
          CASE WHEN ai.ifindex > 0 THEN ai.ifindex ELSE NULL END,
          CASE WHEN r.local_if_index > 0 THEN r.local_if_index ELSE NULL END
        )
        ELSE coalesce(
          CASE WHEN bi.ifindex > 0 THEN bi.ifindex ELSE NULL END,
          CASE WHEN r.neighbor_if_index > 0 THEN r.neighbor_if_index ELSE NULL END
        )
      END AS local_if_index,
      CASE
        WHEN ai.device_id <= bi.device_id THEN coalesce(
          CASE WHEN bi.ifindex > 0 THEN bi.ifindex ELSE NULL END,
          CASE WHEN r.neighbor_if_index > 0 THEN r.neighbor_if_index ELSE NULL END
        )
        ELSE coalesce(
          CASE WHEN ai.ifindex > 0 THEN ai.ifindex ELSE NULL END,
          CASE WHEN r.local_if_index > 0 THEN r.local_if_index ELSE NULL END
        )
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
      conf_rank,
      CASE
        WHEN local_if_index > 0 AND neighbor_if_index > 0 THEN 2
        WHEN local_if_index > 0 OR neighbor_if_index > 0 THEN 1
        ELSE 0
      END AS ifindex_rank
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
      conf_rank,
      ifindex_rank
    ORDER BY
      src_id,
      dst_id,
      ifindex_rank DESC,
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
    WITH src_id, dst_id, head(candidates) AS best
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
    SET cr.local_if_index = best.local_if_index
    SET cr.neighbor_if_index = best.neighbor_if_index
    SET cr.local_if_name = best.local_if_name
    SET cr.neighbor_if_name = best.neighbor_if_name
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

  defp refresh_canonical_edge_telemetry(stale_cutoff) when is_binary(stale_cutoff) do
    with {:ok, edges} <- fetch_canonical_edges(stale_cutoff) do
      metric_keys = telemetry_metric_keys(edges)
      pps_by_if = load_packet_metrics(metric_keys)
      bps_by_if = load_bps_metrics(metric_keys)
      capacity_by_if = load_interface_capacity(metric_keys)

      stats =
        Enum.reduce(edges, empty_canonical_telemetry_stats(), fn edge, acc ->
          telemetry = compute_edge_telemetry(edge, pps_by_if, bps_by_if, capacity_by_if)
          persist_canonical_edge_telemetry(edge, telemetry)
          update_canonical_telemetry_stats(acc, telemetry)
        end)

      Logger.info(
        "canonical_edge_telemetry_stats #{inspect(Map.put(stats, :total_edges, length(edges)))}"
      )
    else
      {:error, reason} ->
        Logger.warning("Canonical edge telemetry refresh failed: #{inspect(reason)}")
    end
  end

  defp fetch_canonical_edges(stale_cutoff) when is_binary(stale_cutoff) do
    cypher = """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
      AND (r.last_observed_at IS NULL OR r.last_observed_at >= '#{Graph.escape(stale_cutoff)}')
    RETURN {
      src_id: a.id,
      dst_id: b.id,
      local_if_index: r.local_if_index,
      neighbor_if_index: r.neighbor_if_index
    }
    """

    case Graph.query(cypher) do
      {:ok, rows} when is_list(rows) ->
        {:ok,
         Enum.reduce(rows, [], fn row, acc ->
           src_id = map_value(row, :src_id)
           dst_id = map_value(row, :dst_id)
           local_if_index = parse_ifindex(map_value(row, :local_if_index))
           neighbor_if_index = parse_ifindex(map_value(row, :neighbor_if_index))

           if is_binary(src_id) and is_binary(dst_id) and src_id != dst_id do
             [
               %{
                 src_id: src_id,
                 dst_id: dst_id,
                 local_if_index: local_if_index,
                 neighbor_if_index: neighbor_if_index
               }
               | acc
             ]
           else
             acc
           end
         end)
         |> Enum.reverse()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp telemetry_metric_keys(edges) when is_list(edges) do
    edges
    |> Enum.flat_map(fn edge ->
      src_id = map_value(edge, :src_id)
      dst_id = map_value(edge, :dst_id)
      local_if_index = map_value(edge, :local_if_index)
      neighbor_if_index = map_value(edge, :neighbor_if_index)

      [
        if(is_binary(src_id) and is_integer(local_if_index) and local_if_index > 0,
          do: {src_id, local_if_index}
        ),
        if(is_binary(dst_id) and is_integer(neighbor_if_index) and neighbor_if_index > 0,
          do: {dst_id, neighbor_if_index}
        )
      ]
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq()
  end

  defp load_packet_metrics([]), do: %{}

  defp load_packet_metrics(metric_keys) when is_list(metric_keys) do
    device_ids = metric_keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = metric_keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    query =
      from(m in "timeseries_metrics",
        where: m.device_id in ^device_ids,
        where: m.if_index in ^if_indexes,
        where: m.metric_name in ^@packet_metric_names,
        where: m.timestamp > ago(@telemetry_window_minutes, "minute"),
        order_by: [asc: m.device_id, asc: m.if_index, asc: m.metric_name, desc: m.timestamp],
        select: {m.device_id, m.if_index, m.metric_name, m.timestamp, m.value}
      )

    query
    |> Repo.all()
    |> rates_by_interface(&packet_metric_direction/1, fn rate -> rate end)
  rescue
    _ -> %{}
  end

  defp load_bps_metrics([]), do: %{}

  defp load_bps_metrics(metric_keys) when is_list(metric_keys) do
    device_ids = metric_keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = metric_keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    query =
      from(m in "timeseries_metrics",
        where: m.device_id in ^device_ids,
        where: m.if_index in ^if_indexes,
        where: m.metric_name in ^@octet_metric_names,
        where: m.timestamp > ago(@telemetry_window_minutes, "minute"),
        order_by: [asc: m.device_id, asc: m.if_index, asc: m.metric_name, desc: m.timestamp],
        select: {m.device_id, m.if_index, m.metric_name, m.timestamp, m.value}
      )

    query
    |> Repo.all()
    |> rates_by_interface(&octet_metric_direction/1, fn rate -> rate * 8 end)
  rescue
    _ -> %{}
  end

  defp rates_by_interface(rows, direction_fun, unit_fun)
       when is_list(rows) and is_function(direction_fun, 1) and is_function(unit_fun, 1) do
    rows
    |> Enum.reduce(%{}, fn {device_id, if_index, metric_name, ts, value}, acc ->
      key = {to_string(device_id), if_index, metric_name}

      with numeric when is_integer(numeric) <- value_to_non_negative_int(value),
           timestamp when not is_nil(timestamp) <- normalize_timestamp(ts) do
        update_metric_samples(acc, key, {timestamp, numeric})
      else
        _ -> acc
      end
    end)
    |> Enum.reduce(%{}, fn {{device_id, if_index, metric_name}, samples}, acc ->
      dir = direction_fun.(metric_name)
      rate = samples_to_rate_per_second(metric_name, samples)

      if is_nil(dir) or is_nil(rate) do
        acc
      else
        key = {device_id, if_index}
        scaled = non_negative_int(unit_fun.(rate)) || 0

        Map.update(acc, key, %{dir => scaled}, fn existing ->
          Map.update(existing, dir, scaled, &max(&1, scaled))
        end)
      end
    end)
  end

  defp update_metric_samples(grouped, key, sample) do
    Map.update(grouped, key, [sample], fn existing ->
      [sample | existing]
      |> Enum.sort_by(fn {timestamp, _value} -> timestamp end, {:desc, DateTime})
      |> Enum.take(@telemetry_max_samples_per_series)
    end)
  end

  defp samples_to_rate_per_second(metric_name, samples)
       when is_binary(metric_name) and is_list(samples) do
    samples
    |> Enum.sort_by(fn {timestamp, _value} -> timestamp end, {:desc, DateTime})
    |> adjacent_pairs()
    |> Enum.find_value(fn {{latest_ts, latest_value}, {prev_ts, prev_value}} ->
      sample_pair_rate(metric_name, latest_ts, latest_value, prev_ts, prev_value)
    end)
  end

  defp samples_to_rate_per_second(_, _), do: nil

  defp sample_pair_rate(
         metric_name,
         latest_ts,
         latest_value,
         prev_ts,
         prev_value
       )
       when is_binary(metric_name) and is_integer(latest_value) and is_integer(prev_value) do
    dt = DateTime.diff(latest_ts, prev_ts, :second)
    dv = counter_delta(metric_name, latest_value, prev_value)

    cond do
      dt < @telemetry_min_sample_spacing_seconds ->
        nil

      is_nil(dv) or dv < 0 ->
        nil

      true ->
        trunc(dv / dt)
    end
  end

  defp sample_pair_rate(_, _, _, _, _), do: nil

  defp adjacent_pairs([first, second | rest]),
    do: [{first, second} | adjacent_pairs([second | rest])]

  defp adjacent_pairs(_), do: []

  defp counter_delta(metric_name, latest_value, prev_value)
       when is_binary(metric_name) and is_integer(latest_value) and is_integer(prev_value) do
    cond do
      latest_value >= prev_value ->
        latest_value - prev_value

      counter32_metric?(metric_name) ->
        # Counter32 wrapped once between samples.
        latest_value + 4_294_967_296 - prev_value

      true ->
        # Counter64 wrap is practically impossible here; treat decrease as reset.
        nil
    end
  end

  defp counter_delta(_, _, _), do: nil

  defp counter32_metric?(metric_name)
       when metric_name in ["ifInOctets", "ifOutOctets", "ifInUcastPkts", "ifOutUcastPkts"],
       do: true

  defp counter32_metric?(_), do: false

  defp normalize_timestamp(%DateTime{} = dt), do: dt

  defp normalize_timestamp(%NaiveDateTime{} = ndt) do
    DateTime.from_naive(ndt, "Etc/UTC")
    |> case do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp normalize_timestamp(_), do: nil

  defp load_interface_capacity([]), do: %{}

  defp load_interface_capacity(metric_keys) when is_list(metric_keys) do
    device_ids = metric_keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = metric_keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    query =
      from(i in "discovered_interfaces",
        where: i.device_id in ^device_ids,
        where: i.if_index in ^if_indexes,
        distinct: [i.device_id, i.if_index],
        order_by: [asc: i.device_id, asc: i.if_index, desc: i.timestamp],
        select: {i.device_id, i.if_index, i.speed_bps, i.if_speed}
      )

    query
    |> Repo.all()
    |> Enum.reduce(%{}, fn {device_id, if_index, speed_bps, if_speed}, acc ->
      cap = non_negative_int(speed_bps) || non_negative_int(if_speed) || 0
      Map.put(acc, {to_string(device_id), if_index}, cap)
    end)
  rescue
    _ -> %{}
  end

  defp compute_edge_telemetry(edge, pps_by_if, bps_by_if, cap_by_if) do
    src_id = map_value(edge, :src_id)
    dst_id = map_value(edge, :dst_id)
    local_if_index = map_value(edge, :local_if_index)
    neighbor_if_index = map_value(edge, :neighbor_if_index)

    pps_ab_local = ifindex_metric(pps_by_if, src_id, local_if_index)
    pps_ba_local = ifindex_metric(pps_by_if, dst_id, neighbor_if_index)
    bps_ab_local = ifindex_metric(bps_by_if, src_id, local_if_index)
    bps_ba_local = ifindex_metric(bps_by_if, dst_id, neighbor_if_index)

    cap_ab = ifindex_capacity(cap_by_if, src_id, local_if_index)
    cap_ba = ifindex_capacity(cap_by_if, dst_id, neighbor_if_index)

    max_pps_ab = max_pps_for_capacity(cap_ab)
    max_pps_ba = max_pps_for_capacity(cap_ba)

    flow_pps_ab =
      (pps_ab_local && map_value(pps_ab_local, :out)) ||
        (pps_ba_local && map_value(pps_ba_local, :in)) || 0

    flow_pps_ba =
      (pps_ba_local && map_value(pps_ba_local, :out)) ||
        (pps_ab_local && map_value(pps_ab_local, :in)) || 0

    flow_bps_ab =
      (bps_ab_local && map_value(bps_ab_local, :out)) ||
        (bps_ba_local && map_value(bps_ba_local, :in)) || 0

    flow_bps_ba =
      (bps_ba_local && map_value(bps_ba_local, :out)) ||
        (bps_ab_local && map_value(bps_ab_local, :in)) || 0

    flow_pps_ab = sanitize_pps(flow_pps_ab, max_pps_ab)
    flow_pps_ba = sanitize_pps(flow_pps_ba, max_pps_ba)
    flow_bps_ab = sanitize_bps(flow_bps_ab, cap_ab)
    flow_bps_ba = sanitize_bps(flow_bps_ba, cap_ba)

    flow_pps = flow_pps_ab + flow_pps_ba
    flow_bps = flow_bps_ab + flow_bps_ba

    capacity_bps =
      cond do
        cap_ab > 0 and cap_ba > 0 -> min(cap_ab, cap_ba)
        cap_ab > 0 -> cap_ab
        cap_ba > 0 -> cap_ba
        true -> 0
      end

    telemetry_source = if flow_pps > 0 or flow_bps > 0, do: "interface", else: "none"

    %{
      flow_pps_ab: flow_pps_ab,
      flow_pps_ba: flow_pps_ba,
      flow_bps_ab: flow_bps_ab,
      flow_bps_ba: flow_bps_ba,
      flow_pps: flow_pps,
      flow_bps: flow_bps,
      capacity_bps: capacity_bps,
      telemetry_source: telemetry_source,
      telemetry_observed_at:
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp persist_canonical_edge_telemetry(edge, telemetry)
       when is_map(edge) and is_map(telemetry) do
    src_id = map_value(edge, :src_id)
    dst_id = map_value(edge, :dst_id)

    cypher = """
    MATCH (a:Device {id: '#{Graph.escape(src_id)}'})-[cr:CANONICAL_TOPOLOGY]->(b:Device {id: '#{Graph.escape(dst_id)}'})
    SET cr.flow_pps_ab = #{map_value(telemetry, :flow_pps_ab)}
    SET cr.flow_pps_ba = #{map_value(telemetry, :flow_pps_ba)}
    SET cr.flow_bps_ab = #{map_value(telemetry, :flow_bps_ab)}
    SET cr.flow_bps_ba = #{map_value(telemetry, :flow_bps_ba)}
    SET cr.flow_pps = #{map_value(telemetry, :flow_pps)}
    SET cr.flow_bps = #{map_value(telemetry, :flow_bps)}
    SET cr.capacity_bps = #{map_value(telemetry, :capacity_bps)}
    SET cr.telemetry_source = '#{Graph.escape(map_value(telemetry, :telemetry_source))}'
    SET cr.telemetry_observed_at = '#{Graph.escape(map_value(telemetry, :telemetry_observed_at))}'
    """

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Canonical edge telemetry upsert failed: #{inspect(reason)}")
    end
  end

  defp empty_canonical_telemetry_stats do
    %{both_sides: 0, one_side: 0, none: 0, interface_source: 0}
  end

  defp update_canonical_telemetry_stats(stats, telemetry) do
    has_ab = map_value(telemetry, :flow_pps_ab) > 0 or map_value(telemetry, :flow_bps_ab) > 0
    has_ba = map_value(telemetry, :flow_pps_ba) > 0 or map_value(telemetry, :flow_bps_ba) > 0

    stats =
      cond do
        has_ab and has_ba -> Map.update!(stats, :both_sides, &(&1 + 1))
        has_ab or has_ba -> Map.update!(stats, :one_side, &(&1 + 1))
        true -> Map.update!(stats, :none, &(&1 + 1))
      end

    if map_value(telemetry, :telemetry_source) == "interface" do
      Map.update!(stats, :interface_source, &(&1 + 1))
    else
      stats
    end
  end

  defp ifindex_metric(metrics, device_id, if_index)
       when is_map(metrics) and is_binary(device_id) and is_integer(if_index) and if_index > 0 do
    Map.get(metrics, {device_id, if_index})
  end

  defp ifindex_metric(_, _, _), do: nil

  defp ifindex_capacity(capacity, device_id, if_index)
       when is_map(capacity) and is_binary(device_id) and is_integer(if_index) and if_index > 0 do
    Map.get(capacity, {device_id, if_index}, 0)
  end

  defp ifindex_capacity(_, _, _), do: 0

  defp sanitize_bps(value, cap_bps)
       when is_integer(value) and value >= 0 and is_integer(cap_bps) do
    cond do
      cap_bps <= 0 -> value
      value > cap_bps * 2 -> 0
      true -> value
    end
  end

  defp sanitize_bps(_, _), do: 0

  defp sanitize_pps(value, max_pps)
       when is_integer(value) and value >= 0 and is_integer(max_pps) do
    cond do
      max_pps <= 0 -> value
      value > max_pps * 2 -> 0
      true -> value
    end
  end

  defp sanitize_pps(_, _), do: 0

  defp max_pps_for_capacity(cap_bps) when is_integer(cap_bps) and cap_bps > 0 do
    # Worst-case ~64-byte packets => cap_bps / (64 * 8)
    max(1, div(cap_bps, 512))
  end

  defp max_pps_for_capacity(_), do: 0

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

  defp value_to_non_negative_int(%Decimal{} = value) do
    value
    |> Decimal.round(0, :floor)
    |> Decimal.to_integer()
    |> non_negative_int()
  rescue
    _ -> nil
  end

  defp value_to_non_negative_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp value_to_non_negative_int(_), do: nil

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)
  defp non_negative_int(_), do: nil

  defp parse_ifindex(value) when is_integer(value) and value > 0, do: value

  defp parse_ifindex(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_ifindex(_), do: nil

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
