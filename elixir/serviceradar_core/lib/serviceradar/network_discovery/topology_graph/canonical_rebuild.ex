defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

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
  @projection_name "runtime_topology_links"

  # Change-detection: the canonical rebuild rewrites every CANONICAL_TOPOLOGY
  # edge with unconditional SETs, and it runs on EVERY mapper topology report
  # (per upsert_links) plus the cleanup worker. For a static topology that means
  # re-rewriting an unchanged graph indefinitely (observed: tens of millions of
  # CANONICAL_TOPOLOGY updates on a few hundred edges). We fingerprint the full
  # mapper-evidence input (every observed edge label's start/end ids plus the
  # per-edge properties that drive the upsert content_hash) and skip the rebuild
  # when it is unchanged, with a heartbeat so a long-static graph still rebuilds
  # periodically (a defence-in-depth backstop, since the fingerprint now covers
  # property changes the old structural-only hash omitted).
  @default_canonical_rebuild_heartbeat_ms 3_600_000

  # The skip-guard fingerprint is persisted on the shared
  # platform.runtime_topology_projection_meta row (input_hash / input_hashed_at)
  # rather than a process-local :persistent_term. persistent_term is wiped on
  # every pod restart, so each rollout forced a cold full canonical rebuild on
  # every replica (the rollout-correlated CNPG CPU burst). The shared meta row
  # makes the guard durable across restarts and consistent across replicas. A nil
  # input_hash (fresh deploy, query failure) always fails open into a rebuild, so
  # the guard can never erroneously skip a needed change.

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
        run_canonical_rebuild(fingerprint)
    end
  end

  # Returns {:skip, stats} when the full mapper-evidence input is unchanged since
  # the last rebuild and the heartbeat window has not elapsed; otherwise
  # {:proceed, fingerprint}. The last-applied fingerprint is read from the shared
  # platform.runtime_topology_projection_meta row so the guard survives restarts
  # and is consistent across replicas. A nil current fingerprint (query failed) or
  # a nil stored fingerprint (fresh deploy) always proceeds (fail-open).
  defp maybe_skip_unchanged_rebuild do
    skip_decision(
      rebuild_input_fingerprint(),
      stored_rebuild_fingerprint(),
      canonical_rebuild_heartbeat_ms(),
      DateTime.utc_now()
    )
  end

  @doc false
  # Pure skip/proceed decision (extracted so it is unit-testable without a DB).
  # Returns {:skip, stats} only when the current fingerprint exactly matches the
  # stored fingerprint AND the heartbeat window has not elapsed; otherwise
  # {:proceed, current_fingerprint}. A nil current fingerprint (query failed) or a
  # nil stored fingerprint (fresh deploy / wiped row) always proceeds (fail-open).
  @spec skip_decision(
          String.t() | nil,
          {String.t(), DateTime.t()} | nil,
          pos_integer(),
          DateTime.t()
        ) :: {:skip, map()} | {:proceed, String.t() | nil}
  def skip_decision(current_fingerprint, stored, heartbeat_ms, now)

  def skip_decision(
        fingerprint,
        {stored_hash, %DateTime{} = hashed_at},
        heartbeat_ms,
        %DateTime{} = now
      )
      when is_binary(fingerprint) and stored_hash == fingerprint and is_integer(heartbeat_ms) do
    if heartbeat_elapsed?(hashed_at, heartbeat_ms, now) do
      {:proceed, fingerprint}
    else
      {:skip, %{skipped: true, reason: :unchanged_topology}}
    end
  end

  def skip_decision(fingerprint, _stored, _heartbeat_ms, _now), do: {:proceed, fingerprint}

  # Wall-clock heartbeat (the stored timestamp is persisted, so monotonic time is
  # meaningless across restarts). A future stored timestamp (clock skew) yields a
  # negative diff, i.e. "not elapsed" — only reachable when the hash already
  # matches (unchanged topology), so treating it as recent and skipping is safe; a
  # changed fingerprint forces a rebuild via skip_decision regardless of time.
  defp heartbeat_elapsed?(%DateTime{} = hashed_at, heartbeat_ms, %DateTime{} = now)
       when is_integer(heartbeat_ms) do
    DateTime.diff(now, hashed_at, :millisecond) >= heartbeat_ms
  end

  defp rebuild_input_fingerprint do
    case Repo.query(Queries.rebuild_input_fingerprint_query(), []) do
      {:ok, %{rows: [[fingerprint]]}} when is_binary(fingerprint) -> fingerprint
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp stored_rebuild_fingerprint do
    # input_hashed_at is a `timestamp without time zone` column, so a schemaless
    # read yields a NaiveDateTime; type/2 loads it as a UTC DateTime to match the
    # DateTime the skip-guard compares against.
    query =
      from(m in "runtime_topology_projection_meta",
        prefix: "platform",
        where: m.projection_name == ^@projection_name,
        select: {m.input_hash, type(m.input_hashed_at, :utc_datetime_usec)}
      )

    case Repo.one(query) do
      {hash, hashed_at} when is_binary(hash) ->
        case normalize_hashed_at(hashed_at) do
          %DateTime{} = dt -> {hash, dt}
          nil -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Normalize the stored timestamp to a UTC DateTime. type/2 above should already
  # load it as a DateTime, but the column is `timestamp without time zone`, so a
  # raw schemaless read can surface a NaiveDateTime — accept both so the skip-guard
  # never silently fails open (which would defeat the whole rebuild-skip).
  defp normalize_hashed_at(%DateTime{} = dt), do: dt
  defp normalize_hashed_at(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp normalize_hashed_at(_), do: nil

  defp canonical_rebuild_heartbeat_ms do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:canonical_rebuild_heartbeat_ms, @default_canonical_rebuild_heartbeat_ms)
    |> Utils.normalize_positive_int(@default_canonical_rebuild_heartbeat_ms)
  end

  defp run_canonical_rebuild(fingerprint) do
    case with_canonical_rebuild_lock(fn -> do_rebuild_canonical_device_links(fingerprint) end) do
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

  defp do_rebuild_canonical_device_links(fingerprint) do
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

        runtime_projection_refresh = refresh_runtime_topology_projection(fingerprint)

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

  # Thread the rebuild-input fingerprint into the projection refresh so it is
  # written to runtime_topology_projection_meta.input_hash in the SAME insert_all
  # that records refreshed_at/row_count. The hash therefore advances only after a
  # successful rebuild + projection refresh, so a failed rebuild is retried next
  # cycle rather than cached as "done".
  defp refresh_runtime_topology_projection(fingerprint) do
    case RuntimeTopologyProjection.refresh_from_graph(input_hash: fingerprint) do
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
