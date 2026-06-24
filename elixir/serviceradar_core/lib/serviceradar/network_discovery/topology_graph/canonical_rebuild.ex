defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild.Conflicts
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.Repo

  require Logger

  @canonical_rebuild_lock_key 1_104_202_506
  @default_canonical_rebuild_timeout_ms 60_000

  # Change-detection: the canonical rebuild rewrites every CANONICAL_TOPOLOGY
  # edge with unconditional SETs, and it runs on EVERY mapper topology report
  # (per upsert_links) plus the cleanup worker. For a static topology that means
  # re-rewriting an unchanged graph indefinitely (observed: tens of millions of
  # CANONICAL_TOPOLOGY updates on a few hundred edges). We fingerprint the
  # structural observed-edge set (CONNECTS_TO start/end ids) and skip the rebuild
  # when it is unchanged, with a heartbeat so a long-static graph still rebuilds
  # periodically (covering rare property-only changes the structural hash omits).
  @default_canonical_rebuild_heartbeat_ms 3_600_000

  @connects_fingerprint_sql "SELECT count(*)::text || ':' || coalesce(md5(string_agg(start_id::text || '>' || end_id::text, ',' ORDER BY start_id, end_id)), '') FROM platform_graph.\"CONNECTS_TO\""

  def rebuild_canonical_links_from_current do
    _ = rebuild_canonical_links_from_current_with_stats()
    :ok
  end

  def rebuild_canonical_links_from_current_with_stats do
    rebuild_canonical_device_links()
  end

  def rebuild_canonical_device_links do
    case maybe_skip_unchanged_rebuild() do
      {:skip, stats} ->
        emit_canonical_rebuild_telemetry(:completed, stats)
        Logger.debug("Canonical topology rebuild skipped; observed topology unchanged")
        {:ok, stats}

      {:proceed, fingerprint} ->
        result = run_canonical_rebuild()
        maybe_record_rebuild_fingerprint(result, fingerprint)
        result
    end
  end

  # Returns {:skip, stats} when the structural observed-edge set is unchanged
  # since the last rebuild and the heartbeat window has not elapsed; otherwise
  # {:proceed, fingerprint}. A nil fingerprint (query failed) always proceeds.
  defp maybe_skip_unchanged_rebuild do
    fingerprint = connects_fingerprint()
    now_ms = System.monotonic_time(:millisecond)
    heartbeat_ms = canonical_rebuild_heartbeat_ms()

    case :persistent_term.get({__MODULE__, :last_rebuild}, nil) do
      {^fingerprint, ts}
      when is_binary(fingerprint) and now_ms - ts < heartbeat_ms ->
        {:skip, %{skipped: true, reason: :unchanged_topology}}

      _ ->
        {:proceed, fingerprint}
    end
  end

  defp connects_fingerprint do
    case Repo.query(@connects_fingerprint_sql, []) do
      {:ok, %{rows: [[fingerprint]]}} when is_binary(fingerprint) -> fingerprint
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_record_rebuild_fingerprint({:ok, _stats}, fingerprint) when is_binary(fingerprint) do
    :persistent_term.put(
      {__MODULE__, :last_rebuild},
      {fingerprint, System.monotonic_time(:millisecond)}
    )

    :ok
  end

  defp maybe_record_rebuild_fingerprint(_result, _fingerprint), do: :ok

  defp canonical_rebuild_heartbeat_ms do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:canonical_rebuild_heartbeat_ms, @default_canonical_rebuild_heartbeat_ms)
    |> Utils.normalize_positive_int(@default_canonical_rebuild_heartbeat_ms)
  end

  defp run_canonical_rebuild do
    case with_canonical_rebuild_lock(&do_rebuild_canonical_device_links/0) do
      {:ok, {:ok, stats}} ->
        {:ok, stats}

      {:ok, {:error, reason, stats}} ->
        {:error, reason, stats}

      {:ok, {:busy, stats}} ->
        emit_canonical_rebuild_telemetry(:completed, stats)
        Logger.debug("Canonical topology rebuild skipped; advisory lock busy")
        {:ok, stats}

      {:error, reason} ->
        failure_stats = lock_skipped_rebuild_stats()
        Logger.warning("Canonical topology rebuild lock acquisition failed: #{inspect(reason)}")
        emit_canonical_rebuild_telemetry(:failed, failure_stats, reason)
        {:error, reason, failure_stats}
    end
  end

  @doc false
  @spec canonical_rebuild_timeout_ms() :: pos_integer()
  def canonical_rebuild_timeout_ms do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:canonical_rebuild_timeout_ms, @default_canonical_rebuild_timeout_ms)
    |> Utils.normalize_positive_int(@default_canonical_rebuild_timeout_ms)
  end

  @doc false
  @spec canonical_rebuild_min_edges() :: pos_integer()
  def canonical_rebuild_min_edges do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:min_canonical_edges, 1)
    |> Utils.normalize_positive_int(1)
  end

  @doc false
  @spec self_heal_needed?(integer(), integer(), integer()) :: boolean()
  def self_heal_needed?(after_prune_edges, mapper_evidence_edges, min_canonical_edges)
      when is_integer(after_prune_edges) and is_integer(mapper_evidence_edges) and
             is_integer(min_canonical_edges) do
    after_prune_edges < min_canonical_edges and mapper_evidence_edges >= min_canonical_edges
  end

  def self_heal_needed?(_after_prune_edges, _mapper_evidence_edges, _min_canonical_edges),
    do: false

  @doc false
  @spec emit_canonical_rebuild_telemetry(:completed | :failed, map(), term() | nil) :: :ok
  def emit_canonical_rebuild_telemetry(status, stats, reason \\ nil)
      when status in [:completed, :failed] and is_map(stats) do
    measurements = %{
      before_edges: Map.get(stats, :before_edges, 0),
      mapper_evidence_edges: Map.get(stats, :mapper_evidence_edges, 0),
      after_upsert_edges: Map.get(stats, :after_upsert_edges, 0),
      after_prune_edges: Map.get(stats, :after_prune_edges, 0)
    }

    metadata =
      maybe_put_reason(
        %{
          status: status,
          stale_cutoff: Map.get(stats, :stale_cutoff),
          prune_result: Map.get(stats, :prune_result),
          telemetry_refresh: Map.get(stats, :telemetry_refresh)
        },
        reason
      )

    :telemetry.execute(
      [:serviceradar, :topology, :canonical_rebuild, status],
      measurements,
      metadata
    )

    :ok
  end

  def canonical_edge_count do
    edge_count_from_query(Queries.canonical_edge_count_query())
  end

  def mapper_evidence_edge_count do
    edge_count_from_query(Queries.mapper_evidence_edge_count_query())
  end

  defp with_canonical_rebuild_lock(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [@canonical_rebuild_lock_key]) do
          {:ok, %{rows: [[true]]}} ->
            fun.()

          {:ok, %{rows: [[false]]}} ->
            {:busy, lock_skipped_rebuild_stats()}

          {:ok, _unexpected} ->
            Repo.rollback(:unexpected_lock_response)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      timeout: canonical_rebuild_timeout_ms()
    )
  end

  defp do_rebuild_canonical_device_links do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()
    stale_cutoff = Utils.stale_cutoff_iso8601()
    min_canonical_edges = canonical_rebuild_min_edges()
    upsert_cypher = Queries.canonical_rebuild_upsert_query(stale_cutoff)

    case Graph.execute(upsert_cypher) do
      :ok ->
        demotion_result = Conflicts.reconcile_competing_same_port_canonical_edges()
        after_upsert_edges = canonical_edge_count()
        prune_result = prune_stale_canonical_device_links(stale_cutoff)
        after_prune_edges = canonical_edge_count()
        telemetry_result = Telemetry.refresh_canonical_edge_telemetry(stale_cutoff)

        {after_prune_edges, self_heal_result} =
          maybe_self_heal_zero_canonical(
            after_prune_edges,
            mapper_evidence_edges,
            stale_cutoff,
            min_canonical_edges
          )

        runtime_projection_refresh = refresh_runtime_topology_projection()

        stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          after_upsert_edges: after_upsert_edges,
          after_prune_edges: after_prune_edges,
          same_port_demotions: demotion_result,
          telemetry_refresh: telemetry_result,
          runtime_projection_refresh: runtime_projection_refresh,
          stale_cutoff: stale_cutoff,
          self_heal_result: self_heal_result,
          lock_skipped: false
        }

        emit_canonical_rebuild_telemetry(:completed, stats)
        Logger.info("canonical_topology_rebuild_stats #{inspect(stats)}")
        {:ok, Map.put(stats, :prune_result, prune_result)}

      {:error, reason} ->
        Logger.warning("Canonical topology rebuild failed: #{inspect(reason)}")

        failure_stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          same_port_demotions: :skipped,
          stale_cutoff: stale_cutoff,
          lock_skipped: false
        }

        emit_canonical_rebuild_telemetry(:failed, failure_stats, reason)
        {:error, reason, failure_stats}
    end
  end

  defp lock_skipped_rebuild_stats do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()

    %{
      before_edges: before_edges,
      mapper_evidence_edges: mapper_evidence_edges,
      after_upsert_edges: before_edges,
      after_prune_edges: before_edges,
      same_port_demotions: :skipped,
      telemetry_refresh: :skipped,
      stale_cutoff: Utils.stale_cutoff_iso8601(),
      self_heal_result: %{status: :skipped},
      prune_result: :skipped,
      lock_skipped: true
    }
  end

  defp refresh_runtime_topology_projection do
    case RuntimeTopologyProjection.refresh_from_graph() do
      {:ok, summary} ->
        summary

      {:error, reason} ->
        Logger.warning("Runtime topology projection refresh failed: #{inspect(reason)}")
        %{status: :failed, reason: inspect(reason)}
    end
  end

  defp maybe_self_heal_zero_canonical(
         after_prune_edges,
         mapper_evidence_edges,
         stale_cutoff,
         min_canonical_edges
       )
       when is_integer(after_prune_edges) and is_integer(mapper_evidence_edges) and
              is_binary(stale_cutoff) and
              is_integer(min_canonical_edges) do
    if self_heal_needed?(after_prune_edges, mapper_evidence_edges, min_canonical_edges) do
      Logger.warning(
        "Canonical topology self-heal triggered",
        after_prune_edges: after_prune_edges,
        mapper_evidence_edges: mapper_evidence_edges,
        min_canonical_edges: min_canonical_edges
      )

      case Graph.execute(Queries.canonical_rebuild_upsert_query(stale_cutoff)) do
        :ok ->
          healed_edges = canonical_edge_count()
          {healed_edges, %{status: :completed, before: after_prune_edges, after: healed_edges}}

        {:error, reason} ->
          Logger.warning("Canonical topology self-heal failed", reason: inspect(reason))

          {after_prune_edges,
           %{status: :failed, before: after_prune_edges, after: after_prune_edges, reason: reason}}
      end
    else
      {after_prune_edges, %{status: :skipped}}
    end
  end

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, inspect(reason))

  defp prune_stale_canonical_device_links(stale_cutoff) when is_binary(stale_cutoff) do
    prune_cypher = Queries.canonical_rebuild_prune_query(stale_cutoff)

    case Graph.execute(prune_cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Canonical topology stale-edge prune failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp edge_count_from_query(cypher) when is_binary(cypher) do
    case Graph.query(cypher) do
      {:ok, [row | _]} ->
        row
        |> Utils.map_value(:count)
        |> parse_count()

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning("Topology edge count query failed: #{inspect(reason)}")
        0
    end
  end

  defp parse_count(value) when is_integer(value) and value >= 0, do: value

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_count(_), do: 0
end
