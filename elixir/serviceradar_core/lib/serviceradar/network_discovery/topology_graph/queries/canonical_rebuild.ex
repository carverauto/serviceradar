defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild do
  @moduledoc false

  alias ServiceRadar.Graph

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
    WITH
      src_id,
      dst_id,
      link_key,
      best,
      pair_support_rank,
      CASE WHEN best_local_if_index > 0 THEN best_local_if_index ELSE best.local_if_index END AS local_if_index,
      CASE WHEN best_neighbor_if_index > 0 THEN best_neighbor_if_index ELSE best.neighbor_if_index END AS neighbor_if_index,
      CASE WHEN best_local_if_name <> '' THEN best_local_if_name ELSE best.local_if_name END AS local_if_name,
      CASE WHEN best_neighbor_if_name <> '' THEN best_neighbor_if_name ELSE best.neighbor_if_name END AS neighbor_if_name
    WITH
      src_id,
      dst_id,
      link_key,
      best,
      pair_support_rank,
      local_if_index,
      neighbor_if_index,
      local_if_name,
      neighbor_if_name,
      coalesce(best.relation_type, '') + '|' +
        coalesce(best.protocol, '') + '|' +
        coalesce(best.evidence_class, '') + '|' +
        coalesce(best.confidence_tier, '') + '|' +
        toString(coalesce(best.confidence_score, 0)) + '|' +
        coalesce(best.confidence_reason, '') + '|' +
        toString(coalesce(pair_support_rank, -1)) + '|' +
        toString(coalesce(local_if_index, -1)) + '|' +
        toString(coalesce(neighbor_if_index, -1)) + '|' +
        coalesce(local_if_name, '') + '|' +
        coalesce(neighbor_if_name, '') + '|' +
        substring(coalesce(best.last_observed_at, ''), 0, 13) AS content_hash
    MERGE (a:Device {id: src_id})
    MERGE (b:Device {id: dst_id})
    MERGE (a)-[cr:CANONICAL_TOPOLOGY {link_key: link_key}]->(b)
    WITH
      cr,
      best,
      pair_support_rank,
      link_key,
      content_hash,
      local_if_index,
      neighbor_if_index,
      local_if_name,
      neighbor_if_name
    WHERE cr.content_hash IS NULL OR cr.content_hash <> content_hash
    SET cr += {
      ingestor: 'mapper_topology_v1',
      link_key: link_key,
      relation_type: best.relation_type,
      protocol: best.protocol,
      evidence_class: best.evidence_class,
      confidence_tier: best.confidence_tier,
      confidence_score: best.confidence_score,
      confidence_reason: best.confidence_reason,
      pair_support_rank: pair_support_rank,
      last_observed_at: best.last_observed_at,
      local_if_index: local_if_index,
      neighbor_if_index: neighbor_if_index,
      local_if_name: local_if_name,
      neighbor_if_name: neighbor_if_name,
      local_if_index_ab: local_if_index,
      local_if_index_ba: neighbor_if_index,
      local_if_name_ab: local_if_name,
      local_if_name_ba: neighbor_if_name,
      flow_pps: coalesce(cr.flow_pps, 0),
      flow_bps: coalesce(cr.flow_bps, 0),
      capacity_bps: coalesce(cr.capacity_bps, 0),
      flow_pps_ab: coalesce(cr.flow_pps_ab, 0),
      flow_pps_ba: coalesce(cr.flow_pps_ba, 0),
      flow_bps_ab: coalesce(cr.flow_bps_ab, 0),
      flow_bps_ba: coalesce(cr.flow_bps_ba, 0),
      telemetry_eligible: coalesce(cr.telemetry_eligible, false),
      telemetry_source: coalesce(cr.telemetry_source, 'none'),
      telemetry_observed_at: coalesce(cr.telemetry_observed_at, ''),
      content_hash: content_hash
    }
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
end
