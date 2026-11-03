defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Links do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  require Logger

  # Skip re-applying a mapper report whose projected link content is unchanged from
  # the last applied report for the same device scope. The per-link backbone/
  # auxiliary upserts (and the canonical rebuild they trigger) rewrite Device/
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
  # restart re-walks the cheap per-link upserts but no longer forces a cold full
  # canonical rebuild. phash2 is acceptable here because the value is per-process
  # and never persisted, so OTP-upgrade instability cannot survive a restart.
  @default_unchanged_report_heartbeat_ms 3_600_000

  @spec upsert_links([map()]) :: :ok
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    case maybe_skip_unchanged_report(links) do
      {:skip, _key} ->
        Logger.debug("Topology upsert skipped; mapper report structurally unchanged")
        :ok

      {:proceed, key, fingerprint} ->
        result = do_upsert_links(links)

        # do_upsert_links/1 returns :ok and raises on failure, so reaching this
        # line means the apply succeeded. Recording the fingerprint only after a
        # successful apply ensures a failed report is retried next cycle rather
        # than cached as "done" and skipped.
        :persistent_term.put(
          {__MODULE__, :report_fingerprint, key},
          {fingerprint, System.monotonic_time(:millisecond)}
        )

        result
    end
  end

  defp do_upsert_links(links) do
    diagnostics =
      Enum.reduce(links, Projection.empty_projection_diagnostics(), &reduce_topology_link/2)

    Pruning.maybe_prune_stale_mapper_evidence_links()
    CanonicalRebuild.rebuild_canonical_device_links()

    Logger.info("Topology projection diagnostics: #{inspect(diagnostics)}")

    :ok
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
  # fingerprint itself includes every projected input except the observation
  # timestamp. This deliberately favors a complete fail-safe identity over a
  # curated field list that could drift when projection gains another mutable
  # vertex, interface, or edge property. Observation timestamps are excluded so
  # unchanged heartbeat reports still use the periodic re-apply window.
  defp report_structural_fingerprint(links) do
    payloads =
      links
      |> Enum.map(&Projection.projection_payload/1)
      |> Enum.reject(&is_nil/1)

    scope =
      payloads
      |> Enum.map(& &1.local_device_id)
      |> Enum.uniq()
      |> Enum.sort()

    identity =
      payloads
      |> Enum.map(&Map.delete(&1, :observed_at))
      |> Enum.sort()

    {:erlang.phash2(scope), :erlang.phash2(identity)}
  end

  defp unchanged_report_heartbeat_ms do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:unchanged_report_heartbeat_ms, @default_unchanged_report_heartbeat_ms)
    |> Utils.normalize_positive_int(@default_unchanged_report_heartbeat_ms)
  end

  defp reduce_topology_link(link, diagnostics) do
    case Projection.projection_payload(link) do
      nil ->
        reason = Projection.drop_reason(link) || :missing_ids
        emit_neighbor_dropped(link, reason)
        Logger.debug("Skipping topology link missing device identifiers")
        Projection.increment_diagnostic(diagnostics, :rejected, reason)

      payload ->
        case Projection.projection_mode(payload) do
          {:backbone, reason} ->
            DgraphPersist.upsert_link(payload, "CONNECTS_TO")
            Projection.increment_diagnostic(diagnostics, :accepted, reason)

          {:auxiliary, reason} ->
            DgraphPersist.upsert_link(payload, Projection.evidence_relation_type(payload))
            Projection.increment_diagnostic(diagnostics, :accepted, reason)

          {:skip, reason} ->
            Projection.increment_diagnostic(diagnostics, :rejected, reason)
        end
    end
  end

  # Accounting for links dropped because their neighbor never resolved to (or
  # was never promoted to) a canonical `sr:` identity. These links are pure
  # evidence (they stay persisted in mapper_topology_links) but MUST NOT write
  # non-`sr:` pseudo-vertices into the topology graph. Public for tests.
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
end
