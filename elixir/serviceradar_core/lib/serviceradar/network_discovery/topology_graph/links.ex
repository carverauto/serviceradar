defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Links do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries

  require Logger

  @spec upsert_links([map()]) :: :ok
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    {local_device_ids, neighbor_index, diagnostics} =
      Enum.reduce(
        links,
        {MapSet.new(), %{}, Projection.empty_projection_diagnostics()},
        &reduce_topology_link/2
      )

    Pruning.maybe_prune_unseen_projected_links(neighbor_index)
    Pruning.maybe_prune_stale_projected_links(MapSet.to_list(local_device_ids))
    Pruning.maybe_prune_stale_mapper_evidence_links()
    Pruning.reconcile_legacy_single_identifier_attachment_links()
    Pruning.purge_legacy_single_identifier_canonical_links()
    CanonicalRebuild.rebuild_canonical_device_links()

    Logger.info("Topology projection diagnostics: #{inspect(diagnostics)}")

    :ok
  end

  defp reduce_topology_link(link, {local_ids, neighbor_index, diagnostics}) do
    case Projection.projection_payload(link) do
      nil ->
        Logger.debug("Skipping topology link missing device identifiers")
        diagnostics = Projection.increment_diagnostic(diagnostics, :rejected, :missing_ids)
        {local_ids, neighbor_index, diagnostics}

      payload ->
        case Projection.projection_mode(payload) do
          {:backbone, reason} ->
            local_ids = MapSet.put(local_ids, payload.local_device_id)
            upsert_backbone_link_payload(payload)
            diagnostics = Projection.increment_diagnostic(diagnostics, :accepted, reason)

            neighbor_index =
              add_neighbor_edge(
                neighbor_index,
                payload.local_device_id,
                payload.neighbor_device_id
              )

            {local_ids, neighbor_index, diagnostics}

          {:auxiliary, reason} ->
            upsert_auxiliary_link_payload(payload)
            diagnostics = Projection.increment_diagnostic(diagnostics, :accepted, reason)
            {local_ids, neighbor_index, diagnostics}

          {:skip, reason} ->
            diagnostics = Projection.increment_diagnostic(diagnostics, :rejected, reason)
            {local_ids, neighbor_index, diagnostics}
        end
    end
  end

  defp add_neighbor_edge(index, local_device_id, neighbor_device_id) do
    update_in(index, [local_device_id], fn
      nil -> MapSet.new([neighbor_device_id])
      existing -> MapSet.put(existing, neighbor_device_id)
    end)
  end

  defp upsert_backbone_link_payload(payload) do
    cypher = Queries.backbone_link_upsert_query(payload)

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Topology graph upsert failed: #{inspect(reason)}")
    end
  end

  defp upsert_auxiliary_link_payload(payload) do
    relation = Projection.evidence_relation_type(payload)
    cypher = Queries.auxiliary_link_upsert_query(payload, relation)

    case Graph.execute(cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Auxiliary topology graph upsert failed: #{inspect(reason)}")
    end
  end
end
