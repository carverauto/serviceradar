defmodule ServiceRadar.ColdTier.RetentionFence do
  @moduledoc """
  The single authority for TimescaleDB retention-policy DDL on cold-tier
  registry tables (OpenSpec add-tiered-telemetry-offload, task 2.4; spec
  requirement "Retention policy installation is fenced through a single
  shared helper").

  Both `ServiceRadar.Observability.DataRetentionWorker` and retention-policy
  migrations MUST route registry-table policy DDL through this module. When
  the cold tier is enabled for a deployment:

    * in-database retention policies for registry tables are REMOVED (never
      re-armed) so the TimescaleDB background worker can never drop
      un-exported chunks autonomously;
    * `drop_chunks` is bounded by `safe_drop_point/2`: the oldest of the
      retention cutoff, the analytics-head-acknowledged query boundary (B),
      and the first non-verified chunk — so only contiguously verified,
      below-boundary data can ever be dropped.

  When the cold tier is disabled (the OSS default), every function delegates
  to today's behavior unchanged.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.Repo

  require Logger

  @query_timeout_ms 120_000

  # Update-prone chunks must have been re-exported within this window to be
  # eligible for drop (review F03). Kept looser than the exporter's pre-drop
  # re-export throttle (@update_prone_reexport_interval_hours) so near-drop
  # chunks stay fresh enough to pass rather than being held indefinitely.
  @update_prone_freshness_hours 6

  # Advisory-lock namespace for cold-tier drop serialization. The gate holds
  # this per-table lock across its read + drop, and the exporter holds it
  # around each manifest status flip, so a chunk can never transition
  # verified<->pending between the gate's checks and its drop (review F02).
  @advisory_namespace 0x0C01D

  # Continuous aggregates that retain less than a cold-tier deployment can
  # usefully look back, with the window they need once raw history is served
  # from the cold tier. Raw-granularity history beyond the hot window comes
  # from cold objects; stats/downsample surfaces stay on in-database CAGGs, so
  # a 90-day cold window over a 24-hour rollup leaves those surfaces blank for
  # the range the raw data covers.
  #
  # These are compile-time constants, never user input -- they are interpolated
  # into DDL below, which is the same pattern the rest of this module uses.
  @cagg_cold_windows [
    {"ocsf_events_hourly_stats", 90},
    {"traces_stats_5m", 90},
    {"ocsf_network_activity_hourly_proto", 90},
    {"ocsf_network_activity_hourly_talkers", 90},
    {"ocsf_network_activity_hourly_ports", 90}
  ]

  @doc """
  Run `fun` while holding the per-table cold-tier drop lock (a transaction
  scoped `pg_advisory_xact_lock`). Serializes the retention drop against the
  exporter's manifest status transitions so the drop gate always reads a
  consistent manifest state. The lock is NOT held across the exporter's COPY —
  only its fast status flips — so a nightly drop never blocks on a long
  export (it just sees the chunk as `pending` and holds it).
  """
  @spec with_table_lock(String.t(), (-> result), keyword()) :: result when result: var
  def with_table_lock(table_name, fun, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    {:ok, result} =
      repo.transaction(
        fn ->
          SQL.query!(
            repo,
            "SELECT pg_advisory_xact_lock($1::int, hashtext($2))",
            [@advisory_namespace, table_name],
            timeout: @query_timeout_ms
          )

          fun.()
        end,
        timeout: @query_timeout_ms
      )

    result
  end

  @doc """
  Whether in-database retention policies are fenced off for this table.

  Keys off the SAME activation state as the exporter (`Config.enabled?/0`,
  i.e. state == :enabled) — NOT mere cold-tier intent. A partial config that
  fenced retention while the exporter could not run would hold data hot
  forever and fill the primary (review F09); a misconfigured deployment
  therefore does not fence, and normal retention proceeds.

  Also fenced when the cold tier has been disabled but un-drained state
  remains (two-phase disable, task 2.6): flipping the env off must never
  silently re-arm drops while un-exported chunks are held. The operator
  completes the disable with `ServiceRadar.ColdTier.Admin.waive/2`, which
  clears the residue.
  """
  @spec fenced?(String.t()) :: boolean()
  def fenced?(table_name) do
    Registry.member?(table_name) and (Config.enabled?() or residue?(table_name))
  end

  @doc "Registry tables still fenced by residue while the cold tier is not enabled."
  @spec undrained_tables(keyword()) :: [String.t()]
  def undrained_tables(opts \\ []) do
    if Config.enabled?() do
      []
    else
      Enum.filter(Registry.table_names(), &residue?(&1, opts))
    end
  end

  defp residue?(table_name, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case SQL.query(
           repo,
           "SELECT 1 FROM platform.cold_tier_boundaries WHERE table_name = $1 LIMIT 1",
           [table_name],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: [_ | _]}} -> true
      {:ok, _} -> false
      # Table absent => cold tier never ran here; nothing to protect.
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> false
      # Unknown state: fail safe — keep the fence up.
      {:error, _} -> true
    end
  end

  @doc """
  Reconcile the in-database retention policy for a table.

  Unfenced: remove + re-add the policy at `retention_days` (current
  behavior). Fenced: remove the policy and do not re-add it. Safe to call
  from migrations and from the retention worker; no-ops gracefully when the
  table is not a hypertable or TimescaleDB is absent.
  """
  @spec reconcile_policy(String.t(), pos_integer(), keyword()) :: :ok | {:error, term()}
  def reconcile_policy(table_name, retention_days, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    if fenced?(table_name) do
      run_policy_sql(repo, table_name, remove_policy_sql(table_name))
    else
      run_policy_sql(repo, table_name, replace_policy_sql(table_name, retention_days))
    end
  end

  @doc """
  Assert no in-database retention policy exists on fenced tables; returns the
  list of violations (empty when clean). The exporter calls this every run
  and alerts on violations (defense-in-depth against future migrations or
  manual DDL re-arming a policy).
  """
  @spec policy_violations(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def policy_violations(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    if Config.enabled?() do
      case SQL.query(
             repo,
             """
             SELECT hypertable_name
             FROM timescaledb_information.jobs
             WHERE proc_name = 'policy_retention'
               AND hypertable_schema = 'platform'
               AND hypertable_name = ANY($1)
             """,
             [Registry.table_names()],
             timeout: @query_timeout_ms
           ) do
        {:ok, %{rows: rows}} ->
          {:ok, List.flatten(rows)}

        {:error, error} ->
          # "Can't check" is NOT "clean" (review F07): a query failure must not
          # read as an absence of violations, or a broken fence looks healthy.
          {:error, error}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  The timestamp below which chunks of `table_name` may be dropped.

  Unfenced: the plain retention cutoff (`now() - retention_days`). Fenced:
  the least of the retention cutoff, the acknowledged query boundary (B),
  and the start of the first chunk that is not `verified` in the manifest —
  which makes dropping a contiguous verified prefix safe by construction
  (design D3/D5). Returns `{:ok, DateTime.t()}` or `:hold` when nothing may
  be dropped (no boundary acked yet, or the oldest chunk is unverified).
  """
  @spec safe_drop_point(String.t(), pos_integer(), keyword()) :: {:ok, DateTime.t()} | :hold
  def safe_drop_point(table_name, retention_days, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    retention_cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    if fenced?(table_name) do
      with {:ok, boundary} when not is_nil(boundary) <- acked_boundary(repo, table_name),
           {:ok, verified_through} when not is_nil(verified_through) <-
             contiguous_verified_through(repo, table_name, retention_cutoff) do
        point = Enum.min([retention_cutoff, boundary, verified_through], DateTime)

        # Drop-time re-verification (spec: "Retention is offload-gated with
        # drop-time re-verification"): count-check every verified chunk about
        # to be dropped against its manifest row; clamp to the first drifted
        # chunk so it is held for the exporter's re-export instead of dropped.
        #
        # Fails CLOSED: if the check itself cannot complete, we do not know
        # whether the archive matches the source, and an unverifiable state
        # must never authorize deletion.
        drift_clamp(repo, table_name, point)
      else
        _ -> :hold
      end
    else
      {:ok, retention_cutoff}
    end
  end

  @doc """
  CAGGs whose refresh window reaches at or past their raw source's retention
  boundary — the configuration that DELETES materialized history when the
  policy refresh covers a dropped-chunk region (verified on TimescaleDB
  2.24.0: drop_chunks plants invalidations; a covering refresh recomputes
  those buckets from empty raw). Data-driven from the Timescale catalog plus,
  for registry tables (whose in-DB retention policy is removed under the
  fence), the configured hot window. Runs on every deployment — this hazard
  class is not cold-tier-specific.

  Returns [%{view, source, refresh_start, source_retention}].
  """
  @spec cagg_refresh_hazards(keyword()) :: [map()]
  def cagg_refresh_hazards(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    registry_windows =
      Map.new(Registry.tables(), fn entry ->
        {entry.table, Registry.hot_retention_days(entry)}
      end)

    sql = """
    SELECT agg.view_name,
           agg.hypertable_name AS source,
           refresh.config->>'start_offset' AS refresh_start,
           retention.config->>'drop_after' AS source_retention,
           CASE
             WHEN retention.config IS NOT NULL
              AND (refresh.config->>'start_offset')::interval >=
                  (retention.config->>'drop_after')::interval
             THEN true
             ELSE false
           END AS policy_hazard
    FROM timescaledb_information.continuous_aggregates agg
    JOIN timescaledb_information.jobs refresh
      ON refresh.proc_name = 'policy_refresh_continuous_aggregate'
     AND refresh.hypertable_schema = agg.view_schema
     AND refresh.hypertable_name = agg.view_name
    LEFT JOIN timescaledb_information.jobs retention
      ON retention.proc_name = 'policy_retention'
     AND retention.hypertable_schema = agg.hypertable_schema
     AND retention.hypertable_name = agg.hypertable_name
    WHERE agg.hypertable_schema = 'platform'
    """

    case SQL.query(repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} ->
        for [view, source, refresh_start, source_retention, policy_hazard] <- rows,
            hazard?(policy_hazard, refresh_start, Map.get(registry_windows, source)) do
          %{
            view: view,
            source: source,
            refresh_start: refresh_start,
            source_retention:
              source_retention || registry_retention_label(registry_windows, source)
          }
        end

      {:error, _} ->
        []
    end
  end

  # In-DB retention policy comparison already decided it.
  defp hazard?(true, _refresh_start, _registry_days), do: true
  # No in-DB policy and not a registry table: nothing drops raw -> no hazard.
  defp hazard?(false, _refresh_start, nil), do: false
  # Registry table under the fence: compare against the configured hot window.
  defp hazard?(false, refresh_start, registry_days) do
    case parse_interval_days(refresh_start) do
      nil -> false
      refresh_days -> refresh_days >= registry_days
    end
  end

  defp registry_retention_label(windows, source) do
    case Map.get(windows, source) do
      nil -> nil
      days -> "#{days} days (configured hot window)"
    end
  end

  # Timescale renders these configs like "32 days" / "10:00:00" / "7 days 00:00:00".
  defp parse_interval_days(value) when is_binary(value) do
    case Regex.run(~r/(\d+)\s*day/, value) do
      [_, days] -> String.to_integer(days)
      # sub-day intervals can never reach past a >=1 day retention window
      nil -> 0
    end
  end

  defp parse_interval_days(_), do: nil

  @doc """
  Widen under-retained continuous-aggregate windows to what a cold-tier
  deployment needs (design task 2.8).

  This runs from the retention worker rather than from a migration on purpose.
  Widening a rollup's retention costs storage on EVERY deployment, and the
  reason to pay it only exists once raw history is being served from the cold
  tier -- so it is gated on `Config.enabled?/0` and follows the flag instead of
  being a one-way schema change that every operator inherits.

  Deliberately asymmetric -- it only ever WIDENS:

    * cold tier enabled, current window shorter than the target -> widen;
    * cold tier disabled -> returns immediately, touching nothing. A window
      widened by an earlier enabled period STAYS widened: shrinking it back
      would DELETE the materialized history between the two windows, and a
      flag toggle must never be a data-deletion event. An operator who wants
      that storage back narrows the policy by hand (see the cold-tier runbook);
    * no retention policy on the CAGG at all -> left alone. Installing one
      would delete everything past the window, which is the opposite of what
      this is for;
    * CAGG absent, or TimescaleDB absent -> skipped.

  Only touches the policy when the window actually differs. That is not just
  an optimisation: `add_retention_policy` resets the job's `next_start`, so
  re-adding it on every hourly worker pass would push the retention job's next
  run past the worker's own period and it would never fire.
  """
  @spec reconcile_cagg_windows(keyword()) :: :ok
  def reconcile_cagg_windows(opts \\ []) do
    if Config.enabled?() do
      repo = Keyword.get(opts, :repo, Repo)

      Enum.each(@cagg_cold_windows, fn {view, target_days} ->
        case current_cagg_window(repo, view, target_days) do
          {:ok, current, false} -> widen_cagg_window(repo, view, current, target_days)
          _ -> :ok
        end
      end)
    else
      :ok
    end
  end

  # {:ok, rendered_window, at_or_above_target?} | :skip
  #
  # `timescaledb_information.jobs` records a CAGG's retention policy against its
  # materialization hypertable, not the user-facing view, so the join accepts
  # either name -- the documented `continuous_aggregates` view supplies both and
  # this stays correct whichever one the running TimescaleDB uses.
  defp current_cagg_window(repo, view, target_days) do
    sql = """
    SELECT j.config->>'drop_after',
           (j.config->>'drop_after')::interval >= make_interval(days => $2::int)
    FROM timescaledb_information.continuous_aggregates ca
    LEFT JOIN timescaledb_information.jobs j
      ON j.proc_name = 'policy_retention'
     AND j.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
     AND j.hypertable_name IN (ca.materialization_hypertable_name, ca.view_name)
    WHERE ca.view_schema = 'platform'
      AND ca.view_name = $1
    LIMIT 1
    """

    case SQL.query(repo, sql, [view, target_days], timeout: @query_timeout_ms) do
      # CAGG present with a retention policy.
      {:ok, %{rows: [[current, at_target]]}} when is_binary(current) ->
        {:ok, current, at_target}

      # CAGG present, no retention policy -- see the doc: never install one.
      {:ok, %{rows: [[nil, _]]}} ->
        :skip

      # CAGG absent on this deployment.
      {:ok, %{rows: []}} ->
        :skip

      # No TimescaleDB, or the catalog is unreadable. Failing to widen is the
      # conservative direction (nothing is dropped that would not already have
      # been), so unlike the drop gate this skips quietly rather than holding.
      {:error, _} ->
        :skip
    end
  end

  defp widen_cagg_window(repo, view, current, target_days) do
    sql = """
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      EXECUTE format(
        'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
        ts_schema,
        'platform.#{view}'
      );

      EXECUTE format(
        'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{target_days} days'', if_not_exists => true)',
        ts_schema,
        'platform.#{view}'
      );
    END;
    $$;
    """

    case SQL.query(repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _} ->
        Logger.info(
          "Cold tier enabled: widened continuous-aggregate retention on #{view} " <>
            "from #{current} to #{target_days} days",
          view: view
        )

        :ok

      {:error, error} ->
        Logger.warning("Cold tier: could not widen continuous-aggregate retention",
          view: view,
          reason: Exception.message(error)
        )

        :ok
    end
  end

  @doc """
  Registry tables carrying invalidation-log entries older than their hot
  boundary — pending "loaded gun" ranges that a covering refresh would
  consume by deleting materialized CAGG history. Alert-only signal.
  """
  @spec stale_invalidations(keyword()) :: [%{table: String.t(), entries: non_neg_integer()}]
  def stale_invalidations(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    Enum.flat_map(Registry.tables(), fn entry ->
      cutoff = DateTime.add(DateTime.utc_now(), -Registry.hot_retention_days(entry) * 86_400)

      sql = """
      SELECT count(*)
      FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log l
      JOIN _timescaledb_catalog.hypertable h ON h.id = l.hypertable_id
      WHERE h.schema_name = 'platform'
        AND h.table_name = $1
        AND l.lowest_modified_value <
            (extract(epoch FROM $2::timestamptz) * 1000000)::bigint
      """

      case SQL.query(repo, sql, [entry.table, cutoff], timeout: @query_timeout_ms) do
        {:ok, %{rows: [[count]]}} when count > 0 -> [%{table: entry.table, entries: count}]
        _ -> []
      end
    end)
  end

  defp drift_clamp(repo, table_name, point) do
    {time_column, update_prone} =
      case Registry.fetch(table_name) do
        {:ok, entry} -> {entry.time_column, entry.update_prone}
        :error -> {"timestamp", false}
      end

    # Update-prone tables (ON CONFLICT DO UPDATE — e.g. ocsf_events) mutate rows
    # in place WITHOUT changing the row count, so count-drift can't detect a
    # stale archive (review F03). For those, additionally hold any verified
    # chunk not re-exported within the freshness window. The hourly pre-drop
    # re-verification keeps near-drop update-prone chunks fresh (its throttle is
    # tighter than this window), so a chunk that legitimately reaches the drop
    # point has a recent generation; this bounds the stale-generation exposure
    # to the re-export cadence instead of "any time since first export".
    freshness_clause =
      if update_prone do
        "OR m.verified_at < now() - INTERVAL '#{@update_prone_freshness_hours} hours'"
      else
        ""
      end

    sql = """
    SELECT min(c.range_start)
    FROM timescaledb_information.chunks c
    JOIN platform.cold_chunk_exports m
      ON m.table_name = $1 AND m.chunk_name = c.chunk_name AND m.status = 'verified'
    WHERE c.hypertable_schema = 'platform'
      AND c.hypertable_name = $1
      AND c.range_end <= $2
      AND (
        m.row_count IS DISTINCT FROM (
          SELECT count(*) FROM platform.#{quoted(table_name)} t
          WHERE t.#{quoted(time_column)} >= c.range_start
            AND t.#{quoted(time_column)} < c.range_end
        )
        #{freshness_clause}
      )
    """

    case SQL.query(repo, sql, [table_name, point], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[nil]]}} ->
        {:ok, point}

      {:ok, %{rows: [[first_drifted_start]]}} ->
        Logger.info(
          "Cold tier: drop-time re-verification found drift; clamping drop point for re-export",
          table: table_name,
          clamped_to: inspect(first_drifted_start)
        )

        {:ok, first_drifted_start}

      {:error, error} ->
        Logger.error(
          "Cold tier: drop-time re-verification could not complete; HOLDING all chunks " <>
            "(an unverifiable archive must never authorize deletion)",
          table: table_name,
          reason: Exception.message(error)
        )

        :hold
    end
  end

  defp quoted(name), do: ~s("#{name}")

  # The acked query boundary B for the table, or nil.
  defp acked_boundary(repo, table_name) do
    case SQL.query(
           repo,
           """
           SELECT query_boundary
           FROM platform.cold_tier_boundaries
           WHERE table_name = $1 AND boundary_acked_at IS NOT NULL
           """,
           [table_name],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: [[boundary]]}} -> {:ok, boundary}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  # The end of the contiguous verified chunk prefix at or below the cutoff:
  # equivalently, the start of the first chunk (by range) that is NOT
  # verified. Chunks entirely above the cutoff don't constrain dropping.
  defp contiguous_verified_through(repo, table_name, cutoff) do
    case SQL.query(
           repo,
           """
           SELECT min(c.range_start)
           FROM timescaledb_information.chunks c
           LEFT JOIN platform.cold_chunk_exports m
             ON m.table_name = $1
            AND m.chunk_name = c.chunk_name
            AND m.status = 'verified'
           WHERE c.hypertable_schema = 'platform'
             AND c.hypertable_name = $1
             AND c.range_start < $2
             AND m.id IS NULL
           """,
           [table_name, cutoff],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: [[nil]]}} ->
        # every chunk below the cutoff is verified
        {:ok, cutoff}

      {:ok, %{rows: [[first_unverified_start]]}} ->
        {:ok, first_unverified_start}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:ok, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  defp remove_policy_sql(table_name) do
    """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """
  end

  defp replace_policy_sql(table_name, retention_days) do
    """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{retention_days} days'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not reconcile retention policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """
  end

  defp run_policy_sql(repo, table_name, sql) do
    case SQL.query(repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        # Do NOT swallow to :ok (review F07): a failed policy removal leaves the
        # TimescaleDB retention worker armed on a fenced table, free to drop
        # un-exported chunks. The caller must treat this as a fence breach.
        Logger.error("Cold-tier retention fence: policy DDL failed",
          table: table_name,
          reason: Exception.message(error)
        )

        {:error, {:policy_ddl_failed, table_name, Exception.message(error)}}
    end
  end
end
