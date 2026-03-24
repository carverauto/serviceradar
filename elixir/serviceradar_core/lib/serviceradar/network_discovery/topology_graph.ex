defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Apache AGE graph.
  """

  import Ecto.Query

  alias ServiceRadar.Graph
  alias ServiceRadar.Repo

  require Logger

  @default_stale_minutes 180
  @telemetry_window_minutes 10
  @canonical_rebuild_lock_key 1_104_202_506
  @default_canonical_rebuild_timeout_ms 60_000
  @default_canonical_edge_telemetry_batch_size 100
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
    device_uid = non_blank(device_uid)
    management_device_uid = non_blank(management_device_uid)

    if is_nil(device_uid) or is_nil(management_device_uid) do
      :ok
    else
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
    neighbor_device_id = non_blank(neighbor_device_id(link))
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
         local_device_ip: link_value(link, :local_device_ip),
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
    cypher = backbone_link_upsert_query(payload)

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Topology graph upsert failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec backbone_link_upsert_query(map()) :: String.t()
  def backbone_link_upsert_query(payload) when is_map(payload) do
    """
    MERGE (a:Device {id: '#{Graph.escape(payload.local_device_id)}'})
    #{set_prop("a", "ip", payload.local_device_ip)}
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

  defp auxiliary_evidence_link?(payload) when is_map(payload) do
    evidence_class = normalize_evidence_class(payload.evidence_class)
    inferred_allowed = inferred_evidence_projectable?(payload)
    attachment_allowed = MapSet.member?(@attachment_evidence_classes, evidence_class)

    inferred_allowed or attachment_allowed
  end

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

      strict_ifindex? and not strict_protocol_interface_identity?(payload) ->
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
    reason_key = to_string(reason)

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

  defp allow_single_identifier_inference_projection?(payload) when is_map(payload) do
    protocol = normalize_protocol(payload.protocol)
    confidence_tier = normalize_confidence_tier(payload.confidence_tier)

    protocol == "snmp-l2" and confidence_tier in ["high", "medium"]
  end

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
    cypher = auxiliary_link_upsert_query(payload, relation)

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Auxiliary topology graph upsert failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec auxiliary_link_upsert_query(map(), String.t()) :: String.t()
  def auxiliary_link_upsert_query(payload, relation)
      when is_map(payload) and is_binary(relation) do
    """
    MERGE (a:Device {id: '#{Graph.escape(payload.local_device_id)}'})
    #{set_prop("a", "ip", payload.local_device_ip)}
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
  end

  defp interface_contract_valid?(protocol, payload) do
    if MapSet.member?(@strict_ifindex_protocols, protocol) do
      strict_protocol_interface_identity?(payload)
    else
      true
    end
  end

  defp strict_protocol_interface_identity?(payload) when is_map(payload) do
    valid_ifindex?(payload.local_if_index) or is_binary(non_blank(payload.local_if_name))
  end

  defp strict_protocol_interface_identity?(_payload), do: false

  defp valid_ifindex?(value) when is_integer(value), do: value > 0
  defp valid_ifindex?(_value), do: false

  defp confidence_tier(link, metadata) do
    link_value(link, :confidence_tier) ||
      map_value(metadata, :confidence_tier) ||
      "low"
  end

  defp confidence_score(link, metadata) do
    link
    |> link_value(:confidence_score)
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
    case with_canonical_rebuild_lock(&do_rebuild_canonical_device_links/0) do
      {:ok, {:ok, stats}} ->
        {:ok, stats}

      {:ok, {:error, reason, stats}} ->
        {:error, reason, stats}

      {:ok, {:busy, stats}} ->
        emit_canonical_rebuild_telemetry(:completed, stats)
        Logger.debug("Canonical topology rebuild skipped; advisory lock busy")
        {:ok, stats}

      {:error, reason} ->
        failure_stats = lock_skipped_rebuild_stats()
        Logger.warning("Canonical topology rebuild lock acquisition failed: #{inspect(reason)}")
        emit_canonical_rebuild_telemetry(:failed, failure_stats, reason)
        {:error, reason, failure_stats}
    end
  end

  defp with_canonical_rebuild_lock(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [@canonical_rebuild_lock_key]) do
          {:ok, %{rows: [[true]]}} ->
            fun.()

          {:ok, %{rows: [[false]]}} ->
            {:busy, lock_skipped_rebuild_stats()}

          {:ok, _unexpected} ->
            Repo.rollback(:unexpected_lock_response)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      timeout: canonical_rebuild_timeout_ms()
    )
  end

  @doc false
  @spec canonical_rebuild_timeout_ms() :: pos_integer()
  def canonical_rebuild_timeout_ms do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:canonical_rebuild_timeout_ms, @default_canonical_rebuild_timeout_ms)
    |> normalize_positive_int(@default_canonical_rebuild_timeout_ms)
  end

  @doc false
  @spec canonical_edge_telemetry_batch_size() :: pos_integer()
  def canonical_edge_telemetry_batch_size do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(
      :canonical_edge_telemetry_batch_size,
      @default_canonical_edge_telemetry_batch_size
    )
    |> normalize_positive_int(@default_canonical_edge_telemetry_batch_size)
  end

  @doc false
  @spec canonical_edge_telemetry_batch_query([map()]) :: String.t()
  def canonical_edge_telemetry_batch_query(updates) when is_list(updates) do
    rows_literal = Enum.map_join(updates, ",\n", &canonical_edge_telemetry_update_literal/1)

    """
    UNWIND [#{rows_literal}] AS row
    MATCH (a:Device {id: row.src_id})-[r:CANONICAL_TOPOLOGY]->(b:Device {id: row.dst_id})
    WHERE r.ingestor = 'mapper_topology_v1'
    SET r.flow_pps = row.flow_pps
    SET r.flow_bps = row.flow_bps
    SET r.capacity_bps = row.capacity_bps
    SET r.flow_pps_ab = row.flow_pps_ab
    SET r.flow_pps_ba = row.flow_pps_ba
    SET r.flow_bps_ab = row.flow_bps_ab
    SET r.flow_bps_ba = row.flow_bps_ba
    SET r.telemetry_eligible = row.telemetry_eligible
    SET r.telemetry_source = row.telemetry_source
    SET r.telemetry_observed_at = row.telemetry_observed_at
    """
  end

  defp canonical_edge_telemetry_update_literal(update) when is_map(update) do
    [
      "src_id: #{cypher_value(Map.get(update, :src_id))}",
      "dst_id: #{cypher_value(Map.get(update, :dst_id))}",
      "flow_pps: #{cypher_value(Map.get(update, :flow_pps, 0))}",
      "flow_bps: #{cypher_value(Map.get(update, :flow_bps, 0))}",
      "capacity_bps: #{cypher_value(Map.get(update, :capacity_bps, 0))}",
      "flow_pps_ab: #{cypher_value(Map.get(update, :flow_pps_ab, 0))}",
      "flow_pps_ba: #{cypher_value(Map.get(update, :flow_pps_ba, 0))}",
      "flow_bps_ab: #{cypher_value(Map.get(update, :flow_bps_ab, 0))}",
      "flow_bps_ba: #{cypher_value(Map.get(update, :flow_bps_ba, 0))}",
      "telemetry_eligible: #{cypher_value(Map.get(update, :telemetry_eligible, false))}",
      "telemetry_source: #{cypher_value(Map.get(update, :telemetry_source, "none"))}",
      "telemetry_observed_at: #{cypher_value(Map.get(update, :telemetry_observed_at, ""))}"
    ]
    |> Enum.join(", ")
    |> then(&"{#{&1}}")
  end

  defp do_rebuild_canonical_device_links do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()
    stale_cutoff = stale_cutoff_iso8601()
    min_canonical_edges = canonical_rebuild_min_edges()
    upsert_cypher = canonical_rebuild_upsert_query(stale_cutoff)

    case Graph.execute(upsert_cypher) do
      :ok ->
        demotion_result = reconcile_competing_same_port_canonical_edges()
        after_upsert_edges = canonical_edge_count()
        prune_result = prune_stale_canonical_device_links(stale_cutoff)
        after_prune_edges = canonical_edge_count()
        telemetry_result = refresh_canonical_edge_telemetry(stale_cutoff)

        {after_prune_edges, self_heal_result} =
          maybe_self_heal_zero_canonical(
            after_prune_edges,
            mapper_evidence_edges,
            stale_cutoff,
            min_canonical_edges
          )

        stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          after_upsert_edges: after_upsert_edges,
          after_prune_edges: after_prune_edges,
          same_port_demotions: demotion_result,
          telemetry_refresh: telemetry_result,
          stale_cutoff: stale_cutoff,
          self_heal_result: self_heal_result,
          lock_skipped: false
        }

        emit_canonical_rebuild_telemetry(:completed, stats)
        Logger.info("canonical_topology_rebuild_stats #{inspect(stats)}")
        {:ok, Map.put(stats, :prune_result, prune_result)}

      {:error, reason} ->
        Logger.warning("Canonical topology rebuild failed: #{inspect(reason)}")

        failure_stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          same_port_demotions: :skipped,
          stale_cutoff: stale_cutoff,
          lock_skipped: false
        }

        emit_canonical_rebuild_telemetry(:failed, failure_stats, reason)
        {:error, reason, failure_stats}
    end
  end

  defp lock_skipped_rebuild_stats do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()

    %{
      before_edges: before_edges,
      mapper_evidence_edges: mapper_evidence_edges,
      after_upsert_edges: before_edges,
      after_prune_edges: before_edges,
      same_port_demotions: :skipped,
      telemetry_refresh: :skipped,
      stale_cutoff: stale_cutoff_iso8601(),
      self_heal_result: %{status: :skipped},
      prune_result: :skipped,
      lock_skipped: true
    }
  end

  defp reconcile_competing_same_port_canonical_edges do
    case Graph.query(competing_same_port_canonical_edges_query()) do
      {:ok, edges} ->
        edge_map = Map.new(edges, &{canonical_edge_key(&1), &1})

        demotions =
          edges
          |> Enum.flat_map(&edge_port_conflicts/1)
          |> Enum.group_by(fn {port_key, _edge_key} -> port_key end, fn {_port_key, edge_key} ->
            edge_key
          end)
          |> Enum.flat_map(fn {_port_key, edge_keys} ->
            demotions_for_port_group(edge_keys, edge_map)
          end)
          |> Enum.uniq()

        Enum.each(demotions, &demote_canonical_edge_to_attachment/1)
        {:ok, length(demotions)}

      {:error, reason} ->
        Logger.warning("Canonical same-port reconciliation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp competing_same_port_canonical_edges_query do
    """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND coalesce(r.relation_type, '') = 'CONNECTS_TO'
      AND coalesce(r.evidence_class, '') = 'direct'
    RETURN {
      src_id: a.id,
      dst_id: b.id,
      pair_support_rank: coalesce(r.pair_support_rank, 0),
      local_if_index_ab: coalesce(r.local_if_index_ab, r.local_if_index),
      local_if_name_ab: coalesce(r.local_if_name_ab, r.local_if_name, ''),
      local_if_index_ba: coalesce(r.local_if_index_ba, r.neighbor_if_index),
      local_if_name_ba: coalesce(r.local_if_name_ba, r.neighbor_if_name, '')
    }
    """
  end

  defp edge_port_conflicts(%{} = edge) do
    edge_key = canonical_edge_key(edge)

    [
      canonical_port_key(
        Map.get(edge, "src_id"),
        Map.get(edge, "local_if_index_ab"),
        Map.get(edge, "local_if_name_ab")
      ),
      canonical_port_key(
        Map.get(edge, "dst_id"),
        Map.get(edge, "local_if_index_ba"),
        Map.get(edge, "local_if_name_ba")
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1, edge_key})
  end

  defp edge_port_conflicts(_), do: []

  defp demotions_for_port_group(edge_keys, edge_map)
       when is_list(edge_keys) and is_map(edge_map) do
    group =
      edge_keys
      |> Enum.uniq()
      |> Enum.map(&Map.get(edge_map, &1))
      |> Enum.reject(&is_nil/1)

    if length(group) > 1 and Enum.any?(group, &(pair_support_rank(&1) > 0)) do
      group
      |> Enum.filter(&(pair_support_rank(&1) == 0))
      |> Enum.map(&canonical_edge_key/1)
    else
      []
    end
  end

  defp demotions_for_port_group(_edge_keys, _edge_map), do: []

  defp demote_canonical_edge_to_attachment({src_id, dst_id})
       when is_binary(src_id) and is_binary(dst_id) do
    cypher = """
    MATCH (a:Device {id: '#{Graph.escape(src_id)}'})-[r:CANONICAL_TOPOLOGY]->(b:Device {id: '#{Graph.escape(dst_id)}'})
    SET r.relation_type = 'ATTACHED_TO'
    SET r.evidence_class = 'endpoint-attachment'
    SET r.confidence_tier = 'medium'
    SET r.confidence_score = CASE WHEN coalesce(r.confidence_score, 0) > 78 THEN r.confidence_score ELSE 78 END
    SET r.confidence_reason = 'shared_segment_via_uplink'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Canonical edge demotion failed: #{inspect(reason)}")
    end
  end

  defp demote_canonical_edge_to_attachment(_edge_key), do: :ok

  defp canonical_edge_key(%{} = edge) do
    src_id = Map.get(edge, "src_id")
    dst_id = Map.get(edge, "dst_id")

    if is_binary(src_id) and is_binary(dst_id), do: {src_id, dst_id}
  end

  defp canonical_edge_key(_), do: nil

  defp canonical_port_key(device_id, if_index, if_name) do
    device_id = non_blank(device_id)
    if_name = non_blank(if_name)
    if_index = value_to_non_negative_int(if_index)

    cond do
      is_binary(device_id) and is_integer(if_index) and if_index > 0 ->
        {device_id, {:ifindex, if_index}}

      is_binary(device_id) and is_binary(if_name) ->
        {device_id, {:ifname, if_name}}

      true ->
        nil
    end
  end

  defp pair_support_rank(%{} = edge) do
    edge
    |> Map.get("pair_support_rank")
    |> value_to_non_negative_int()
    |> Kernel.||(0)
  end

  defp pair_support_rank(_), do: 0

  @doc false
  @spec canonical_rebuild_min_edges() :: pos_integer()
  def canonical_rebuild_min_edges do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:min_canonical_edges, 1)
    |> normalize_positive_int(1)
  end

  @doc false
  @spec self_heal_needed?(integer(), integer(), integer()) :: boolean()
  def self_heal_needed?(after_prune_edges, mapper_evidence_edges, min_canonical_edges)
      when is_integer(after_prune_edges) and is_integer(mapper_evidence_edges) and
             is_integer(min_canonical_edges) do
    after_prune_edges < min_canonical_edges and mapper_evidence_edges >= min_canonical_edges
  end

  def self_heal_needed?(_after_prune_edges, _mapper_evidence_edges, _min_canonical_edges),
    do: false

  defp maybe_self_heal_zero_canonical(
         after_prune_edges,
         mapper_evidence_edges,
         stale_cutoff,
         min_canonical_edges
       )
       when is_integer(after_prune_edges) and is_integer(mapper_evidence_edges) and
              is_binary(stale_cutoff) and
              is_integer(min_canonical_edges) do
    if self_heal_needed?(after_prune_edges, mapper_evidence_edges, min_canonical_edges) do
      Logger.warning(
        "Canonical topology self-heal triggered",
        after_prune_edges: after_prune_edges,
        mapper_evidence_edges: mapper_evidence_edges,
        min_canonical_edges: min_canonical_edges
      )

      case Graph.execute(canonical_rebuild_upsert_query(stale_cutoff)) do
        :ok ->
          healed_edges = canonical_edge_count()
          {healed_edges, %{status: :completed, before: after_prune_edges, after: healed_edges}}

        {:error, reason} ->
          Logger.warning("Canonical topology self-heal failed", reason: inspect(reason))

          {after_prune_edges,
           %{status: :failed, before: after_prune_edges, after: after_prune_edges, reason: reason}}
      end
    else
      {after_prune_edges, %{status: :skipped}}
    end
  end

  @doc false
  @spec emit_canonical_rebuild_telemetry(:completed | :failed, map(), term() | nil) :: :ok
  def emit_canonical_rebuild_telemetry(status, stats, reason \\ nil)
      when status in [:completed, :failed] and is_map(stats) do
    measurements = %{
      before_edges: Map.get(stats, :before_edges, 0),
      mapper_evidence_edges: Map.get(stats, :mapper_evidence_edges, 0),
      after_upsert_edges: Map.get(stats, :after_upsert_edges, 0),
      after_prune_edges: Map.get(stats, :after_prune_edges, 0)
    }

    metadata =
      maybe_put_reason(
        %{
          status: status,
          stale_cutoff: Map.get(stats, :stale_cutoff),
          prune_result: Map.get(stats, :prune_result),
          telemetry_refresh: Map.get(stats, :telemetry_refresh)
        },
        reason
      )

    :telemetry.execute(
      [:serviceradar, :topology, :canonical_rebuild, status],
      measurements,
      metadata
    )

    :ok
  end

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, inspect(reason))

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

  defp refresh_canonical_edge_telemetry(stale_cutoff) when is_binary(stale_cutoff) do
    case fetch_canonical_edges(stale_cutoff) do
      {:ok, edges} ->
        metric_keys = telemetry_metric_keys(edges)
        pps_by_if = load_packet_pps(metric_keys)
        bps_by_if = load_octet_bps(metric_keys)
        capacity_by_if = load_interface_capacity(metric_keys)
        observed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        {stats, updates} =
          Enum.reduce(
            edges,
            {%{
               total_edges: length(edges),
               interface_source: 0,
               none_source: 0,
               render_ready: 0,
               render_partial: 0,
               render_unattributed: 0
             }, []},
            fn edge, {acc, updates} ->
              telemetry =
                compute_edge_telemetry(edge, pps_by_if, bps_by_if, capacity_by_if, observed_at)

              acc = update_render_readiness_stats(acc, edge_render_readiness_class(edge))
              acc = update_telemetry_source_stats(acc, telemetry.telemetry_source)
              {acc, [canonical_edge_telemetry_update(edge, telemetry) | updates]}
            end
          )

        case persist_canonical_edge_telemetry_updates(Enum.reverse(updates)) do
          :ok ->
            Logger.info("canonical_edge_telemetry_stats #{inspect(stats)}")
            {:ok, stats}

          {:error, reason} ->
            Logger.warning("Canonical edge telemetry refresh failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Canonical edge telemetry refresh failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_telemetry_source_stats(acc, "interface"),
    do: Map.update!(acc, :interface_source, &(&1 + 1))

  defp update_telemetry_source_stats(acc, _source), do: Map.update!(acc, :none_source, &(&1 + 1))

  defp fetch_canonical_edges(stale_cutoff) when is_binary(stale_cutoff) do
    cypher = """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND (r.last_observed_at IS NULL OR r.last_observed_at >= '#{Graph.escape(stale_cutoff)}')
      AND a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
    RETURN {
      src_id: a.id,
      dst_id: b.id,
      local_if_index: r.local_if_index,
      neighbor_if_index: r.neighbor_if_index,
      local_if_index_ab: r.local_if_index_ab,
      local_if_index_ba: r.local_if_index_ba
    }
    """

    case Graph.query(cypher) do
      {:ok, rows} when is_list(rows) -> {:ok, Enum.flat_map(rows, &parse_canonical_edge_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_canonical_edge_row(row) do
    src_id = map_value(row, :src_id)
    dst_id = map_value(row, :dst_id)

    with true <- is_binary(src_id),
         true <- is_binary(dst_id) do
      local_if_index_ab = parse_ifindex(map_value(row, :local_if_index_ab))
      local_if_index_ba = parse_ifindex(map_value(row, :local_if_index_ba))
      local_if_index = parse_ifindex(map_value(row, :local_if_index))
      neighbor_if_index = parse_ifindex(map_value(row, :neighbor_if_index))

      [
        %{
          src_id: src_id,
          dst_id: dst_id,
          local_if_index_ab: local_if_index_ab || local_if_index,
          local_if_index_ba: local_if_index_ba || neighbor_if_index,
          local_if_index: local_if_index,
          neighbor_if_index: neighbor_if_index
        }
      ]
    else
      _ -> []
    end
  end

  defp telemetry_metric_keys(edges) when is_list(edges) do
    edges
    |> Enum.flat_map(fn edge ->
      Enum.reject(
        [
          metric_key(
            Map.get(edge, :src_id),
            Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index)
          ),
          metric_key(
            Map.get(edge, :dst_id),
            Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index)
          )
        ],
        &is_nil/1
      )
    end)
    |> Enum.uniq()
  end

  defp metric_key(device_id, if_index)
       when is_binary(device_id) and is_integer(if_index) and if_index > 0,
       do: {device_id, if_index}

  defp metric_key(_, _), do: nil

  defp load_packet_pps(keys) when is_list(keys) do
    load_directional_metric(
      keys,
      @packet_metric_names,
      &packet_metric_direction/1,
      &value_to_non_negative_int/1,
      fn value -> value end
    )
  end

  defp load_octet_bps(keys) when is_list(keys) do
    load_directional_metric(
      keys,
      @octet_metric_names,
      &octet_metric_direction/1,
      &value_to_non_negative_int/1,
      fn value -> value * 8 end
    )
  end

  defp load_interface_capacity(keys) when is_list(keys) do
    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    device_identity = build_device_identity(device_ids)
    accepted_device_ids = telemetry_metric_device_ids(device_identity)

    if accepted_device_ids == [] or if_indexes == [] do
      %{}
    else
      from(i in "discovered_interfaces",
        where:
          fragment(
            "? = ANY(?)",
            i.device_id,
            type(^accepted_device_ids, {:array, :string})
          ),
        where: fragment("? = ANY(?)", i.if_index, type(^if_indexes, {:array, :integer})),
        distinct: [i.device_id, i.if_index],
        order_by: [asc: i.device_id, asc: i.if_index, desc: i.timestamp],
        select: {i.device_id, i.if_index, i.speed_bps, i.if_speed}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn row, acc -> reduce_capacity_row(row, acc, device_identity) end)
    end
  end

  defp build_device_identity(device_uids) when is_list(device_uids) do
    uid_set =
      device_uids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> MapSet.new()

    ip_to_uid =
      case MapSet.size(uid_set) do
        0 ->
          %{}

        _ ->
          uid_list = MapSet.to_list(uid_set)

          from(d in "ocsf_devices",
            where: fragment("? = ANY(?)", d.uid, type(^uid_list, {:array, :string})),
            select: {d.uid, d.ip}
          )
          |> Repo.all()
          |> Enum.reduce(%{}, &reduce_device_ip_row/2)
      end

    %{uid_set: uid_set, ip_to_uid: ip_to_uid}
  end

  defp telemetry_metric_device_ids(%{uid_set: uid_set, ip_to_uid: ip_to_uid}) do
    Enum.uniq(MapSet.to_list(uid_set) ++ Map.keys(ip_to_uid))
  end

  defp telemetry_metric_ips(%{ip_to_uid: ip_to_uid}) when is_map(ip_to_uid),
    do: Map.keys(ip_to_uid)

  defp canonical_metric_device_id(device_id, target_ip, identity) do
    cond do
      is_binary(device_id) and
          MapSet.member?(Map.get(identity, :uid_set, MapSet.new()), device_id) ->
        device_id

      is_binary(device_id) ->
        ip = extract_ip(device_id)
        Map.get(Map.get(identity, :ip_to_uid, %{}), ip)

      true ->
        nil
    end || Map.get(Map.get(identity, :ip_to_uid, %{}), normalize_ip(target_ip))
  end

  defp extract_ip(value) when is_binary(value) do
    normalized = normalize_ip(value)

    cond do
      is_binary(normalized) and normalized != "" ->
        normalized

      String.contains?(value, ":") ->
        value
        |> String.split(":", parts: 2)
        |> List.last()
        |> normalize_ip()

      true ->
        nil
    end
  end

  defp extract_ip(_), do: nil

  defp normalize_ip(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_ip(_), do: nil

  defp compute_edge_telemetry(edge, pps_by_if, bps_by_if, capacity_by_if, observed_at)
       when is_map(edge) and is_map(pps_by_if) and is_map(bps_by_if) and is_map(capacity_by_if) and
              is_binary(observed_at) do
    src_id = Map.get(edge, :src_id)
    dst_id = Map.get(edge, :dst_id)
    src_if_index = Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index)
    dst_if_index = Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index)

    src_pps = directional_metrics(pps_by_if, src_id, src_if_index)
    dst_pps = directional_metrics(pps_by_if, dst_id, dst_if_index)
    src_bps = directional_metrics(bps_by_if, src_id, src_if_index)
    dst_bps = directional_metrics(bps_by_if, dst_id, dst_if_index)

    flow_pps_ab = directional_min_flow(src_pps, dst_pps)
    flow_pps_ba = directional_min_flow(dst_pps, src_pps)
    flow_bps_ab = directional_min_flow(src_bps, dst_bps)
    flow_bps_ba = directional_min_flow(dst_bps, src_bps)
    flow_pps = flow_pps_ab + flow_pps_ba
    flow_bps = flow_bps_ab + flow_bps_ba
    src_capacity = directional_capacity(capacity_by_if, src_id, src_if_index)
    dst_capacity = directional_capacity(capacity_by_if, dst_id, dst_if_index)
    capacity_bps = min_non_zero(src_capacity, dst_capacity)

    base = %{
      flow_pps: flow_pps,
      flow_bps: flow_bps,
      capacity_bps: capacity_bps,
      flow_pps_ab: flow_pps_ab,
      flow_pps_ba: flow_pps_ba,
      flow_bps_ab: flow_bps_ab,
      flow_bps_ba: flow_bps_ba
    }

    Map.merge(base, telemetry_status_fields(flow_pps, flow_bps, observed_at))
  end

  defp load_directional_metric(keys, metric_names, direction_fun, value_fun, transform_fun) do
    {device_identity, accepted_metric_ids, accepted_metric_ips, if_indexes} =
      telemetry_metric_scope(keys)

    if accepted_metric_ids == [] or if_indexes == [] do
      %{}
    else
      from(m in "timeseries_metrics",
        where:
          fragment(
            "(? = ANY(?)) OR (? = ANY(?))",
            m.device_id,
            type(^accepted_metric_ids, {:array, :string}),
            m.target_device_ip,
            type(^accepted_metric_ips, {:array, :string})
          ),
        where: fragment("? = ANY(?)", m.if_index, type(^if_indexes, {:array, :integer})),
        where: fragment("? = ANY(?)", m.metric_name, type(^metric_names, {:array, :string})),
        where: m.timestamp > ago(@telemetry_window_minutes, "minute"),
        distinct: [m.device_id, m.target_device_ip, m.if_index, m.metric_name],
        order_by: [
          asc: m.device_id,
          asc: m.target_device_ip,
          asc: m.if_index,
          asc: m.metric_name,
          desc: m.timestamp
        ],
        select: {m.device_id, m.target_device_ip, m.if_index, m.metric_name, m.value}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn row, acc ->
        reduce_directional_metric_row(
          row,
          acc,
          device_identity,
          direction_fun,
          value_fun,
          transform_fun
        )
      end)
    end
  end

  defp telemetry_metric_scope(keys) do
    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    device_identity = build_device_identity(device_ids)

    {
      device_identity,
      telemetry_metric_device_ids(device_identity),
      telemetry_metric_ips(device_identity),
      if_indexes
    }
  end

  defp reduce_directional_metric_row(
         {device_id, target_ip, if_index, metric_name, value},
         acc,
         device_identity,
         direction_fun,
         value_fun,
         transform_fun
       ) do
    with dir when not is_nil(dir) <- direction_fun.(metric_name),
         numeric_value when not is_nil(numeric_value) <- value_fun.(value),
         canonical_device_id when not is_nil(canonical_device_id) <-
           canonical_metric_device_id(device_id, target_ip, device_identity) do
      mapped_value = transform_fun.(numeric_value)

      Map.update(acc, {canonical_device_id, if_index}, %{dir => mapped_value}, fn current ->
        Map.update(current, dir, mapped_value, &max(&1, mapped_value))
      end)
    else
      _ -> acc
    end
  end

  defp reduce_capacity_row({device_id, if_index, speed_bps, if_speed}, acc, device_identity) do
    canonical_device_id = canonical_metric_device_id(device_id, nil, device_identity)
    capacity = value_to_non_negative_int(speed_bps) || value_to_non_negative_int(if_speed)

    with true <- is_binary(canonical_device_id),
         true <- is_integer(if_index) and if_index > 0,
         true <- is_integer(capacity) and capacity > 0 do
      Map.update(acc, {canonical_device_id, if_index}, capacity, &max(&1, capacity))
    else
      _ -> acc
    end
  end

  defp reduce_device_ip_row({uid, ip}, acc) do
    with true <- is_binary(uid),
         true <- is_binary(ip),
         trimmed when trimmed != "" <- String.trim(ip) do
      Map.put(acc, trimmed, uid)
    else
      _ -> acc
    end
  end

  defp directional_metrics(source, device_id, if_index),
    do: Map.get(source, metric_key(device_id, if_index), %{})

  defp directional_capacity(source, device_id, if_index),
    do: Map.get(source, metric_key(device_id, if_index), 0)

  defp directional_min_flow(primary, secondary),
    do: min_non_zero(Map.get(primary, :out, 0), Map.get(secondary, :in, 0))

  defp telemetry_status_fields(flow_pps, flow_bps, observed_at) do
    eligible? = flow_pps > 0 or flow_bps > 0

    %{
      telemetry_eligible: eligible?,
      telemetry_source: if(eligible?, do: "interface", else: "none"),
      telemetry_observed_at: observed_at
    }
  end

  defp canonical_edge_telemetry_update(edge, telemetry) when is_map(edge) and is_map(telemetry) do
    %{
      src_id: Map.get(edge, :src_id),
      dst_id: Map.get(edge, :dst_id),
      flow_pps: Map.get(telemetry, :flow_pps, 0),
      flow_bps: Map.get(telemetry, :flow_bps, 0),
      capacity_bps: Map.get(telemetry, :capacity_bps, 0),
      flow_pps_ab: Map.get(telemetry, :flow_pps_ab, 0),
      flow_pps_ba: Map.get(telemetry, :flow_pps_ba, 0),
      flow_bps_ab: Map.get(telemetry, :flow_bps_ab, 0),
      flow_bps_ba: Map.get(telemetry, :flow_bps_ba, 0),
      telemetry_eligible: Map.get(telemetry, :telemetry_eligible, false),
      telemetry_source: Map.get(telemetry, :telemetry_source, "none"),
      telemetry_observed_at: Map.get(telemetry, :telemetry_observed_at, "")
    }
  end

  defp canonical_edge_telemetry_update(_edge, _telemetry), do: %{}

  defp persist_canonical_edge_telemetry_updates([]), do: :ok

  defp persist_canonical_edge_telemetry_updates(updates) when is_list(updates) do
    updates
    |> Enum.chunk_every(canonical_edge_telemetry_batch_size())
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Graph.execute(canonical_edge_telemetry_batch_query(batch)) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning(
            "Canonical edge telemetry upsert failed",
            reason: inspect(reason),
            batch_size: length(batch)
          )

          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_ifindex(value) when is_integer(value) and value > 0, do: value

  defp parse_ifindex(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_ifindex(_), do: nil

  @doc false
  @spec edge_render_readiness_class(map()) ::
          :render_ready | :render_partial | :render_unattributed
  def edge_render_readiness_class(edge) when is_map(edge) do
    src_if_index =
      parse_ifindex(Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index))

    dst_if_index =
      parse_ifindex(Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index))

    cond do
      is_integer(src_if_index) and is_integer(dst_if_index) ->
        :render_ready

      is_integer(src_if_index) or is_integer(dst_if_index) ->
        :render_partial

      true ->
        :render_unattributed
    end
  end

  def edge_render_readiness_class(_edge), do: :render_unattributed

  defp update_render_readiness_stats(acc, :render_ready),
    do: Map.update!(acc, :render_ready, &(&1 + 1))

  defp update_render_readiness_stats(acc, :render_partial),
    do: Map.update!(acc, :render_partial, &(&1 + 1))

  defp update_render_readiness_stats(acc, _),
    do: Map.update!(acc, :render_unattributed, &(&1 + 1))

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifInUcastPkts", "ifHCInUcastPkts"], do: :in

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifOutUcastPkts", "ifHCOutUcastPkts"], do: :out

  defp packet_metric_direction(_), do: nil

  defp octet_metric_direction(metric_name) when metric_name in ["ifInOctets", "ifHCInOctets"],
    do: :in

  defp octet_metric_direction(metric_name) when metric_name in ["ifOutOctets", "ifHCOutOctets"],
    do: :out

  defp octet_metric_direction(_), do: nil

  defp value_to_non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp value_to_non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)

  defp value_to_non_negative_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp value_to_non_negative_int(_), do: nil

  defp min_non_zero(a, b) do
    av = value_to_non_negative_int(a) || 0
    bv = value_to_non_negative_int(b) || 0

    cond do
      av > 0 and bv > 0 -> min(av, bv)
      av > 0 -> av
      bv > 0 -> bv
      true -> 0
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
      AND toLower(trim(ai.device_id)) <> 'nil'
      AND toLower(trim(ai.device_id)) <> 'null'
      AND toLower(trim(ai.device_id)) <> 'undefined'
      AND toLower(trim(bi.device_id)) <> 'nil'
      AND toLower(trim(bi.device_id)) <> 'null'
      AND toLower(trim(bi.device_id)) <> 'undefined'
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
      END AS conf_rank,
      CASE type(r)
        WHEN 'INFERRED_TO' THEN 1
        WHEN 'ATTACHED_TO' THEN 1
        ELSE 0
      END AS support_rank
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
      support_rank
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
      support_rank: support_rank,
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
      max(c.support_rank) AS pair_support_rank,
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
    SET cr.pair_support_rank = pair_support_rank
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
    SET cr.local_if_index_ab = cr.local_if_index
    SET cr.local_if_index_ba = cr.neighbor_if_index
    SET cr.local_if_name_ab = cr.local_if_name
    SET cr.local_if_name_ba = cr.neighbor_if_name
    SET cr.flow_pps = coalesce(cr.flow_pps, 0)
    SET cr.flow_bps = coalesce(cr.flow_bps, 0)
    SET cr.capacity_bps = coalesce(cr.capacity_bps, 0)
    SET cr.flow_pps_ab = coalesce(cr.flow_pps_ab, 0)
    SET cr.flow_pps_ba = coalesce(cr.flow_pps_ba, 0)
    SET cr.flow_bps_ab = coalesce(cr.flow_bps_ab, 0)
    SET cr.flow_bps_ba = coalesce(cr.flow_bps_ba, 0)
    SET cr.telemetry_eligible = coalesce(cr.telemetry_eligible, false)
    SET cr.telemetry_source = coalesce(cr.telemetry_source, 'none')
    SET cr.telemetry_observed_at = coalesce(cr.telemetry_observed_at, '')
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
      :serviceradar_core
      |> Application.get_env(
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

  defp cypher_value(nil), do: "null"
  defp cypher_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp cypher_value(value) when is_integer(value), do: Integer.to_string(value)

  defp cypher_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 8])

  defp cypher_value(value) when is_binary(value), do: "'#{Graph.escape(value)}'"
  defp cypher_value(value) when is_atom(value), do: "'#{Graph.escape(value)}'"
  defp cypher_value(value), do: "'#{Graph.escape(to_string(value))}'"
end
