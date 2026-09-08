defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.EdgeLinks do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

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
      AND (
        coalesce(r.last_observed_at, r.observed_at) IS NULL
        OR coalesce(r.last_observed_at, r.observed_at) < '#{Graph.escape(stale_cutoff)}'
      )
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

  defp allowed_neighbor_literals(neighbor_ids) do
    Enum.map_join(neighbor_ids, ", ", &"'#{Graph.escape(&1)}'")
  end
end
