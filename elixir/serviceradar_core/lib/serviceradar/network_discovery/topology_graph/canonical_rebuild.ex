defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalMutationLock
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild.Conflicts
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.Repo

  require Logger

  @default_canonical_rebuild_timeout_ms 60_000
  @projection_name "runtime_topology_links"

  # Starvation guard (fj #4378): when mapper evidence ingest freezes upstream,
  # every evidence edge eventually ages past the stale cutoff. The upsert then
  # matches nothing while the stale prune would still happily delete the entire
  # CANONICAL_TOPOLOGY set — that is evidence starvation, not topology change,
  # and the prune must be skipped instead. Two persistent health conditions
  # (deduplicated via HealthConditions) track the outage: transitions log at
  # error level, steady-state repeats at info, recovery logs the all-clear.
  @starvation_condition :canonical_rebuild_starved
  @self_heal_condition :canonical_self_heal
  @default_canonical_prune_max_fraction 0.5

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
    case with_canonical_rebuild_lock(fn -> do_rebuild_canonical_device_links() end) do
      {:ok, {:ok, structural_stats}} ->
        # The telemetry + projection refresh run AFTER the advisory-lock
        # transaction commits, at top level. Both call paths reach here without
        # an enclosing transaction (the hourly TopologyStateCleanupWorker and the
        # per-report mapper ingest in MapperResultsIngestor), so this is a real
        # top-level checkout, not a nested savepoint.
        #
        # They are idempotent, eventually-consistent materializations of the
        # just-rebuilt CANONICAL_TOPOLOGY. Keeping their full read/compute/write
        # pipelines inside this transaction made one pooled connection hold, in
        # series, the structural rebuild + a full metrics scan + N cypher telemetry
        # batches + the projection delete/insert. On a churn-bloated AGE graph the
        # cumulative hold exceeded the 60s pool checkout budget. Running them here
        # bounds this transaction to the structural rebuild. The telemetry writer
        # reacquires the same advisory lock only for its AGE SET batches, preventing
        # concurrent canonical mutations without putting its metric scan back under
        # this long-lived transaction.
        finalize_canonical_rebuild(structural_stats, fingerprint)

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
  @spec self_heal_condition() :: atom()
  def self_heal_condition, do: @self_heal_condition

  @doc false
  @spec starvation_condition() :: atom()
  def starvation_condition, do: @starvation_condition

  @doc false
  # Canonical edge count at or below this floor after the upsert counts as
  # starved when mapper evidence exists. Default 0: only an empty canonical
  # graph triggers via this term (the evidence-freshness term catches the
  # first fatal run, when stale edges are still present).
  @spec canonical_rebuild_min_upsert_floor() :: non_neg_integer()
  def canonical_rebuild_min_upsert_floor do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:canonical_rebuild_min_upsert_floor, 0)
    |> Utils.non_negative_integer(0)
  end

  @doc false
  # Mass-deletion guardrail: refuse a stale prune that would delete more than
  # this fraction of the pre-rebuild canonical edges in one pass.
  @spec canonical_prune_max_fraction() :: float()
  def canonical_prune_max_fraction do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:canonical_prune_max_fraction, @default_canonical_prune_max_fraction)
    |> normalize_fraction(@default_canonical_prune_max_fraction)
  end

  defp normalize_fraction(value, _default) when is_number(value) and value > 0 and value <= 1,
    do: value * 1.0

  defp normalize_fraction(_value, default), do: default

  @doc false
  # Operator override for the mass-deletion guardrail (a deliberate large prune
  # after a real topology cutover). Leave false in steady state.
  @spec canonical_prune_guard_override?() :: boolean()
  def canonical_prune_guard_override? do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:canonical_prune_guard_override, false)
    |> Utils.truthy?()
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
  # Pure starvation decision (extracted so it is unit-testable without a DB).
  # Starved when mapper evidence exists AND either:
  #   * the canonical edge count after the upsert is at or below the configured
  #     floor (steady state after a wipe: upsert matched nothing, graph empty), or
  #   * the freshest evidence is older than the stale cutoff (first fatal run:
  #     stale canonical edges are still present, so the count looks healthy, but
  #     the prune would delete every one of them).
  # Timestamps are ISO8601 UTC strings compared bytewise — the exact comparison
  # the upsert/prune cypher already performs on these same values, and binary
  # `<` is guard-safe. A nil evidence max (no evidence rows carry timestamps)
  # fails open into normal behavior.
  @spec starvation_check(integer(), integer(), String.t() | nil, String.t(), non_neg_integer()) ::
          :starved | :ok
  def starvation_check(
        after_upsert_edges,
        mapper_evidence_edges,
        evidence_max_last_observed_at,
        stale_cutoff,
        min_upsert_floor
      )

  def starvation_check(after_upsert_edges, mapper_evidence_edges, _evidence_max, _cutoff, floor)
      when is_integer(after_upsert_edges) and is_integer(mapper_evidence_edges) and
             is_integer(floor) and
             mapper_evidence_edges > 0 and after_upsert_edges <= floor do
    :starved
  end

  def starvation_check(_after_upsert_edges, mapper_evidence_edges, evidence_max, cutoff, _floor)
      when is_integer(mapper_evidence_edges) and mapper_evidence_edges > 0 and
             is_binary(evidence_max) and
             is_binary(cutoff) and evidence_max < cutoff do
    :starved
  end

  def starvation_check(_after_upsert, _mapper_evidence, _evidence_max, _cutoff, _floor), do: :ok

  @doc false
  # Pure mass-deletion guardrail decision. Refuses when a single prune pass
  # would delete more than max_fraction of the pre-rebuild canonical edges,
  # unless the operator override is set. A nil candidate count (count query
  # failed) fails closed — stale-but-connected beats silently-empty.
  @spec prune_guard_check(non_neg_integer() | nil, integer(), number(), boolean()) ::
          :allow | {:refuse, :mass_deletion | :candidate_count_unavailable}
  def prune_guard_check(prune_candidates, before_edges, max_fraction, override?)

  def prune_guard_check(_candidates, _before_edges, _max_fraction, true), do: :allow
  def prune_guard_check(0, _before_edges, _max_fraction, false), do: :allow

  def prune_guard_check(candidates, before_edges, max_fraction, false)
      when is_integer(candidates) and is_integer(before_edges) and is_number(max_fraction) do
    if candidates > before_edges * max_fraction do
      {:refuse, :mass_deletion}
    else
      :allow
    end
  end

  def prune_guard_check(_candidates, _before_edges, _max_fraction, false),
    do: {:refuse, :candidate_count_unavailable}

  @doc false
  # Emits the starvation signal: telemetry on every occurrence plus a
  # deduplicated persistent condition (error log on transition, info with
  # ongoing_failure flag on repeats).
  @spec report_starvation(map(), String.t(), String.t() | nil, non_neg_integer(), keyword()) ::
          :ok
  def report_starvation(counts, stale_cutoff, evidence_max_last_observed_at, floor, opts \\ [])
      when is_map(counts) do
    condition = Keyword.get(opts, :condition, @starvation_condition)

    :telemetry.execute(
      [:serviceradar, :topology, :canonical_rebuild, :starved],
      %{
        before_edges: Map.get(counts, :before_edges, 0),
        mapper_evidence_edges: Map.get(counts, :mapper_evidence_edges, 0),
        after_upsert_edges: Map.get(counts, :after_upsert_edges, 0)
      },
      %{
        stale_cutoff: stale_cutoff,
        evidence_max_last_observed_at: evidence_max_last_observed_at,
        min_upsert_floor: floor
      }
    )

    _ =
      HealthConditions.report_failure(
        condition,
        "Canonical topology rebuild starved: mapper evidence exists but none is fresh enough to upsert; skipping stale prune to protect the canonical graph",
        before_edges: Map.get(counts, :before_edges, 0),
        mapper_evidence_edges: Map.get(counts, :mapper_evidence_edges, 0),
        after_upsert_edges: Map.get(counts, :after_upsert_edges, 0),
        stale_cutoff: stale_cutoff,
        evidence_max_last_observed_at: evidence_max_last_observed_at
      )

    :ok
  end

  @doc false
  # Emits the mass-deletion refusal signal (always error level: a refusal is a
  # rare, actionable event, not a steady state).
  @spec report_prune_refusal(atom(), non_neg_integer() | nil, map(), String.t(), number()) :: :ok
  def report_prune_refusal(reason, candidates, counts, stale_cutoff, max_fraction)
      when is_atom(reason) and is_map(counts) do
    before_edges = Map.get(counts, :before_edges, 0)

    :telemetry.execute(
      [:serviceradar, :topology, :canonical_rebuild, :prune_refused],
      %{
        prune_candidates: candidates || 0,
        before_edges: before_edges,
        mapper_evidence_edges: Map.get(counts, :mapper_evidence_edges, 0),
        after_upsert_edges: Map.get(counts, :after_upsert_edges, 0)
      },
      %{reason: reason, stale_cutoff: stale_cutoff, max_fraction: max_fraction}
    )

    Logger.error(
      "Canonical topology stale prune refused (#{reason}): would delete " <>
        "#{candidates || "unknown"} of #{before_edges} canonical edges in one pass " <>
        "(max fraction #{max_fraction}); set canonical_prune_guard_override to force"
    )

    :ok
  end

  @doc false
  # Honest self-heal outcome (fj #4378): a recovery upsert that still leaves the
  # canonical edge count below the threshold while mapper evidence exists is a
  # FAILURE — emit self_heal_failed telemetry and the deduplicated unhealthy
  # condition instead of claiming completion. Recovery above the threshold
  # clears the condition and logs the all-clear.
  @spec finalize_self_heal_outcome(integer(), integer(), integer(), integer(), keyword()) ::
          map()
  def finalize_self_heal_outcome(
        before_edges,
        healed_edges,
        mapper_evidence_edges,
        min_canonical_edges,
        opts \\ []
      )
      when is_integer(before_edges) and is_integer(healed_edges) and
             is_integer(mapper_evidence_edges) and
             is_integer(min_canonical_edges) do
    condition = Keyword.get(opts, :condition, @self_heal_condition)

    if self_heal_needed?(healed_edges, mapper_evidence_edges, min_canonical_edges) do
      :telemetry.execute(
        [:serviceradar, :topology, :canonical_rebuild, :self_heal_failed],
        %{
          before_edges: before_edges,
          after_edges: healed_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          min_canonical_edges: min_canonical_edges
        },
        %{reason: :canonical_edges_below_threshold}
      )

      _ =
        HealthConditions.report_failure(
          condition,
          "Canonical topology self-heal FAILED: rebuild still has fewer canonical edges than the threshold while mapper evidence exists",
          before_edges: before_edges,
          after_edges: healed_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          min_canonical_edges: min_canonical_edges
        )

      %{
        status: :failed,
        reason: :canonical_edges_below_threshold,
        before: before_edges,
        after: healed_edges
      }
    else
      _ =
        HealthConditions.report_recovery(
          condition,
          "Canonical topology self-heal recovered canonical edges",
          before_edges: before_edges,
          after_edges: healed_edges,
          min_canonical_edges: min_canonical_edges
        )

      %{status: :completed, before: before_edges, after: healed_edges}
    end
  end

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
          telemetry_refresh: Map.get(stats, :telemetry_refresh),
          starved: Map.get(stats, :starved, false),
          evidence_max_last_observed_at: Map.get(stats, :evidence_max_last_observed_at)
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

  @doc false
  # Max last_observed_at (falling back to observed_at) across mapper evidence,
  # as an ISO8601 string, or nil when unavailable. Feeds the rebuild stats /
  # telemetry so evidence freshness vs. the stale cutoff is visible, and the
  # starvation guard's freshness term.
  @spec mapper_evidence_max_last_observed_at() :: String.t() | nil
  def mapper_evidence_max_last_observed_at do
    case Graph.query(Queries.mapper_evidence_freshness_query()) do
      {:ok, [row | _]} ->
        case Utils.map_value(row, :max_last_observed_at) do
          value when is_binary(value) -> value
          _ -> nil
        end

      {:ok, _} ->
        nil

      {:error, reason} ->
        Logger.warning("Mapper evidence freshness query failed: #{inspect(reason)}")
        nil
    end
  end

  defp with_canonical_rebuild_lock(fun) when is_function(fun, 0) do
    CanonicalMutationLock.try_run(fun,
      busy_result: {:busy, lock_skipped_rebuild_stats()},
      timeout: canonical_rebuild_timeout_ms()
    )
  end

  # Structural canonical rebuild — runs INSIDE the canonical mutation lock.
  # Everything here mutates CANONICAL_TOPOLOGY structure (upsert + reconcile +
  # guarded prune + self-heal) and must be serialized by the lock. The two
  # downstream materializations (telemetry refresh + projection refresh) are
  # deliberately NOT run here; they run in finalize_canonical_rebuild/2 after the
  # structural transaction commits so they don't extend the lock connection's
  # checkout past the pool budget. Telemetry reacquires this lock only around its
  # AGE writes. Returns {:ok, structural_stats} (telemetry_refresh /
  # runtime_projection_refresh are merged in later) or {:error, reason, stats}.
  defp do_rebuild_canonical_device_links do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()
    evidence_max_last_observed_at = mapper_evidence_max_last_observed_at()
    stale_cutoff = Utils.stale_cutoff_iso8601()
    min_canonical_edges = canonical_rebuild_min_edges()
    upsert_cypher = Queries.canonical_rebuild_upsert_query(stale_cutoff)

    case Graph.execute(upsert_cypher) do
      :ok ->
        demotion_result = Conflicts.reconcile_competing_same_port_canonical_edges()
        after_upsert_edges = canonical_edge_count()

        counts = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          after_upsert_edges: after_upsert_edges
        }

        {starved, prune_result} =
          run_guarded_stale_prune(counts, stale_cutoff, evidence_max_last_observed_at)

        after_prune_edges = canonical_edge_count()

        {after_prune_edges, self_heal_result} =
          maybe_self_heal_zero_canonical(
            after_prune_edges,
            mapper_evidence_edges,
            stale_cutoff,
            min_canonical_edges
          )

        structural_stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          after_upsert_edges: after_upsert_edges,
          after_prune_edges: after_prune_edges,
          same_port_demotions: demotion_result,
          stale_cutoff: stale_cutoff,
          evidence_max_last_observed_at: evidence_max_last_observed_at,
          starved: starved,
          prune_result: prune_result,
          self_heal_result: self_heal_result,
          lock_skipped: false
        }

        {:ok, structural_stats}

      {:error, reason} ->
        Logger.warning("Canonical topology rebuild failed: #{inspect(reason)}")

        failure_stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          evidence_max_last_observed_at: evidence_max_last_observed_at,
          same_port_demotions: :skipped,
          stale_cutoff: stale_cutoff,
          lock_skipped: false
        }

        emit_canonical_rebuild_telemetry(:failed, failure_stats, reason)
        {:error, reason, failure_stats}
    end
  end

  # Runs AFTER the advisory-lock transaction commits (see run_canonical_rebuild/1).
  # Refreshes the canonical-edge flow telemetry and then the SQL runtime-topology
  # projection, each on its own pooled connection rather than the (now released)
  # lock connection. Telemetry runs before the projection because the projection
  # query reads the flow_pps/flow_bps the telemetry step writes onto the canonical
  # edges. Both degrade gracefully: a failure is captured in the stats map (as it
  # was before) and never fails the sibling step or the overall rebuild — the
  # cleanup worker treats the {:ok, stats} as completed-with-degradation and
  # retries the failed materialization next cycle.
  defp finalize_canonical_rebuild(structural_stats, fingerprint) when is_map(structural_stats) do
    stale_cutoff = Map.fetch!(structural_stats, :stale_cutoff)

    telemetry_result = Telemetry.refresh_canonical_edge_telemetry(stale_cutoff)
    runtime_projection_refresh = refresh_runtime_topology_projection(fingerprint)

    stats =
      structural_stats
      |> Map.put(:telemetry_refresh, telemetry_result)
      |> Map.put(:runtime_projection_refresh, runtime_projection_refresh)

    emit_canonical_rebuild_telemetry(:completed, stats)
    Logger.info("canonical_topology_rebuild_stats #{inspect(stats)}")
    {:ok, stats}
  end

  # Starvation guard (fj #4378): decide whether the stale prune may run at all.
  # Starved -> skip the prune entirely and raise the starvation signal (the
  # canonical edges are retained until fresh evidence arrives or an operator
  # intervenes). Not starved -> clear any prior starvation condition, then run
  # the prune behind the mass-deletion guardrail. Returns {starved?, prune_result}.
  defp run_guarded_stale_prune(counts, stale_cutoff, evidence_max_last_observed_at) do
    min_upsert_floor = canonical_rebuild_min_upsert_floor()

    case starvation_check(
           counts.after_upsert_edges,
           counts.mapper_evidence_edges,
           evidence_max_last_observed_at,
           stale_cutoff,
           min_upsert_floor
         ) do
      :starved ->
        report_starvation(counts, stale_cutoff, evidence_max_last_observed_at, min_upsert_floor)
        {true, :skipped_starved}

      :ok ->
        _ =
          HealthConditions.report_recovery(
            @starvation_condition,
            "Canonical topology rebuild starvation cleared; fresh mapper evidence is flowing again",
            before_edges: counts.before_edges,
            mapper_evidence_edges: counts.mapper_evidence_edges,
            after_upsert_edges: counts.after_upsert_edges
          )

        {false, guarded_prune(counts, stale_cutoff)}
    end
  end

  # Defense-in-depth: count what the prune would delete (mirrored WHERE clause)
  # and refuse a single pass that removes more than the configured fraction of
  # the pre-rebuild canonical edges, unless the operator override is set.
  defp guarded_prune(counts, stale_cutoff) do
    candidates = prune_candidate_count(stale_cutoff)
    max_fraction = canonical_prune_max_fraction()
    override? = canonical_prune_guard_override?()

    case prune_guard_check(candidates, counts.before_edges, max_fraction, override?) do
      :allow ->
        prune_stale_canonical_device_links(stale_cutoff)

      {:refuse, reason} ->
        report_prune_refusal(reason, candidates, counts, stale_cutoff, max_fraction)
        {:refused, reason}
    end
  end

  # nil (not 0) on failure so the guardrail fails closed rather than treating an
  # unknown candidate set as "nothing to delete".
  defp prune_candidate_count(stale_cutoff) when is_binary(stale_cutoff) do
    case Graph.query(Queries.canonical_rebuild_prune_candidate_count_query(stale_cutoff)) do
      {:ok, [row | _]} ->
        row
        |> Utils.map_value(:count)
        |> parse_count()

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning("Canonical prune candidate count query failed: #{inspect(reason)}")
        nil
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
      evidence_max_last_observed_at: nil,
      starved: false,
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

          {healed_edges,
           finalize_self_heal_outcome(
             after_prune_edges,
             healed_edges,
             mapper_evidence_edges,
             min_canonical_edges
           )}

        {:error, reason} ->
          Logger.warning("Canonical topology self-heal failed", reason: inspect(reason))

          {after_prune_edges,
           %{status: :failed, before: after_prune_edges, after: after_prune_edges, reason: reason}}
      end
    else
      # Canonical edges are above the threshold (or there is no evidence to
      # rebuild from): if a self-heal failure condition was active, this is the
      # recovery — clear it and log the all-clear. Read-only no-op otherwise.
      _ =
        HealthConditions.report_recovery(
          @self_heal_condition,
          "Canonical topology recovered: canonical edges are back above the self-heal threshold",
          after_prune_edges: after_prune_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          min_canonical_edges: min_canonical_edges
        )

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
