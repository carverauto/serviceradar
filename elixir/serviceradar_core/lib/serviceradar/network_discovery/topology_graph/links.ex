defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Links do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Persist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  require Logger

  # Skip re-applying a mapper report whose projected link content is unchanged from
  # the last applied report for the same device scope. The per-link backbone/
  # auxiliary MERGEs (and the canonical rebuild they trigger) rewrite Device/
  # Interface vertices and edges on every report regardless of change; gating the
  # whole apply on a structural fingerprint stops that churn for a static topology.
  # A heartbeat still re-applies periodically so stale-link pruning advances.
  #
  # This per-report guard is intentionally an in-process persistent_term fast path
  # (not the durable shared meta-table guard used by CanonicalRebuild). It is keyed
  # per device scope, so making it cross-replica would mean one meta row per scope
  # — extra schema/write surface for a smaller win. The expensive downstream work
  # this guard protects (CanonicalRebuild.rebuild_canonical_device_links/0) is now
  # itself durably + cross-replica gated, so a process-local miss here after a
  # restart re-walks the cheap per-link MERGEs but no longer forces a cold full
  # canonical rebuild. phash2 is acceptable here because the value is per-process
  # and never persisted, so OTP-upgrade instability cannot survive a restart.
  @default_unchanged_report_heartbeat_ms 3_600_000

  @spec upsert_links([map()]) :: :ok | {:error, term()}
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    case maybe_skip_unchanged_report(links) do
      {:skip, _key} ->
        Logger.debug("Topology upsert skipped; mapper report structurally unchanged")
        :ok

      {:proceed, key, fingerprint} ->
        with :ok <- do_upsert_links(links) do
          # Recording the fingerprint only after a successful apply ensures a
          # failed report is retried rather than cached as "done" and skipped.
          :persistent_term.put(
            {__MODULE__, :report_fingerprint, key},
            {fingerprint, System.monotonic_time(:millisecond)}
          )
        end
    end
  end

  defp do_upsert_links(links) do
    links = Enum.sort_by(links, &link_observed_unix/1)

    {local_device_ids, neighbor_index, diagnostics, dgraph_links} =
      Enum.reduce(
        links,
        {MapSet.new(), %{}, Projection.empty_projection_diagnostics(), []},
        &reduce_topology_link/2
      )

    # Dgraph receives every link whose AGE write succeeded in one batch, before
    # pruning and the canonical rebuild read the graph back, as when each link
    # was written in turn.
    with :ok <- DgraphPersist.upsert_links(Enum.reverse(dgraph_links)) do
      Pruning.maybe_prune_unseen_projected_links(neighbor_index)
      Pruning.maybe_prune_stale_projected_links(MapSet.to_list(local_device_ids))

      Logger.info("Topology projection diagnostics: #{inspect(diagnostics)}")

      :ok
    end
  end

  @doc """
  The graph-wide passes that follow link projection: global stale-evidence
  pruning (AGE and Dgraph), the legacy single-identifier attachment
  reconciliation and purge, and the canonical rebuild. They read and rewrite
  the whole graph, so they run once per burst of device projections rather than
  once per device.
  """
  @spec run_global_passes() :: :ok | {:error, term()}
  def run_global_passes do
    Pruning.maybe_prune_stale_mapper_evidence_links()
    Pruning.reconcile_legacy_single_identifier_attachment_links()
    Pruning.purge_legacy_single_identifier_canonical_links()

    case CanonicalRebuild.rebuild_canonical_device_links() do
      {:error, reason, _stats} -> {:error, reason}
      _ -> :ok
    end
  end

  # Returns {:skip, key} when this report's structural link set matches the last
  # applied report for the same device scope within the heartbeat window;
  # otherwise {:proceed, key, fingerprint}.
  defp maybe_skip_unchanged_report(links) do
    {key, fingerprint} = report_structural_fingerprint(links)
    now_ms = System.monotonic_time(:millisecond)
    heartbeat_ms = unchanged_report_heartbeat_ms()

    case :persistent_term.get({__MODULE__, :report_fingerprint, key}, nil) do
      {^fingerprint, ts} when now_ms - ts < heartbeat_ms ->
        {:skip, key}

      _ ->
        {:proceed, key, fingerprint}
    end
  end

  # Scope the fingerprint by the set of reporting (local) devices so concurrent
  # reports from different agents don't thrash a single shared entry. The
  # fingerprint is the set of values the apply would leave: links are taken in
  # the same observation order do_upsert_links/1 applies them, the newest
  # non-empty value wins each device IP or name and interface name or ifindex,
  # including the neighbor's as the reporting device observed it, and the
  # newest link between two interfaces wins that pair's edge of each relation.
  # Links the apply skips write nothing and are left out. A report that changes
  # which row wins therefore changes the fingerprint even when the set of rows
  # is the same. Observation timestamps are excluded so unchanged heartbeat
  # reports still use the periodic re-apply window.
  defp report_structural_fingerprint(links) do
    payloads =
      links
      |> Enum.sort_by(&link_observed_unix/1)
      |> Enum.map(&Projection.projection_payload/1)
      |> Enum.reject(&is_nil/1)

    written = Enum.flat_map(payloads, &written_relation/1)

    scope =
      payloads
      |> Enum.map(& &1.local_device_id)
      |> Enum.uniq()
      |> Enum.sort()

    {:erlang.phash2(scope), :erlang.phash2(resolved_winners(written))}
  end

  defp written_relation(payload) do
    case Projection.projection_mode(payload) do
      {:backbone, _reason} -> [{payload, "CONNECTS_TO"}]
      {:auxiliary, _reason} -> [{payload, Projection.evidence_relation_type(payload)}]
      {:skip, _reason} -> []
    end
  end

  defp resolved_winners(written) do
    Enum.reduce(written, {%{}, %{}, %{}, %{}}, fn {payload, relation},
                                                  {devices, locals, neighbors, edges} ->
      {
        devices
        |> put_winner(payload.local_device_id, %{ip: payload.local_device_ip})
        |> put_winner(payload.neighbor_device_id, %{
          ip: payload.neighbor_ip,
          name: payload.neighbor_name
        }),
        put_winner(locals, payload.local_interface_id, %{
          name: payload.local_if_name,
          ifindex: payload.local_if_index
        }),
        put_winner(neighbors, payload.neighbor_interface_id, %{name: payload.neighbor_port_name}),
        Map.put(
          edges,
          {payload.local_interface_id, payload.neighbor_interface_id, relation},
          Map.delete(payload, :observed_at)
        )
      }
    end)
  end

  defp put_winner(winners, key, fields) do
    Map.update(
      winners,
      key,
      fields,
      &Map.merge(&1, fields, fn _field, earlier, later -> newer(earlier, later) end)
    )
  end

  defp newer(earlier, later) when later in [nil, ""], do: earlier
  defp newer(_earlier, later), do: later

  defp unchanged_report_heartbeat_ms do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:unchanged_report_heartbeat_ms, @default_unchanged_report_heartbeat_ms)
    |> Utils.normalize_positive_int(@default_unchanged_report_heartbeat_ms)
  end

  defp link_observed_unix(link) when is_map(link) do
    case Map.get(link, :timestamp) || Map.get(link, "timestamp") do
      %DateTime{} = timestamp ->
        DateTime.to_unix(timestamp, :microsecond)

      %NaiveDateTime{} = timestamp ->
        NaiveDateTime.diff(timestamp, ~N[1970-01-01 00:00:00], :microsecond)

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, parsed, _offset} ->
            DateTime.to_unix(parsed, :microsecond)

          _ ->
            case NaiveDateTime.from_iso8601(timestamp) do
              {:ok, parsed} -> NaiveDateTime.diff(parsed, ~N[1970-01-01 00:00:00], :microsecond)
              _ -> 0
            end
        end

      _ ->
        0
    end
  end

  defp reduce_topology_link(link, {local_ids, neighbor_index, diagnostics, dgraph_links}) do
    case Projection.projection_payload(link) do
      nil ->
        reason = Projection.drop_reason(link) || :missing_ids
        emit_neighbor_dropped(link, reason)
        Logger.debug("Skipping topology link missing device identifiers")
        diagnostics = Projection.increment_diagnostic(diagnostics, :rejected, reason)
        {local_ids, neighbor_index, diagnostics, dgraph_links}

      payload ->
        case Projection.projection_mode(payload) do
          {:backbone, reason} ->
            local_ids = MapSet.put(local_ids, payload.local_device_id)
            dgraph_links = upsert_backbone_link_payload(payload) ++ dgraph_links
            diagnostics = Projection.increment_diagnostic(diagnostics, :accepted, reason)

            neighbor_index =
              add_neighbor_edge(
                neighbor_index,
                payload.local_device_id,
                payload.neighbor_device_id
              )

            {local_ids, neighbor_index, diagnostics, dgraph_links}

          {:auxiliary, reason} ->
            dgraph_links = upsert_auxiliary_link_payload(payload) ++ dgraph_links
            diagnostics = Projection.increment_diagnostic(diagnostics, :accepted, reason)
            {local_ids, neighbor_index, diagnostics, dgraph_links}

          {:skip, reason} ->
            diagnostics = Projection.increment_diagnostic(diagnostics, :rejected, reason)
            {local_ids, neighbor_index, diagnostics, dgraph_links}
        end
    end
  end

  # Accounting for links dropped because their neighbor never resolved to (or
  # was never promoted to) a canonical `sr:` identity. These links are pure
  # evidence (they stay persisted in mapper_topology_links) but MUST NOT write
  # non-`sr:` pseudo-vertices into AGE. Public for tests.
  @doc false
  def emit_neighbor_dropped(link, reason)
      when reason in [:neighbor_unresolved, :neighbor_not_canonical] do
    :telemetry.execute(
      [:serviceradar, :mapper_topology, :neighbor_dropped],
      %{count: 1},
      %{reason: reason, protocol: Utils.link_value(link, :protocol) || "unknown"}
    )
  end

  def emit_neighbor_dropped(_link, _reason), do: :ok

  defp add_neighbor_edge(index, local_device_id, neighbor_device_id) do
    update_in(index, [local_device_id], fn
      nil -> MapSet.new([neighbor_device_id])
      existing -> MapSet.put(existing, neighbor_device_id)
    end)
  end

  # Each returns the `{payload, relation}` the Dgraph batch receives once the
  # AGE write (when AGE is written at all) has succeeded.
  defp upsert_backbone_link_payload(payload) do
    cypher = Queries.backbone_link_upsert_query(payload)

    case Persist.execute_age(cypher) do
      :ok ->
        [{payload, "CONNECTS_TO"}]

      {:error, reason} ->
        Logger.warning("Topology graph upsert failed: #{inspect(reason)}")
        []
    end
  end

  defp upsert_auxiliary_link_payload(payload) do
    relation = Projection.evidence_relation_type(payload)
    cypher = Queries.auxiliary_link_upsert_query(payload, relation)

    case Persist.execute_age(cypher) do
      :ok ->
        [{payload, relation}]

      {:error, reason} ->
        Logger.warning("Auxiliary topology graph upsert failed: #{inspect(reason)}")
        []
    end
  end
end
