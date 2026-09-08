defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Queries do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.EdgeLinks
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.RiskSummary
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.Telemetry

  defdelegate endpoint_inventory_risk_summary_query(device_uid, summary), to: RiskSummary
  defdelegate endpoint_inventory_risk_summary_fields(), to: RiskSummary
  defdelegate backbone_link_upsert_query(payload), to: EdgeLinks
  defdelegate auxiliary_link_upsert_query(payload, relation), to: EdgeLinks
  defdelegate prune_unseen_projected_links_queries(local_device_id, neighbor_ids), to: EdgeLinks

  defdelegate prune_unseen_projected_forward_links_query(local_device_id, neighbor_ids),
    to: EdgeLinks

  defdelegate prune_unseen_projected_reverse_links_query(local_device_id, neighbor_ids),
    to: EdgeLinks

  defdelegate prune_stale_mapper_evidence_links_query(stale_cutoff), to: EdgeLinks
  defdelegate reconcile_legacy_single_identifier_attachment_links_query(), to: EdgeLinks
  defdelegate purge_legacy_single_identifier_canonical_links_query(), to: EdgeLinks
  defdelegate canonical_edge_telemetry_batch_query(updates), to: Telemetry
  defdelegate canonical_edge_count_query(), to: CanonicalRebuild
  defdelegate mapper_evidence_edge_count_query(), to: CanonicalRebuild
  defdelegate mapper_evidence_freshness_query(), to: CanonicalRebuild
  defdelegate canonical_rebuild_upsert_query(stale_cutoff), to: CanonicalRebuild
  defdelegate canonical_rebuild_prune_query(stale_cutoff), to: CanonicalRebuild

  defdelegate canonical_rebuild_prune_candidate_count_query(stale_cutoff),
    to: CanonicalRebuild

  defdelegate rebuild_input_fingerprint_query(), to: CanonicalRebuild
  defdelegate rebuild_input_edge_labels(), to: CanonicalRebuild
  defdelegate rebuild_input_property_fields(), to: CanonicalRebuild
  defdelegate content_hash_property_fields(), to: CanonicalRebuild
end
