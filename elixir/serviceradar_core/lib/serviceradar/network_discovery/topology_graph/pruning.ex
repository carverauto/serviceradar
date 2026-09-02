defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  require Logger

  def prune_unseen_projected_links(neighbor_index) when map_size(neighbor_index) == 0, do: :ok

  def prune_unseen_projected_links(neighbor_index) do
    Enum.each(neighbor_index, fn {local_device_id, neighbor_ids} ->
      local_device_id
      |> Queries.prune_unseen_projected_links_queries(neighbor_ids)
      |> Enum.each(fn cypher ->
        case Graph.execute(cypher) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Topology unseen edge pruning failed: #{inspect(reason)}")
        end
      end)
    end)
  end

  def maybe_prune_unseen_projected_links(neighbor_index) do
    if prune_unseen_projected_links_enabled?() do
      prune_unseen_projected_links(neighbor_index)
    else
      :ok
    end
  end

  def prune_unseen_projected_links_enabled? do
    Application.get_env(
      :serviceradar_core,
      :mapper_topology_prune_unseen_projected_links_enabled,
      false
    ) == true
  end

  def prune_stale_projected_links([]), do: :ok

  def prune_stale_projected_links(local_device_ids) do
    stale_cutoff = Utils.stale_cutoff_iso8601()
    escaped_ids = Enum.map_join(local_device_ids, ", ", &"'#{Graph.escape(&1)}'")

    cypher = """
    MATCH (a:Interface)-[r:CONNECTS_TO]->(:Interface)
    WHERE a.device_id IN [#{escaped_ids}]
      AND r.ingestor = 'mapper_topology_v1'
      AND (
        coalesce(r.last_observed_at, r.observed_at) IS NULL
        OR coalesce(r.last_observed_at, r.observed_at) < '#{Graph.escape(stale_cutoff)}'
      )
    DELETE r
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Topology stale edge pruning failed: #{inspect(reason)}")
    end
  end

  def maybe_prune_stale_projected_links(local_device_ids) do
    if prune_stale_projected_links_enabled?() do
      prune_stale_projected_links(local_device_ids)
    else
      :ok
    end
  end

  def prune_stale_mapper_evidence_links do
    stale_cutoff = Utils.stale_cutoff_iso8601()
    cypher = Queries.prune_stale_mapper_evidence_links_query(stale_cutoff)

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Topology global stale edge pruning failed: #{inspect(reason)}")
    end
  end

  def reconcile_legacy_single_identifier_attachment_links do
    cypher = Queries.reconcile_legacy_single_identifier_attachment_links_query()

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Legacy mapper ATTACHED_TO reconciliation failed: #{inspect(reason)}")
    end
  end

  def purge_legacy_single_identifier_canonical_links do
    cypher = Queries.purge_legacy_single_identifier_canonical_links_query()

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Legacy canonical ATTACHED_TO purge failed: #{inspect(reason)}")
    end
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
