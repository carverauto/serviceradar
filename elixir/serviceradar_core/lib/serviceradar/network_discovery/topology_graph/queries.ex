defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Queries do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @endpoint_inventory_risk_summary_fields [
    :pkg_worst_severity,
    :pkg_critical_count,
    :pkg_kev_count,
    :pkg_has_unpatched_rce,
    :pkg_risk_summary_at
  ]

  @doc false
  @spec endpoint_inventory_risk_summary_query(String.t(), map()) :: String.t() | nil
  def endpoint_inventory_risk_summary_query(device_uid, summary)
      when is_binary(device_uid) and is_map(summary) do
    case Utils.non_blank(device_uid) do
      nil ->
        nil

      uid ->
        summary = Utils.normalize_endpoint_inventory_risk_summary(summary)

        """
        MERGE (d:Device {id: '#{Graph.escape(uid)}'})
        SET d.pkg_worst_severity = #{Utils.cypher_value(summary.pkg_worst_severity)}
        SET d.pkg_critical_count = #{Utils.cypher_value(summary.pkg_critical_count)}
        SET d.pkg_kev_count = #{Utils.cypher_value(summary.pkg_kev_count)}
        SET d.pkg_has_unpatched_rce = #{Utils.cypher_value(summary.pkg_has_unpatched_rce)}
        SET d.pkg_risk_summary_at = #{Utils.cypher_value(summary.pkg_risk_summary_at)}
        """
    end
  end

  def endpoint_inventory_risk_summary_query(_device_uid, _summary), do: nil

  @doc false
  @spec endpoint_inventory_risk_summary_fields() :: [atom()]
  def endpoint_inventory_risk_summary_fields, do: @endpoint_inventory_risk_summary_fields

  @doc false
  @spec backbone_link_upsert_query(map()) :: String.t()
  def backbone_link_upsert_query(payload) when is_map(payload) do
    """
    MERGE (a:Device {id: '#{Graph.escape(payload.local_device_id)}'})
    #{Utils.set_prop("a", "ip", payload.local_device_ip)}
    MERGE (b:Device {id: '#{Graph.escape(payload.neighbor_device_id)}'})
    #{Utils.set_prop("b", "name", payload.neighbor_name)}
    #{Utils.set_prop("b", "ip", payload.neighbor_ip)}
    MERGE (ai:Interface {id: '#{Graph.escape(payload.local_interface_id)}'})
    SET ai.device_id = '#{Graph.escape(payload.local_device_id)}'
    #{Utils.set_prop("ai", "name", payload.local_if_name)}
    #{Utils.set_prop("ai", "ifindex", payload.local_if_index)}
    MERGE (bi:Interface {id: '#{Graph.escape(payload.neighbor_interface_id)}'})
    SET bi.device_id = '#{Graph.escape(payload.neighbor_device_id)}'
    #{Utils.set_prop("bi", "name", payload.neighbor_port_name)}
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
    SET r.evidence_class = '#{Graph.escape(Utils.normalize_evidence_class(payload.evidence_class))}'
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
    SET rr.evidence_class = '#{Graph.escape(Utils.normalize_evidence_class(payload.evidence_class))}'
    SET rr.observed_at = '#{Graph.escape(payload.observed_at)}'
    SET rr.last_observed_at = '#{Graph.escape(payload.observed_at)}'
    """
  end

  @doc false
  @spec auxiliary_link_upsert_query(map(), String.t()) :: String.t()
  def auxiliary_link_upsert_query(payload, relation)
      when is_map(payload) and is_binary(relation) do
    """
    MERGE (a:Device {id: '#{Graph.escape(payload.local_device_id)}'})
    #{Utils.set_prop("a", "ip", payload.local_device_ip)}
    MERGE (b:Device {id: '#{Graph.escape(payload.neighbor_device_id)}'})
    #{Utils.set_prop("b", "name", payload.neighbor_name)}
    #{Utils.set_prop("b", "ip", payload.neighbor_ip)}
    MERGE (ai:Interface {id: '#{Graph.escape(payload.local_interface_id)}'})
    SET ai.device_id = '#{Graph.escape(payload.local_device_id)}'
    #{Utils.set_prop("ai", "name", payload.local_if_name)}
    #{Utils.set_prop("ai", "ifindex", payload.local_if_index)}
    MERGE (bi:Interface {id: '#{Graph.escape(payload.neighbor_interface_id)}'})
    SET bi.device_id = '#{Graph.escape(payload.neighbor_device_id)}'
    #{Utils.set_prop("bi", "name", payload.neighbor_port_name)}
    MERGE (a)-[r1:HAS_INTERFACE]->(ai)
    SET r1.source = 'mapper'
    MERGE (b)-[r2:HAS_INTERFACE]->(bi)
    SET r2.source = 'mapper'
    WITH a, b, ai, bi
    OPTIONAL MATCH (ai)-[legacy]->(bi)
    WHERE legacy.ingestor = 'mapper_topology_v1'
      AND type(legacy) IN ['LOGICAL_PEER', 'HOSTED_ON', 'ATTACHED_TO', 'INFERRED_TO', 'OBSERVED_TO']
      AND type(legacy) <> '#{Graph.escape(relation)}'
    DELETE legacy
    MERGE (ai)-[r:#{relation}]->(bi)
    SET r.first_observed_at = coalesce(r.first_observed_at, '#{Graph.escape(payload.observed_at)}')
    SET r.ingestor = 'mapper_topology_v1'
    SET r.source = '#{Graph.escape(payload.protocol)}'
    SET r.protocol = '#{Graph.escape(payload.protocol)}'
    SET r.evidence_class = '#{Graph.escape(Utils.normalize_evidence_class(payload.evidence_class))}'
    SET r.confidence_tier = '#{Graph.escape(payload.confidence_tier)}'
    SET r.confidence_score = #{payload.confidence_score}
    SET r.confidence_reason = '#{Graph.escape(payload.confidence_reason)}'
    SET r.observed_at = '#{Graph.escape(payload.observed_at)}'
    SET r.last_observed_at = '#{Graph.escape(payload.observed_at)}'
    """
  end

  @doc false
  @spec prune_unseen_projected_links_queries(String.t(), Enumerable.t()) :: [String.t()]
  def prune_unseen_projected_links_queries(local_device_id, neighbor_ids)
      when is_binary(local_device_id) do
    [
      prune_unseen_projected_reverse_links_query(local_device_id, neighbor_ids),
      prune_unseen_projected_forward_links_query(local_device_id, neighbor_ids)
    ]
  end

  @doc false
  @spec prune_unseen_projected_forward_links_query(String.t(), Enumerable.t()) :: String.t()
  def prune_unseen_projected_forward_links_query(local_device_id, neighbor_ids)
      when is_binary(local_device_id) do
    escaped_local = Graph.escape(local_device_id)
    allowed_neighbors = allowed_neighbor_literals(neighbor_ids)

    """
    MATCH (a:Interface)-[r:CONNECTS_TO]->(b:Interface)
    WHERE a.device_id = '#{escaped_local}'
      AND r.ingestor = 'mapper_topology_v1'
      AND (b.device_id IS NULL OR NOT b.device_id IN [#{allowed_neighbors}])
    DELETE r
    """
  end

  @doc false
  @spec prune_unseen_projected_reverse_links_query(String.t(), Enumerable.t()) :: String.t()
  def prune_unseen_projected_reverse_links_query(local_device_id, neighbor_ids)
      when is_binary(local_device_id) do
    escaped_local = Graph.escape(local_device_id)
    allowed_neighbors = allowed_neighbor_literals(neighbor_ids)

    """
    MATCH (a:Interface)-[r:CONNECTS_TO]->(b:Interface)
    WHERE a.device_id = '#{escaped_local}'
      AND r.ingestor = 'mapper_topology_v1'
      AND (b.device_id IS NULL OR NOT b.device_id IN [#{allowed_neighbors}])
    MATCH (b)-[rr:CONNECTS_TO]->(a)
    WHERE rr.ingestor = 'mapper_topology_v1'
    DELETE rr
    """
  end

  @doc false
  @spec prune_stale_mapper_evidence_links_query(String.t()) :: String.t()
  def prune_stale_mapper_evidence_links_query(stale_cutoff) when is_binary(stale_cutoff) do
    """
    MATCH ()-[r]->()
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']
      AND r.last_observed_at IS NOT NULL
      AND r.last_observed_at < '#{Graph.escape(stale_cutoff)}'
    DELETE r
    """
  end

  @doc false
  @spec reconcile_legacy_single_identifier_attachment_links_query() :: String.t()
  def reconcile_legacy_single_identifier_attachment_links_query do
    """
    MATCH (ai:Interface)-[legacy:ATTACHED_TO]->(bi:Interface)
    WHERE legacy.ingestor = 'mapper_topology_v1'
      AND toLower(coalesce(legacy.protocol, legacy.source, 'unknown')) = 'snmp-l2'
      AND toLower(coalesce(legacy.evidence_class, 'unknown')) = 'endpoint-attachment'
      AND toLower(coalesce(legacy.confidence_reason, 'unknown')) = 'single_identifier_inference'
    MERGE (ai)-[observed:OBSERVED_TO]->(bi)
    SET observed.first_observed_at = coalesce(observed.first_observed_at, legacy.first_observed_at, legacy.observed_at)
    SET observed.ingestor = 'mapper_topology_v1'
    SET observed.source = coalesce(legacy.source, 'snmp-l2')
    SET observed.protocol = coalesce(legacy.protocol, legacy.source, 'snmp-l2')
    SET observed.evidence_class = coalesce(legacy.evidence_class, 'endpoint-attachment')
    SET observed.confidence_tier = coalesce(legacy.confidence_tier, 'low')
    SET observed.confidence_score = coalesce(legacy.confidence_score, 40)
    SET observed.confidence_reason = coalesce(legacy.confidence_reason, 'single_identifier_inference')
    SET observed.observed_at = coalesce(legacy.observed_at, observed.observed_at)
    SET observed.last_observed_at = coalesce(legacy.last_observed_at, legacy.observed_at, observed.last_observed_at)
    DELETE legacy
    """
  end

  @doc false
  @spec purge_legacy_single_identifier_canonical_links_query() :: String.t()
  def purge_legacy_single_identifier_canonical_links_query do
    """
    MATCH ()-[r:CANONICAL_TOPOLOGY]->()
    WHERE r.ingestor = 'mapper_topology_v1'
      AND toLower(coalesce(r.relation_type, 'unknown')) = 'attached_to'
      AND toLower(coalesce(r.protocol, 'unknown')) = 'snmp-l2'
      AND toLower(coalesce(r.evidence_class, 'unknown')) = 'endpoint-attachment'
      AND toLower(coalesce(r.confidence_reason, 'unknown')) = 'single_identifier_inference'
    DELETE r
    """
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
      AND type(r) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']
    RETURN {count: count(r)}
    """
  end

  @doc false
  @spec canonical_rebuild_upsert_query(String.t()) :: String.t()
  def canonical_rebuild_upsert_query(stale_cutoff) when is_binary(stale_cutoff) do
    """
    MATCH (ai:Interface)-[r]->(bi:Interface)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON', 'INFERRED_TO', 'ATTACHED_TO']
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
      coalesce(CASE WHEN ai.device_id <= bi.device_id THEN ai.id ELSE bi.id END, CASE WHEN ai.device_id <= bi.device_id THEN ai.name ELSE bi.name END, 'unknown') AS local_interface_key,
      coalesce(CASE WHEN ai.device_id <= bi.device_id THEN bi.id ELSE ai.id END, CASE WHEN ai.device_id <= bi.device_id THEN bi.name ELSE ai.name END, 'unknown') AS neighbor_interface_key,
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
        WHEN 'CONNECTS_TO' THEN 5
        WHEN 'LOGICAL_PEER' THEN 4
        WHEN 'HOSTED_ON' THEN 4
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
        WHEN 'LOGICAL_PEER' THEN 1
        WHEN 'HOSTED_ON' THEN 1
        WHEN 'INFERRED_TO' THEN 1
        WHEN 'ATTACHED_TO' THEN 1
        ELSE 0
      END AS support_rank
    WITH
      src_id,
      dst_id,
      local_interface_key,
      neighbor_interface_key,
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
      local_interface_key,
      neighbor_interface_key,
      rel_rank DESC,
      conf_rank DESC,
      last_observed_at DESC
    WITH src_id, dst_id, local_interface_key + '|' + neighbor_interface_key AS link_key, collect({
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
    WITH src_id, dst_id, link_key, head(candidates) AS best, candidates
    UNWIND candidates AS c
    WITH
      src_id,
      dst_id,
      link_key,
      best,
      max(c.support_rank) AS pair_support_rank,
      max(CASE WHEN c.local_if_index IS NOT NULL AND c.local_if_index > 0 THEN c.local_if_index ELSE -1 END) AS best_local_if_index,
      max(CASE WHEN c.neighbor_if_index IS NOT NULL AND c.neighbor_if_index > 0 THEN c.neighbor_if_index ELSE -1 END) AS best_neighbor_if_index,
      max(CASE WHEN c.local_if_name IS NOT NULL AND c.local_if_name <> '' AND toLower(c.local_if_name) <> 'unknown' THEN c.local_if_name ELSE '' END) AS best_local_if_name,
      max(CASE WHEN c.neighbor_if_name IS NOT NULL AND c.neighbor_if_name <> '' AND toLower(c.neighbor_if_name) <> 'unknown' THEN c.neighbor_if_name ELSE '' END) AS best_neighbor_if_name
    MERGE (a:Device {id: src_id})
    MERGE (b:Device {id: dst_id})
    MERGE (a)-[cr:CANONICAL_TOPOLOGY {link_key: link_key}]->(b)
    SET cr.ingestor = 'mapper_topology_v1'
    SET cr.link_key = link_key
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

  defp allowed_neighbor_literals(neighbor_ids) do
    Enum.map_join(neighbor_ids, ", ", &"'#{Graph.escape(&1)}'")
  end

  defp canonical_edge_telemetry_update_literal(update) when is_map(update) do
    [
      "src_id: #{Utils.cypher_value(Map.get(update, :src_id))}",
      "dst_id: #{Utils.cypher_value(Map.get(update, :dst_id))}",
      "flow_pps: #{Utils.cypher_value(Map.get(update, :flow_pps, 0))}",
      "flow_bps: #{Utils.cypher_value(Map.get(update, :flow_bps, 0))}",
      "capacity_bps: #{Utils.cypher_value(Map.get(update, :capacity_bps, 0))}",
      "flow_pps_ab: #{Utils.cypher_value(Map.get(update, :flow_pps_ab, 0))}",
      "flow_pps_ba: #{Utils.cypher_value(Map.get(update, :flow_pps_ba, 0))}",
      "flow_bps_ab: #{Utils.cypher_value(Map.get(update, :flow_bps_ab, 0))}",
      "flow_bps_ba: #{Utils.cypher_value(Map.get(update, :flow_bps_ba, 0))}",
      "telemetry_eligible: #{Utils.cypher_value(Map.get(update, :telemetry_eligible, false))}",
      "telemetry_source: #{Utils.cypher_value(Map.get(update, :telemetry_source, "none"))}",
      "telemetry_observed_at: #{Utils.cypher_value(Map.get(update, :telemetry_observed_at, ""))}"
    ]
    |> Enum.join(", ")
    |> then(&"{#{&1}}")
  end
end
