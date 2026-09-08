defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Refresh do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalMutationLock
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Edges
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Metrics
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.Repo

  require Logger

  def refresh_canonical_edge_telemetry(stale_cutoff) when is_binary(stale_cutoff) do
    case Edges.fetch_canonical_edges(stale_cutoff) do
      {:ok, edges} ->
        metric_keys = Metrics.telemetry_metric_keys(edges)
        pps_by_if = Metrics.load_packet_pps(metric_keys)
        bps_by_if = Metrics.load_octet_bps(metric_keys)
        capacity_by_if = Metrics.load_interface_capacity(metric_keys)
        observed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        {stats, updates} =
          build_telemetry_updates(edges, pps_by_if, bps_by_if, capacity_by_if, observed_at)

        case persist_canonical_edge_telemetry_updates(Enum.reverse(updates)) do
          :ok ->
            Logger.info("canonical_edge_telemetry_stats #{inspect(stats)}")
            {:ok, stats}

          {:skipped, :canonical_mutation_in_progress} ->
            stats =
              Map.merge(stats, %{
                write_skipped: true,
                skip_reason: :canonical_mutation_in_progress
              })

            Logger.debug("Canonical edge telemetry write skipped; canonical mutation lock busy")

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

  defp build_telemetry_updates(edges, pps_by_if, bps_by_if, capacity_by_if, observed_at) do
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

        acc = update_render_readiness_stats(acc, Edges.edge_render_readiness_class(edge))
        acc = update_telemetry_source_stats(acc, telemetry.telemetry_source)
        {acc, [canonical_edge_telemetry_update(edge, telemetry) | updates]}
      end
    )
  end

  defp update_telemetry_source_stats(acc, "interface"),
    do: Map.update!(acc, :interface_source, &(&1 + 1))

  defp update_telemetry_source_stats(acc, _source), do: Map.update!(acc, :none_source, &(&1 + 1))

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
    capacity_bps = Utils.min_non_zero(src_capacity, dst_capacity)

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

  defp directional_metrics(source, device_id, if_index),
    do: Map.get(source, Metrics.metric_key(device_id, if_index), %{})

  defp directional_capacity(source, device_id, if_index),
    do: Map.get(source, Metrics.metric_key(device_id, if_index), 0)

  defp directional_min_flow(primary, secondary),
    do: Utils.min_non_zero(Map.get(primary, :out, 0), Map.get(secondary, :in, 0))

  defp telemetry_status_fields(flow_pps, flow_bps, observed_at) do
    flow_present? = flow_pps > 0 or flow_bps > 0
    # Capacity is still attached for utilization labels. Particles only need a
    # rate series: UniFi–Cisco L2 edges often have speed on one side only, and
    # requiring both flow and capacity left the Traffic toggle looking static.
    eligible? = flow_present?

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
    # Fetching and computing telemetry stays outside the advisory-lock transaction.
    # Only the AGE relationship writes are serialized with structural canonical
    # rebuilds and other telemetry finalizers. This prevents concurrent SETs from
    # deadlocking or hitting AGE's stale-entity update failure without restoring
    # the old, long-lived transaction that also covered metric scans/projection.
    case CanonicalMutationLock.try_run(
           fn ->
             case do_persist_canonical_edge_telemetry_updates(updates) do
               :ok ->
                 :ok

               {:error, reason} ->
                 Repo.rollback({:canonical_edge_telemetry_upsert_failed, reason})
             end
           end,
           busy_result: {:skipped, :canonical_mutation_in_progress}
         ) do
      {:ok, result} -> result
      {:error, {:canonical_edge_telemetry_upsert_failed, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_persist_canonical_edge_telemetry_updates(updates) when is_list(updates) do
    updates
    |> Enum.chunk_every(Telemetry.canonical_edge_telemetry_batch_size())
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Graph.execute(Queries.canonical_edge_telemetry_batch_query(batch)) do
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

  defp update_render_readiness_stats(acc, :render_ready),
    do: Map.update!(acc, :render_ready, &(&1 + 1))

  defp update_render_readiness_stats(acc, :render_partial),
    do: Map.update!(acc, :render_partial, &(&1 + 1))

  defp update_render_readiness_stats(acc, _),
    do: Map.update!(acc, :render_unattributed, &(&1 + 1))
end
