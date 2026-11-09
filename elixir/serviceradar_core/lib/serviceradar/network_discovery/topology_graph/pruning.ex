defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  # The mapper evidence edge kinds the stale prune ages out. MTR_PATH is
  # deliberately absent: it is pruned on its own 24h window by MtrGraph, and
  # MANAGED_BY / MANAGES are not observation evidence.
  @mapper_edge_kinds [
    "CONNECTS_TO",
    "LOGICAL_PEER",
    "HOSTED_ON",
    "CONTAINS",
    "INFERRED_TO",
    "ATTACHED_TO",
    "OBSERVED_TO"
  ]

  def prune_stale_mapper_evidence_links do
    DgraphPersist.prune_stale(Utils.stale_cutoff_iso8601(), @mapper_edge_kinds)
  end

  def maybe_prune_stale_mapper_evidence_links do
    if prune_stale_projected_links_enabled?() do
      prune_stale_mapper_evidence_links()
    else
      :ok
    end
  end

  @doc false
  @spec prune_stale_projected_links_enabled?() :: boolean()
  def prune_stale_projected_links_enabled? do
    Application.get_env(
      :serviceradar_core,
      :mapper_topology_prune_stale_projected_links_enabled,
      true
    ) != false
  end
end
