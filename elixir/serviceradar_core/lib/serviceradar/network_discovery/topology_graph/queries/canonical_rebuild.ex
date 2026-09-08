defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild do
  @moduledoc false

  alias ServiceRadar.Graph

  # Mapper-evidence edge label tables the canonical rebuild + projection read.
  # These MUST be Apache AGE label tables that actually exist in `platform_graph`
  # (HOSTED_ON is in the rebuild's relation IN-list but has no label table yet, so
  # it is intentionally absent here — unioning a non-existent table errors).
  @rebuild_input_edge_labels [
    "CONNECTS_TO",
    "LOGICAL_PEER",
    "INFERRED_TO",
    "ATTACHED_TO",
    "OBSERVED_TO"
  ]

  # Per-edge agtype property fields that feed the upsert `content_hash` below
  # (relation_type comes from the source edge label table, not a property). The
  # rebuild-input fingerprint covers exactly these so a property-only change flips
  # the fingerprint immediately rather than waiting for the heartbeat. Keep this in
  # lock-step with @content_hash_property_fields — the coverage parity test asserts
  # equality so adding a field to one without the other fails CI.
  @rebuild_input_property_fields [
    "protocol",
    "source",
    "evidence_class",
    "confidence_tier",
    "confidence_score",
    "confidence_reason",
    "last_observed_at",
    "observed_at"
  ]

  # Edge-property fields the per-edge upsert `content_hash` keys on. The remaining
  # content_hash terms include the edge type and mutable Interface properties.
  # The fingerprint query joins both endpoint Interface vertices so name/ifindex-
  # only changes cannot be hidden behind the durable one-hour rebuild guard.
  @content_hash_property_fields [
    "protocol",
    "source",
    "evidence_class",
    "confidence_tier",
    "confidence_score",
    "confidence_reason",
    "last_observed_at",
    "observed_at"
  ]

  @doc false
  @spec rebuild_input_edge_labels() :: [String.t()]
  def rebuild_input_edge_labels, do: @rebuild_input_edge_labels

  @doc false
  @spec rebuild_input_property_fields() :: [String.t()]
  def rebuild_input_property_fields, do: @rebuild_input_property_fields

  @doc false
  @spec content_hash_property_fields() :: [String.t()]
  def content_hash_property_fields, do: @content_hash_property_fields

  @doc """
  Single-pass SQL fingerprint of the full mapper-evidence input the canonical
  rebuild reads: structural endpoints (start_id/end_id) plus the per-edge
  properties that drive the upsert content_hash, across every existing edge label
  table. Output shape is `{count}:{md5}` so the existing binary compare in
  CanonicalRebuild is unchanged. Properties are AGE `agtype` (not jsonb), so
  access uses `properties->'"key"'` with `::text` coercion; a missing key yields
  SQL NULL (coalesced to '') rather than raising.
  """
  @spec rebuild_input_fingerprint_query() :: String.t()
  def rebuild_input_fingerprint_query do
    union = Enum.map_join(@rebuild_input_edge_labels, "\n  UNION ALL\n  ", &edge_label_select/1)

    """
    SELECT count(*)::text || ':' || coalesce(md5(string_agg(edge_sig, ',' ORDER BY start_id, end_id, rel)), '')
    FROM (
      #{union}
    ) rebuild_input_edges
    """
  end

  # Timestamp fields are hour-bucketed (left(.., 13) => 'YYYY-MM-DDTHH') so the
  # fingerprint flips ~hourly instead of on every mapper report. last_observed_at
  # is refreshed on essentially every report, so a raw-timestamp fingerprint would
  # churn constantly and the skip-guard would almost never fire — defeating the
  # whole rebuild-skip. This matches the upsert content_hash, which already buckets
  # last_observed_at with substring(.., 0, 13), and stays well within the ~180min
  # stale prune cutoff so canonical edges still refresh ~hourly.
  @timestamp_property_fields ["last_observed_at", "observed_at"]

  defp edge_label_select(label) when is_binary(label) do
    property_terms =
      Enum.map_join(@rebuild_input_property_fields, "", fn field ->
        " || '|' || #{property_term("edge", field)}"
      end)

    interface_terms =
      Enum.map_join(["start_interface", "end_interface"], "", fn endpoint ->
        Enum.map_join(["name", "ifindex"], "", fn field ->
          " || '|' || #{property_term(endpoint, field)}"
        end)
      end)

    "SELECT edge.start_id, edge.end_id, '#{label}' AS rel,\n" <>
      "    edge.start_id::text || '>' || edge.end_id::text || '|#{label}'#{property_terms}#{interface_terms} AS edge_sig\n" <>
      "  FROM platform_graph.\"#{label}\" edge\n" <>
      "  LEFT JOIN platform_graph.\"Interface\" start_interface ON start_interface.id = edge.start_id\n" <>
      "  LEFT JOIN platform_graph.\"Interface\" end_interface ON end_interface.id = edge.end_id"
  end

  defp property_term(owner, field) when field in @timestamp_property_fields do
    "left(coalesce((#{owner}.properties->'\"#{field}\"')::text, ''), 13)"
  end

  defp property_term(owner, field) do
    "coalesce((#{owner}.properties->'\"#{field}\"')::text, '')"
  end

  # Relation types that count as mapper evidence for the canonical rebuild.
  # Shared by the evidence count and the evidence-freshness queries so the
  # starvation guard judges freshness over exactly the evidence set it counts.
  @mapper_evidence_relation_types [
    "CONNECTS_TO",
    "LOGICAL_PEER",
    "HOSTED_ON",
    "INFERRED_TO",
    "ATTACHED_TO",
    "OBSERVED_TO"
  ]

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
      AND type(r) IN #{mapper_evidence_relation_in_list()}
    RETURN {count: count(r)}
    """
  end

  @doc """
  Max evidence recency (`last_observed_at`, falling back to `observed_at`)
  across the mapper evidence edges the canonical rebuild reads. Lets the
  rebuild stats/telemetry expose evidence freshness vs. the stale cutoff so
  evidence starvation (frozen ingest) is distinguishable from real topology
  change.
  """
  @spec mapper_evidence_freshness_query() :: String.t()
  def mapper_evidence_freshness_query do
    """
    MATCH ()-[r]->()
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN #{mapper_evidence_relation_in_list()}
    RETURN {max_last_observed_at: max(coalesce(r.last_observed_at, r.observed_at))}
    """
  end

  defp mapper_evidence_relation_in_list do
    "[" <> Enum.map_join(@mapper_evidence_relation_types, ", ", &"'#{&1}'") <> "]"
  end

  @doc false
  @spec canonical_rebuild_upsert_query(String.t()) :: String.t()
  def canonical_rebuild_upsert_query(stale_cutoff) when is_binary(stale_cutoff) do
    """
    MATCH (ai:Interface)-[r]->(bi:Interface)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON', 'INFERRED_TO', 'ATTACHED_TO']
      AND coalesce(r.last_observed_at, r.observed_at) >= '#{Graph.escape(stale_cutoff)}'
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
    WHERE #{canonical_prune_predicate(stale_cutoff)}
    DELETE r
    """
  end

  @doc """
  Counts the `CANONICAL_TOPOLOGY` edges the stale prune would delete. Built
  from the same predicate as `canonical_rebuild_prune_query/1` so the
  mass-deletion guardrail judges exactly the set the prune would remove.
  """
  @spec canonical_rebuild_prune_candidate_count_query(String.t()) :: String.t()
  def canonical_rebuild_prune_candidate_count_query(stale_cutoff) when is_binary(stale_cutoff) do
    """
    MATCH ()-[r:CANONICAL_TOPOLOGY]->()
    WHERE #{canonical_prune_predicate(stale_cutoff)}
    RETURN {count: count(r)}
    """
  end

  # The single source of truth for what the canonical stale prune deletes.
  # Both the DELETE and the guardrail count query interpolate this so they can
  # never drift apart.
  defp canonical_prune_predicate(stale_cutoff) when is_binary(stale_cutoff) do
    "r.ingestor = 'mapper_topology_v1'\n" <>
      "  AND r.last_observed_at IS NOT NULL\n" <>
      "  AND r.last_observed_at < '#{Graph.escape(stale_cutoff)}'"
  end
end
